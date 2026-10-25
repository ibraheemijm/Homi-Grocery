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
  tearDown(() async { await database.close(); await directory.delete(recursive: true); });

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

  test('يرفض ملفًا غير صالح كنسخة احتياطية', () async {
    final invalid = File('${directory.path}/invalid.db');
    await invalid.writeAsString('not a sqlite database');
    await expectLater(BackupRepository(database).validateBackup(invalid.path), throwsA(isA<FormatException>()));
  });
}
