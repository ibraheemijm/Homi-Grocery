import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/auth_repository.dart';
import 'package:homi_grocery/data/cash_shift_repository.dart';
import 'package:homi_grocery/data/grocery_database.dart';

void main() {
  late Database database;
  late AuthRepository auth;
  late CashShiftRepository shifts;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    database = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      onCreate: (db, version) async {
        await GroceryDatabase.createAuthSchema(db);
        await GroceryDatabase.createCashTransactionsSchema(db);
        await GroceryDatabase.createCashShiftsSchema(db);
      },
    );
    auth = AuthRepository(database);
    shifts = CashShiftRepository(database);
  });

  tearDown(() async {
    await database.close();
  });

  test('يفتح وردية برصيد افتتاحي ويستعيدها بدل فتح وردية ثانية', () async {
    final manager = await auth.createInitialManager(
      username: 'store_admin',
      displayName: 'مدير المتجر',
      password: 'StrongPass!2026',
    );

    final opened = await shifts.openShift(userId: manager.id, openingCash: 25000);
    expect(opened.openingCash, 25000);
    expect(opened.isOpen, isTrue);

    final recovered = await shifts.getOpenShift();
    expect(recovered?.id, opened.id);
    expect(recovered?.openingCash, 25000);

    await expectLater(
      shifts.openShift(userId: manager.id, openingCash: 90000),
      throwsA(isA<CashShiftException>()),
    );
    expect((await shifts.getOpenShift())?.openingCash, 25000);
  });

  test('يمنع فتح ورديتين متزامنتين حتى عند اختلاف المستخدم', () async {
    final manager = await auth.createInitialManager(
      username: 'store_admin',
      displayName: 'مدير المتجر',
      password: 'StrongPass!2026',
    );
    final cashier = await auth.createCashier(
      manager: manager,
      username: 'cashier_one',
      displayName: 'الكاشير الأول',
      password: 'CashierPass!2026',
    );

    await shifts.openShift(userId: manager.id, openingCash: 0);
    await expectLater(
      shifts.openShift(userId: cashier.id, openingCash: 1000),
      throwsA(isA<CashShiftException>()),
    );
  });

  test('يتحقق من ملكية الوردية وأنها مفتوحة قبل الحركة النقدية', () async {
    final manager = await auth.createInitialManager(
      username: 'store_admin',
      displayName: 'مدير المتجر',
      password: 'StrongPass!2026',
    );
    final cashier = await auth.createCashier(
      manager: manager,
      username: 'cashier_one',
      displayName: 'الكاشير الأول',
      password: 'CashierPass!2026',
    );
    final shift = await shifts.openShift(userId: manager.id, openingCash: 500);

    await expectLater(
      CashShiftRepository.validateActiveShift(
        database,
        shiftId: shift.id,
        userId: manager.id,
      ),
      completes,
    );
    await expectLater(
      CashShiftRepository.validateActiveShift(
        database,
        shiftId: shift.id,
        userId: cashier.id,
      ),
      throwsA(isA<CashShiftException>()),
    );
    await expectLater(
      CashShiftRepository.validateActiveShift(
        database,
        shiftId: shift.id + 999,
        userId: manager.id,
      ),
      throwsA(isA<CashShiftException>()),
    );

    await shifts.closeShift(
      shiftId: shift.id,
      userId: manager.id,
      closingCash: 500,
    );
    await expectLater(
      CashShiftRepository.validateActiveShift(
        database,
        shiftId: shift.id,
        userId: manager.id,
      ),
      throwsA(isA<CashShiftException>()),
    );
  });

  test('يحسب المتوقع والفرق عند الإغلاق من المقبوضات والمدفوعات النقدية للوردية', () async {
    final manager = await auth.createInitialManager(
      username: 'store_admin',
      displayName: 'مدير المتجر',
      password: 'StrongPass!2026',
    );
    final shift = await shifts.openShift(userId: manager.id, openingCash: 10000);

    await database.insert('cash_transactions', {
      'direction': 'in',
      'category': 'مبيعات',
      'amount': 7000,
      'payment_method': 'نقدي',
      'user_id': manager.id,
      'shift_id': shift.id,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await database.insert('cash_transactions', {
      'direction': 'out',
      'category': 'مصروف',
      'amount': 2000,
      'payment_method': 'نقدي',
      'user_id': manager.id,
      'shift_id': shift.id,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await database.insert('cash_transactions', {
      'direction': 'in',
      'category': 'تحويل',
      'amount': 5000,
      'payment_method': 'تحويل بنكي',
      'user_id': manager.id,
      'shift_id': shift.id,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });

    final closed = await shifts.closeShift(
      shiftId: shift.id,
      userId: manager.id,
      closingCash: 16000,
    );

    expect(closed.expectedCash, 15000);
    expect(closed.closingCash, 16000);
    expect(closed.difference, 1000);
    expect(closed.isOpen, isFalse);
    expect(await shifts.getOpenShift(), isNull);

    await expectLater(
      shifts.closeShift(shiftId: shift.id, userId: manager.id, closingCash: 15000),
      throwsA(isA<CashShiftException>()),
    );
  });

  test('لا يسمح لمستخدم بإغلاق وردية مستخدم آخر أو برصيد سالب', () async {
    final manager = await auth.createInitialManager(
      username: 'store_admin',
      displayName: 'مدير المتجر',
      password: 'StrongPass!2026',
    );
    final cashier = await auth.createCashier(
      manager: manager,
      username: 'cashier_one',
      displayName: 'الكاشير الأول',
      password: 'CashierPass!2026',
    );
    final shift = await shifts.openShift(userId: manager.id, openingCash: 0);

    await expectLater(
      shifts.closeShift(shiftId: shift.id, userId: cashier.id, closingCash: 0),
      throwsA(isA<CashShiftException>()),
    );
    await expectLater(
      shifts.openShift(userId: manager.id, openingCash: -1),
      throwsA(isA<CashShiftException>()),
    );
  });
}
