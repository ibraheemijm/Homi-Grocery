// اختبارات دفتر ديون الزبائن والتحصيلات المالية.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/customer_repository.dart';
import 'package:homi_grocery/data/grocery_database.dart';
import 'package:homi_grocery/data/product_repository.dart';
import 'package:homi_grocery/data/sale_repository.dart';

void main() {
  late Database database;
  late CustomerRepository customers;
  late ProductRepository products;
  late SaleRepository sales;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createSalesSchema(database);
    await GroceryDatabase.createCustomersSchema(database);
    await GroceryDatabase.createStockMovementsSchema(database);
    customers = CustomerRepository(database);
    products = ProductRepository(database);
    sales = SaleRepository(database);
  });

  tearDown(() async => database.close());

  test('يسجل التحصيل ويخفض الرصيد المستحق بدقة', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'أرز', sellingPrice: 1000, stockQuantity: 5,
    ));
    final product = (await products.getById(productId))!;
    await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 0,
      paidAmount: 1200,
      paymentMethod: 'جزئي',
      customerName: 'أحمد',
    );

    final before = (await customers.balances()).single;
    expect(before.name, 'أحمد');
    expect(before.totalDebt, 800);
    expect(before.balance, 800);

    await customers.recordPayment(customerId: before.id, amount: 300, note: 'تحصيل نقدي');
    final after = (await customers.balances()).single;
    expect(after.totalPaid, 300);
    expect(after.balance, 500);
  });

  test('يرفض التحصيل الذي يتجاوز الرصيد دون تسجيله', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'دقيق', sellingPrice: 200, stockQuantity: 4,
    ));
    final product = (await products.getById(productId))!;
    await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 0,
      paidAmount: 0,
      paymentMethod: 'آجل',
      customerName: 'منى',
    );
    final customer = (await customers.balances()).single;

    await expectLater(
      customers.recordPayment(customerId: customer.id, amount: 201),
      throwsArgumentError,
    );
    expect((await customers.balances()).single.balance, 200);
  });

  test('يمنع إضافة اسم فارغ', () async {
    await expectLater(
      customers.addCustomer(name: '   '),
      throwsArgumentError,
    );
  });
}
