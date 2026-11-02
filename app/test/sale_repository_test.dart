// اختبارات إنشاء الفواتير وتحديث المخزون كوحدة عمل واحدة.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/auth_repository.dart';
import 'package:homi_grocery/data/cash_shift_repository.dart';
import 'package:homi_grocery/data/grocery_database.dart';
import 'package:homi_grocery/data/product_repository.dart';
import 'package:homi_grocery/data/sale_repository.dart';
import 'package:homi_grocery/data/manager_approval_repository.dart';

void main() {
  late Database database;
  late ProductRepository products;
  late SaleRepository sales;
  late int managerId;
  late AuthUser managerAccount;

  const managerPassword = 'StrongPass!2026';

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createAuthSchema(database);
    await GroceryDatabase.createSalesSchema(database);
    await GroceryDatabase.createCustomersSchema(database);
    await GroceryDatabase.createStockMovementsSchema(database);
    await GroceryDatabase.createSalesReturnsSchema(database);
    await GroceryDatabase.createCashTransactionsSchema(database);
    await GroceryDatabase.createCashShiftsSchema(database);
    await GroceryDatabase.createManagerApprovalsSchema(database);
    await GroceryDatabase.createSaleReturnRefundsSchema(database);
    await GroceryDatabase.createCustomerOverpaymentsSchema(database);
    await GroceryDatabase.createCostOfGoodsSchema(database);
    managerAccount = await AuthRepository(database).createInitialManager(
      username: 'sale_test_manager',
      displayName: 'مدير الاختبار',
      password: managerPassword,
    );
    managerId = managerAccount.id;
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

  tearDown(() async {
    await database.close();
  });


  test('يرفض وسيلة رد غير معتمدة لمرتجع البيع دون تسجيل حركة مالية', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'صنف رد غير معتمد', sellingPrice: 100, stockQuantity: 2,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 0,
      paidAmount: 100,
      paymentMethod: 'نقدي',
      userId: managerId,
      shiftId: await ensureManagerShift(),
    );
    final itemId = (await database.query('sale_items',
      columns: ['id'], where: 'sale_id = ?', whereArgs: [sale.id],
    )).single['id'] as int;
    await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 1},
      userId: managerId,
    );

    await expectLater(
      sales.recordReturnRefund(
        saleId: sale.id, amount: 50, paymentMethod: 'شيك', userId: managerId,
      ),
      throwsArgumentError,
    );
    expect(await database.query('sale_return_refunds'), isEmpty);
    expect(await database.query('cash_transactions',
      where: "reference_type = 'sale_return_refund'"), isEmpty);
  });

  test('يسجل المبلغ الزائد كالتزام مستقل ولا يربطه بدفتر الزبائن', () async {
    final productId = await products.add(const GroceryProduct(name: 'ماء', sellingPrice: 700, stockQuantity: 5));
    final product = (await products.getById(productId))!;
    final shiftId = await ensureManagerShift();
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)], discount: 0,
      paidAmount: 1000, paymentMethod: 'نقدي', paymentChannel: 'نقدي',
      userId: managerId, shiftId: shiftId,
    );
    expect(sale.total, 700); expect(sale.paidAmount, 700);
    expect(sale.remainingAmount, 0); expect(sale.overpaymentAmount, 300);
    expect(sale.customerName, isNull); expect(await database.query('customers'), isEmpty);
    expect((await database.query('cash_transactions')).single['amount'], 1000);
    expect((await sales.pendingCustomerOverpayments(userId: managerId)).single['outstanding_amount'], 300);
    final remaining = await sales.refundCustomerOverpayment(saleId: sale.id, amount: 100,
      paymentMethod: 'نقدي', userId: managerId, shiftId: shiftId);
    expect(remaining, 200);
    final movements = await database.query('cash_transactions', orderBy: 'id');
    expect(movements.last['direction'], 'out'); expect(movements.last['amount'], 100);
    expect(movements.last['category'], 'رد زيادة دفع للزبون');
    expect((await sales.pendingCustomerOverpayments(userId: managerId)).single['outstanding_amount'], 200);
    final invoice = (await sales.invoiceHistory(userId: managerId)).single;
    expect(invoice['overpayment_received'], 300);
    expect(invoice['overpayment_refunded'], 100);
    expect(invoice['overpayment_outstanding'], 200);
  });


  test('يفصل المقبوض النقدي والتحويل البنكي والزيادة عن إيراد الفاتورة', () async {
    final productId = await products.add(const GroceryProduct(name: 'حليب', sellingPrice: 700, stockQuantity: 4));
    final product = (await products.getById(productId))!;
    final shiftId = await ensureManagerShift();
    final sale = await sales.createSale(lines: [SaleLine(product: product, quantity: 1)],
      discount: 0, paidAmount: 1000, paymentMethod: 'نقدي', paymentChannel: 'مختلط',
      cashPaidAmount: 400, bankPaidAmount: 600, userId: managerId, shiftId: shiftId);
    expect(sale.total, 700); expect(sale.paidAmount, 700); expect(sale.overpaymentAmount, 300);
    final movements = await database.query('cash_transactions',
      where: "reference_type = 'sale' AND reference_id = ?", whereArgs: [sale.id]);
    expect(movements, hasLength(2));
    expect(movements.map((row) => row['payment_method']).toSet(), {'نقدي', 'تحويل بنكي'});
    expect(movements.fold<int>(0, (sum, row) => sum + (row['amount'] as int)), 1000);
    expect(movements.firstWhere((row) => row['payment_method'] == 'نقدي')['shift_id'], shiftId);
    expect(movements.firstWhere((row) => row['payment_method'] == 'تحويل بنكي')['shift_id'], isNull);
  });


  test('يرفض توزيع مبالغ دفع لا يساوي إجمالي المبلغ المستلم', () async {
    final productId = await products.add(const GroceryProduct(name: 'عصير', sellingPrice: 500, stockQuantity: 3));
    final product = (await products.getById(productId))!;
    final shiftId = await ensureManagerShift();
    await expectLater(
      sales.createSale(lines: [SaleLine(product: product, quantity: 1)],
        discount: 0, paidAmount: 500, paymentMethod: 'نقدي', paymentChannel: 'مختلط',
        cashPaidAmount: 200, bankPaidAmount: 200, userId: managerId, shiftId: shiftId),
      throwsArgumentError,
    );
    expect(await database.query('sales'), isEmpty);
    expect(await database.query('cash_transactions'), isEmpty);
  });


  test('يسمح للكاشير باستلام الزيادة نقدًا دون منحه البيع الآجل', () async {
    final cashier = await AuthRepository(database).createCashier(
      manager: managerAccount, username: 'cashier_overpay',
      displayName: 'كاشير الزيادة', password: 'CashierPass!2026');
    final managerShiftId = await ensureManagerShift();
    await CashShiftRepository(database).closeShift(
      shiftId: managerShiftId, userId: managerId, closingCash: 0);
    final shift = await CashShiftRepository(database).openShift(
      userId: cashier.id, openingCash: 0);
    final productId = await products.add(const GroceryProduct(
      name: 'خبز', sellingPrice: 500, stockQuantity: 5));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)], discount: 0,
      paidAmount: 800, paymentMethod: 'نقدي', paymentChannel: 'نقدي',
      userId: cashier.id, shiftId: shift.id);
    expect(sale.total, 500);
    expect(sale.paidAmount, 500);
    expect(sale.overpaymentAmount, 300);
    expect(sale.customerName, isNull);
    expect(await database.query('customers'), isEmpty);
    await expectLater(
      sales.refundCustomerOverpayment(saleId: sale.id, amount: 100,
        paymentMethod: 'نقدي', userId: cashier.id, shiftId: shift.id),
      throwsA(isA<StateError>()));
    final settings = await AuthRepository(database).getCashierPermissions(
      manager: managerAccount, cashierId: cashier.id);
    await AuthRepository(database).saveCashierPermissions(
      manager: managerAccount, cashierId: cashier.id,
      permissions: settings.map((setting) => setting.key == 'customer_overpayments'
        ? CashierPermissionSetting(key: setting.key, label: setting.label, isAllowed: true)
        : setting).toList());
    await expectLater(
      sales.refundCustomerOverpayment(saleId: sale.id, amount: 100,
        paymentMethod: 'نقدي', userId: cashier.id, shiftId: shift.id),
      throwsA(isA<StateError>()),
    );
    expect(await sales.refundCustomerOverpayment(saleId: sale.id, amount: 50,
      paymentMethod: 'نقدي', userId: cashier.id, shiftId: shift.id), 250);
    expect(await sales.refundCustomerOverpayment(saleId: sale.id, amount: 50,
      paymentMethod: 'نقدي', userId: cashier.id, shiftId: shift.id), 200);
  });

  test('يحمي قائمة الزيادات المعلقة بهوية المستخدم وصلاحية الرد', () async {
    final cashier = await AuthRepository(database).createCashier(
      manager: managerAccount,
      username: 'cashier_overpayment_reader',
      displayName: 'كاشير تسوية الزيادة',
      password: 'CashierPass!2026',
    );

    await expectLater(
      sales.pendingCustomerOverpayments(userId: cashier.id),
      throwsA(isA<StateError>()),
    );

    final settings = await AuthRepository(database).getCashierPermissions(
      manager: managerAccount,
      cashierId: cashier.id,
    );
    await AuthRepository(database).saveCashierPermissions(
      manager: managerAccount,
      cashierId: cashier.id,
      permissions: settings.map((setting) => setting.key == 'customer_overpayments'
          ? CashierPermissionSetting(
              key: setting.key,
              label: setting.label,
              isAllowed: true,
            )
          : setting).toList(),
    );
    expect(await sales.pendingCustomerOverpayments(userId: cashier.id), isEmpty);
    expect(await sales.pendingCustomerOverpayments(userId: managerId), isEmpty);
  });

  test('يسمح للكاشير بالتحويل البنكي والدفع المختلط دون صلاحية إضافية', () async {
    final cashier = await AuthRepository(database).createCashier(
      manager: managerAccount, username: 'cashier_bank',
      displayName: 'كاشير التحويل', password: 'CashierPass!2026');
    final managerShiftId = await ensureManagerShift();
    await CashShiftRepository(database).closeShift(
      shiftId: managerShiftId, userId: managerId, closingCash: 0);
    final shift = await CashShiftRepository(database).openShift(
      userId: cashier.id, openingCash: 0);
    final productId = await products.add(const GroceryProduct(
      name: 'معلبات', sellingPrice: 500, stockQuantity: 4));
    final product = (await products.getById(productId))!;

    final bankSale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)], discount: 0,
      paidAmount: 500, paymentMethod: 'نقدي', paymentChannel: 'تحويل بنكي',
      cashPaidAmount: 0, bankPaidAmount: 500,
      userId: cashier.id, shiftId: shift.id);
    expect(bankSale.total, 500);
    final bankMovement = (await database.query('cash_transactions',
      where: "reference_type = 'sale' AND reference_id = ?",
      whereArgs: [bankSale.id])).single;
    expect(bankMovement['payment_method'], 'تحويل بنكي');
    expect(bankMovement['amount'], 500);
    expect(bankMovement['shift_id'], isNull);

    final mixedSale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)], discount: 0,
      paidAmount: 500, paymentMethod: 'نقدي', paymentChannel: 'مختلط',
      cashPaidAmount: 200, bankPaidAmount: 300,
      userId: cashier.id, shiftId: shift.id);
    final mixedMovements = await database.query('cash_transactions',
      where: "reference_type = 'sale' AND reference_id = ?",
      whereArgs: [mixedSale.id]);
    expect(mixedMovements, hasLength(2));
    expect(mixedMovements.map((row) => row['payment_method']).toSet(),
      {'نقدي', 'تحويل بنكي'});
    expect(mixedMovements.firstWhere(
      (row) => row['payment_method'] == 'نقدي')['shift_id'], shift.id);
    expect(mixedMovements.firstWhere(
      (row) => row['payment_method'] == 'تحويل بنكي')['shift_id'], isNull);
  });

  test('يحمي سجل الفواتير من الكاشير حتى منح صلاحية العرض', () async {
    final auth = AuthRepository(database);
    final cashier = await auth.createCashier(
      manager: managerAccount,
      username: 'invoice_reader',
      displayName: 'قارئ الفواتير',
      password: 'CashierPass!2026',
    );
    final productId = await products.add(const GroceryProduct(
      name: 'ماء', sellingPrice: 100, stockQuantity: 2,
    ));
    final product = (await products.getById(productId))!;
    await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 0, paidAmount: 100, paymentMethod: 'نقدي',
    
      userId: managerId, shiftId: await ensureManagerShift());
    expect(await sales.invoiceHistory(userId: managerId), hasLength(1));
    await expectLater(
      sales.invoiceHistory(userId: cashier.id),
      throwsA(isA<StateError>()),
    );
    final settings = await auth.getCashierPermissions(
      manager: managerAccount, cashierId: cashier.id,
    );
    await auth.saveCashierPermissions(
      manager: managerAccount,
      cashierId: cashier.id,
      permissions: settings.map((setting) => setting.key == 'view_invoice_history'
          ? CashierPermissionSetting(
              key: setting.key, label: setting.label, isAllowed: true,
            )
          : setting).toList(),
    );
    expect(await sales.invoiceHistory(userId: cashier.id), hasLength(1));
  });

  test('يحفظ الفاتورة ويخصم الكمية من المخزون', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'سكر',
      unit: 'كيلوجرام',
      sellingPrice: 1000,
      stockQuantity: 10,
    ));
    final product = (await products.getById(productId))!;

    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 200,
      paidAmount: 1000,
      paymentMethod: 'جزئي',
      paymentChannel: 'تحويل بنكي',
      customerName: 'زبون اختبار',
    
      userId: managerId);

    expect(sale.total, 1800);
    expect(sale.paidAmount, 1000);
    expect(sale.remainingAmount, 800);
    expect(sale.customerName, 'زبون اختبار');
    expect((await products.getById(productId))!.stockQuantity, 8);
    expect((await sales.recentSales(userId: managerId)).length, 1);
    final cashEntries = await database.query('cash_transactions', where: "reference_type = 'sale'");
    expect(cashEntries, hasLength(1));
    expect(cashEntries.single['direction'], 'in');
    expect(cashEntries.single['amount'], 1000);
    expect(cashEntries.single['payment_method'], 'تحويل بنكي');
  });


  test('يحسب بيع نصف وربع الكيلوجرام ويخصم الوزن الكسري من المخزون', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'سكر',
      unit: 'كيلوجرام',
      sellingPrice: 2000,
      stockQuantity: 2,
    ));
    final product = (await products.getById(productId))!;
    final halfKilo = SaleLine(product: product, quantity: 0.5);
    final quarterKilo = SaleLine(product: product, quantity: 0.25);

    expect(halfKilo.lineTotal, 1000);
    expect(quarterKilo.lineTotal, 500);

    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 0.75)],
      discount: 0,
      paidAmount: 1500,
      paymentMethod: 'نقدي',
    
      userId: managerId, shiftId: await ensureManagerShift());

    expect(sale.total, 1500);
    expect((await products.getById(productId))!.stockQuantity, 1.25);
    final item = (await database.query(
      'sale_items', where: 'sale_id = ?', whereArgs: [sale.id],
    )).single;
    expect(item['quantity'], 0.75);
    expect(item['unit'], 'كيلوجرام');
  });

  test('البيع النقدي لا يحفظ اسم الزبون ولا ينشئ حسابًا حتى مع تطابق الاسم', () async {
    await database.insert('customers', {
      'name': 'محمد أحمد',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    final productId = await products.add(const GroceryProduct(
      name: 'ماء', sellingPrice: 100, stockQuantity: 5,
    ));
    final product = (await products.getById(productId))!;

    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 0,
      paidAmount: 100,
      paymentMethod: 'نقدي',
      customerName: 'محمد أحمد',
    
      userId: managerId, shiftId: await ensureManagerShift());

    expect(sale.customerName, isNull);
    final savedSale = (await database.query(
      'sales', where: 'id = ?', whereArgs: [sale.id],
    )).single;
    expect(savedSale['customer_id'], isNull);
    expect(savedSale['customer_name'], isNull);
    expect(await database.query('customers'), hasLength(1));
  });

  test('الدين لا يرتبط بحساب موجود إلا عند تمرير معرّف الحساب المختار', () async {
    final customerId = await database.insert('customers', {
      'name': 'محمد أحمد',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    final productId = await products.add(const GroceryProduct(
      name: 'خبز', sellingPrice: 200, stockQuantity: 5,
    ));
    final product = (await products.getById(productId))!;

    await expectLater(
      sales.createSale(
        lines: [SaleLine(product: product, quantity: 1)],
        discount: 0,
        paidAmount: 0,
        paymentMethod: 'آجل',
        customerName: 'محمد أحمد',
      
      userId: managerId),
      throwsStateError,
    );
    expect(await sales.recentSales(userId: managerId), isEmpty);

    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 0,
      paidAmount: 0,
      paymentMethod: 'آجل',
      customerName: 'محمد أحمد',
      customerId: customerId,
    
      userId: managerId);
    final savedSale = (await database.query(
      'sales', where: 'id = ?', whereArgs: [sale.id],
    )).single;
    expect(savedSale['customer_id'], customerId);
    expect(savedSale['customer_name'], 'محمد أحمد');
    expect(await database.query('customers'), hasLength(1));
  });

  test('يحفظ تكلفة الصنف وقت البيع لا سعر الشراء الذي قد يتغير لاحقًا', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'قهوة', purchasePrice: 40, sellingPrice: 100, stockQuantity: 5,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 0,
      paidAmount: 200,
      paymentMethod: 'نقدي',
    
      userId: managerId, shiftId: await ensureManagerShift());
    final item = (await database.query(
      'sale_items', where: 'sale_id = ?', whereArgs: [sale.id],
    )).single;
    expect(item['cost_price'], 40);
    await database.update('products', {'purchase_price': 75}, where: 'id = ?', whereArgs: [productId]);
    final saved = (await database.query(
      'sale_items', where: 'sale_id = ?', whereArgs: [sale.id],
    )).single;
    expect(saved['cost_price'], 40);
  });

  test('يرفض الخصم الزائد دون حفظ فاتورة أو تعديل المخزون', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'زيت',
      sellingPrice: 500,
      stockQuantity: 4,
    ));
    final product = (await products.getById(productId))!;

    await expectLater(
      sales.createSale(
        lines: [SaleLine(product: product, quantity: 1)],
        discount: 600,
        paidAmount: 0,
        paymentMethod: 'آجل',
      
      userId: managerId),
      throwsArgumentError,
    );

    expect(await sales.recentSales(userId: managerId), isEmpty);
    expect((await products.getById(productId))!.stockQuantity, 4);
  });

  test('يعيد الكمية إلى المخزون ويسجل المرتجع مرة واحدة', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'حليب', sellingPrice: 250, stockQuantity: 5,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 3)],
      discount: 0,
      paidAmount: 750,
      paymentMethod: 'نقدي',
    
      userId: managerId, shiftId: await ensureManagerShift());
    final item = (await database.query(
      'sale_items',
      columns: ['id'],
      where: 'sale_id = ?',
      whereArgs: [sale.id],
    )).single;
    final itemId = item['id'] as int;

    final returned = await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 1},
      note: 'عبوة تالفة',
    
      userId: managerId);

    expect(returned.amount, 250);
    expect((await products.getById(productId))!.stockQuantity, 3);
    expect(await sales.returnedQuantity(itemId, userId: managerId), 1);
    final movements = await database.query(
      'stock_movements',
      where: "reference_type = 'sale_return'",
    );
    expect(movements, hasLength(1));
    expect(movements.single['quantity_delta'], 1);
  });

  test('يرفض تكرار إرجاع كمية تتجاوز المتبقي دون تغيير المخزون', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'زيت', sellingPrice: 100, stockQuantity: 2,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 0,
      paidAmount: 200,
      paymentMethod: 'نقدي',
    
      userId: managerId, shiftId: await ensureManagerShift());
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
    await expectLater(
      sales.returnItems(
        saleId: sale.id,
        quantitiesBySaleItemId: {itemId: 1.1},
      
      userId: managerId),
      throwsArgumentError,
    );

    expect((await products.getById(productId))!.stockQuantity, 1);
    expect(await sales.returnedQuantity(itemId, userId: managerId), 1);
    expect(await database.query('sale_returns'), hasLength(1));
  });

  test('لا يسمح برد نقد يتجاوز فائض المرتجع عن الدين الأصلي للفاتورة', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'منظف', sellingPrice: 100, stockQuantity: 4,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 0,
      paidAmount: 100,
      paymentMethod: 'جزئي',
      customerName: 'زبون مرتجع',
    
      userId: managerId, shiftId: await ensureManagerShift());
    final itemId = (await database.query(
      'sale_items', columns: ['id'], where: 'sale_id = ?', whereArgs: [sale.id],
    )).single['id'] as int;

    final returned = await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 2},
    
      userId: managerId);
    expect(returned.amount, 200);
    expect(await sales.maximumRefundableAmount(sale.id , userId: managerId), 100);

    await expectLater(
      sales.recordReturnRefund(saleId: sale.id, amount: 101 , userId: managerId, shiftId: await ensureManagerShift()),
      throwsArgumentError,
    );
    await sales.recordReturnRefund(
      saleId: sale.id, amount: 80, paymentMethod: 'نقدي', note: 'رد فعلي',
    
      userId: managerId, shiftId: await ensureManagerShift());
    expect(await sales.maximumRefundableAmount(sale.id , userId: managerId), 20);
    await sales.recordReturnRefund(saleId: sale.id, amount: 20 , userId: managerId, shiftId: await ensureManagerShift());
    expect(await sales.maximumRefundableAmount(sale.id , userId: managerId), 0);
    expect(await database.query('sale_return_refunds'), hasLength(2));
    final cashEntries = await database.query(
      'cash_transactions',
      where: "reference_type = 'sale_return_refund'",
    );
    expect(cashEntries, hasLength(2));
    expect(cashEntries.fold<int>(0, (sum, row) => sum + (row['amount'] as int)), 100);
    expect(cashEntries.every((row) => row['direction'] == 'out'), isTrue);
  });

  test('المرتجع لفاتورة مدفوعة بالكامل يسمح برد قيمة المرتجع فقط', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'صابون', sellingPrice: 75, stockQuantity: 3,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 0,
      paidAmount: 150,
      paymentMethod: 'نقدي',
    
      userId: managerId, shiftId: await ensureManagerShift());
    final itemId = (await database.query(
      'sale_items', columns: ['id'], where: 'sale_id = ?', whereArgs: [sale.id],
    )).single['id'] as int;
    await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 1},
    
      userId: managerId);

    expect(await sales.maximumRefundableAmount(sale.id , userId: managerId), 75);
    await sales.recordReturnRefund(saleId: sale.id, amount: 75 , userId: managerId, shiftId: await ensureManagerShift());
    expect(await sales.maximumRefundableAmount(sale.id , userId: managerId), 0);
    await expectLater(
      sales.recordReturnRefund(saleId: sale.id, amount: 1 , userId: managerId, shiftId: await ensureManagerShift()),
      throwsArgumentError,
    );
  });

  test('يوزع خصم الفاتورة على المرتجعات الجزئية دون تجاوز القيمة المدفوعة', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'أرز', sellingPrice: 100, stockQuantity: 4,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 40,
      paidAmount: 160,
      paymentMethod: 'نقدي',
    
      userId: managerId, shiftId: await ensureManagerShift());
    final itemId = (await database.query(
      'sale_items',
      columns: ['id'],
      where: 'sale_id = ?',
      whereArgs: [sale.id],
    )).single['id'] as int;

    final first = await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 1},
    
      userId: managerId);
    final second = await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 1},
    
      userId: managerId);

    expect(first.amount, 80);
    expect(second.amount, 80);
    final returns = await database.query('sale_returns');
    expect(
      returns.fold<int>(0, (sum, row) => sum + (row['amount'] as int)),
      160,
    );
    expect((await products.getById(productId))!.stockQuantity, 4);
  });

  test('يسمح بالمخزون السالب وفق سياسة المشروع', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'حليب',
      sellingPrice: 300,
      stockQuantity: 1,
    ));
    final product = (await products.getById(productId))!;

    await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 0,
      paidAmount: 600,
      paymentMethod: 'نقدي',
    
      userId: managerId, shiftId: await ensureManagerShift());

    expect((await products.getById(productId))!.stockQuantity, -1);
  });

  test('يرفض البيع النقدي للمدير دون وردية نشطة ولا يسجل حركة يتيمة', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'ماء', sellingPrice: 100, stockQuantity: 2,
    ));
    final product = (await products.getById(productId))!;
    await expectLater(
      sales.createSale(
        lines: [SaleLine(product: product, quantity: 1)],
        discount: 0,
        paidAmount: 100,
        paymentMethod: 'نقدي',
        userId: managerId,
      ),
      throwsA(isA<CashShiftException>()),
    );
    expect(await database.query('sales'), isEmpty);
    expect(await database.query('cash_transactions'), isEmpty);
    expect((await products.getById(productId))!.stockQuantity, 2);
  });

  test('يربط البيع النقدي بالوردية النشطة ويستثني التحويل البنكي', () async {
    final manager = managerAccount;
    final shift = await CashShiftRepository(database).openShift(
      userId: manager.id,
      openingCash: 0,
    );
    final productId = await products.add(const GroceryProduct(
      name: 'ماء', sellingPrice: 100, stockQuantity: 4,
    ));
    final product = (await products.getById(productId))!;

    final cashSale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 0,
      paidAmount: 100,
      paymentMethod: 'نقدي',
      userId: manager.id,
      shiftId: shift.id,
    );
    final cashEntry = (await database.query(
      'cash_transactions',
      where: "reference_type = 'sale' AND reference_id = ?",
      whereArgs: [cashSale.id],
    )).single;
    expect(cashEntry['user_id'], manager.id);
    expect(cashEntry['shift_id'], shift.id);

    final bankSale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 0,
      paidAmount: 100,
      paymentMethod: 'نقدي',
      paymentChannel: 'تحويل بنكي',
      userId: manager.id,
      shiftId: shift.id,
    );
    final bankEntry = (await database.query(
      'cash_transactions',
      where: "reference_type = 'sale' AND reference_id = ?",
      whereArgs: [bankSale.id],
    )).single;
    expect(bankEntry['user_id'], manager.id);
    expect(bankEntry['shift_id'], isNull);
    expect(bankEntry['payment_method'], 'تحويل بنكي');
  });

  test('يشترط الوردية النشطة لرد مبالغ المرتجعات نقدًا', () async {
    final manager = managerAccount;
    final shift = await CashShiftRepository(database).openShift(
      userId: manager.id,
      openingCash: 0,
    );
    final productId = await products.add(const GroceryProduct(
      name: 'ماء', sellingPrice: 100, stockQuantity: 2,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 0,
      paidAmount: 100,
      paymentMethod: 'نقدي',
      userId: manager.id,
      shiftId: shift.id,
    );
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
    await sales.recordReturnRefund(
      saleId: sale.id,
      amount: 100,
      paymentMethod: 'نقدي',
      userId: manager.id,
      shiftId: shift.id,
    );
    final refund = (await database.query(
      'cash_transactions',
      where: "reference_type = 'sale_return_refund'",
    )).single;
    expect(refund['user_id'], manager.id);
    expect(refund['shift_id'], shift.id);
    expect(refund['direction'], 'out');
  });

  test('يمنع الكاشير من الخصم والدين دون صلاحية مع السماح بالبيع النقدي', () async {
    final auth = AuthRepository(database);
    final manager = managerAccount;
    final cashier = await auth.createCashier(
      manager: manager,
      username: 'cashier_one',
      displayName: 'الكاشير الأول',
      password: 'CashierPass!2026',
    );
    final shift = await CashShiftRepository(database).openShift(
      userId: cashier.id,
      openingCash: 0,
    );
    final productId = await products.add(const GroceryProduct(
      name: 'ماء', sellingPrice: 100, stockQuantity: 10,
    ));
    final product = (await products.getById(productId))!;

    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 0,
      paidAmount: 100,
      paymentMethod: 'نقدي',
      userId: cashier.id,
      shiftId: shift.id,
    );
    expect(sale.total, 100);

    await expectLater(
      sales.createSale(
        lines: [SaleLine(product: product, quantity: 1)],
        discount: 1,
        paidAmount: 99,
        paymentMethod: 'نقدي',
        userId: cashier.id,
        shiftId: shift.id,
      ),
      throwsStateError,
    );
    await expectLater(
      sales.createSale(
        lines: [SaleLine(product: product, quantity: 1)],
        discount: 0,
        paidAmount: 0,
        paymentMethod: 'آجل',
        customerName: 'زبون',
        userId: cashier.id,
        shiftId: shift.id,
      ),
      throwsStateError,
    );
    final freeProductId = await products.add(const GroceryProduct(
      name: 'عينة مجانية', sellingPrice: 0, stockQuantity: 2,
    ));
    final freeProduct = (await products.getById(freeProductId))!;
    await expectLater(
      sales.createSale(
        lines: [SaleLine(product: freeProduct, quantity: 1)],
        discount: 0,
        paidAmount: 0,
        paymentMethod: 'نقدي',
        userId: cashier.id,
        shiftId: shift.id,
      ),
      throwsStateError,
    );
    expect(await sales.recentSales(userId: managerId), hasLength(1));
  });

  test('يمنع الكاشير من تسجيل مرتجع أو رد مبلغ حتى عند استدعاء المستودع مباشرة', () async {
    final auth = AuthRepository(database);
    final manager = managerAccount;
    final cashier = await auth.createCashier(
      manager: manager,
      username: 'cashier_one',
      displayName: 'الكاشير الأول',
      password: 'CashierPass!2026',
    );
    final shift = await CashShiftRepository(database).openShift(
      userId: cashier.id,
      openingCash: 0,
    );
    final productId = await products.add(const GroceryProduct(
      name: 'صابون', sellingPrice: 100, stockQuantity: 2,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 0,
      paidAmount: 100,
      paymentMethod: 'نقدي',
      userId: cashier.id,
      shiftId: shift.id,
    );
    final itemId = (await database.query(
      'sale_items',
      columns: ['id'],
      where: 'sale_id = ?',
      whereArgs: [sale.id],
    )).single['id'] as int;

    await expectLater(
      sales.returnItems(
        saleId: sale.id,
        quantitiesBySaleItemId: {itemId: 1},
        userId: cashier.id,
      ),
      throwsStateError,
    );
    await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 1},
    
      userId: managerId);
    await expectLater(
      sales.recordReturnRefund(
        saleId: sale.id,
        amount: 100,
        userId: cashier.id,
        shiftId: shift.id,
      ),
      throwsStateError,
    );
  });

  test('يرفض البيع النقدي إذا كانت الوردية غير مملوكة أو مغلقة', () async {
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
      name: 'ماء', sellingPrice: 100, stockQuantity: 4,
    ));
    final product = (await products.getById(productId))!;
    await expectLater(
      sales.createSale(
        lines: [SaleLine(product: product, quantity: 1)],
        discount: 0,
        paidAmount: 100,
        paymentMethod: 'نقدي',
        userId: cashier.id,
        shiftId: shift.id,
      ),
      throwsA(isA<CashShiftException>()),
    );
    await CashShiftRepository(database).closeShift(
      shiftId: shift.id,
      userId: manager.id,
      closingCash: 0,
    );
    await expectLater(
      sales.createSale(
        lines: [SaleLine(product: product, quantity: 1)],
        discount: 0,
        paidAmount: 100,
        paymentMethod: 'نقدي',
        userId: manager.id,
        shiftId: shift.id,
      ),
      throwsA(isA<CashShiftException>()),
    );
    expect(await sales.recentSales(userId: managerId), isEmpty);
    expect(await database.query('cash_transactions'), isEmpty);
  });

  test('يفرض صلاحية الخصم وحدها المالية للكاشير داخل معاملة البيع', () async {
    final auth = AuthRepository(database);
    final manager = managerAccount;
    final cashier = await auth.createCashier(
      manager: manager,
      username: 'cashier_sale',
      displayName: 'الكاشير',
      password: 'CashierPass!2026',
    );
    final settings = await auth.getCashierPermissions(
      manager: manager,
      cashierId: cashier.id,
    );
    await auth.saveCashierPermissions(
      manager: manager,
      cashierId: cashier.id,
      permissions: settings.map((setting) =>
        setting.key == 'discounts'
          ? CashierPermissionSetting(
              key: setting.key,
              label: setting.label,
              isAllowed: true,
              maxAmount: 30,
            )
          : setting
      ).toList(),
    );
    // أغلق وردية المدير قبل نقل ملكية الدرج إلى الكاشير.
    final managerShiftId = await ensureManagerShift();
    await CashShiftRepository(database).closeShift(
      shiftId: managerShiftId,
      userId: managerId,
      closingCash: 40,
    );
    final shift = await CashShiftRepository(database).openShift(
      userId: cashier.id,
      openingCash: 100,
    );
    final productId = await products.add(const GroceryProduct(
      name: 'سلعة اختبار الخصم',
      sellingPrice: 100,
      stockQuantity: 10,
    ));
    final product = (await products.getById(productId))!;

    await expectLater(
      sales.createSale(
        lines: [SaleLine(product: product, quantity: 1)],
        discount: 31,
        paidAmount: 69,
        paymentMethod: 'نقدي',
        userId: cashier.id,
        shiftId: shift.id,
      ),
      throwsStateError,
    );
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 30,
      paidAmount: 70,
      paymentMethod: 'نقدي',
      userId: cashier.id,
      shiftId: shift.id,
    );
    expect(sale.total, 70);
  });

  test('يقبل الخصم الذي تجاوز حد الكاشير بموافقة مدير مطابقة ويستهلكها مع الفاتورة', () async {
    final auth = AuthRepository(database);
    final cashier = await auth.createCashier(
      manager: managerAccount,
      username: 'cashier_approved_discount',
      displayName: 'كاشير الخصم',
      password: 'CashierPass!2026',
    );
    final settings = await auth.getCashierPermissions(
      manager: managerAccount,
      cashierId: cashier.id,
    );
    await auth.saveCashierPermissions(
      manager: managerAccount,
      cashierId: cashier.id,
      permissions: settings.map((setting) =>
        setting.key == 'discounts'
          ? CashierPermissionSetting(
              key: setting.key,
              label: setting.label,
              isAllowed: true,
              maxAmount: 30,
            )
          : setting
      ).toList(),
    );
    final shift = await CashShiftRepository(database).openShift(
      userId: cashier.id,
      openingCash: 100,
    );
    final productId = await products.add(const GroceryProduct(
      name: 'سلعة خصم بموافقة', sellingPrice: 100, stockQuantity: 5,
    ));
    final product = (await products.getById(productId))!;
    final grant = await ManagerApprovalRepository(database, auth).issueApproval(
      manager: managerAccount,
      managerPassword: managerPassword,
      scope: ManagerApprovalScope(
        cashierUserId: cashier.id,
        shiftId: shift.id,
        permissionKey: 'discounts',
        operationType: 'sale.create',
        amount: 31,
      ),
    );

    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 31,
      paidAmount: 69,
      paymentMethod: 'نقدي',
      userId: cashier.id,
      shiftId: shift.id,
      managerApprovalToken: grant.token,
    );

    expect(sale.total, 69);
    expect(await database.query('sales'), hasLength(1));
    expect(await database.query('cash_transactions'), hasLength(1));
    expect((await products.getById(productId))!.stockQuantity, 4);
    final approval = (await database.query('manager_approvals')).single;
    expect(approval['status'], 'consumed');
    expect(approval['consumed_at'], isNotNull);
  });

  test('يرفض الخصم إذا اختلف مبلغه عن نطاق الموافقة ولا ينشئ أي أثر مالي أو مخزني', () async {
    final auth = AuthRepository(database);
    final cashier = await auth.createCashier(
      manager: managerAccount,
      username: 'cashier_mismatched_discount',
      displayName: 'كاشير الخصم',
      password: 'CashierPass!2026',
    );
    final settings = await auth.getCashierPermissions(
      manager: managerAccount,
      cashierId: cashier.id,
    );
    await auth.saveCashierPermissions(
      manager: managerAccount,
      cashierId: cashier.id,
      permissions: settings.map((setting) =>
        setting.key == 'discounts'
          ? CashierPermissionSetting(
              key: setting.key,
              label: setting.label,
              isAllowed: true,
              maxAmount: 30,
            )
          : setting
      ).toList(),
    );
    final shift = await CashShiftRepository(database).openShift(
      userId: cashier.id,
      openingCash: 100,
    );
    final productId = await products.add(const GroceryProduct(
      name: 'سلعة خصم مختلف', sellingPrice: 100, stockQuantity: 5,
    ));
    final product = (await products.getById(productId))!;
    final grant = await ManagerApprovalRepository(database, auth).issueApproval(
      manager: managerAccount,
      managerPassword: managerPassword,
      scope: ManagerApprovalScope(
        cashierUserId: cashier.id,
        shiftId: shift.id,
        permissionKey: 'discounts',
        operationType: 'sale.create',
        amount: 31,
      ),
    );

    await expectLater(
      sales.createSale(
        lines: [SaleLine(product: product, quantity: 1)],
        discount: 32,
        paidAmount: 68,
        paymentMethod: 'نقدي',
        userId: cashier.id,
        shiftId: shift.id,
        managerApprovalToken: grant.token,
      ),
      throwsStateError,
    );

    expect(await database.query('sales'), isEmpty);
    expect(await database.query('cash_transactions'), isEmpty);
    expect((await products.getById(productId))!.stockQuantity, 5);
    expect((await database.query('manager_approvals')).single['status'], 'rejected');
  });

  test('يرفض موافقة الخصم المنتهية قبل حفظ الفاتورة أو حركة النقد', () async {
    final auth = AuthRepository(database);
    final cashier = await auth.createCashier(
      manager: managerAccount,
      username: 'cashier_expired_discount',
      displayName: 'كاشير الخصم',
      password: 'CashierPass!2026',
    );
    final settings = await auth.getCashierPermissions(
      manager: managerAccount,
      cashierId: cashier.id,
    );
    await auth.saveCashierPermissions(
      manager: managerAccount,
      cashierId: cashier.id,
      permissions: settings.map((setting) =>
        setting.key == 'discounts'
          ? CashierPermissionSetting(
              key: setting.key,
              label: setting.label,
              isAllowed: true,
              maxAmount: 30,
            )
          : setting
      ).toList(),
    );
    final shift = await CashShiftRepository(database).openShift(
      userId: cashier.id,
      openingCash: 100,
    );
    final productId = await products.add(const GroceryProduct(
      name: 'سلعة موافقة منتهية', sellingPrice: 100, stockQuantity: 5,
    ));
    final product = (await products.getById(productId))!;
    final grant = await ManagerApprovalRepository(database, auth).issueApproval(
      manager: managerAccount,
      managerPassword: managerPassword,
      scope: ManagerApprovalScope(
        cashierUserId: cashier.id,
        shiftId: shift.id,
        permissionKey: 'discounts',
        operationType: 'sale.create',
        amount: 31,
      ),
    );
    await database.update(
      'manager_approvals',
      {'expires_at': DateTime.now().toUtc().subtract(const Duration(minutes: 1)).toIso8601String()},
    );

    await expectLater(
      sales.createSale(
        lines: [SaleLine(product: product, quantity: 1)],
        discount: 31,
        paidAmount: 69,
        paymentMethod: 'نقدي',
        userId: cashier.id,
        shiftId: shift.id,
        managerApprovalToken: grant.token,
      ),
      throwsStateError,
    );

    expect(await database.query('sales'), isEmpty);
    expect(await database.query('cash_transactions'), isEmpty);
    expect((await products.getById(productId))!.stockQuantity, 5);
    expect((await database.query('manager_approvals')).single['status'], 'expired');
  });

  test('يرفض بيع الكاشير بالدين دون صلاحية أو عند تجاوز سقف الدين', () async {
    final auth = AuthRepository(database);
    final manager = managerAccount;
    final cashier = await auth.createCashier(
      manager: manager,
      username: 'cashier_credit',
      displayName: 'الكاشير',
      password: 'CashierPass!2026',
    );
    final productId = await products.add(const GroceryProduct(
      name: 'سلعة اختبار الدين',
      sellingPrice: 100,
      stockQuantity: 10,
    ));
    final product = (await products.getById(productId))!;
    final shift = await CashShiftRepository(database).openShift(
      userId: cashier.id,
      openingCash: 100,
    );

    await expectLater(
      sales.createSale(
        lines: [SaleLine(product: product, quantity: 1)],
        discount: 0,
        paidAmount: 0,
        paymentMethod: 'آجل',
        customerName: 'عميل اختبار',
        userId: cashier.id,
        shiftId: shift.id,
      ),
      throwsStateError,
    );

    final defaults = await auth.getCashierPermissions(
      manager: manager,
      cashierId: cashier.id,
    );
    await auth.saveCashierPermissions(
      manager: manager,
      cashierId: cashier.id,
      permissions: defaults.map((setting) =>
        setting.key == 'credit_sales'
          ? CashierPermissionSetting(
              key: setting.key,
              label: setting.label,
              isAllowed: true,
              maxAmount: 40,
            )
          : setting
      ).toList(),
    );
    await expectLater(
      sales.createSale(
        lines: [SaleLine(product: product, quantity: 1)],
        discount: 0,
        paidAmount: 50,
        paymentMethod: 'جزئي',
        customerName: 'عميل اختبار',
        userId: cashier.id,
        shiftId: shift.id,
      ),
      throwsStateError,
    );
    final allowed = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 0,
      paidAmount: 60,
      paymentMethod: 'جزئي',
      customerName: 'عميل اختبار آخر',
      userId: cashier.id,
      shiftId: shift.id,
    );
    expect(allowed.remainingAmount, 40);
  });

  test('يفرض صلاحية المرتجعات ورد المبالغ وحدودهما للكاشير', () async {
    final auth = AuthRepository(database);
    final manager = managerAccount;
    final cashier = await auth.createCashier(
      manager: manager,
      username: 'cashier_returns',
      displayName: 'الكاشير',
      password: 'CashierPass!2026',
    );
    final productId = await products.add(const GroceryProduct(
      name: 'سلعة اختبار المرتجع',
      sellingPrice: 40,
      stockQuantity: 5,
    ));
    final product = (await products.getById(productId))!;
    final managerShiftId = await ensureManagerShift();
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 0,
      paidAmount: 40,
      paymentMethod: 'نقدي',
      userId: managerId,
      shiftId: managerShiftId,
    );
    final itemId = (await database.query(
      'sale_items',
      columns: ['id'],
      where: 'sale_id = ?',
      whereArgs: [sale.id],
    )).single['id'] as int;

    // أغلق وردية المدير بعد إتمام فاتورته وقبل فتح وردية الكاشير.
    await CashShiftRepository(database).closeShift(
      shiftId: managerShiftId,
      userId: managerId,
      closingCash: 40,
    );

    await expectLater(
      sales.returnItems(
        saleId: sale.id,
        quantitiesBySaleItemId: {itemId: 1},
        userId: cashier.id,
      ),
      throwsStateError,
    );

    final defaults = await auth.getCashierPermissions(
      manager: manager,
      cashierId: cashier.id,
    );
    await auth.saveCashierPermissions(
      manager: manager,
      cashierId: cashier.id,
      permissions: defaults.map((setting) {
        if (setting.key == 'returns') {
          return CashierPermissionSetting(
            key: setting.key,
            label: setting.label,
            isAllowed: true,
            maxAmount: 40,
          );
        }
        if (setting.key == 'return_refunds') {
          return CashierPermissionSetting(
            key: setting.key,
            label: setting.label,
            isAllowed: true,
            maxAmount: 30,
          );
        }
        return setting;
      }).toList(),
    );
    final shift = await CashShiftRepository(database).openShift(
      userId: cashier.id,
      openingCash: 100,
    );
    final returned = await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 1},
      userId: cashier.id,
      shiftId: shift.id,
    );
    expect(returned.amount, 40);

    await expectLater(
      sales.recordReturnRefund(
        saleId: sale.id,
        amount: 31,
        userId: cashier.id,
        shiftId: shift.id,
      ),
      throwsStateError,
    );
    await sales.recordReturnRefund(
      saleId: sale.id,
      amount: 30,
      userId: cashier.id,
      shiftId: shift.id,
    );
    expect(await sales.maximumRefundableAmount(sale.id , userId: managerId), 10);
  });

}
