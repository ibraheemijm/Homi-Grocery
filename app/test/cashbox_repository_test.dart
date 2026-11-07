import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/auth_repository.dart';
import 'package:homi_grocery/data/cash_shift_repository.dart';
import 'package:homi_grocery/data/cashbox_repository.dart';
import 'package:homi_grocery/data/grocery_database.dart';

void main() {
  late Database database;
  late CashboxRepository cashbox;
  late AuthRepository auth;
  late CashShiftRepository shifts;
  late int managerId;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createAuthSchema(database);
    await GroceryDatabase.createCashTransactionsSchema(database);
    await GroceryDatabase.createCashShiftsSchema(database);
    auth = AuthRepository(database);
    shifts = CashShiftRepository(database);
    managerId = await database.insert('users', {
      'username': 'cashbox_test_manager', 'display_name': 'مدير الاختبار',
      'password_hash': 'test-hash', 'password_salt': 'test-salt',
      'password_iterations': 100000, 'role': 'manager', 'is_active': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    cashbox = CashboxRepository(database);
  });

  tearDown(() async => database.close());

  test('يحسب المقبوضات والمدفوعات اليومية والرصيد التراكمي', () async {
    final managerShiftId = (await shifts.openShift(userId: managerId, openingCash: 0)).id;
    await cashbox.recordManualMovement(
      direction: 'in', category: 'دخل متنوع', amount: 1500, userId: managerId, shiftId: managerShiftId,
    );
    await cashbox.recordManualMovement(
      direction: 'out', category: 'كهرباء', amount: 400, userId: managerId, shiftId: managerShiftId,
    );

    await cashbox.recordManualMovement(
      direction: 'in', category: 'تحويل وارد', amount: 700, paymentMethod: 'تحويل بنكي', userId: managerId,
    );
    await cashbox.recordManualMovement(
      direction: 'out', category: 'تحويل صادر', amount: 100, paymentMethod: 'تحويل بنكي', userId: managerId,
    );

    final summary = await cashbox.summary(userId: managerId);
    expect(summary.todayIncome, 2200);
    expect(summary.todayExpense, 500);
    expect(summary.todayNet, 1700);
    expect(summary.currentBalance, 1700);
    expect(summary.todayCount, 4);
    expect(summary.todayCashIncome, 1500);
    expect(summary.todayCashExpense, 400);
    expect(summary.todayBankIncome, 700);
    expect(summary.todayBankExpense, 100);
    expect(summary.todayCashNet, 1100);
    expect(summary.todayBankNet, 600);
    expect(await cashbox.recent(userId: managerId), hasLength(4));
    expect(await cashbox.recent(userId: managerId, paymentMethod: 'نقدي'), hasLength(2));
    expect(await cashbox.recent(userId: managerId, paymentMethod: 'تحويل بنكي'), hasLength(2));
  });

  test('يمنع الكاشير من قراءة إجمالي الخزينة حتى مع وجود صلاحية قديمة', () async {
    final manager = AuthUser(
      id: managerId,
      username: 'cashbox_test_manager',
      displayName: 'مدير الاختبار',
      role: 'manager',
    );
    final cashier = await auth.createCashier(
      manager: manager,
      username: 'cashbox_reader',
      displayName: 'قارئ الخزينة',
      password: 'CashierPass!2026',
    );

    await expectLater(cashbox.summary(userId: cashier.id), throwsStateError);
    await expectLater(cashbox.recent(userId: cashier.id), throwsStateError);

    // يحاكي سجل صلاحية قديمًا من إصدار كان يسمح بعرض إجمالي الخزينة.
    await database.insert('cashier_permissions', {
      'user_id': cashier.id,
      'permission_key': 'view_cashbox',
      'is_allowed': 1,
      'updated_by': managerId,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });

    await expectLater(cashbox.summary(userId: cashier.id), throwsStateError);
    await expectLater(cashbox.recent(userId: cashier.id), throwsStateError);
    expect(cashierPermissionLabels.containsKey('view_cashbox'), isFalse);
  });

  test('يرفض المبالغ غير الصالحة واتجاه الحركة غير المعروف', () async {
    await expectLater(
      cashbox.recordManualMovement(direction: 'in', category: 'دخل', amount: 0, userId: managerId),
      throwsArgumentError,
    );
    await expectLater(
      cashbox.recordManualMovement(direction: 'unknown', category: 'دخل', amount: 10, userId: managerId),
      throwsArgumentError,
    );
    expect(await cashbox.recent(userId: managerId), isEmpty);
  });


  test('يرفض وسيلة حركة خزينة غير معتمدة', () async {
    await expectLater(
      cashbox.recordManualMovement(
        direction: 'in', category: 'دخل غير مصنف', amount: 100,
        paymentMethod: 'شيك', userId: managerId,
      ),
      throwsArgumentError,
    );
    expect(await cashbox.recent(userId: managerId), isEmpty);
  });

  test('يربط الحركة اليدوية النقدية بالمستخدم والوردية ولا يربط التحويل بالدرج', () async {
    final manager = AuthUser(id: managerId, username: 'cashbox_test_manager', displayName: 'مدير الاختبار', role: 'manager');
    final shift = await shifts.openShift(userId: manager.id, openingCash: 0);
    await cashbox.recordManualMovement(
      direction: 'in',
      category: 'إيداع',
      amount: 300,
      userId: manager.id,
      shiftId: shift.id,
    );
    await cashbox.recordManualMovement(
      direction: 'in',
      category: 'تحويل',
      amount: 500,
      paymentMethod: 'تحويل بنكي',
      userId: manager.id,
      shiftId: shift.id,
    );
    final rows = await database.query('cash_transactions', orderBy: 'id');
    expect(rows[0]['user_id'], manager.id);
    expect(rows[0]['shift_id'], shift.id);
    expect(rows[1]['user_id'], manager.id);
    expect(rows[1]['shift_id'], isNull);
  });

  test('يرفض الحركة النقدية إذا كانت الوردية لمستخدم آخر أو مغلقة', () async {
    final manager = AuthUser(id: managerId, username: 'cashbox_test_manager', displayName: 'مدير الاختبار', role: 'manager');
    final cashier = await auth.createCashier(
      manager: manager,
      username: 'cashier_one',
      displayName: 'الكاشير الأول',
      password: 'CashierPass!2026',
    );
    final shift = await shifts.openShift(userId: manager.id, openingCash: 0);
    await expectLater(
      cashbox.recordManualMovement(
        direction: 'in',
        category: 'محاولة غير مصرح بها',
        amount: 100,
        userId: cashier.id,
        shiftId: shift.id,
      ),
      throwsA(isA<CashShiftException>()),
    );
    await shifts.closeShift(shiftId: shift.id, userId: manager.id, closingCash: 0);
    await expectLater(
      cashbox.recordManualMovement(
        direction: 'in',
        category: 'وردية مغلقة',
        amount: 100,
        userId: manager.id,
        shiftId: shift.id,
      ),
      throwsA(isA<CashShiftException>()),
    );
    expect(await database.query('cash_transactions'), isEmpty);
  });

  test('يقيد مصروفات الكاشير بصلاحية وحد مالي ويرفض الإيرادات اليدوية', () async {
    final manager = AuthUser(id: managerId, username: 'cashbox_test_manager', displayName: 'مدير الاختبار', role: 'manager');
    final cashier = await auth.createCashier(
      manager: manager,
      username: 'cashbox_cashier',
      displayName: 'الكاشير',
      password: 'CashierPass!2026',
    );
    final shift = await shifts.openShift(userId: cashier.id, openingCash: 500);

    await expectLater(
      cashbox.recordManualMovement(
        direction: 'out',
        category: 'مصروف',
        amount: 100,
        userId: cashier.id,
        shiftId: shift.id,
      ),
      throwsStateError,
    );
    await expectLater(
      cashbox.recordManualMovement(
        direction: 'in',
        category: 'دخل يدوي',
        amount: 100,
        userId: cashier.id,
        shiftId: shift.id,
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
        setting.key == 'cash_expenses'
          ? CashierPermissionSetting(
              key: setting.key,
              label: setting.label,
              isAllowed: true,
              maxAmount: 200,
            )
          : setting
      ).toList(),
    );
    await expectLater(cashbox.summary(userId: cashier.id), throwsStateError);
    await expectLater(cashbox.recent(userId: cashier.id), throwsStateError);

    await expectLater(
      cashbox.recordManualMovement(
        direction: 'out',
        category: 'مصروف',
        amount: 201,
        userId: cashier.id,
        shiftId: shift.id,
      ),
      throwsStateError,
    );
    await cashbox.recordManualMovement(
      direction: 'out',
      category: 'مصروف',
      amount: 200,
      userId: cashier.id,
      shiftId: shift.id,
    );
    final movement = (await cashbox.recent(userId: managerId)).single;
    expect(movement.amount, 200);
    expect(movement.direction, 'out');
  });

}
