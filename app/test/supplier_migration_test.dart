// اختبارات ترحيل قاعدة بيانات الإصدار الخامس إلى مخطط الموردين والمشتريات v6.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/grocery_database.dart';

void main() {
  late Database database;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.execute('PRAGMA foreign_keys = ON');
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createSalesSchema(database);
    await GroceryDatabase.createCustomersSchema(database);
    await GroceryDatabase.createStockMovementsSchema(database);
    await GroceryDatabase.createSalesReturnsSchema(database);
  });

  tearDown(() async => database.close());

  test('إضافة مخطط v6 لا تفقد بيانات الأصناف أو المبيعات القديمة', () async {
    final productId = await database.insert('products', {
      'name': 'سكر',
      'purchase_price': 120,
      'selling_price': 160,
      'stock_quantity': 8,
      'created_at': '2026-01-01T00:00:00.000Z',
    });
    final saleId = await database.insert('sales', {
      'invoice_number': 'OLD-SALE-001',
      'customer_name': null,
      'subtotal': 320,
      'discount': 0,
      'total': 320,
      'paid_amount': 320,
      'payment_method': 'نقدي',
      'created_at': '2026-01-02T00:00:00.000Z',
    });

    await GroceryDatabase.createPurchasesSchema(database);

    final product = (await database.query('products', where: 'id = ?', whereArgs: [productId])).single;
    final sale = (await database.query('sales', where: 'id = ?', whereArgs: [saleId])).single;
    final purchaseTables = await database.rawQuery("""
      SELECT name FROM sqlite_master
      WHERE type = 'table'
        AND name IN ('suppliers', 'purchases', 'purchase_items', 'supplier_payments')
    """);

    expect(product['name'], 'سكر');
    expect(product['stock_quantity'], 8);
    expect(sale['invoice_number'], 'OLD-SALE-001');
    expect(sale['total'], 320);
    expect(purchaseTables, hasLength(4));
  });

  test('يمكن إعادة تطبيق مخطط v6 دون تكرار الجداول أو الفهارس', () async {
    await GroceryDatabase.createPurchasesSchema(database);
    await expectLater(GroceryDatabase.createPurchasesSchema(database), completes);
    final indexes = await database.rawQuery("""
      SELECT name FROM sqlite_master
      WHERE type = 'index'
        AND name IN ('idx_purchases_supplier', 'idx_purchase_items_purchase', 'idx_supplier_payments_supplier')
    """);
    expect(indexes, hasLength(3));
  });
}
