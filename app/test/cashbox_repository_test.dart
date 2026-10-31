import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/cashbox_repository.dart';
import 'package:homi_grocery/data/grocery_database.dart';

void main() {
  late Database database;
  late CashboxRepository cashbox;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createCashTransactionsSchema(database);
    cashbox = CashboxRepository(database);
  });

  tearDown(() async => database.close());

  test('يحسب المقبوضات والمدفوعات اليومية والرصيد التراكمي', () async {
    await cashbox.recordManualMovement(
      direction: 'in', category: 'دخل متنوع', amount: 1500,
    );
    await cashbox.recordManualMovement(
      direction: 'out', category: 'كهرباء', amount: 400,
    );

    await cashbox.recordManualMovement(
      direction: 'in', category: 'تحويل وارد', amount: 700, paymentMethod: 'تحويل بنكي',
    );
    await cashbox.recordManualMovement(
      direction: 'out', category: 'تحويل صادر', amount: 100, paymentMethod: 'تحويل بنكي',
    );

    final summary = await cashbox.summary();
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
    expect(await cashbox.recent(), hasLength(4));
    expect(await cashbox.recent(paymentMethod: 'نقدي'), hasLength(2));
    expect(await cashbox.recent(paymentMethod: 'تحويل بنكي'), hasLength(2));
  });

  test('يرفض المبالغ غير الصالحة واتجاه الحركة غير المعروف', () async {
    await expectLater(
      cashbox.recordManualMovement(direction: 'in', category: 'دخل', amount: 0),
      throwsArgumentError,
    );
    await expectLater(
      cashbox.recordManualMovement(direction: 'unknown', category: 'دخل', amount: 10),
      throwsArgumentError,
    );
    expect(await cashbox.recent(), isEmpty);
  });

  test('يربط الحركة اليدوية النقدية بالمستخدم والوردية ولا يربط التحويل بالدرج', () async {
    await cashbox.recordManualMovement(
      direction: 'in',
      category: 'إيداع',
      amount: 300,
      userId: 7,
      shiftId: 12,
    );
    await cashbox.recordManualMovement(
      direction: 'in',
      category: 'تحويل',
      amount: 500,
      paymentMethod: 'تحويل بنكي',
      userId: 7,
      shiftId: 12,
    );
    final rows = await database.query('cash_transactions', orderBy: 'id');
    expect(rows[0]['user_id'], 7);
    expect(rows[0]['shift_id'], 12);
    expect(rows[1]['user_id'], 7);
    expect(rows[1]['shift_id'], isNull);
  });

}
