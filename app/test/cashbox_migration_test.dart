import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/grocery_database.dart';

void main() {
  late Database database;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createSalesSchema(database);
    await GroceryDatabase.createCustomersSchema(database);
    await GroceryDatabase.createStockMovementsSchema(database);
    await GroceryDatabase.createSalesReturnsSchema(database);
    await GroceryDatabase.createPurchasesSchema(database);
    await GroceryDatabase.createSaleReturnRefundsSchema(database);
    await database.insert('products', {
      'name': 'صنف قديم',
      'unit': 'حبة',
      'purchase_price': 50,
      'selling_price': 100,
      'stock_quantity': 4,
      'minimum_quantity': 0,
      'is_active': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  });

  tearDown(() async => database.close());

  test('يضيف مخطط الخزينة v8 دون حذف بيانات الأصناف ويقبل إعادة التطبيق', () async {
    await GroceryDatabase.createCashTransactionsSchema(database);
    await GroceryDatabase.createCashTransactionsSchema(database);

    final products = await database.query('products');
    final tables = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'cash_transactions'",
    );
    final indexes = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_cash_transactions_created'",
    );

    expect(products, hasLength(1));
    expect(products.single['name'], 'صنف قديم');
    expect(tables, hasLength(1));
    expect(indexes, hasLength(1));
  });
}
