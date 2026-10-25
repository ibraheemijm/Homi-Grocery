// النسخ الاحتياطي والاستعادة: لا يستبدل قاعدة البيانات قبل فحص النسخة.
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'grocery_database.dart';

class BackupRepository(
    this._database, {
    Future<void> Function()? closeForMaintenance,
    Future<Database> Function()? openRestoredDatabase,
  })  : _closeForMaintenance = closeForMaintenance ?? GroceryDatabase.closeForMaintenance,
        _openRestoredDatabase = openRestoredDatabase ?? GroceryDatabase.open;

  final Database _database;
  final Future<void> Function() _closeForMaintenance;
  final Future<Database> Function() _openRestoredDatabase;

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
      final versionRows = await candidate.rawQuery('PRAGMA user_version');
      if (versionRows.isEmpty || versionRows.first.isEmpty) {
        throw const FormatException('تعذر قراءة إصدار مخطط قاعدة البيانات.');
      }
      final version = (versionRows.first.values.first as num).toInt();
      if (version < 1 || version > GroceryDatabase.schemaVersion) {
        throw FormatException('إصدار مخطط قاعدة البيانات غير مدعوم: $version');
      }

      final tables = await candidate.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'");
      final names = tables.map((row) => row['name']).whereType<String>().toSet();
      // اسمح بالنسخ القديمة المدعومة؛ ستُرحّل عند فتحها بدل رفضها بسبب جداول أضيفت لاحقًا.
      final required = <String>{'products', 'sales', 'sale_items', 'app_metadata'};
      if (version >= 7) required.add('sale_return_refunds');
      if (version >= 8) required.add('cash_transactions');
      if (version >= 9) {
        required.addAll({'supplier_returns', 'supplier_return_items'});
      }
      if (version >= 11) required.add('supplier_return_refunds');
      if (!names.containsAll(required)) {
        throw const FormatException('الملف لا يحتوي على جداول قاعدة Homi Grocery المتوقعة لإصداره.');
      }
      if (version >= 10) {
        final saleItemColumns = await candidate.rawQuery('PRAGMA table_info(sale_items)');
        if (!saleItemColumns.any((column) => column['name'] == 'cost_price')) {
          throw const FormatException('النسخة لا تحتوي على عمود تكلفة الصنف المتوقع لإصدارها.');
        }
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
    var rollbackRecovered = false;
    var restoreCompleted = false;
    await _closeForMaintenance();
    try {
      // لا تنسخ قاعدة البيانات الحية: أغلق اتصال SQLite أولًا لتفادي نسخة غير متسقة.
      if (hadCurrent) {
        await target.copy(rollback.path);
        await validateBackup(rollback.path);
      }
      if (await target.exists()) await target.delete();
      await staged.copy(target.path);
      final restored = await _openRestoredDatabase();
      await _validateOpenedDatabase(restored);
      restoreCompleted = true;
    } catch (_) {
      await GroceryDatabase.closeForMaintenance();
      try {
        if (hadCurrent && await rollback.exists()) {
          // لا تستبدل الملف الحالي بنسخة تراجع لم تجتز فحص السلامة.
          await validateBackup(rollback.path);
          if (await target.exists()) await target.delete();
          await rollback.copy(target.path);
          rollbackRecovered = true;
        } else if (!hadCurrent && await target.exists()) {
          await target.delete();
        }
      } finally {
        // حتى إن فشل التراجع، أعد فتح القاعدة الأصلية إن كانت ما تزال سليمة.
        await _openRestoredDatabase();
      }
      rethrow;
    } finally {
      if (await staged.exists()) await staged.delete();
      // احتفظ بنسخة التراجع إذا تعذر استرجاعها؛ قد تكون آخر نسخة قابلة للإنقاذ.
      if ((restoreCompleted || rollbackRecovered) && await rollback.exists()) {
        await rollback.delete();
      }
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
