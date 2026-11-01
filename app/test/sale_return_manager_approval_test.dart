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
  late DateTime now;

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
      username: 'return_manager',
      displayName: 'مدير المرتجعات',
      password: managerPassword,
    );
    cashier = await auth.createCashier(
      manager: manager,
      username: 'return_cashier',
      displayName: 'كاشير المرتجعات',
      password: 'CashierPass!2026',
    );
    final shift = await CashShiftRepository(database).openShift(
      userId: cashier.id,
      openingCash: 500,
    );
    shiftId = shift.id;
    products = ProductRepository(database);
    now = DateTime.utc(2026, 11, 1, 8);
    sales = SaleRepository(database, clock: () => now);
    await setReturnPermission(allowed: false);
  });

  tearDown(() async => database.close());

  Future<void> setReturnPermission({required bool allowed, int limit = 50}) async {
    await auth.saveCashierPermissions(
      manager: manager,
      cashierId: cashier.id,
      permissions: [
        CashierPermissionSetting(
          key: 'returns',
          label: 'تسجيل مرتجعات البيع',
          isAllowed: allowed,
          maxAmount: limit,
        ),
      ],
    );
  }

  Future<({SaleRecord sale, int itemId, int productId})> createSale() async {
    final productId = await products.add(const GroceryProduct(
      name: 'منتج المرتجع',
      unit: 'حبة',
      sellingPrice: 100,
      stockQuantity: 5,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 0,
      paidAmount: 200,
      paymentMethod: 'نقدي',
      userId: cashier.id,
      shiftId: shiftId,
    );
    final itemId = (await database.query(
      'sale_items',
      columns: ['id'],
      where: 'sale_id = ?',
      whereArgs: [sale.id],
    )).single['id'] as int;
    return (sale: sale, itemId: itemId, productId: productId);
  }

  Future<String> issueApproval({
    required int saleId,
    int amount = 100,
  }) {
    return sales.requestCashierReturnApproval(
      managerUsername: manager.username,
      managerPassword: managerPassword,
      cashierUserId: cashier.id,
      shiftId: shiftId,
      saleId: saleId,
      returnAmount: amount,
    );
  }

  test('يرفض المرتجع إذا لم يمتلك الكاشير صلاحية returns حتى مع طلب موافقة', () async {
    final fixture = await createSale();

    await expectLater(
      sales.returnItems(
        saleId: fixture.sale.id,
        quantitiesBySaleItemId: {fixture.itemId: 1},
        userId: cashier.id,
        shiftId: shiftId,
      ),
      throwsStateError,
    );

    expect(await database.query('sale_returns'), isEmpty);
    expect((await products.getById(fixture.productId))!.stockQuantity, 3);
    await expectLater(
      issueApproval(saleId: fixture.sale.id),
      throwsA(isA<ManagerApprovalException>()),
    );
    expect(await database.query('manager_approvals'), isEmpty);
  });

  test('يطلب موافقة فوق السقف ثم يستهلكها ذريًا مع حفظ المرتجع والمخزون', () async {
    await setReturnPermission(allowed: true);
    final fixture = await createSale();

    await expectLater(
      sales.returnItems(
        saleId: fixture.sale.id,
        quantitiesBySaleItemId: {fixture.itemId: 1},
        userId: cashier.id,
        shiftId: shiftId,
      ),
      throwsA(
        isA<ManagerApprovalRequiredException>().having(
          (error) => error.amount,
          'amount',
          100,
        ),
      ),
    );
    expect(await database.query('sale_returns'), isEmpty);
    expect((await products.getById(fixture.productId))!.stockQuantity, 3);

    final token = await issueApproval(saleId: fixture.sale.id);
    final returned = await sales.returnItems(
      saleId: fixture.sale.id,
      quantitiesBySaleItemId: {fixture.itemId: 1},
      userId: cashier.id,
      shiftId: shiftId,
      managerApprovalToken: token,
    );

    expect(returned.amount, 100);
    expect((await products.getById(fixture.productId))!.stockQuantity, 4);
    final approval = (await database.query('manager_approvals')).single;
    expect(approval['status'], 'consumed');
    expect(approval['consumed_at'], isNotNull);
    expect(approval['cashier_user_id'], cashier.id);
    expect(approval['shift_id'], shiftId);
    expect(approval['permission_key'], 'returns');
    expect(approval['operation_type'], 'sale.return');
    expect(approval['amount'], 100);
    expect(approval['reference_type'], 'sale');
    expect(approval['reference_id'], fixture.sale.id);

    final cashierRow = (await database.query(
      'users',
      columns: ['id', 'role', 'is_active'],
      where: 'id = ?',
      whereArgs: [cashier.id],
    )).single;
    expect(cashierRow['role'], 'cashier');
    expect(cashierRow['is_active'], 1);
  });

  test('يرفض كلمة مرور المدير الخاطئة ولا يحفظ المرتجع أو يغير المخزون', () async {
    await setReturnPermission(allowed: true);
    final fixture = await createSale();

    await expectLater(
      sales.requestCashierReturnApproval(
        managerUsername: manager.username,
        managerPassword: 'WrongPassword!2026',
        cashierUserId: cashier.id,
        shiftId: shiftId,
        saleId: fixture.sale.id,
        returnAmount: 100,
      ),
      throwsA(isA<AuthException>()),
    );

    expect(await database.query('manager_approvals'), isEmpty);
    expect(await database.query('sale_returns'), isEmpty);
    expect((await products.getById(fixture.productId))!.stockQuantity, 3);
  });

  test('يرفض الموافقة المنتهية ولا يحفظ المرتجع أو يغير المخزون', () async {
    await setReturnPermission(allowed: true);
    final fixture = await createSale();
    final token = await issueApproval(saleId: fixture.sale.id);
    now = now.add(const Duration(minutes: 3));

    await expectLater(
      sales.returnItems(
        saleId: fixture.sale.id,
        quantitiesBySaleItemId: {fixture.itemId: 1},
        userId: cashier.id,
        shiftId: shiftId,
        managerApprovalToken: token,
      ),
      throwsStateError,
    );

    expect((await database.query('manager_approvals')).single['status'], 'expired');
    expect(await database.query('sale_returns'), isEmpty);
    expect((await products.getById(fixture.productId))!.stockQuantity, 3);
  });

  test('يرفض إعادة استخدام الموافقة بعد نجاح المرتجع الأول', () async {
    await setReturnPermission(allowed: true);
    final fixture = await createSale();
    final token = await issueApproval(saleId: fixture.sale.id);

    await sales.returnItems(
      saleId: fixture.sale.id,
      quantitiesBySaleItemId: {fixture.itemId: 1},
      userId: cashier.id,
      shiftId: shiftId,
      managerApprovalToken: token,
    );
    await expectLater(
      sales.returnItems(
        saleId: fixture.sale.id,
        quantitiesBySaleItemId: {fixture.itemId: 1},
        userId: cashier.id,
        shiftId: shiftId,
        managerApprovalToken: token,
      ),
      throwsStateError,
    );

    expect((await database.query('manager_approvals')).single['status'], 'consumed');
    expect(await database.query('sale_returns'), hasLength(1));
    expect((await products.getById(fixture.productId))!.stockQuantity, 4);
  });

  test('يرفض اختلاف مبلغ المرتجع عن النطاق المعتمد دون أي تغيير مالي أو مخزني', () async {
    await setReturnPermission(allowed: true);
    final fixture = await createSale();
    final token = await issueApproval(saleId: fixture.sale.id);

    await expectLater(
      sales.returnItems(
        saleId: fixture.sale.id,
        quantitiesBySaleItemId: {fixture.itemId: 2},
        userId: cashier.id,
        shiftId: shiftId,
        managerApprovalToken: token,
      ),
      throwsStateError,
    );

    expect((await database.query('manager_approvals')).single['status'], 'rejected');
    expect(await database.query('sale_returns'), isEmpty);
    expect((await products.getById(fixture.productId))!.stockQuantity, 3);
  });

  test('يرفض استخدام الموافقة لفاتورة أخرى', () async {
    await setReturnPermission(allowed: true);
    final first = await createSale();
    final second = await createSale();
    final token = await issueApproval(saleId: first.sale.id);

    await expectLater(
      sales.returnItems(
        saleId: second.sale.id,
        quantitiesBySaleItemId: {second.itemId: 1},
        userId: cashier.id,
        shiftId: shiftId,
        managerApprovalToken: token,
      ),
      throwsStateError,
    );

    expect((await database.query('manager_approvals')).single['status'], 'rejected');
    expect(
      await database.query(
        'sale_returns',
        where: 'sale_id = ?',
        whereArgs: [second.sale.id],
      ),
      isEmpty,
    );
    expect((await products.getById(second.productId))!.stockQuantity, 3);
  });
}
