import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/auth_repository.dart';
import 'package:homi_grocery/data/cash_shift_repository.dart';
import 'package:homi_grocery/data/grocery_database.dart';
import 'package:homi_grocery/data/manager_approval_repository.dart';
import 'package:homi_grocery/data/product_repository.dart';
import 'package:homi_grocery/data/sale_repository.dart';

void main() {
  late Database database;
  late AuthRepository auth;
  late AuthUser manager;
  late AuthUser cashier;
  late int shiftId;
  late ProductRepository products;
  late SaleRepository sales;

  const managerPassword = 'StrongPass!2026';

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    database = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await GroceryDatabase.createSchema(db);
        await GroceryDatabase.createAuthSchema(db);
        await GroceryDatabase.createSalesSchema(db);
        await GroceryDatabase.createCustomersSchema(db);
        await GroceryDatabase.createStockMovementsSchema(db);
        await GroceryDatabase.createSalesReturnsSchema(db);
        await GroceryDatabase.createCashTransactionsSchema(db);
        await GroceryDatabase.createCashShiftsSchema(db);
        await GroceryDatabase.createSaleReturnRefundsSchema(db);
        await GroceryDatabase.createCostOfGoodsSchema(db);
        await GroceryDatabase.createManagerApprovalsSchema(db);
      },
    );
    auth = AuthRepository(database);
    manager = await auth.createInitialManager(
      username: 'store_manager',
      displayName: 'مدير المتجر',
      password: managerPassword,
    );
    cashier = await auth.createCashier(
      manager: manager,
      username: 'cashier_sale',
      displayName: 'كاشير البيع',
      password: 'CashierPass!2026',
    );
    final shift = await CashShiftRepository(database).openShift(
      userId: cashier.id,
      openingCash: 500,
    );
    shiftId = shift.id;
    products = ProductRepository(database);
    sales = SaleRepository(database);
    await auth.saveCashierPermissions(
      manager: manager,
      cashierId: cashier.id,
      permissions: const [
        CashierPermissionSetting(
          key: 'discounts',
          label: 'تقديم خصم على الفاتورة',
          isAllowed: false,
          maxAmount: 50,
        ),
      ],
    );
  });

  tearDown(() async => database.close());

  Future<GroceryProduct> addProduct() async {
    final id = await products.add(const GroceryProduct(
      name: 'منتج اختبار',
      unit: 'حبة',
      sellingPrice: 1000,
      stockQuantity: 5,
    ));
    return (await products.getById(id))!;
  }

  ManagerApprovalScope discountScope(int amount) => ManagerApprovalScope(
        cashierUserId: cashier.id,
        shiftId: shiftId,
        permissionKey: 'discounts',
        operationType: 'sale.create',
        amount: amount,
      );

  test('يسمح بالخصم فوق حد الكاشير بعد موافقة المدير المحددة', () async {
    final product = await addProduct();
    final token = await sales.requestCashierDiscountApproval(
      managerUsername: manager.username,
      managerPassword: managerPassword,
      cashierUserId: cashier.id,
      shiftId: shiftId,
      discountAmount: 100,
    );

    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 100,
      paidAmount: 900,
      paymentMethod: 'نقدي',
      userId: cashier.id,
      shiftId: shiftId,
      managerApprovalToken: token,
    );

    expect(sale.total, 900);
    expect((await products.getById(product.id!))!.stockQuantity, 4);
    final saved = (await database.query('sales')).single;
    expect(saved['discount'], 100);
    final approval = (await database.query('manager_approvals')).single;
    expect(approval['status'], 'consumed');
    expect(approval['consumed_at'], isNotNull);
    final cashEntries = await database.query(
      'cash_transactions',
      where: "reference_type = 'sale'",
    );
    expect(cashEntries, hasLength(1));
    expect(cashEntries.single['amount'], 900);
  });

  test('يرفض طلب موافقة باسم مستخدم ليس مديرًا نشطًا', () async {
    await expectLater(
      sales.requestCashierDiscountApproval(
        managerUsername: cashier.username,
        managerPassword: 'CashierPass!2026',
        cashierUserId: cashier.id,
        shiftId: shiftId,
        discountAmount: 100,
      ),
      throwsA(isA<ManagerApprovalException>()),
    );
    expect(await database.query('manager_approvals'), isEmpty);
  });

  test('يرفض اختلاف مبلغ الخصم دون إنشاء فاتورة أو حركة نقد أو مخزون', () async {
    final product = await addProduct();
    final approvals = ManagerApprovalRepository(database, auth);
    final grant = await approvals.issueApproval(
      manager: manager,
      managerPassword: managerPassword,
      scope: discountScope(100),
    );

    await expectLater(
      sales.createSale(
        lines: [SaleLine(product: product, quantity: 1)],
        discount: 150,
        paidAmount: 850,
        paymentMethod: 'نقدي',
        userId: cashier.id,
        shiftId: shiftId,
        managerApprovalToken: grant.token,
      ),
      throwsA(isA<StateError>()),
    );

    expect(await database.query('sales'), isEmpty);
    expect(await database.query('cash_transactions'), isEmpty);
    expect((await products.getById(product.id!))!.stockQuantity, 5);
    expect((await database.query('manager_approvals')).single['status'], 'rejected');
  });

  test('يرفض خصم الكاشير دون موافقة عندما تكون الصلاحية معطلة', () async {
    final product = await addProduct();

    await expectLater(
      sales.createSale(
        lines: [SaleLine(product: product, quantity: 1)],
        discount: 100,
        paidAmount: 900,
        paymentMethod: 'نقدي',
        userId: cashier.id,
        shiftId: shiftId,
      ),
      throwsA(isA<StateError>()),
    );

    expect(await database.query('sales'), isEmpty);
    expect((await products.getById(product.id!))!.stockQuantity, 5);
  });

  test('لا يحتاج الكاشير إلى موافقة إذا كان الخصم داخل الحد المسموح', () async {
    await auth.saveCashierPermissions(
      manager: manager,
      cashierId: cashier.id,
      permissions: const [
        CashierPermissionSetting(
          key: 'discounts',
          label: 'تقديم خصم على الفاتورة',
          isAllowed: true,
          maxAmount: 100,
        ),
      ],
    );
    expect(
      await sales.requiresCashierApproval(userId: cashier.id, amount: 100),
      isFalse,
    );
    expect(
      await sales.requiresCashierApproval(userId: cashier.id, amount: 101),
      isTrue,
    );
  });
}
