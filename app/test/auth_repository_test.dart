import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/auth_repository.dart';
import 'package:homi_grocery/data/grocery_database.dart';

void main() {
  late Database database;
  late AuthRepository repository;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    database = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      onCreate: (db, version) => GroceryDatabase.createAuthSchema(db),
    );
    repository = AuthRepository(database);
  });

  tearDown(() async {
    await database.close();
  });

  test('ينشئ المدير الأول دون تخزين كلمة المرور الأصلية', () async {
    expect(await repository.hasAccounts(), isFalse);

    final user = await repository.createInitialManager(
      username: 'store_admin',
      displayName: 'مدير المتجر',
      password: 'StrongPass!2026',
    );

    expect(user.role, 'manager');
    expect(await repository.hasAccounts(), isTrue);

    final rows = await database.query('users');
    expect(rows.single['password_hash'], isNot('StrongPass!2026'));
    expect(rows.single['password_salt'], isNotEmpty);
    expect(rows.single['password_iterations'], greaterThanOrEqualTo(600000));
  });

  test('يسمح بتسجيل الدخول بكلمة المرور الصحيحة ويسجل الحدث', () async {
    await repository.createInitialManager(
      username: 'store_admin',
      displayName: 'مدير المتجر',
      password: 'StrongPass!2026',
    );

    final user = await repository.login(
      username: 'STORE_ADMIN',
      password: 'StrongPass!2026',
    );

    expect(user.username, 'store_admin');
    expect(user.isManager, isTrue);
    final events = await database.query('auth_audit_log');
    expect(events.map((event) => event['action']),
        containsAll(['initial_manager_created', 'login_success']));
  });

  test('يرفض إنشاء مدير أول ثانٍ ويحافظ على الحساب الموجود', () async {
    await repository.createInitialManager(
      username: 'store_admin',
      displayName: 'مدير المتجر',
      password: 'StrongPass!2026',
    );

    await expectLater(
      repository.createInitialManager(
        username: 'another_admin',
        displayName: 'مدير آخر',
        password: 'AnotherStrong!2026',
      ),
      throwsA(isA<AuthException>()),
    );
    final users = await database.query('users');
    expect(users, hasLength(1));
  });

  test('يسمح للمدير بإنشاء كاشير وعرض الحساب دون كشف بيانات الاعتماد', () async {
    final manager = await repository.createInitialManager(
      username: 'store_admin',
      displayName: 'مدير المتجر',
      password: 'StrongPass!2026',
    );

    final cashier = await repository.createCashier(
      manager: manager,
      username: 'cashier_one',
      displayName: 'الكاشير الأول',
      password: 'CashierPass!2026',
    );

    expect(cashier.role, 'cashier');
    final accounts = await repository.listCashiers(manager: manager);
    expect(accounts, hasLength(1));
    expect(accounts.single.user.username, 'cashier_one');
    expect(accounts.single.isActive, isTrue);

    final events = await database.query('auth_audit_log');
    expect(
      events.map((event) => event['action']),
      contains('cashier_created:cashier_one'),
    );
    final stored = (await database.query(
      'users',
      where: 'username = ?',
      whereArgs: ['cashier_one'],
    )).single;
    expect(stored.containsKey('password_hash'), isTrue);
    expect(stored['password_hash'], isNot('CashierPass!2026'));
  });

  test('يرفض إنشاء أو إدارة حسابات الكاشير من حساب غير مدير', () async {
    final manager = await repository.createInitialManager(
      username: 'store_admin',
      displayName: 'مدير المتجر',
      password: 'StrongPass!2026',
    );
    final cashier = await repository.createCashier(
      manager: manager,
      username: 'cashier_one',
      displayName: 'الكاشير الأول',
      password: 'CashierPass!2026',
    );

    await expectLater(
      repository.createCashier(
        manager: cashier,
        username: 'cashier_two',
        displayName: 'الكاشير الثاني',
        password: 'AnotherPass!2026',
      ),
      throwsA(isA<AuthException>()),
    );
    await expectLater(
      repository.listCashiers(manager: cashier),
      throwsA(isA<AuthException>()),
    );
    await expectLater(
      repository.setCashierActive(
        manager: cashier,
        cashierId: cashier.id,
        isActive: false,
      ),
      throwsA(isA<AuthException>()),
    );
  });

  test('يمنع الحساب الموقوف من الدخول ويسجل تفعيل وإيقاف الحساب', () async {
    final manager = await repository.createInitialManager(
      username: 'store_admin',
      displayName: 'مدير المتجر',
      password: 'StrongPass!2026',
    );
    final cashier = await repository.createCashier(
      manager: manager,
      username: 'cashier_one',
      displayName: 'الكاشير الأول',
      password: 'CashierPass!2026',
    );

    await repository.setCashierActive(
      manager: manager,
      cashierId: cashier.id,
      isActive: false,
    );
    await expectLater(
      repository.login(username: 'cashier_one', password: 'CashierPass!2026'),
      throwsA(isA<AuthException>()),
    );

    await repository.setCashierActive(
      manager: manager,
      cashierId: cashier.id,
      isActive: true,
    );
    final events = await database.query('auth_audit_log');
    expect(
      events.map((event) => event['action']),
      containsAll([
        'cashier_deactivated:${cashier.id}',
        'cashier_activated:${cashier.id}',
      ]),
    );
  });

  test('يعيد المدير تعيين كلمة مرور الكاشير ويمسح القفل والمحاولات', () async {
    final manager = await repository.createInitialManager(
      username: 'store_admin',
      displayName: 'مدير المتجر',
      password: 'StrongPass!2026',
    );
    final cashier = await repository.createCashier(
      manager: manager,
      username: 'cashier_one',
      displayName: 'الكاشير الأول',
      password: 'CashierPass!2026',
    );
    await database.update(
      'users',
      {'failed_attempts': 4, 'locked_until': '2099-01-01T00:00:00.000Z'},
      where: 'id = ?',
      whereArgs: [cashier.id],
    );

    await repository.resetCashierPassword(
      manager: manager,
      cashierId: cashier.id,
      newPassword: 'NewCashier!2026',
    );
    final stored = (await database.query(
      'users',
      where: 'id = ?',
      whereArgs: [cashier.id],
    )).single;
    expect(stored['failed_attempts'], 0);
    expect(stored['locked_until'], isNull);

    final loggedIn = await repository.login(
      username: 'cashier_one',
      password: 'NewCashier!2026',
    );
    expect(loggedIn.id, cashier.id);
    final events = await database.query('auth_audit_log');
    expect(
      events.map((event) => event['action']),
      contains('cashier_password_reset:${cashier.id}'),
    );
  });

}
