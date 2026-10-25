import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/invoice_print_service.dart';

void main() {
  late Database database;
  late InvoicePrintService printer;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.execute('''
      CREATE TABLE sales (
        id INTEGER PRIMARY KEY,
        invoice_number TEXT NOT NULL,
        total INTEGER NOT NULL,
        paid_amount INTEGER NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE sale_returns (
        id INTEGER PRIMARY KEY,
        sale_id INTEGER NOT NULL,
        amount INTEGER NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE sale_return_refunds (
        id INTEGER PRIMARY KEY,
        sale_id INTEGER NOT NULL,
        amount INTEGER NOT NULL
      )
    ''');
    printer = InvoicePrintService(database);
  });

  tearDown(() async {
    await database.close();
  });

  test('يخصم المرتجعات من رصيد الفاتورة غير المسدد دون تجاوز الصفر', () async {
    await database.insert('sales', {
      'id': 1,
      'invoice_number': 'HG-1',
      'total': 1000,
      'paid_amount': 500,
    });
    await database.insert('sale_returns', {'sale_id': 1, 'amount': 200});

    final summary = await printer.loadSummary(1);

    expect(summary.returnedAmount, 200);
    expect(summary.refundedAmount, 0);
    expect(summary.outstandingAfterReturns, 300);
  });

  test('يعرض رد النقد المسجل ولا يحوله إلى رصيد دين سالب', () async {
    await database.insert('sales', {
      'id': 2,
      'invoice_number': 'HG-2',
      'total': 1000,
      'paid_amount': 1000,
    });
    await database.insert('sale_returns', {'sale_id': 2, 'amount': 150});
    await database.insert('sale_return_refunds', {'sale_id': 2, 'amount': 150});

    final summary = await printer.loadSummary(2);

    expect(summary.returnedAmount, 150);
    expect(summary.refundedAmount, 150);
    expect(summary.outstandingAfterReturns, 0);
  });

  test('يرفض طباعة ملخص فاتورة غير موجودة', () async {
    await expectLater(printer.loadSummary(999), throwsStateError);
  });
}
