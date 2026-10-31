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
}
