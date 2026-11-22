import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/grocery_database.dart';

void main() {
  late Database database;
  late int managerId;
  late int cashierId;
  late int shiftId;

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
        await GroceryDatabase.createCashTransactionsSchema(db);
        await GroceryDatabase.createCashShiftsSchema(db);
      },
    );

    final now = DateTime.now().toUtc().toIso8601String();
    managerId = await database.insert('users', {
      'username': 'manager_one',
      'display_name': 'المدير',
      'password_hash': 'hash',
      'password_salt': 'salt',
      'password_iterations': 600000,
      'role': 'manager',
      'is_active': 1,
      'created_at': now,
    });
    cashierId = await database.insert('users', {
      'username': 'cashier_one',
      'display_name': 'الكاشير',
      'password_hash': 'hash',
      'password_salt': 'salt',
      'password_iterations': 600000,
      'role': 'cashier',
      'is_active': 1,
      'created_at': now,
    });
    shiftId = await database.insert('cash_shifts', {
      'user_id': cashierId,
      'opening_cash': 1000,
      'status': 'open',
      'opened_at': now,
    });
  });

  tearDown(() async => database.close());

  test('ينشئ مخطط الموافقات دون حذف الحسابات أو الورديات ويقبل إعادة التطبيق', () async {
    await GroceryDatabase.createManagerApprovalsSchema(database);
    await GroceryDatabase.createManagerApprovalsSchema(database);

    final managers = await database.query('users', where: 'id = ?', whereArgs: [managerId]);
    final cashiers = await database.query('users', where: 'id = ?', whereArgs: [cashierId]);
    final shifts = await database.query('cash_shifts', where: 'id = ?', whereArgs: [shiftId]);
    final tables = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'manager_approvals'",
    );
    final indexes = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_manager_approvals_%'",
    );

    expect(managers, hasLength(1));
    expect(cashiers, hasLength(1));
    expect(shifts, hasLength(1));
    expect(tables, hasLength(1));
    expect(indexes, hasLength(2));
  });

  test('يحفظ بصمة الرمز ونطاق الموافقة ويرفض تكرار البصمة', () async {
    await GroceryDatabase.createManagerApprovalsSchema(database);
    final now = DateTime.now().toUtc();
    const tokenHash = 'sha256-token-fingerprint';

    await database.insert('manager_approvals', {
      'token_hash': tokenHash,
      'manager_user_id': managerId,
      'cashier_user_id': cashierId,
      'shift_id': shiftId,
      'permission_key': 'discounts',
      'operation_type': 'sale.create',
      'amount': 250,
      'status': 'pending',
      'created_at': now.toIso8601String(),
      'expires_at': now.add(const Duration(minutes: 2)).toIso8601String(),
    });

    final saved = (await database.query('manager_approvals')).single;
    expect(saved['token_hash'], tokenHash);
    expect(saved['cashier_user_id'], cashierId);
    expect(saved['shift_id'], shiftId);
    expect(saved['permission_key'], 'discounts');
    expect(saved['operation_type'], 'sale.create');
    expect(saved['amount'], 250);
    expect(saved['status'], 'pending');

    await expectLater(
      database.insert('manager_approvals', {
        'token_hash': tokenHash,
        'manager_user_id': managerId,
        'cashier_user_id': cashierId,
        'shift_id': shiftId,
        'permission_key': 'discounts',
        'operation_type': 'sale.create',
        'amount': 250,
        'status': 'pending',
        'created_at': now.toIso8601String(),
        'expires_at': now.add(const Duration(minutes: 2)).toIso8601String(),
      }),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('يفرض ارتباط الموافقة بحساب موجود ووردية موجودة', () async {
    await GroceryDatabase.createManagerApprovalsSchema(database);
    final now = DateTime.now().toUtc();

    await expectLater(
      database.insert('manager_approvals', {
        'token_hash': 'orphaned-approval',
        'manager_user_id': managerId,
        'cashier_user_id': cashierId,
        'shift_id': shiftId + 999,
        'permission_key': 'discounts',
        'operation_type': 'sale.create',
        'amount': 250,
        'created_at': now.toIso8601String(),
        'expires_at': now.add(const Duration(minutes: 2)).toIso8601String(),
      }),
      throwsA(isA<DatabaseException>()),
    );
  });
}
