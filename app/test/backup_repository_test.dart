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

  test('يرفض ملفًا غير صالح كنسخة احتياطية', () async {
    final invalid = File('${directory.path}/invalid.db');
    await invalid.writeAsString('not a sqlite database');
    await expectLater(BackupRepository(database).validateBackup(invalid.path), throwsA(isA<FormatException>()));
  });
}
