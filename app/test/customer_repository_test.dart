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
    await GroceryDatabase.createCostOfGoodsSchema(database);
    await GroceryDatabase.createCustomersSchema(database);
    await GroceryDatabase.createStockMovementsSchema(database);
    await GroceryDatabase.createSalesReturnsSchema(database);
    await GroceryDatabase.createCashTransactionsSchema(database);
    await GroceryDatabase.createSaleReturnRefundsSchema(database);
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
    final cashEntries = await database.query('cash_transactions', where: "reference_type = 'customer_payment'");
    expect(cashEntries, hasLength(1));
    expect(cashEntries.single['amount'], 300);
    expect(cashEntries.single['direction'], 'in');
    final after = (await customers.balances()).single;
    expect(after.totalPaid, 300);
    expect(after.balance, 500);
  });

  test('يخصم مرتجع البيع من رصيد الزبون ومن حد التحصيل', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'أرز', sellingPrice: 1000, stockQuantity: 5,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 0,
      paidAmount: 0,
      paymentMethod: 'آجل',
      customerName: 'سارة',
    );
    final customer = (await customers.balances()).single;
    final itemId = (await database.query(
      'sale_items',
      columns: ['id'],
      where: 'sale_id = ?',
      whereArgs: [sale.id],
    )).single['id'] as int;

    await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 1},
    );

    expect((await customers.balances()).single.balance, 1000);
    await customers.recordPayment(customerId: customer.id, amount: 1000);
    expect((await customers.balances()).single.balance, 0);
    await expectLater(
      customers.recordPayment(customerId: customer.id, amount: 1),
      throwsArgumentError,
    );
  });

  test('يعرض رد النقد الفعلي كحركة مستقلة في كشف الحساب', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'صابون', sellingPrice: 90, stockQuantity: 3,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 0,
      paidAmount: 180,
      paymentMethod: 'نقدي',
      customerName: 'عميل الرد النقدي',
    );
    final customer = (await customers.balances()).single;
    final itemId = (await database.query(
      'sale_items', columns: ['id'], where: 'sale_id = ?', whereArgs: [sale.id],
    )).single['id'] as int;
    await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 1},
      note: 'مرتجع مدفوع',
    );
    await sales.recordReturnRefund(
      saleId: sale.id, amount: 90, note: 'تم تسليم النقد',
    );

    final ledger = await customers.ledger(customer.id);
    final refund = ledger.singleWhere((entry) => entry.title == 'رد نقدي للزبون');
    expect(refund.amount, 90);
    expect(refund.isCredit, isFalse);
    expect(refund.note, 'تم تسليم النقد');
    expect((await customers.balances()).single.balance, 0);
  });

  test('يعرض كشف الحساب الفواتير والمرتجعات والتحصيلات بترتيب زمني', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'سكر', sellingPrice: 100, stockQuantity: 5,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 0,
      paidAmount: 0,
      paymentMethod: 'آجل',
      customerName: 'خالد',
    );
    final customer = (await customers.balances()).single;
    final itemId = (await database.query(
      'sale_items',
      columns: ['id'],
      where: 'sale_id = ?',
      whereArgs: [sale.id],
    )).single['id'] as int;

    await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 1},
      note: 'إرجاع عبوة',
    );
    await customers.recordPayment(
      customerId: customer.id,
      amount: 100,
      note: 'تحصيل نقدي',
    );

    final ledger = await customers.ledger(customer.id);
    expect(ledger.length, 3);
    expect(ledger[0].title, contains('فاتورة'));
    expect(ledger[0].isCredit, isFalse);
    expect(ledger[1].title, contains('مرتجع'));
    expect(ledger[1].isCredit, isTrue);
    expect(ledger[1].note, 'إرجاع عبوة');
    expect(ledger[2].title, 'تحصيل من الزبون');
    expect(ledger[2].isCredit, isTrue);
    expect((await customers.balances()).single.balance, 0);
  });

  test('مرتجع فاتورة مدفوعة بالكامل لا يمحو دين فاتورة أخرى', () async {
    final paidProductId = await products.add(const GroceryProduct(
      name: 'جهاز مدفوع', sellingPrice: 2000, stockQuantity: 3,
    ));
    final debtProductId = await products.add(const GroceryProduct(
      name: 'صنف آجل', sellingPrice: 500, stockQuantity: 3,
    ));
    final customerName = 'عميل متعدد الفواتير';
    final paidProduct = (await products.getById(paidProductId))!;
    final debtProduct = (await products.getById(debtProductId))!;

    final paidSale = await sales.createSale(
      lines: [SaleLine(product: paidProduct, quantity: 1)],
      discount: 0,
      paidAmount: 2000,
      paymentMethod: 'نقدي',
      customerName: customerName,
    );
    await sales.createSale(
      lines: [SaleLine(product: debtProduct, quantity: 1)],
      discount: 0,
      paidAmount: 0,
      paymentMethod: 'آجل',
      customerName: customerName,
    );
    final customer = (await customers.balances()).single;
    final paidItemId = (await database.query(
      'sale_items',
      columns: ['id'],
      where: 'sale_id = ?',
      whereArgs: [paidSale.id],
    )).single['id'] as int;

    await sales.returnItems(
      saleId: paidSale.id,
      quantitiesBySaleItemId: {paidItemId: 1},
      note: 'إرجاع فاتورة مدفوعة',
    );

    final afterReturn = (await customers.balances()).single;
    expect(afterReturn.totalDebt, 500);
    expect(afterReturn.balance, 500);
    await customers.recordPayment(customerId: customer.id, amount: 500);
    expect((await customers.balances()).single.balance, 0);
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
