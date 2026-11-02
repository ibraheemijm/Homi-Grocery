// اختبارات دفتر ديون الزبائن والتحصيلات المالية.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/auth_repository.dart';
import 'package:homi_grocery/data/cash_shift_repository.dart';
import 'package:homi_grocery/data/customer_repository.dart';
import 'package:homi_grocery/data/grocery_database.dart';
import 'package:homi_grocery/data/product_repository.dart';
import 'package:homi_grocery/data/sale_repository.dart';

void main() {
  late Database database;
  late CustomerRepository customers;
  late ProductRepository products;
  late SaleRepository sales;
  late int managerId;
  late AuthUser managerAccount;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createAuthSchema(database);
    await GroceryDatabase.createSalesSchema(database);
    await GroceryDatabase.createCostOfGoodsSchema(database);
    await GroceryDatabase.createCustomersSchema(database);
    await GroceryDatabase.createStockMovementsSchema(database);
    await GroceryDatabase.createSalesReturnsSchema(database);
    await GroceryDatabase.createCashTransactionsSchema(database);
    await GroceryDatabase.createCashShiftsSchema(database);
    await GroceryDatabase.createSaleReturnRefundsSchema(database);
    await GroceryDatabase.createOpeningBalancesSchema(database);
    managerId = await database.insert('users', {
      'username': 'test_manager', 'display_name': 'مدير الاختبار',
      'password_hash': 'test-hash', 'password_salt': 'test-salt',
      'password_iterations': 100000, 'role': 'manager', 'is_active': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    managerAccount = AuthUser(
      id: managerId,
      username: 'test_manager',
      displayName: 'مدير الاختبار',
      role: 'manager',
    );
    customers = CustomerRepository(database);
    products = ProductRepository(database);
    sales = SaleRepository(database);
  });

  Future<int> ensureManagerShift() async {
    final shifts = CashShiftRepository(database);
    final current = await shifts.getOpenShift(userId: managerId);
    if (current != null) {
      if (current.userId != managerId) {
        throw StateError('وردية الاختبار المفتوحة لا تخص المدير.');
      }
      return current.id;
    }
    return (await shifts.openShift(userId: managerId, openingCash: 0)).id;
  }

  tearDown(() async => database.close());


  test('يمنع الكاشير من قراءة أرصدة وكشوف الزبائن افتراضيًا', () async {
    final cashierId = await database.insert('users', {
      'username': 'test_cashier', 'display_name': 'كاشير الاختبار',
      'password_hash': 'test-hash', 'password_salt': 'test-salt',
      'password_iterations': 100000, 'role': 'cashier', 'is_active': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await expectLater(
      customers.balances(userId: cashierId),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      customers.ledger(1, userId: cashierId),
      throwsA(isA<StateError>()),
    );
  });

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
    
      userId: managerId, shiftId: await ensureManagerShift());

    final before = (await customers.balances(userId: managerId)).single;
    expect(before.name, 'أحمد');
    expect(before.totalDebt, 800);
    expect(before.balance, 800);

    await customers.recordPayment(customerId: before.id, amount: 300, paymentMethod: 'تحويل بنكي', note: 'تحصيل بنكي' , userId: managerId);
    final cashEntries = await database.query('cash_transactions', where: "reference_type = 'customer_payment'");
    expect(cashEntries, hasLength(1));
    expect(cashEntries.single['amount'], 300);
    expect(cashEntries.single['direction'], 'in');
    expect(cashEntries.single['payment_method'], 'تحويل بنكي');
    final after = (await customers.balances(userId: managerId)).single;
    expect(after.totalPaid, 300);
    expect(after.balance, 500);
  });

  test('يرفض تحصيل الدين النقدي دون وردية حتى لحساب المدير', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'سكر', sellingPrice: 100, stockQuantity: 2,
    ));
    final product = (await products.getById(productId))!;
    await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 0,
      paidAmount: 0,
      paymentMethod: 'آجل',
      customerName: 'عميل دون وردية',
      userId: managerId,
    );
    final customer = (await customers.balances(userId: managerId)).single;
    await expectLater(
      customers.recordPayment(
        customerId: customer.id,
        amount: 50,
        paymentMethod: 'نقدي',
        userId: managerId,
      ),
      throwsA(isA<CashShiftException>()),
    );
    expect(await database.query('customer_payments'), isEmpty);
    expect(await database.query('cash_transactions'), isEmpty);
  });

  test('يشترط وردية المستخدم النشطة للتحصيل النقدي فقط', () async {
    final auth = AuthRepository(database);
    final manager = managerAccount;
    final cashier = await auth.createCashier(
      manager: manager,
      username: 'cashier_one',
      displayName: 'الكاشير الأول',
      password: 'CashierPass!2026',
    );
    final shift = await CashShiftRepository(database).openShift(
      userId: manager.id,
      openingCash: 0,
    );
    final productId = await products.add(const GroceryProduct(
      name: 'أرز', sellingPrice: 100, stockQuantity: 2,
    ));
    final product = (await products.getById(productId))!;
    await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 0,
      paidAmount: 0,
      paymentMethod: 'آجل',
      customerName: 'عميل الوردية',
    
      userId: managerId);
    final customer = (await customers.balances(userId: managerId)).single;

    await customers.recordPayment(
      customerId: customer.id,
      amount: 20,
      userId: manager.id,
      shiftId: shift.id,
    );
    await expectLater(
      customers.recordPayment(
        customerId: customer.id,
        amount: 20,
        userId: cashier.id,
        shiftId: shift.id,
      ),
      throwsA(isA<CashShiftException>()),
    );
    await CashShiftRepository(database).closeShift(
      shiftId: shift.id,
      userId: manager.id,
      closingCash: 20,
    );
    await expectLater(
      customers.recordPayment(
        customerId: customer.id,
        amount: 20,
        userId: manager.id,
        shiftId: shift.id,
      ),
      throwsA(isA<CashShiftException>()),
    );
    final entries = await database.query(
      'cash_transactions',
      where: "reference_type = 'customer_payment'",
    );
    expect(entries, hasLength(1));
    expect(entries.single['shift_id'], shift.id);
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
    
      userId: managerId);
    final customer = (await customers.balances(userId: managerId)).single;
    final itemId = (await database.query(
      'sale_items',
      columns: ['id'],
      where: 'sale_id = ?',
      whereArgs: [sale.id],
    )).single['id'] as int;

    await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 1},
    
      userId: managerId);

    expect((await customers.balances(userId: managerId)).single.balance, 1000);
    await customers.recordPayment(customerId: customer.id, amount: 1000 , userId: managerId, shiftId: await ensureManagerShift());
    expect((await customers.balances(userId: managerId)).single.balance, 0);
    await expectLater(
      customers.recordPayment(customerId: customer.id, amount: 1 , userId: managerId, shiftId: await ensureManagerShift()),
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
      paidAmount: 90,
      paymentMethod: 'جزئي',
      customerName: 'عميل الرد النقدي',
    
      userId: managerId, shiftId: await ensureManagerShift());
    final customer = (await customers.balances(userId: managerId)).single;
    final itemId = (await database.query(
      'sale_items', columns: ['id'], where: 'sale_id = ?', whereArgs: [sale.id],
    )).single['id'] as int;
    await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 2},
      note: 'مرتجع يغطي الدين ويتجاوزُه',
    
      userId: managerId);
    await sales.recordReturnRefund(
      saleId: sale.id, amount: 90, note: 'تم تسليم النقد',
    
      userId: managerId, shiftId: await ensureManagerShift());

    final ledger = await customers.ledger(customer.id, userId: managerId);
    final refund = ledger.singleWhere((entry) => entry.title == 'رد نقدي للزبون');
    expect(refund.amount, 90);
    expect(refund.isCredit, isFalse);
    expect(refund.note, 'تم تسليم النقد');
    expect((await customers.balances(userId: managerId)).single.balance, 0);
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
    
      userId: managerId);
    final customer = (await customers.balances(userId: managerId)).single;
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
    
      userId: managerId);
    await customers.recordPayment(
      customerId: customer.id,
      amount: 100,
      note: 'تحصيل نقدي',
    
      userId: managerId, shiftId: await ensureManagerShift());

    final ledger = await customers.ledger(customer.id, userId: managerId);
    expect(ledger.length, 3);
    expect(ledger[0].title, contains('فاتورة'));
    expect(ledger[0].isCredit, isFalse);
    expect(ledger[1].title, contains('مرتجع'));
    expect(ledger[1].isCredit, isTrue);
    expect(ledger[1].note, 'إرجاع عبوة');
    expect(ledger[2].title, 'تحصيل من الزبون');
    expect(ledger[2].isCredit, isTrue);
    expect((await customers.balances(userId: managerId)).single.balance, 0);
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
    
      userId: managerId, shiftId: await ensureManagerShift());
    await sales.createSale(
      lines: [SaleLine(product: debtProduct, quantity: 1)],
      discount: 0,
      paidAmount: 0,
      paymentMethod: 'آجل',
      customerName: customerName,
    
      userId: managerId);
    final customer = (await customers.balances(userId: managerId)).single;
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
    
      userId: managerId);

    final afterReturn = (await customers.balances(userId: managerId)).single;
    expect(afterReturn.totalDebt, 500);
    expect(afterReturn.balance, 500);
    await customers.recordPayment(customerId: customer.id, amount: 500 , userId: managerId, shiftId: await ensureManagerShift());
    expect((await customers.balances(userId: managerId)).single.balance, 0);
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
    
      userId: managerId);
    final customer = (await customers.balances(userId: managerId)).single;

    await expectLater(
      customers.recordPayment(customerId: customer.id, amount: 201 , userId: managerId, shiftId: await ensureManagerShift()),
      throwsArgumentError,
    );
    expect((await customers.balances(userId: managerId)).single.balance, 200);
  });

  test('يمنع إضافة اسم فارغ', () async {
    await expectLater(
      customers.addCustomer(name: '   '),
      throwsArgumentError,
    );
  });
  test('يفرض صلاحية التحصيل وحده المالي على حساب الكاشير', () async {
    final auth = AuthRepository(database);
    final manager = managerAccount;
    final cashier = await auth.createCashier(
      manager: manager,
      username: 'collection_cashier',
      displayName: 'الكاشير',
      password: 'CashierPass!2026',
    );
    final productId = await products.add(const GroceryProduct(
      name: 'سلعة التحصيل',
      sellingPrice: 500,
      stockQuantity: 5,
    ));
    final product = (await products.getById(productId))!;
    await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 0,
      paidAmount: 500,
      paymentMethod: 'جزئي',
      customerName: 'عميل التحصيل',
    
      userId: managerId, shiftId: await ensureManagerShift());
    final customer = (await customers.balances(userId: managerId)).single;

    await expectLater(
      customers.recordPayment(
        customerId: customer.id,
        amount: 100,
        paymentMethod: 'تحويل بنكي',
        userId: cashier.id,
      ),
      throwsStateError,
    );

    final settings = await auth.getCashierPermissions(
      manager: manager,
      cashierId: cashier.id,
    );
    await auth.saveCashierPermissions(
      manager: manager,
      cashierId: cashier.id,
      permissions: settings.map((setting) =>
        setting.key == 'customer_collections'
          ? CashierPermissionSetting(
              key: setting.key,
              label: setting.label,
              isAllowed: true,
              maxAmount: 300,
            )
          : setting
      ).toList(),
    );
    await expectLater(
      customers.recordPayment(
        customerId: customer.id,
        amount: 301,
        paymentMethod: 'تحويل بنكي',
        userId: cashier.id,
      ),
      throwsStateError,
    );
    await customers.recordPayment(
      customerId: customer.id,
      amount: 300,
      paymentMethod: 'تحويل بنكي',
      userId: cashier.id,
    );
    expect((await customers.balances(userId: managerId)).single.balance, 200);
  });

  test('يضيف الرصيد الافتتاحي للزبون في الرصيد والكشف ويسمح بتحصيله', () async {
    final customerId = await customers.addCustomer(name: 'زبون برصيد سابق', openingBalance: 1000);
    var balance = (await customers.balances(userId: managerId)).single;
    expect(balance.id, customerId);
    expect(balance.openingBalance, 1000);
    expect(balance.balance, 1000);

    final ledger = await customers.ledger(customerId, userId: managerId);
    expect(ledger, hasLength(1));
    expect(ledger.single.title, 'رصيد افتتاحي');
    expect(ledger.single.amount, 1000);
    expect(ledger.single.isCredit, isFalse);

    await customers.recordPayment(
      customerId: customerId,
      amount: 400,
      paymentMethod: 'تحويل بنكي',
      userId: managerId,
    );
    balance = (await customers.balances(userId: managerId)).single;
    expect(balance.balance, 600);
    expect(await database.query('cash_transactions'), hasLength(1));
  });

  test('يمنع الرصيد الافتتاحي السالب للزبون ويقصر تعديله على المدير', () async {
    await expectLater(customers.addCustomer(name: 'رصيد غير صالح', openingBalance: -1), throwsArgumentError);
    final customerId = await customers.addCustomer(name: 'زبون تعديل الرصيد');
    final cashierId = await database.insert('users', {
      'username': 'opening_balance_cashier', 'display_name': 'كاشير',
      'password_hash': 'test-hash', 'password_salt': 'test-salt',
      'password_iterations': 100000, 'role': 'cashier', 'is_active': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await expectLater(
      customers.setOpeningBalance(customerId: customerId, amount: 200, userId: cashierId),
      throwsStateError,
    );
    await customers.setOpeningBalance(customerId: customerId, amount: 200, userId: managerId);
    expect((await customers.balances(userId: managerId)).single.balance, 200);
  });

}
