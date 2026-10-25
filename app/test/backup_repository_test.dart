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

  test('يرفض ملفًا غير صالح كنسخة احتياطية', () async {
    final invalid = File('${directory.path}/invalid.db');
    await invalid.writeAsString('not a sqlite database');
    await expectLater(BackupRepository(database).validateBackup(invalid.path), throwsA(isA<FormatException>()));
  });
}
