import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:homi_grocery/data/backup_repository.dart';
import 'package:homi_grocery/data/grocery_database.dart';

void main() {
  late Directory directory;
  late Database database;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('homi-backup-test-');
    database = await databaseFactoryFfi.openDatabase('${directory.path}/source.db', options: OpenDatabaseOptions(version: 11));
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createSalesSchema(database);
    await GroceryDatabase.createCustomersSchema(database);
    await GroceryDatabase.createStockMovementsSchema(database);
    await GroceryDatabase.createSalesReturnsSchema(database);
    await GroceryDatabase.createPurchasesSchema(database);
    await GroceryDatabase.createSaleReturnRefundsSchema(database);
    await GroceryDatabase.createCashTransactionsSchema(database);
    await GroceryDatabase.createSupplierReturnsSchema(database);
    await GroceryDatabase.createCostOfGoodsSchema(database);
    await GroceryDatabase.createSupplierReturnRefundsSchema(database);
    await database.insert('products', {'name': 'سكر', 'purchase_price': 100, 'selling_price': 150, 'stock_quantity': 12, 'created_at': DateTime.now().toUtc().toIso8601String()});
  });
  tearDown(() async { if (database.isOpen) await database.close(); await directory.delete(recursive: true); });

  test('يعرض النسخ المحلية السليمة من الأحدث ويتجاهل الملفات غير المدارة', () async {
    final backupsDir = Directory('${directory.path}/managed-backups');
    await backupsDir.create();
    final older = File('${backupsDir.path}/homi-grocery-older.db');
    final newer = File('${backupsDir.path}/homi-grocery-newer.db');
    final unrelated = File('${backupsDir.path}/notes.db');
    final corrupt = File('${backupsDir.path}/homi-grocery-corrupt.db');
    await database.execute("VACUUM INTO '${older.path}'");
    await database.execute("VACUUM INTO '${newer.path}'");
    await older.setLastModified(DateTime.utc(2020, 1, 1));
    await newer.setLastModified(DateTime.utc(2021, 1, 1));
    await unrelated.writeAsString('not a backup');
    await corrupt.writeAsString('not a sqlite database');

    final repository = BackupRepository(
      database,
      resolveBackupDirectory: () async => backupsDir,
    );
    final backups = await repository.listBackups();

    expect(backups.map((file) => file.path).toList(), [newer.path, older.path]);
  });

  test('يسمح بحذف نسخة مدارة فقط ويرفض المسارات الخارجية', () async {
    final backupsDir = Directory('${directory.path}/managed-backups');
    await backupsDir.create();
    final backup = File('${backupsDir.path}/homi-grocery-test.db');
    await database.execute("VACUUM INTO '${backup.path}'");
    final unrelated = File('${directory.path}/important.db');
    await database.execute("VACUUM INTO '${unrelated.path}'");

    final repository = BackupRepository(
      database,
      resolveBackupDirectory: () async => backupsDir,
    );
    await expectLater(
      repository.deleteBackup(unrelated.path),
      throwsA(isA<ArgumentError>()),
    );
    expect(await unrelated.exists(), isTrue);

    await repository.deleteBackup(backup.path);
    expect(await backup.exists(), isFalse);
  });

  test('يفحص نسخة SQLite سليمة ويقرأ بياناتها', () async {
    final path = '${directory.path}/backup.db';
    await database.execute("VACUUM INTO '$path'");
    await BackupRepository(database).validateBackup(path);
    final copy = await databaseFactoryFfi.openDatabase(path);
    final rows = await copy.query('products');
    expect(rows.single['name'], 'سكر');
    expect(rows.single['stock_quantity'], 12);
    await copy.close();
  });

  test('يقبل نسخة إصدار 1 التي لا تحتوي بعد على جداول المبيعات', () async {
    final path = '${directory.path}/legacy-v1.db';
    final legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 1),
    );
    await GroceryDatabase.createSchema(legacy);
    await legacy.close();

    await BackupRepository(database).validateBackup(path);
  });

  test('يقبل نسخة قديمة مدعومة قبل إضافة سجل الخزينة', () async {
    final path = '${directory.path}/legacy-v7.db';
    final legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 7),
    );
    await GroceryDatabase.createSchema(legacy);
    await GroceryDatabase.createSalesSchema(legacy);
    await GroceryDatabase.createCustomersSchema(legacy);
    await GroceryDatabase.createStockMovementsSchema(legacy);
    await GroceryDatabase.createSalesReturnsSchema(legacy);
    await GroceryDatabase.createPurchasesSchema(legacy);
    await GroceryDatabase.createSaleReturnRefundsSchema(legacy);
    await legacy.execute('PRAGMA user_version = 7');
    await legacy.close();

    await BackupRepository(database).validateBackup(path);
  });




  test('يرفض نسخة إصدار 12 إذا غاب جدول سجل الموافقات', () async {
    final path = '${directory.path}/missing-approval-table-v12.db';
    await GroceryDatabase.createNotificationsSchema(database);
    await database.execute('PRAGMA user_version = 12');
    await database.execute("VACUUM INTO '$path'");

    final copy = await databaseFactoryFfi.openDatabase(path);
    await copy.execute('DROP TABLE delivery_publication_approvals');
    await copy.close();

    await expectLater(
      BackupRepository(database).validateBackup(path),
      throwsA(isA<FormatException>()),
    );
  });

  test('يرفض نسخة إصدار 12 إذا غاب جدول الإشعارات', () async {
    final path = '${directory.path}/missing-notifications-v12.db';
    await GroceryDatabase.createNotificationsSchema(database);
    await database.execute('PRAGMA user_version = 12');
    await database.execute("VACUUM INTO '$path'");

    final copy = await databaseFactoryFfi.openDatabase(path);
    await copy.execute('DROP TABLE local_notifications');
    await copy.close();

    await expectLater(
      BackupRepository(database).validateBackup(path),
      throwsA(isA<FormatException>()),
    );
  });

  test('يستعيد نسخة إصدار 1 ويرحّلها إلى المخطط الحالي دون فقد بياناتها', () async {
    final backupPath = '${directory.path}/restore-legacy-v1.db';
    final legacy = await databaseFactoryFfi.openDatabase(
      backupPath,
      options: OpenDatabaseOptions(version: 1),
    );
    await GroceryDatabase.createSchema(legacy);
    await legacy.insert('products', {
      'name': 'سكر قديم',
      'purchase_price': 80,
      'selling_price': 120,
      'stock_quantity': 7,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await legacy.close();
    await database.update('products', {'name': 'طحين'});

    final targetPath = database.path;
    final repository = BackupRepository(
      database,
      closeForMaintenance: () async {
        if (database.isOpen) await database.close();
      },
      openRestoredDatabase: () async {
        database = await databaseFactoryFfi.openDatabase(
          targetPath,
          options: OpenDatabaseOptions(
            version: GroceryDatabase.schemaVersion,
            onUpgrade: (db, oldVersion, newVersion) async {
              if (oldVersion < 2) await GroceryDatabase.createSalesSchema(db);
              if (oldVersion < 3) await GroceryDatabase.createCustomersSchema(db);
              if (oldVersion < 4) await GroceryDatabase.createStockMovementsSchema(db);
              if (oldVersion < 5) await GroceryDatabase.createSalesReturnsSchema(db);
              if (oldVersion < 6) await GroceryDatabase.createPurchasesSchema(db);
              if (oldVersion < 7) await GroceryDatabase.createSaleReturnRefundsSchema(db);
              if (oldVersion < 8) await GroceryDatabase.createCashTransactionsSchema(db);
              if (oldVersion < 9) await GroceryDatabase.createSupplierReturnsSchema(db);
              if (oldVersion < 10) await GroceryDatabase.createCostOfGoodsSchema(db);
              if (oldVersion < 11) await GroceryDatabase.createSupplierReturnRefundsSchema(db);
              await db.insert(
                'app_metadata',
                {'key': 'schema_version', 'value': newVersion.toString()},
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
            },
          ),
        );
        return database;
      },
    );

    await repository.restoreBackup(backupPath);

    final products = await database.query('products');
    expect(products.single['name'], 'سكر قديم');
    expect(products.single['stock_quantity'], 7);
    final tables = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final names = tables.map((row) => row['name']).whereType<String>().toSet();
    expect(names, contains('sales'));
    expect(names, contains('supplier_return_refunds'));
  });

  test('يعيد النسخة السليمة ويستبدل البيانات الحالية بالبيانات المحفوظة', () async {
    final backupPath = '${directory.path}/restore-source.db';
    await database.execute("VACUUM INTO '$backupPath'");
    await database.update('products', {'name': 'طحين'});

    final targetPath = database.path;
    final repository = BackupRepository(
      database,
      closeForMaintenance: () async {
        if (database.isOpen) await database.close();
      },
      openRestoredDatabase: () async {
        database = await databaseFactoryFfi.openDatabase(
          targetPath,
          options: OpenDatabaseOptions(version: 11),
        );
        return database;
      },
    );

    await repository.restoreBackup(backupPath);

    final rows = await database.query('products');
    expect(rows.single['name'], 'سكر');
    expect(rows.single['stock_quantity'], 12);
  });

  test('يحافظ على البيانات الحالية ويعيد فتح القاعدة إذا فشل فتح النسخة المستعادة', () async {
    final backupPath = '${directory.path}/restore-source-failure.db';
    await database.execute("VACUUM INTO '$backupPath'");
    await database.update('products', {'name': 'طحين'});

    final targetPath = database.path;
    var openAttempts = 0;
    final repository = BackupRepository(
      database,
      closeForMaintenance: () async {
        if (database.isOpen) await database.close();
      },
      openRestoredDatabase: () async {
        openAttempts++;
        if (openAttempts == 1) {
          throw StateError('محاكاة فشل فتح النسخة المستعادة');
        }
        database = await databaseFactoryFfi.openDatabase(
          targetPath,
          options: OpenDatabaseOptions(version: 11),
        );
        return database;
      },
    );

    await expectLater(
      repository.restoreBackup(backupPath),
      throwsA(isA<StateError>()),
    );

    expect(openAttempts, 2);
    expect(database.isOpen, isTrue);
    final rows = await database.query('products');
    expect(rows.single['name'], 'طحين');
    expect(rows.single['stock_quantity'], 12);
  });

  test('يستعيد النسخة الأصلية إذا رمى إغلاق القاعدة خطأ أثناء مسار التراجع', () async {
    final backupPath = '${directory.path}/restore-rollback-close-failure.db';
    await database.execute("VACUUM INTO '$backupPath'");
    await database.update('products', {'name': 'طحين'});

    final targetPath = database.path;
    var closeAttempts = 0;
    var openAttempts = 0;
    final repository = BackupRepository(
      database,
      closeForMaintenance: () async {
        closeAttempts++;
        if (database.isOpen) await database.close();
        if (closeAttempts == 2) {
          throw StateError('محاكاة خطأ إغلاق أثناء التراجع بعد إغلاق الاتصال');
        }
      },
      openRestoredDatabase: () async {
        openAttempts++;
        if (openAttempts == 1) {
          throw StateError('محاكاة فشل فتح النسخة الجديدة');
        }
        database = await databaseFactoryFfi.openDatabase(
          targetPath,
          options: OpenDatabaseOptions(version: 11),
        );
        return database;
      },
    );

    await expectLater(
      repository.restoreBackup(backupPath),
      throwsA(isA<StateError>()),
    );

    expect(closeAttempts, 2);
    expect(openAttempts, 2);
    expect(database.isOpen, isTrue);
    final rows = await database.query('products');
    expect(rows.single['name'], 'طحين');
    expect(rows.single['stock_quantity'], 12);
  });

  test('يتراجع إذا فشل فحص المخطط بعد فتح قاعدة البيانات المستعادة', () async {
    final backupPath = '${directory.path}/restore-post-open-check.db';
    await database.execute("VACUUM INTO '$backupPath'");
    await database.update('products', {'name': 'طحين'});

    final targetPath = database.path;
    final invalidOpenedPath = '${directory.path}/opened-but-incomplete.db';
    var openAttempts = 0;
    final repository = BackupRepository(
      database,
      closeForMaintenance: () async {
        if (database.isOpen) await database.close();
      },
      openRestoredDatabase: () async {
        openAttempts++;
        if (openAttempts == 1) {
          database = await databaseFactoryFfi.openDatabase(
            invalidOpenedPath,
            options: OpenDatabaseOptions(
              version: 13,
              onCreate: (db, version) async {
                await db.execute(
                  'CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT)',
                );
              },
            ),
          );
          return database;
        }
        database = await databaseFactoryFfi.openDatabase(
          targetPath,
          options: OpenDatabaseOptions(version: 13),
        );
        return database;
      },
    );

    await expectLater(
      repository.restoreBackup(backupPath),
      throwsA(isA<FormatException>()),
    );

    expect(openAttempts, 2);
    expect(database.isOpen, isTrue);
    final rows = await database.query('products');
    expect(rows.single['name'], 'طحين');
  });
  test('يرفض استعادة ملف غير صالح ويحافظ على قاعدة البيانات الحالية', () async {
    final invalid = File('${directory.path}/invalid-restore.db');
    await invalid.writeAsString('not a sqlite database');
    await database.update('products', {'name': 'طحين'});

    await expectLater(
      BackupRepository(database).restoreBackup(invalid.path),
      throwsA(isA<FormatException>()),
    );

    expect(database.isOpen, isTrue);
    final rows = await database.query('products');
    expect(rows.single['name'], 'طحين');
    expect(rows.single['stock_quantity'], 12);
  });

  test('ينظف ملف الاستعادة المؤقت إذا فشل إغلاق القاعدة قبل الاستعادة', () async {
    final backupPath = '${directory.path}/restore-close-failure.db';
    await database.execute("VACUUM INTO '$backupPath'");
    final targetPath = database.path;
    var closeAttempts = 0;

    final repository = BackupRepository(
      database,
      closeForMaintenance: () async {
        closeAttempts++;
        if (database.isOpen) await database.close();
        if (closeAttempts == 1) {
          throw StateError('محاكاة فشل إعداد الصيانة بعد إغلاق الاتصال');
        }
      },
      openRestoredDatabase: () async {
        database = await databaseFactoryFfi.openDatabase(
          targetPath,
          options: OpenDatabaseOptions(version: 11),
        );
        return database;
      },
    );

    await expectLater(
      repository.restoreBackup(backupPath),
      throwsA(isA<StateError>()),
    );

    expect(database.isOpen, isTrue);
    expect((await database.query('products')).single['name'], 'سكر');
    final temporaryFiles = directory
        .listSync()
        .whereType<File>()
        .where((file) =>
            file.uri.pathSegments.last.startsWith('.homi-restore-') ||
            file.uri.pathSegments.last.startsWith('.homi-rollback-'));
    expect(temporaryFiles, isEmpty);
  });

  test('يرفض نسخة تحتوي على مرجع مفتاح خارجي مكسور', () async {
    final path = '${directory.path}/broken-foreign-key.db';
    await database.execute('PRAGMA foreign_keys = OFF');
    await database.insert('sale_items', {
      'sale_id': 999999,
      'product_id': 1,
      'product_name': 'سكر',
      'unit': 'حبة',
      'quantity': 1,
      'unit_price': 150,
      'line_total': 150,
    });
    await database.execute("VACUUM INTO '$path'");

    await expectLater(
      BackupRepository(database).validateBackup(path),
      throwsA(isA<FormatException>()),
    );
  });

  test('يرفض ملفًا غير صالح كنسخة احتياطية', () async {
    final invalid = File('${directory.path}/invalid.db');
    await invalid.writeAsString('not a sqlite database');
    await expectLater(BackupRepository(database).validateBackup(invalid.path), throwsA(isA<FormatException>()));
  });
}
