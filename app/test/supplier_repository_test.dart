// اختبارات الموردين والمشتريات وتحديث المخزون والمدفوعات.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/auth_repository.dart';
import 'package:homi_grocery/data/cash_shift_repository.dart';
import 'package:homi_grocery/data/grocery_database.dart';
import 'package:homi_grocery/data/product_repository.dart';
import 'package:homi_grocery/data/supplier_repository.dart';

void main() {
  late Database database;
  late ProductRepository products;
  late SupplierRepository suppliers;
  late int managerId;
  late AuthUser managerAccount;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createAuthSchema(database);
    await GroceryDatabase.createSalesSchema(database);
    await GroceryDatabase.createCustomersSchema(database);
    await GroceryDatabase.createStockMovementsSchema(database);
    await GroceryDatabase.createSalesReturnsSchema(database);
    await GroceryDatabase.createPurchasesSchema(database);
    await GroceryDatabase.createCashTransactionsSchema(database);
    await GroceryDatabase.createCashShiftsSchema(database);
    await GroceryDatabase.createSupplierReturnsSchema(database);
    await GroceryDatabase.createSupplierReturnRefundsSchema(database);
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
    products = ProductRepository(database, userId: managerId);
    suppliers = SupplierRepository(database);
  });

  tearDown(() async => database.close());


  test('يمنع الكاشير من قراءة أرصدة الموردين افتراضيًا', () async {
    final cashierId = await database.insert('users', {
      'username': 'test_cashier', 'display_name': 'كاشير الاختبار',
      'password_hash': 'test-hash', 'password_salt': 'test-salt',
      'password_iterations': 100000, 'role': 'cashier', 'is_active': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await expectLater(
      suppliers.balances(userId: cashierId),
      throwsA(isA<StateError>()),
    );
  });

  test('يسمح بالبحث عن اسم المورد بصلاحية الشراء دون كشف رصيده', () async {
    final auth = AuthRepository(database);
    final cashier = await auth.createCashier(manager: managerAccount, username: 'supplier_lookup_cashier', displayName: 'كاشير شراء', password: 'CashierPass!2026');
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد بحث محدود');
    final settings = await auth.getCashierPermissions(manager: managerAccount, cashierId: cashier.id);
    await auth.saveCashierPermissions(manager: managerAccount, cashierId: cashier.id, permissions: settings.map((setting) => setting.key == 'supplier_purchases' ? CashierPermissionSetting(key: setting.key, label: setting.label, isAllowed: true) : setting).toList());
    final lookup = await suppliers.supplierLookup(userId: cashier.id);
    expect(lookup.single.id, supplierId);
    expect(lookup.single.name, 'مورد بحث محدود');
    await expectLater(suppliers.balances(userId: cashier.id), throwsStateError);
  });

  test('يفصل صلاحية مرتجعات المورد عن سجل المبالغ وصلاحية استلام الاسترداد', () async {
    final auth = AuthRepository(database);
    final cashier = await auth.createCashier(
      manager: managerAccount,
      username: 'supplier_returns_only',
      displayName: 'كاشير المرتجعات فقط',
      password: 'CashierPass!2026',
    );
    final productId = await products.add(const GroceryProduct(
      name: 'زيت', purchasePrice: 200, sellingPrice: 250, stockQuantity: 2,
    ));
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد المرتجعات');
    final purchase = await suppliers.createPurchase(
      userId: managerId,
      supplierId: supplierId,
      lines: [PurchaseLine(productId: productId, productName: 'زيت', unit: 'عبوة', quantity: 2, unitCost: 200)],
      paidAmount: 0,
    );
    final settings = await auth.getCashierPermissions(manager: managerAccount, cashierId: cashier.id);
    await auth.saveCashierPermissions(
      manager: managerAccount,
      cashierId: cashier.id,
      permissions: settings.map((setting) => setting.key == 'supplier_returns'
          ? CashierPermissionSetting(key: setting.key, label: setting.label, isAllowed: true)
          : setting).toList(),
    );

    final lookup = await suppliers.purchaseHistoryForReturns(userId: cashier.id);
    expect(lookup.single.id, purchase.id);
    expect(lookup.single.invoiceNumber, purchase.invoiceNumber);
    expect(lookup.single.supplierName, 'مورد المرتجعات');
    await expectLater(suppliers.purchaseHistory(userId: cashier.id), throwsStateError);
    await expectLater(suppliers.purchaseItems(purchase.id, userId: cashier.id), throwsStateError);
    final itemId = (await suppliers.returnablePurchaseItems(purchase.id, userId: cashier.id)).single['id'] as int;
    final returnId = await suppliers.createSupplierReturn(
      userId: cashier.id,
      purchaseId: purchase.id,
      quantitiesByPurchaseItemId: {itemId: 1},
    );
    await expectLater(suppliers.maximumRefundableSupplierReturnAmount(returnId, userId: cashier.id), throwsStateError);
  });

  test('يعرض للكاشير استردادات المورد المعلقة دون كشف دفتر الموردين', () async {
    final auth = AuthRepository(database);
    final cashier = await auth.createCashier(
      manager: managerAccount,
      username: 'supplier_refund_only',
      displayName: 'كاشير استلام الاسترداد',
      password: 'CashierPass!2026',
    );
    final productId = await products.add(const GroceryProduct(
      name: 'أرز', purchasePrice: 100, sellingPrice: 140, stockQuantity: 3,
    ));
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد الاستردادات');
    final purchase = await suppliers.createPurchase(
      userId: managerId,
      supplierId: supplierId,
      lines: [PurchaseLine(productId: productId, productName: 'أرز', unit: 'كيلو', quantity: 3, unitCost: 100)],
      paidAmount: 0,
    );
    final itemId = (await suppliers.returnablePurchaseItems(purchase.id, userId: managerId)).single['id'] as int;
    final returnId = await suppliers.createSupplierReturn(
      userId: managerId,
      purchaseId: purchase.id,
      quantitiesByPurchaseItemId: {itemId: 1},
    );
    final settings = await auth.getCashierPermissions(manager: managerAccount, cashierId: cashier.id);
    await auth.saveCashierPermissions(
      manager: managerAccount,
      cashierId: cashier.id,
      permissions: settings.map((setting) => setting.key == 'supplier_return_refunds'
          ? CashierPermissionSetting(key: setting.key, label: setting.label, isAllowed: true)
          : setting).toList(),
    );

    final pending = await suppliers.pendingSupplierReturnRefunds(userId: cashier.id);
    expect(pending, hasLength(1));
    expect(pending.single.returnId, returnId);
    expect(pending.single.invoiceNumber, purchase.invoiceNumber);
    expect(pending.single.supplierName, 'مورد الاستردادات');
    expect(pending.single.refundableAmount, 100);
    await expectLater(suppliers.balances(userId: cashier.id), throwsStateError);
    await expectLater(suppliers.purchaseHistory(userId: cashier.id), throwsStateError);

    await suppliers.recordSupplierReturnRefund(
      userId: cashier.id,
      returnId: returnId,
      amount: 40,
      paymentMethod: 'تحويل بنكي',
    );
    final remaining = await suppliers.pendingSupplierReturnRefunds(userId: cashier.id);
    expect(remaining.single.refundableAmount, 60);
  });

  test('يفرض صلاحيات قراءة المشتريات ومرتجعات المورد وحدود الاسترداد', () async {
    final auth = AuthRepository(database);
    final cashier = await auth.createCashier(
      manager: managerAccount,
      username: 'supplier_permissions_cashier',
      displayName: 'كاشير الموردين',
      password: 'CashierPass!2026',
    );
    final productId = await products.add(const GroceryProduct(
      name: 'حليب', purchasePrice: 100, sellingPrice: 150, stockQuantity: 0,
    ));
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد الصلاحيات');
    final purchase = await suppliers.createPurchase(
        userId: managerId,
      supplierId: supplierId,
      lines: [PurchaseLine(
        productId: productId,
        productName: 'حليب',
        unit: 'عبوة',
        quantity: 1,
        unitCost: 100,
      )],
      paidAmount: 0,
    );
    final itemId = (await suppliers.returnablePurchaseItems(
      purchase.id, userId: managerId,
    )).single['id'] as int;
    final managerReturnId = await suppliers.createSupplierReturn(
      userId: managerId,
      purchaseId: purchase.id,
      quantitiesByPurchaseItemId: {itemId: 0.5},
    );

    await expectLater(
      suppliers.purchaseHistory(userId: cashier.id),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      suppliers.purchaseItems(purchase.id, userId: cashier.id),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      suppliers.returnablePurchaseItems(purchase.id, userId: cashier.id),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      suppliers.maximumRefundableSupplierReturnAmount(managerReturnId, userId: cashier.id),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      suppliers.createSupplierReturn(
        userId: cashier.id,
        purchaseId: purchase.id,
        quantitiesByPurchaseItemId: {itemId: 0.2},
      ),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      suppliers.recordSupplierReturnRefund(
        userId: cashier.id,
        returnId: managerReturnId,
        amount: 10,
        paymentMethod: 'تحويل بنكي',
      ),
      throwsA(isA<StateError>()),
    );

    final settings = await auth.getCashierPermissions(
      manager: managerAccount,
      cashierId: cashier.id,
    );
    await auth.saveCashierPermissions(
      manager: managerAccount,
      cashierId: cashier.id,
      permissions: settings.map((setting) {
        if (setting.key == 'view_supplier_data') {
          return CashierPermissionSetting(
            key: setting.key, label: setting.label, isAllowed: true,
          );
        }
        if (setting.key == 'supplier_returns') {
          return CashierPermissionSetting(
            key: setting.key, label: setting.label, isAllowed: true, maxAmount: 30,
          );
        }
        if (setting.key == 'supplier_return_refunds') {
          return CashierPermissionSetting(
            key: setting.key, label: setting.label, isAllowed: true, maxAmount: 20,
          );
        }
        return setting;
      }).toList(),
    );

    expect(await suppliers.purchaseHistory(userId: cashier.id), hasLength(1));
    expect(await suppliers.purchaseItems(purchase.id, userId: cashier.id), hasLength(1));
    expect(await suppliers.returnablePurchaseItems(purchase.id, userId: cashier.id), hasLength(1));
    expect(await suppliers.maximumRefundableSupplierReturnAmount(
      managerReturnId, userId: cashier.id,
    ), 50);
    await expectLater(
      suppliers.createSupplierReturn(
        userId: cashier.id,
        purchaseId: purchase.id,
        quantitiesByPurchaseItemId: {itemId: 0.4},
      ),
      throwsA(isA<StateError>()),
    );
    final cashierReturnId = await suppliers.createSupplierReturn(
      userId: cashier.id,
      purchaseId: purchase.id,
      quantitiesByPurchaseItemId: {itemId: 0.2},
    );
    await expectLater(
      suppliers.recordSupplierReturnRefund(
        userId: cashier.id,
        returnId: managerReturnId,
        amount: 21,
        paymentMethod: 'تحويل بنكي',
      ),
      throwsA(isA<StateError>()),
    );
    await suppliers.recordSupplierReturnRefund(
      userId: cashier.id,
      returnId: managerReturnId,
      amount: 20,
      paymentMethod: 'تحويل بنكي',
    );
    expect(await suppliers.maximumRefundableSupplierReturnAmount(
      managerReturnId, userId: cashier.id,
    ), 30);
    expect(await database.query('supplier_returns', where: 'id = ?', whereArgs: [cashierReturnId]), hasLength(1));
  });

  test('يحفظ فاتورة الشراء ويزيد المخزون ويسجل حركة الشراء', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'سكر', purchasePrice: 100, sellingPrice: 150, stockQuantity: 4,
    ));
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد السكر');
    final purchase = await suppliers.createPurchase(
        userId: managerId,
      supplierId: supplierId,
      lines: [PurchaseLine(productId: productId, productName: 'سكر', unit: 'كيلوجرام', quantity: 3, unitCost: 120, sellingPrice: 180)],
      discount: 20,
      paidAmount: 100,
      paymentMethod: 'جزئي',
      paymentChannel: 'تحويل بنكي',
    );

    expect(purchase.subtotal, 360);
    expect(purchase.total, 340);
    expect(purchase.remainingAmount, 240);
    expect((await products.getById(productId))!.stockQuantity, 7);
    expect((await products.getById(productId))!.purchasePrice, 120);
    expect((await products.getById(productId))!.sellingPrice, 180);
    expect(await database.query('purchase_items'), hasLength(1));
    final movements = await database.query('stock_movements', where: "reference_type = 'purchase'");
    expect(movements, hasLength(1));
    expect(movements.single['quantity_delta'], 3);
    expect((await suppliers.balances(userId: managerId)).single.balance, 240);
    final cashEntries = await database.query('cash_transactions', where: "reference_type = 'purchase'");
    expect(cashEntries, hasLength(1));
    expect(cashEntries.single['direction'], 'out');
    expect(cashEntries.single['amount'], 100);
    expect(cashEntries.single['payment_method'], 'تحويل بنكي');
  });

  test('يشترط وردية المستخدم النشطة لشراء النقد وسداد المورد نقدًا', () async {
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
      name: 'سكر', purchasePrice: 100, sellingPrice: 150, stockQuantity: 0,
    ));
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد الوردية');
    final purchase = await suppliers.createPurchase(
      supplierId: supplierId,
      lines: [
        PurchaseLine(
          productId: productId,
          productName: 'سكر',
          unit: 'كيلوجرام',
          quantity: 1,
          unitCost: 100,
        ),
      ],
      paidAmount: 40,
      paymentChannel: 'نقدي',
      userId: manager.id,
      shiftId: shift.id,
    );
    await suppliers.recordPayment(
      supplierId: supplierId,
      amount: 20,
      userId: manager.id,
      shiftId: shift.id,
    );

    await expectLater(
      suppliers.recordPayment(
        supplierId: supplierId,
        amount: 10,
        userId: cashier.id,
        shiftId: shift.id,
      ),
      throwsA(isA<CashShiftException>()),
    );
    await CashShiftRepository(database).closeShift(
      shiftId: shift.id,
      userId: manager.id,
      closingCash: 60,
    );
    await expectLater(
      suppliers.recordPayment(
        supplierId: supplierId,
        amount: 10,
        userId: manager.id,
        shiftId: shift.id,
      ),
      throwsA(isA<CashShiftException>()),
    );

    final entries = await database.query('cash_transactions');
    expect(entries, hasLength(2));
    expect(entries.every((row) => row['shift_id'] == shift.id), isTrue);
    expect(purchase.paidAmount, 40);
  });

  test('يشترط الوردية النشطة لاسترداد مرتجع المورد نقدًا', () async {
    final manager = managerAccount;
    final shift = await CashShiftRepository(database).openShift(
      userId: manager.id,
      openingCash: 0,
    );
    final productId = await products.add(const GroceryProduct(
      name: 'حليب', purchasePrice: 100, sellingPrice: 150, stockQuantity: 0,
    ));
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد الاسترداد النقدي');
    final purchase = await suppliers.createPurchase(
      supplierId: supplierId,
      lines: [
        PurchaseLine(
          productId: productId,
          productName: 'حليب',
          unit: 'عبوة',
          quantity: 1,
          unitCost: 100,
        ),
      ],
      paidAmount: 100,
      paymentChannel: 'نقدي',
      userId: manager.id,
      shiftId: shift.id,
    );
    final itemId = (await suppliers.returnablePurchaseItems(purchase.id, userId: managerId))
        .single['id'] as int;
    final returnId = await suppliers.createSupplierReturn(
      userId: managerId,
      purchaseId: purchase.id,
      quantitiesByPurchaseItemId: {itemId: 1},
    );
    await suppliers.recordSupplierReturnRefund(
      userId: manager.id,
      returnId: returnId,
      amount: 50,
      paymentMethod: 'نقدي',
      shiftId: shift.id,
    );
    final refund = (await database.query(
      'cash_transactions',
      where: "reference_type = 'supplier_return_refund'",
    )).single;
    expect(refund['user_id'], manager.id);
    expect(refund['shift_id'], shift.id);
    expect(refund['direction'], 'in');
  });


  test('يرفض وسيلة استرداد غير معتمدة من المورد دون تسجيل حركة مالية', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'صنف استرداد غير معتمد', purchasePrice: 100, sellingPrice: 150, stockQuantity: 0,
    ));
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد وسيلة الدفع');
    final purchase = await suppliers.createPurchase(
      supplierId: supplierId,
      lines: [PurchaseLine(productId: productId, productName: 'صنف استرداد غير معتمد',
        unit: 'حبة', quantity: 1, unitCost: 100)],
      paidAmount: 100,
      paymentChannel: 'تحويل بنكي',
      userId: managerId,
    );
    final itemId = (await suppliers.returnablePurchaseItems(
      purchase.id, userId: managerId,
    )).single['id'] as int;
    final returnId = await suppliers.createSupplierReturn(
      userId: managerId,
      purchaseId: purchase.id,
      quantitiesByPurchaseItemId: {itemId: 1},
    );

    await expectLater(
      suppliers.recordSupplierReturnRefund(
        userId: managerId, returnId: returnId, amount: 50,
        paymentMethod: 'شيك',
      ),
      throwsArgumentError,
    );
    expect(await database.query('supplier_return_refunds'), isEmpty);
    expect(await database.query('cash_transactions',
      where: "reference_type = 'supplier_return_refund'"), isEmpty);
  });

  test('يدعم عدة أصناف في فاتورة واحدة ويحدّث المخزون لكل صنف', () async {
    final riceId = await products.add(const GroceryProduct(
      name: 'أرز', purchasePrice: 100, sellingPrice: 150, stockQuantity: 2,
    ));
    final oilId = await products.add(const GroceryProduct(
      name: 'زيت', purchasePrice: 200, sellingPrice: 280, stockQuantity: 5,
    ));
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد متعدد الأصناف');

    final purchase = await suppliers.createPurchase(
        paymentChannel: 'تحويل بنكي',
        userId: managerId,
      supplierId: supplierId,
      lines: [
        PurchaseLine(productId: riceId, productName: 'أرز', unit: 'كيلوجرام', quantity: 3, unitCost: 110),
        PurchaseLine(productId: oilId, productName: 'زيت', unit: 'عبوة', quantity: 2, unitCost: 210),
      ],
      discount: 20,
      paidAmount: 100,
    );

    expect(purchase.subtotal, 750);
    expect(purchase.total, 730);
    expect((await products.getById(riceId))!.stockQuantity, 5);
    expect((await products.getById(oilId))!.stockQuantity, 7);
    expect(await database.query('purchase_items'), hasLength(2));
    expect(await database.query('stock_movements', where: "reference_type = 'purchase'"), hasLength(2));
  });

  test('أي صنف غير موجود يلغي فاتورة الشراء وكل تغييرات المخزون', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'طحين', purchasePrice: 100, sellingPrice: 150, stockQuantity: 3,
    ));
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد الطحين');

    await expectLater(
      suppliers.createPurchase(
        userId: managerId,
        supplierId: supplierId,
        lines: [
          PurchaseLine(productId: productId, productName: 'طحين', unit: 'كيلوجرام', quantity: 2, unitCost: 100),
          const PurchaseLine(productId: 999999, productName: 'غير موجود', unit: 'حبة', quantity: 1, unitCost: 50),
        ],
        paidAmount: 0,
      ),
      throwsArgumentError,
    );

    expect((await products.getById(productId))!.stockQuantity, 3);
    expect((await products.getById(productId))!.sellingPrice, 150);
    expect(await database.query('purchases'), isEmpty);
    expect(await database.query('purchase_items'), isEmpty);
    expect(await database.query('stock_movements', where: "reference_type = 'purchase'"), isEmpty);
  });

  test('يرفض الخصم أو المدفوع الزائد دون تعديل المخزون', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'أرز', purchasePrice: 100, sellingPrice: 150, stockQuantity: 2,
    ));
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد الأرز');
    final line = PurchaseLine(productId: productId, productName: 'أرز', unit: 'كيلوجرام', quantity: 2, unitCost: 100);

    await expectLater(
      suppliers.createPurchase(
        userId: managerId,supplierId: supplierId, lines: [line], discount: 201, paidAmount: 0),
      throwsArgumentError,
    );
    await expectLater(
      suppliers.createPurchase(
        paymentChannel: 'تحويل بنكي',
        userId: managerId,supplierId: supplierId, lines: [line], paidAmount: 201),
      throwsArgumentError,
    );
    expect((await products.getById(productId))!.stockQuantity, 2);
    expect(await database.query('purchases'), isEmpty);
    expect(await database.query('stock_movements', where: "reference_type = 'purchase'"), isEmpty);
  });

  test('يسجل دفعة المورد ويمنع تجاوز المستحق', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'زيت', purchasePrice: 50, sellingPrice: 80, stockQuantity: 1,
    ));
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد الزيت');
    await suppliers.createPurchase(
        paymentChannel: 'تحويل بنكي',
        userId: managerId,
      supplierId: supplierId,
      lines: [PurchaseLine(productId: productId, productName: 'زيت', unit: 'عبوة', quantity: 2, unitCost: 50)],
      paidAmount: 20,
    );

    expect((await suppliers.balances(userId: managerId)).single.balance, 80);
    await suppliers.recordPayment(
        userId: managerId,supplierId: supplierId, amount: 30, paymentMethod: 'تحويل بنكي', note: 'دفعة بنكية');
    expect((await suppliers.balances(userId: managerId)).single.balance, 50);
    await expectLater(
      suppliers.recordPayment(
        userId: managerId,supplierId: supplierId, amount: 51, paymentMethod: 'تحويل بنكي'),
      throwsArgumentError,
    );
    expect(await database.query('supplier_payments'), hasLength(1));
    final cashEntries = await database.query('cash_transactions', where: "reference_type = 'supplier_payment'");
    expect(cashEntries.single['payment_method'], 'تحويل بنكي');
    expect(cashEntries.single['direction'], 'out');
  });

  test('يعرض سجل فواتير الشراء وبنودها كما حُفظت', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'سكر', purchasePrice: 100, sellingPrice: 150, stockQuantity: 0,
    ));
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد السكر');
    final purchase = await suppliers.createPurchase(
        paymentChannel: 'تحويل بنكي',
        userId: managerId,
      supplierId: supplierId,
      lines: [
        PurchaseLine(productId: productId, productName: 'سكر وقت الشراء', unit: 'كيلوجرام', quantity: 2, unitCost: 125),
      ],
      discount: 10,
      paidAmount: 100,
      note: 'اختبار السجل',
    );

    final history = await suppliers.purchaseHistory(userId: managerId);
    expect(history, hasLength(1));
    expect(history.single.id, purchase.id);
    expect(history.single.invoiceNumber, purchase.invoiceNumber);
    expect(history.single.supplierName, 'مورد السكر');
    expect(history.single.subtotal, 250);
    expect(history.single.discount, 10);
    expect(history.single.total, 240);
    expect(history.single.paidAmount, 100);
    expect(history.single.remainingAmount, 140);
    expect(history.single.note, 'اختبار السجل');

    final items = await suppliers.purchaseItems(purchase.id, userId: managerId);
    expect(items, hasLength(1));
    expect(items.single.productName, 'سكر وقت الشراء');
    expect(items.single.unitCost, 125);
    expect(items.single.lineTotal, 250);
    expect(await suppliers.purchaseHistory(userId: managerId, supplierId: supplierId), hasLength(1));
    expect(await suppliers.purchaseHistory(userId: managerId, supplierId: supplierId + 1), isEmpty);
  });

  test('يرفض حد سجل مشتريات غير صالح', () async {
    await expectLater(suppliers.purchaseHistory(userId: managerId, limit: 0), throwsArgumentError);
    await expectLater(suppliers.purchaseHistory(userId: managerId, limit: 1001), throwsArgumentError);
  });

  test('مرتجع المورد يخفض المخزون والمستحق ويسجل حركة عكسية ذريًا', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'أرز', purchasePrice: 100, sellingPrice: 150, stockQuantity: 0,
    ));
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد الأرز');
    final purchase = await suppliers.createPurchase(
        userId: managerId,
      supplierId: supplierId,
      lines: [PurchaseLine(productId: productId, productName: 'أرز', unit: 'كيلوجرام', quantity: 4, unitCost: 100)],
      paidAmount: 0,
    );
    final items = await suppliers.returnablePurchaseItems(purchase.id, userId: managerId);
    final itemId = items.single['id'] as int;

    final returnId = await suppliers.createSupplierReturn(
      userId: managerId,
      purchaseId: purchase.id,
      quantitiesByPurchaseItemId: {itemId: 1},
      note: 'صنف تالف',
    );

    expect((await products.getById(productId))!.stockQuantity, 3);
    expect((await suppliers.balances(userId: managerId)).single.balance, 300);
    final returns = await database.query('supplier_returns', where: 'id = ?', whereArgs: [returnId]);
    expect(returns.single['amount'], 100);
    final lines = await database.query('supplier_return_items', where: 'return_id = ?', whereArgs: [returnId]);
    expect(lines.single['quantity'], 1);
    final movements = await database.query('stock_movements', where: "reference_type = 'supplier_return'");
    expect(movements, hasLength(1));
    expect(movements.single['quantity_delta'], -1);
    expect(movements.single['stock_before'], 4);
    expect(movements.single['stock_after'], 3);
    expect(await database.query('cash_transactions', where: "reference_type = 'supplier_return'"), isEmpty);
  });

  test('يوزع خصم الشراء على المرتجعات الجزئية دون تكرار الخصم', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'سكر', purchasePrice: 100, sellingPrice: 150, stockQuantity: 0,
    ));
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد السكر بخصم');
    final purchase = await suppliers.createPurchase(
        userId: managerId,
      supplierId: supplierId,
      lines: [PurchaseLine(productId: productId, productName: 'سكر', unit: 'كيلوجرام', quantity: 2, unitCost: 100)],
      discount: 20,
      paidAmount: 0,
    );
    final itemId = (await suppliers.returnablePurchaseItems(purchase.id, userId: managerId)).single['id'] as int;
    final first = await suppliers.createSupplierReturn(
      userId: managerId,
      purchaseId: purchase.id,
      quantitiesByPurchaseItemId: {itemId: 1},
    );
    final second = await suppliers.createSupplierReturn(
      userId: managerId,
      purchaseId: purchase.id,
      quantitiesByPurchaseItemId: {itemId: 1},
    );
    final returns = await database.query('supplier_returns');
    expect(returns, hasLength(2));
    expect(first, isNot(second));
    expect(returns.fold<int>(0, (sum, row) => sum + (row['amount'] as int)), 180);
    expect((await suppliers.balances(userId: managerId)).single.balance, 0);
    expect((await products.getById(productId))!.stockQuantity, 0);
  });

  test('يرفض تجاوز كمية الفاتورة أو المستحق دون تعديل البيانات', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'زيت', purchasePrice: 50, sellingPrice: 80, stockQuantity: 0,
    ));
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد الزيت');
    final purchase = await suppliers.createPurchase(
        userId: managerId,
      supplierId: supplierId,
      lines: [PurchaseLine(productId: productId, productName: 'زيت', unit: 'عبوة', quantity: 2, unitCost: 50)],
      paidAmount: 0,
    );
    final itemId = (await suppliers.returnablePurchaseItems(purchase.id, userId: managerId)).single['id'] as int;

    await suppliers.createSupplierReturn(
      userId: managerId,
      purchaseId: purchase.id,
      quantitiesByPurchaseItemId: {itemId: 1},
    );
    await expectLater(
      suppliers.createSupplierReturn(
      userId: managerId,
        purchaseId: purchase.id,
        quantitiesByPurchaseItemId: {itemId: 2},
      ),
      throwsArgumentError,
    );
    expect((await products.getById(productId))!.stockQuantity, 1);
    expect(await database.query('supplier_returns'), hasLength(1));
    expect(await database.query('supplier_return_items'), hasLength(1));
  });

  test('يسمح برصيد دائن بعد مرتجع فاتورة مدفوعة ويسجل الاسترداد النقدي منفصلًا', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'حليب', purchasePrice: 100, sellingPrice: 150, stockQuantity: 0,
    ));
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد الحليب');
    final purchase = await suppliers.createPurchase(
        paymentChannel: 'تحويل بنكي',
        userId: managerId,
      supplierId: supplierId,
      lines: [PurchaseLine(productId: productId, productName: 'حليب', unit: 'عبوة', quantity: 1, unitCost: 100)],
      paidAmount: 100,
      paymentMethod: 'نقدي',
    );
    final itemId = (await suppliers.returnablePurchaseItems(purchase.id, userId: managerId)).single['id'] as int;
    final returnId = await suppliers.createSupplierReturn(
      userId: managerId,
      purchaseId: purchase.id,
      quantitiesByPurchaseItemId: {itemId: 1},
    );

    var balance = (await suppliers.balances(userId: managerId)).single;
    expect(balance.balance, -100);
    expect(balance.credit, 100);
    expect(await suppliers.maximumRefundableSupplierReturnAmount(returnId, userId: managerId), 100);
    expect(await database.query('cash_transactions', where: "reference_type = 'supplier_return_refund'"), isEmpty);

    await expectLater(
      suppliers.recordSupplierReturnRefund(userId: managerId, returnId: returnId, amount: 101, paymentMethod: 'تحويل بنكي'),
      throwsArgumentError,
    );
    await suppliers.recordSupplierReturnRefund(
      userId: managerId,
      returnId: returnId,
      amount: 40,
      paymentMethod: 'تحويل بنكي',
    );
    balance = (await suppliers.balances(userId: managerId)).single;
    expect(balance.balance, -60);
    expect(balance.credit, 60);
    expect(await suppliers.maximumRefundableSupplierReturnAmount(returnId, userId: managerId), 60);
    final cashEntries = await database.query(
      'cash_transactions',
      where: "reference_type = 'supplier_return_refund'",
    );
    expect(cashEntries, hasLength(1));
    expect(cashEntries.single['direction'], 'in');
    expect(cashEntries.single['amount'], 40);
    expect(cashEntries.single['payment_method'], 'تحويل بنكي');
  });

  test('يرفض اسم المورد الفارغ', () async {
    await expectLater(suppliers.addSupplier(userId: managerId, name: '  '), throwsArgumentError);
  });
  test('يمنع الكاشير والحساب الموقوف من إنشاء مورد مباشرة عبر المستودع', () async {
    final cashierId = await database.insert('users', {
      'username': 'supplier_create_cashier', 'display_name': 'كاشير',
      'password_hash': 'test-hash', 'password_salt': 'test-salt',
      'password_iterations': 100000, 'role': 'cashier', 'is_active': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await expectLater(
      suppliers.addSupplier(userId: cashierId, name: 'مورد ممنوع'),
      throwsA(isA<StateError>()),
    );
    await database.update('users', {'is_active': 0}, where: 'id = ?', whereArgs: [managerId]);
    await expectLater(
      suppliers.addSupplier(userId: managerId, name: 'مورد من مدير موقوف'),
      throwsA(isA<StateError>()),
    );
    expect(await database.query('suppliers'), isEmpty);
    expect(await database.query('auth_audit_log'), isEmpty);
  });

  test('يفرض صلاحيات وحدود فواتير الشراء ومدفوعات المورد للكاشير', () async {
    final auth = AuthRepository(database);
    final manager = managerAccount;
    final cashier = await auth.createCashier(
      manager: manager,
      username: 'supplier_cashier',
      displayName: 'الكاشير',
      password: 'CashierPass!2026',
    );
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد الصلاحيات');
    final productId = await products.add(const GroceryProduct(
      name: 'صنف المورد',
      purchasePrice: 100,
      sellingPrice: 150,
      stockQuantity: 0,
    ));
    final line = PurchaseLine(
      productId: productId,
      productName: 'صنف المورد',
      unit: 'قطعة',
      quantity: 1,
      unitCost: 400,
    );

    await expectLater(
      suppliers.createPurchase(
        supplierId: supplierId,
        lines: [line],
        paidAmount: 0,
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
      permissions: settings.map((setting) {
        if (setting.key == 'supplier_purchases') {
          return CashierPermissionSetting(
            key: setting.key,
            label: setting.label,
            isAllowed: true,
            maxAmount: 350,
          );
        }
        if (setting.key == 'supplier_payments') {
          return CashierPermissionSetting(
            key: setting.key,
            label: setting.label,
            isAllowed: true,
            maxAmount: 200,
          );
        }
        return setting;
      }).toList(),
    );

    await expectLater(
      suppliers.createPurchase(
        supplierId: supplierId,
        lines: [line],
        paidAmount: 0,
        userId: cashier.id,
      ),
      throwsStateError,
    );
    await expectLater(
      suppliers.createPurchase(
        supplierId: supplierId,
        lines: [line],
        paidAmount: 201,
        discount: 100,
        paymentChannel: 'تحويل بنكي',
        userId: cashier.id,
      ),
      throwsStateError,
    );
    await expectLater(
      suppliers.createPurchase(
        supplierId: supplierId,
        lines: [PurchaseLine(
          productId: productId,
          productName: 'صنف المورد',
          unit: 'قطعة',
          quantity: 1,
          unitCost: 400,
          sellingPrice: 200,
        )],
        paidAmount: 0,
        discount: 100,
        userId: cashier.id,
      ),
      throwsStateError,
    );
    expect((await products.getById(productId))!.sellingPrice, 150);
    expect(await database.query('purchases'), isEmpty);

    final purchase = await suppliers.createPurchase(
      supplierId: supplierId,
      lines: [line],
      paidAmount: 0,
      discount: 100,
      userId: cashier.id,
    );
    expect(purchase.total, 300);

    await expectLater(
      suppliers.recordPayment(
        supplierId: supplierId,
        amount: 201,
        paymentMethod: 'تحويل بنكي',
        userId: cashier.id,
      ),
      throwsStateError,
    );
    await suppliers.recordPayment(
      supplierId: supplierId,
      amount: 200,
      paymentMethod: 'تحويل بنكي',
      userId: cashier.id,
    );
    expect((await suppliers.balances(userId: managerId)).single.balance, 100);
  });

  test('يحتسب الرصيد الافتتاحي الموجب للمورد ضمن المستحق ويسمح بسداده', () async {
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد برصيد افتتاحي موجب', openingBalance: 500);
    var balance = (await suppliers.balances(userId: managerId)).single;
    expect(balance.openingBalance, 500);
    expect(balance.balance, 500);

    await suppliers.recordPayment(
      supplierId: supplierId,
      amount: 300,
      paymentMethod: 'تحويل بنكي',
      userId: managerId,
    );
    balance = (await suppliers.balances(userId: managerId)).single;
    expect(balance.balance, 200);
    expect(await database.query('cash_transactions'), hasLength(1));
  });

  test('يخصم الرصيد الافتتاحي السالب للمورد من مشتريات النظام قبل السماح بالسداد', () async {
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد له رصيد دائن', openingBalance: -200);
    final productId = await products.add(const GroceryProduct(
      name: 'صنف يقابل الرصيد الدائن', purchasePrice: 100, sellingPrice: 150, stockQuantity: 0,
    ));
    await suppliers.createPurchase(
      userId: managerId,
      supplierId: supplierId,
      lines: [PurchaseLine(productId: productId, productName: 'صنف يقابل الرصيد الدائن', unit: 'حبة', quantity: 3, unitCost: 100)],
      paidAmount: 0,
    );
    expect((await suppliers.balances(userId: managerId)).single.balance, 100);
    await suppliers.recordPayment(
      supplierId: supplierId,
      amount: 100,
      paymentMethod: 'تحويل بنكي',
      userId: managerId,
    );
    expect((await suppliers.balances(userId: managerId)).single.balance, 0);
  });

  test('يمنع غير المدير من تعديل الرصيد الافتتاحي للمورد', () async {
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد صلاحية الرصيد');
    final cashierId = await database.insert('users', {
      'username': 'supplier_opening_cashier', 'display_name': 'كاشير',
      'password_hash': 'test-hash', 'password_salt': 'test-salt',
      'password_iterations': 100000, 'role': 'cashier', 'is_active': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await expectLater(
      suppliers.setOpeningBalance(supplierId: supplierId, amount: -50, userId: cashierId),
      throwsStateError,
    );
    await suppliers.setOpeningBalance(supplierId: supplierId, amount: -50, userId: managerId);
    final balance = (await suppliers.balances(userId: managerId)).single;
    expect(balance.balance, -50);
    expect(balance.credit, 50);
  });

  test('يعرض الرصيد الافتتاحي للمورد كبند مستقل في كشف الحساب', () async {
    final supplierId = await suppliers.addSupplier(userId: managerId, name: 'مورد كشف الحساب', openingBalance: -350);
    final entries = await suppliers.ledger(supplierId, userId: managerId);
    expect(entries, hasLength(1));
    expect(entries.single.title, 'رصيد افتتاحي');
    expect(entries.single.amount, 350);
    expect(entries.single.isPayable, isFalse);
  });

}
