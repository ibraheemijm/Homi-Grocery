// إدارة موقع بيانات المتجر ونقلها بأمان على Windows وLinux.
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class AppDataLocation {
  AppDataLocation._();
  static const _databaseName = 'homi_grocery.db';
  static const _configName = 'homi-data-location.txt';
  static const _managedFolder = 'Homi Grocery Data';

  static Future<Directory> _support() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _config() async =>
      File(p.join((await _support()).path, _configName));

  /// لا يرجع إلى قاعدة افتراضية فارغة إذا تعذر الوصول إلى القرص المحدد.
  static Future<Directory> resolveDataDirectory() async {
    final file = await _config();
    if (!await file.exists()) return _support();
    final value = (await file.readAsString()).trim();
    if (value.isEmpty || !p.isAbsolute(value)) {
      throw const FormatException('مسار بيانات Homi المحفوظ غير صالح.');
    }
    final dir = Directory(p.normalize(value));
    if (!await dir.exists()) {
      throw FileSystemException(
        'مجلد بيانات Homi غير متاح. أعد توصيل القرص أو القسم المحدد.',
        dir.path,
      );
    }
    return dir;
  }

  static Future<String> currentPath() async =>
      (await resolveDataDirectory()).absolute.path;

  /// يربط نسخة بيانات موجودة بعد إعادة تثبيت النظام أو فقدان إعداد الموقع.
  /// لا ينسخ قاعدة البيانات الافتراضية فوق النسخة الموجودة ولا يحذف أي ملف.
  static Future<Directory> connectExisting({
    required Database currentDatabase,
    required Future<void> Function() closeDatabase,
    required Future<Database> Function() reopenDatabase,
    required String selectedParentPath,
  }) async {
    if (!Platform.isWindows && !Platform.isLinux) {
      throw UnsupportedError('ربط مجلد بيانات موجود متاح حاليًا على Windows وLinux فقط.');
    }
    final parent = Directory(selectedParentPath.trim());
    if (!p.isAbsolute(parent.path) || !await parent.exists()) {
      throw FileSystemException('اختر المجلد الأب الذي يحتوي بيانات Homi.', parent.path);
    }
    final target = Directory(p.join(parent.absolute.path, _managedFolder));
    final dbPath = p.join(target.path, _databaseName);
    if (!await target.exists() || !await File(dbPath).exists()) {
      throw FileSystemException('لم يتم العثور على قاعدة بيانات Homi في المجلد المحدد.', dbPath);
    }

    Database? candidate;
    try {
      candidate = await databaseFactory.openDatabase(dbPath);
      await candidate.execute('PRAGMA foreign_keys = ON');
      await _verify(candidate);
    } finally {
      if (candidate != null && candidate.isOpen) await candidate.close();
    }

    final previousPath = await currentPath();
    final targetPath = p.normalize(target.absolute.path);
    if (p.equals(p.normalize(previousPath), targetPath)) return target;

    await currentDatabase.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    await closeDatabase();
    var committed = false;
    try {
      await _writeConfig(targetPath);
      committed = true;
      final reopened = await reopenDatabase();
      await _verify(reopened);
      return target;
    } on Object {
      if (committed) await _restoreConfig(previousPath);
      try {
        await reopenDatabase();
      } on Object {
        // تبقى النسخة الموجودة سليمة ولا نحذفها عند تعذر إعادة الفتح.
      }
      rethrow;
    }
  }

  /// ينسخ قاعدة البيانات وملفات الأصناف والخطوط والنسخ الاحتياطية.
  /// يبقي المصدر كما هو بعد النقل ليكون نسخة رجوع آمنة.
  static Future<Directory> migrate({
    required Database currentDatabase,
    required Future<void> Function() closeDatabase,
    required Future<Database> Function() reopenDatabase,
    required String selectedParentPath,
  }) async {
    if (!Platform.isWindows && !Platform.isLinux) {
      throw UnsupportedError('تحديد موقع البيانات متاح حاليًا على Windows وLinux فقط.');
    }
    final parent = Directory(selectedParentPath.trim());
    if (!p.isAbsolute(parent.path) || !await parent.exists()) {
      throw FileSystemException('اختر مجلدًا موجودًا ويمكن الوصول إليه.', parent.path);
    }

    final source = await resolveDataDirectory();
    final target = Directory(p.join(parent.absolute.path, _managedFolder));
    final sourcePath = p.normalize(source.absolute.path);
    final targetPath = p.normalize(target.absolute.path);
    if (p.equals(sourcePath, targetPath)) return source;
    if (p.isWithin(sourcePath, targetPath) || p.isWithin(targetPath, sourcePath)) {
      throw ArgumentError('لا يمكن وضع مجلد البيانات داخل مجلد البيانات الحالي أو العكس.');
    }

    await target.parent.create(recursive: true);
    if (await target.exists() && !(await target.list(followLinks: false).isEmpty)) {
      throw FileSystemException('المجلد الهدف موجود ويحتوي ملفات؛ اختر مجلدًا فارغًا.', target.path);
    }
    await target.create(recursive: true);
    final probe = File(p.join(target.path, '.homi-write-test'));
    try {
      await probe.writeAsString('Homi data location test', flush: true);
      await probe.delete();
    } on Object {
      rethrow;
    }

    await currentDatabase.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    await closeDatabase();
    var committed = false;
    try {
      await _copyContents(source, target);
      final dbPath = p.join(target.path, _databaseName);
      if (!await File(dbPath).exists()) {
        throw const FileSystemException('لم يتم العثور على قاعدة البيانات بعد النسخ.');
      }

      Database? candidate;
      try {
        candidate = await databaseFactory.openDatabase(dbPath);
        await candidate.execute('PRAGMA foreign_keys = ON');
        await _rewritePaths(candidate, sourcePath, targetPath);
        await _verify(candidate);
      } finally {
        if (candidate != null && candidate.isOpen) await candidate.close();
      }

      await _writeConfig(targetPath);
      committed = true;
      final reopened = await reopenDatabase();
      await _verify(reopened);
      return target;
    } on Object {
      if (committed) await _restoreConfig(sourcePath);
      try {
        await reopenDatabase();
      } on Object {
        // يبقى المصدر الأصلي دون حذف ويمكن استعادته يدويًا.
      }
      if (await target.exists()) await target.delete(recursive: true);
      rethrow;
    }
  }

  static Future<void> _copyContents(Directory source, Directory target) async {
    await for (final entity in source.list(recursive: true, followLinks: false)) {
      if (p.basename(entity.path) == _configName) continue;
      final relative = p.relative(entity.path, from: source.path);
      final destination = p.join(target.path, relative);
      if (entity is Directory) {
        await Directory(destination).create(recursive: true);
      } else if (entity is File) {
        await Directory(p.dirname(destination)).create(recursive: true);
        await entity.copy(destination);
      } else if (entity is Link) {
        throw FileSystemException('رابط رمزي غير مدعوم داخل مجلد البيانات.', entity.path);
      }
    }
  }

  static Future<void> _rewritePaths(Database db, String source, String target) async {
    final products = await db.query('products', columns: ['id', 'image_path'],
        where: 'image_path IS NOT NULL');
    for (final row in products) {
      final oldPath = p.normalize(row['image_path'] as String);
      if (!p.isWithin(source, oldPath)) continue;
      await db.update('products',
          {'image_path': p.join(target, p.relative(oldPath, from: source))},
          where: 'id = ?', whereArgs: [row['id']]);
    }

    final fonts = await db.query('app_metadata', columns: ['value'],
        where: 'key = ?', whereArgs: ['imported_font_path'], limit: 1);
    if (fonts.isNotEmpty) {
      final oldPath = p.normalize(fonts.single['value'] as String);
      if (p.isWithin(source, oldPath)) {
        await db.update('app_metadata',
            {'value': p.join(target, p.relative(oldPath, from: source))},
            where: 'key = ?', whereArgs: ['imported_font_path']);
      }
    }
  }

  static Future<void> _verify(Database db) async {
    final integrity = await db.rawQuery('PRAGMA integrity_check');
    if (integrity.isEmpty || integrity.first.values.first != 'ok') {
      throw const FormatException('فشل فحص سلامة قاعدة بيانات Homi بعد النقل.');
    }
    if ((await db.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
      throw const FormatException('توجد علاقات غير سليمة بين الجداول بعد النقل.');
    }
    if ((await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'products'",
    )).isEmpty) {
      throw const FormatException('قاعدة البيانات المنقولة لا تحتوي جدول الأصناف.');
    }
  }

  static Future<void> _writeConfig(String path) async {
    final file = await _config();
    final temp = File('${file.path}.tmp');
    final backup = File('${file.path}.previous');
    await temp.writeAsString(path, flush: true);
    if (await backup.exists()) await backup.delete();
    if (await file.exists()) await file.rename(backup.path);
    try {
      await temp.rename(file.path);
      if (await backup.exists()) await backup.delete();
    } on Object {
      if (await backup.exists() && !await file.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
  }

  static Future<void> _restoreConfig(String source) async {
    final support = await _support();
    if (p.equals(p.normalize(source), p.normalize(support.absolute.path))) {
      final file = await _config();
      if (await file.exists()) await file.delete();
    } else {
      await _writeConfig(source);
    }
  }
}
