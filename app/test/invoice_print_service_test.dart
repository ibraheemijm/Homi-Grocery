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
        customer_name TEXT,
        subtotal INTEGER NOT NULL DEFAULT 0,
        discount INTEGER NOT NULL DEFAULT 0,
        total INTEGER NOT NULL,
        paid_amount INTEGER NOT NULL,
        created_at TEXT NOT NULL DEFAULT '2026-01-01T10:00:00.000'
      )
    ''');
    await database.execute('''
      CREATE TABLE sale_items (
        id INTEGER PRIMARY KEY,
        sale_id INTEGER NOT NULL,
        product_name TEXT,
        quantity REAL NOT NULL,
        unit_price INTEGER NOT NULL,
        line_total INTEGER NOT NULL
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

  test('يجمع المرتجعات وردود النقد ويمنع الرصيد السالب عند تجاوز الدين', () async {
    await database.insert('sales', {
      'id': 3,
      'invoice_number': 'HG-3',
      'total': 1000,
      'paid_amount': 600,
    });
    await database.insert('sale_returns', {'sale_id': 3, 'amount': 250});
    await database.insert('sale_returns', {'sale_id': 3, 'amount': 350});
    await database.insert('sale_return_refunds', {'sale_id': 3, 'amount': 100});
    await database.insert('sale_return_refunds', {'sale_id': 3, 'amount': 150});

    final summary = await printer.loadSummary(3);

    expect(summary.returnedAmount, 600);
    expect(summary.refundedAmount, 250);
    // الدين الأصلي 400؛ لا يجوز أن يتحول إلى رصيد سالب بسبب زيادة المرتجعات.
    expect(summary.outstandingAfterReturns, 0);
  });

  test('يبني PDF فعليًا دون فتح نافذة الطباعة', () async {
    await database.insert('sales', {
      'id': 4,
      'invoice_number': 'HG-PDF-4',
      'customer_name': 'زبون اختبار',
      'subtotal': 500,
      'discount': 0,
      'total': 500,
      'paid_amount': 500,
      'created_at': '2026-10-25T10:30:00.000',
    });
    await database.insert('sale_items', {
      'sale_id': 4,
      'product_name': 'سكر',
      'quantity': 1,
      'unit_price': 500,
      'line_total': 500,
    });

    final bytes = await printer.buildInvoicePdf(4, thermal: false);

    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(1000));
  });

  test('يرفض طباعة ملخص فاتورة غير موجودة', () async {
    await expectLater(printer.loadSummary(999), throwsStateError);
  });
}
