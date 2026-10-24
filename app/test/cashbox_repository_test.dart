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

    final summary = await cashbox.summary();
    expect(summary.todayIncome, 1500);
    expect(summary.todayExpense, 400);
    expect(summary.todayNet, 1100);
    expect(summary.currentBalance, 1100);
    expect(summary.todayCount, 2);
    expect(await cashbox.recent(), hasLength(2));
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
}
