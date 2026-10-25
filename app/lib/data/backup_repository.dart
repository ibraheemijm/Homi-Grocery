// النسخ الاحتياطي والاستعادة: لا يستبدل قاعدة البيانات قبل فحص النسخة.
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'grocery_database.dart';

class BackupRepository {
  BackupRepository(this._database);
  final Database _database;

  Future<Directory> backupDirectory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'backups'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> createBackup() async {
    final directory = await backupDirectory();
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-').replaceAll('.', '-');
    final destination = File(p.join(directory.path, 'homi-grocery-$stamp.db'));
    final escaped = destination.path.replaceAll("'", "''");
    await _database.execute("VACUUM INTO '$escaped'");
    await validateBackup(destination.path);
    return destination;
  }

  Future<void> validateBackup(String path) async {
    final file = File(path);
    if (!await file.exists() || await file.length() < 100) {
      throw const FormatException('ملف النسخة غير موجود أو حجمه غير صالح.');
    }
    Database? candidate;
    try {
      candidate = await databaseFactory.openDatabase(path);
      final integrity = await candidate.rawQuery('PRAGMA integrity_check');
      if (integrity.isEmpty || integrity.first.values.first != 'ok') {
        throw const FormatException('فشل فحص سلامة قاعدة البيانات.');
      }
      final tables = await candidate.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'");
      final names = tables.map((row) => row['name']).whereType<String>().toSet();
      const required = {'products', 'sales', 'sale_items', 'cash_transactions', 'app_metadata'};
      if (!names.containsAll(required)) {
        throw const FormatException('الملف ليس نسخة كاملة من قاعدة Homi Grocery.');
      }
      final versionRows = await candidate.rawQuery('PRAGMA user_version');
      final version = (versionRows.first.values.first as num).toInt();
      if (version < 1 || version > GroceryDatabase.schemaVersion) {
        throw FormatException('إصدار مخطط قاعدة البيانات غير مدعوم: $version');
      }
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('تعذر فتح النسخة الاحتياطية أو فحصها.');
    } finally {
      await candidate?.close();
    }
  }

  Future<void> restoreBackup(String sourcePath) async {
    final source = File(sourcePath);
    final targetPath = _database.path;
    if (p.equals(p.normalize(source.absolute.path), p.normalize(File(targetPath).absolute.path))) {
      throw ArgumentError('اختر ملف نسخة احتياطية، وليس قاعدة البيانات الحالية.');
    }
    await validateBackup(source.path);
    final target = File(targetPath);
    final parent = target.parent;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final staged = File(p.join(parent.path, '.homi-restore-$stamp.db'));
    final rollback = File(p.join(parent.path, '.homi-rollback-$stamp.db'));
    await source.copy(staged.path);
    final hadCurrent = await target.exists();
    if (hadCurrent) await target.copy(rollback.path);
    await GroceryDatabase.closeForMaintenance();
    try {
      if (await target.exists()) await target.delete();
      await staged.copy(target.path);
      final restored = await GroceryDatabase.open();
      await _validateOpenedDatabase(restored);
      if (await rollback.exists()) await rollback.delete();
    } catch (_) {
      await GroceryDatabase.closeForMaintenance();
      if (hadCurrent && await rollback.exists()) {
        if (await target.exists()) await target.delete();
        await rollback.copy(target.path);
      }
      await GroceryDatabase.open();
      rethrow;
    } finally {
      if (await staged.exists()) await staged.delete();
      if (await rollback.exists()) await rollback.delete();
    }
  }

  Future<void> _validateOpenedDatabase(Database database) async {
    final result = await database.rawQuery('PRAGMA integrity_check');
    if (result.isEmpty || result.first.values.first != 'ok') {
      throw const FormatException('قاعدة البيانات المستعادة لم تجتز فحص السلامة.');
    }
    final rows = await database.rawQuery('SELECT COUNT(*) AS count FROM products');
    if (rows.isEmpty || rows.first['count'] == null) {
      throw const FormatException('تعذر التحقق من بيانات الأصناف بعد الاستعادة.');
    }
  }
}
