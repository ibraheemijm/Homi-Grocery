// اختبارات إحصاءات اللوحة الرئيسية اعتمادًا على البيانات المحلية.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/customer_repository.dart';
import 'package:homi_grocery/data/dashboard_repository.dart';
import 'package:homi_grocery/data/grocery_database.dart';
import 'package:homi_grocery/data/product_repository.dart';
import 'package:homi_grocery/data/sale_repository.dart';

void main() {
  late Database database;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createSalesSchema(database);
    await GroceryDatabase.createCustomersSchema(database);
  });

  tearDown(() async => database.close());

  test('تحسب المبيعات والمدفوعات والديون والأصناف المنخفضة من قاعدة البيانات', () async {
    final products = ProductRepository(database);
    final sales = SaleRepository(database);
    final customers = CustomerRepository(database);

    final soldId = await products.add(const GroceryProduct(
      name: 'سكر', sellingPrice: 500, stockQuantity: 5,
    ));
    final soldProduct = (await products.getById(soldId))!;
    await sales.createSale(
      lines: [SaleLine(product: soldProduct, quantity: 1)],
      discount: 0,
      paidAmount: 200,
      paymentMethod: 'جزئي',
      customerName: 'زبون اللوحة',
    );
    final customer = (await customers.balances()).single;
    await customers.recordPayment(customerId: customer.id, amount: 100);

    await products.add(const GroceryProduct(
      name: 'حليب منخفض', sellingPrice: 100, stockQuantity: 1, minimumQuantity: 2,
    ));

    final stats = await DashboardRepository(database).load(now: DateTime.now());
    expect(stats.todaySales, 500);
    expect(stats.todayPaid, 200);
    expect(stats.customerDebt, 200);
    expect(stats.lowStockCount, 1);
  });
}
