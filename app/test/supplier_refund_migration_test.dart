// اختبارات ترحيل v11 لإضافة استردادات الموردين دون فقد بيانات الإصدارات السابقة.
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
    await GroceryDatabase.createPurchasesSchema(database);
    await GroceryDatabase.createSaleReturnRefundsSchema(database);
    await GroceryDatabase.createCashTransactionsSchema(database);
    await GroceryDatabase.createSupplierReturnsSchema(database);
    await GroceryDatabase.createCostOfGoodsSchema(database);
  });

  tearDown(() async => database.close());

  test('إضافة مخطط استرداد المورد v11 تحفظ المرتجعات السابقة وتقبل إعادة التطبيق', () async {
    final createdAt = DateTime.utc(2026, 10, 1).toIso8601String();
    final supplierId = await database.insert('suppliers', {
      'name': 'مورد قديم',
      'created_at': createdAt,
    });
    final productId = await database.insert('products', {
      'name': 'صنف قديم',
      'unit': 'حبة',
      'purchase_price': 50,
      'selling_price': 80,
      'stock_quantity': 3,
      'minimum_quantity': 0,
      'is_active': 1,
      'created_at': createdAt,
    });
    final purchaseId = await database.insert('purchases', {
      'invoice_number': 'OLD-PURCHASE-V10',
      'supplier_id': supplierId,
      'subtotal': 100,
      'discount': 0,
      'total': 100,
      'paid_amount': 100,
      'payment_method': 'نقدي',
      'created_at': createdAt,
    });
    final purchaseItemId = await database.insert('purchase_items', {
      'purchase_id': purchaseId,
      'product_id': productId,
      'product_name': 'صنف قديم',
      'unit': 'حبة',
      'quantity': 2,
      'unit_cost': 50,
      'line_total': 100,
    });
    final returnId = await database.insert('supplier_returns', {
      'purchase_id': purchaseId,
      'amount': 50,
      'note': 'مرتجع محفوظ قبل v11',
      'created_at': createdAt,
    });
    await database.insert('supplier_return_items', {
      'return_id': returnId,
      'purchase_item_id': purchaseItemId,
      'product_id': productId,
      'product_name': 'صنف قديم',
      'quantity': 1,
      'unit_cost': 50,
      'line_total': 50,
    });

    await GroceryDatabase.createSupplierReturnRefundsSchema(database);
    await GroceryDatabase.createSupplierReturnRefundsSchema(database);

    final savedReturn = (await database.query(
      'supplier_returns',
      where: 'id = ?',
      whereArgs: [returnId],
    )).single;
    final tables = await database.rawQuery("""
      SELECT name FROM sqlite_master
      WHERE type = 'table' AND name = 'supplier_return_refunds'
    """);
    final indexes = await database.rawQuery("""
      SELECT name FROM sqlite_master
      WHERE type = 'index' AND name = 'idx_supplier_return_refunds_return'
    """);
    final costColumn = await database.rawQuery('PRAGMA table_info(sale_items)');

    expect(savedReturn['amount'], 50);
    expect(savedReturn['note'], 'مرتجع محفوظ قبل v11');
    expect(tables, hasLength(1));
    expect(indexes, hasLength(1));
    expect(costColumn.any((column) => column['name'] == 'cost_price'), isTrue);
    expect(await database.query('supplier_return_items'), hasLength(1));
  });
}
