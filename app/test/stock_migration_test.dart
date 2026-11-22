// اختبارات توافق مخطط المخزون مع قواعد بيانات الإصدار السابق.
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
  });

  tearDown(() async => database.close());

  test('إضافة مخطط حركات المخزون لا تفقد بيانات الأصناف أو المبيعات', () async {
    final productId = await database.insert('products', {
      'name': 'أرز',
      'stock_quantity': 14,
      'created_at': '2026-01-01T00:00:00.000Z',
    });
    final saleId = await database.insert('sales', {
      'invoice_number': 'MIGRATION-001',
      'customer_name': null,
      'subtotal': 100,
      'discount': 0,
      'total': 100,
      'paid_amount': 100,
      'payment_method': 'نقدي',
      'created_at': '2026-01-02T00:00:00.000Z',
    });

    await GroceryDatabase.createStockMovementsSchema(database);

    final product = (await database.query(
      'products',
      where: 'id = ?',
      whereArgs: [productId],
    )).single;
    final sale = (await database.query(
      'sales',
      where: 'id = ?',
      whereArgs: [saleId],
    )).single;
    final tables = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'stock_movements'",
    );

    expect(product['name'], 'أرز');
    expect(product['stock_quantity'], 14);
    expect(sale['invoice_number'], 'MIGRATION-001');
    expect(sale['total'], 100);
    expect(tables, hasLength(1));
  });

  test('يمكن تهيئة مخطط الحركات أكثر من مرة دون خطأ', () async {
    await GroceryDatabase.createStockMovementsSchema(database);
    await expectLater(
      GroceryDatabase.createStockMovementsSchema(database),
      completes,
    );
  });
}
