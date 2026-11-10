// اختبارات ترحيل مخطط رد النقد v7 دون فقد بيانات المرتجعات السابقة.
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
  });

  tearDown(() async => database.close());

  test('يضيف مخطط رد النقد إلى قاعدة v6 دون فقد الفواتير والمرتجعات', () async {
    final saleId = await database.insert('sales', {
      'invoice_number': 'REFUND-MIGRATION-001',
      'customer_name': null,
      'subtotal': 250,
      'discount': 0,
      'total': 250,
      'paid_amount': 250,
      'payment_method': 'نقدي',
      'created_at': '2026-02-01T00:00:00.000Z',
    });
    final returnId = await database.insert('sale_returns', {
      'sale_id': saleId,
      'amount': 50,
      'note': 'مرتجع سابق',
      'created_at': '2026-02-02T00:00:00.000Z',
    });

    await GroceryDatabase.createSaleReturnRefundsSchema(database);

    final sale = (await database.query('sales', where: 'id = ?', whereArgs: [saleId])).single;
    final saleReturn = (await database.query('sale_returns', where: 'id = ?', whereArgs: [returnId])).single;
    final table = await database.rawQuery("""
      SELECT name FROM sqlite_master
      WHERE type = 'table' AND name = 'sale_return_refunds'
    """);

    expect(sale['invoice_number'], 'REFUND-MIGRATION-001');
    expect(saleReturn['amount'], 50);
    expect(table, hasLength(1));
  });

  test('يمكن إعادة تطبيق مخطط رد النقد دون تكرار الجدول أو الفهرس', () async {
    await GroceryDatabase.createSaleReturnRefundsSchema(database);
    await expectLater(GroceryDatabase.createSaleReturnRefundsSchema(database), completes);
    final indexes = await database.rawQuery("""
      SELECT name FROM sqlite_master
      WHERE type = 'index' AND name = 'idx_sale_return_refunds_sale'
    """);
    expect(indexes, hasLength(1));
  });
}
