import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/auth_repository.dart';
import 'package:homi_grocery/data/cash_shift_repository.dart';
import 'package:homi_grocery/data/grocery_database.dart';
import 'package:homi_grocery/data/manager_approval_repository.dart';

void main() {
  late Database database;
  late AuthRepository auth;
  late ManagerApprovalRepository approvals;
  late AuthUser manager;
  late AuthUser cashier;
  late CashShift shift;
  late DateTime now;

  const managerPassword = 'StrongPass!2026';
  const cashierPassword = 'CashierPass!2026';

  ManagerApprovalScope scopeFor({
    int? amount = 250,
    int? shiftOverride,
    String permissionKey = 'discounts',
  }) =>
      ManagerApprovalScope(
        cashierUserId: cashier.id,
        shiftId: shiftOverride ?? shift.id,
        permissionKey: permissionKey,
        operationType: 'sale.create',
        amount: amount,
      );

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    database = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await GroceryDatabase.createAuthSchema(db);
        await GroceryDatabase.createCashTransactionsSchema(db);
        await GroceryDatabase.createCashShiftsSchema(db);
        await GroceryDatabase.createManagerApprovalsSchema(db);
      },
    );
    auth = AuthRepository(database);
    manager = await auth.createInitialManager(
      username: 'store_admin',
      displayName: 'مدير المتجر',
      password: managerPassword,
    );
    cashier = await auth.createCashier(
      manager: manager,
      username: 'cashier_one',
      displayName: 'الكاشير الأول',
      password: cashierPassword,
    );
    shift = await CashShiftRepository(database).openShift(
      userId: cashier.id,
      openingCash: 1000,
    );
    now = DateTime.utc(2026, 11, 1, 8);
    approvals = ManagerApprovalRepository(
      database,
      auth,
      clock: () => now,
    );
  });

  tearDown(() async => database.close());

  test('يصدر رمزًا عشوائيًا قصير الصلاحية ويحفظ بصمته فقط', () async {
    final grant = await approvals.issueApproval(
      manager: manager,
      managerPassword: managerPassword,
      scope: scopeFor(),
    );

    expect(grant.token, isNotEmpty);
    expect(grant.token.length, greaterThan(40));
    expect(grant.expiresAt, now.add(ManagerApprovalRepository.approvalLifetime));

    final rows = await database.query('manager_approvals');
    expect(rows, hasLength(1));
    expect(rows.single['token_hash'], isNot(grant.token));
    expect((rows.single['token_hash'] as String).length, 64);
    expect(rows.single['status'], 'pending');

    final actions = (await database.query('auth_audit_log'))
        .map((row) => row['action'] as String)
        .toList();
    expect(actions.any((value) => value.startsWith('manager_approval_requested:')), isTrue);
    expect(actions.any((value) => value.startsWith('manager_approval_granted:')), isTrue);
    expect(actions.join(' '), isNot(contains(grant.token)));
  });

  test('يستهلك الموافقة مرة واحدة داخل المعاملة ويرفض إعادة استخدامها', () async {
    final grant = await approvals.issueApproval(
      manager: manager,
      managerPassword: managerPassword,
      scope: scopeFor(),
    );

    final first = await database.transaction(
      (txn) => approvals.consumeWithinTransaction(
        txn,
        token: grant.token,
        scope: scopeFor(),
      ),
    );
    final second = await database.transaction(
      (txn) => approvals.consumeWithinTransaction(
        txn,
        token: grant.token,
        scope: scopeFor(),
      ),
    );

    expect(first, ManagerApprovalConsumeResult.consumed);
    expect(second, ManagerApprovalConsumeResult.alreadyUsed);
    final row = (await database.query('manager_approvals')).single;
    expect(row['status'], 'consumed');
    expect(row['consumed_at'], isNotNull);
    final events = (await database.query('auth_audit_log'))
        .map((row) => row['action'] as String);
    expect(events.any((value) => value.startsWith('manager_approval_consumed:')), isTrue);
    expect(events.any((value) => value.startsWith('manager_approval_used:')), isTrue);
  });

  test('يمنع الاستهلاك المتزامن للرمز نفسه أكثر من مرة', () async {
    final grant = await approvals.issueApproval(
      manager: manager,
      managerPassword: managerPassword,
      scope: scopeFor(),
    );

    final results = await Future.wait([
      database.transaction(
        (txn) => approvals.consumeWithinTransaction(
          txn,
          token: grant.token,
          scope: scopeFor(),
        ),
      ),
      database.transaction(
        (txn) => approvals.consumeWithinTransaction(
          txn,
          token: grant.token,
          scope: scopeFor(),
        ),
      ),
    ]);

    expect(
      results.where((result) => result == ManagerApprovalConsumeResult.consumed),
      hasLength(1),
    );
    expect(
      results.where((result) => result == ManagerApprovalConsumeResult.alreadyUsed),
      hasLength(1),
    );
  });

  test('يرفض الموافقة المنتهية ويسجل انتهاءها', () async {
    final grant = await approvals.issueApproval(
      manager: manager,
      managerPassword: managerPassword,
      scope: scopeFor(),
    );
    now = now.add(const Duration(minutes: 3));

    final result = await database.transaction(
      (txn) => approvals.consumeWithinTransaction(
        txn,
        token: grant.token,
        scope: scopeFor(),
      ),
    );

    expect(result, ManagerApprovalConsumeResult.expired);
    final row = (await database.query('manager_approvals')).single;
    expect(row['status'], 'expired');
    expect(row['expired_at'], isNotNull);
    final events = await database.query(
      'auth_audit_log',
      where: "action LIKE 'manager_approval_expired:%'",
    );
    expect(events, hasLength(1));
  });

  test('يبطل الرمز عند اختلاف المبلغ أو نطاق العملية', () async {
    final grant = await approvals.issueApproval(
      manager: manager,
      managerPassword: managerPassword,
      scope: scopeFor(),
    );

    final result = await database.transaction(
      (txn) => approvals.consumeWithinTransaction(
        txn,
        token: grant.token,
        scope: scopeFor(amount: 251),
      ),
    );

    expect(result, ManagerApprovalConsumeResult.scopeMismatch);
    final row = (await database.query('manager_approvals')).single;
    expect(row['status'], 'rejected');
    expect(row['rejected_at'], isNotNull);
    final events = await database.query(
      'auth_audit_log',
      where: "action LIKE 'manager_approval_rejected:%'",
    );
    expect(events, hasLength(1));
  });

  test('لا يسمح باستخدام موافقة لتجاوز صلاحيات القراءة', () async {
    await expectLater(
      approvals.issueApproval(
        manager: manager,
        managerPassword: managerPassword,
        scope: scopeFor(permissionKey: 'view_cashbox'),
      ),
      throwsA(isA<ManagerApprovalException>()),
    );
    expect(await database.query('manager_approvals'), isEmpty);
  });

  test('يرفض كلمة مرور المدير الخاطئة دون إصدار موافقة', () async {
    await expectLater(
      approvals.issueApproval(
        manager: manager,
        managerPassword: 'IncorrectPass!2026',
        scope: scopeFor(),
      ),
      throwsA(isA<AuthException>()),
    );
    expect(await database.query('manager_approvals'), isEmpty);
  });

  test('يرفض إصدار موافقة لوردية لا تخص الكاشير أو ليست مفتوحة', () async {
    await expectLater(
      approvals.issueApproval(
        manager: manager,
        managerPassword: managerPassword,
        scope: scopeFor(shiftOverride: shift.id + 100),
      ),
      throwsA(isA<ManagerApprovalException>()),
    );
    expect(await database.query('manager_approvals'), isEmpty);
  });
}
