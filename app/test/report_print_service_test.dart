import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/data/report_print_service.dart';
import 'package:homi_grocery/data/reports_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ينشئ PDF عربيًا لملخص الفترة والأصناف الأكثر مبيعًا', () async {
    final report = PeriodReport(
      start: DateTime(2026, 5, 1),
      end: DateTime(2026, 6, 1),
      salesTotal: 1200,
      salesCount: 4,
      returnsTotal: 200,
      purchaseTotal: 700,
      purchaseCount: 3,
      supplierReturns: 50,
      products: const [
        BestSellingProduct(
          productId: 1,
          name: 'سكر',
          unit: 'كيس',
          soldQuantity: 8,
          returnedQuantity: 1,
        ),
      ],
      grossProfit: 350,
    );

    final bytes = await ReportPrintService().buildPeriodPdf(
      report: report,
      storeName: 'بقالة الاختبار',
      periodLabel: '2026-05',
    );

    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(1000));
  });

  test('ينشئ PDF للتقرير اليومي مع التحصيلات والمرتجعات والخزينة', () async {
    final report = DailyReport(
      day: DateTime(2026, 10, 28),
      salesTotal: 1200,
      salesCount: 4,
      purchaseTotal: 500,
      purchaseCount: 2,
      supplierReturns: 35,
      customerCollections: 150,
      supplierPayments: 100,
      supplierRefunds: 20,
      returnRefunds: 40,
      saleReturns: 75,
      grossProfit: 250,
      cashIncome: 500,
      cashExpense: 200,
      cashOnlyIncome: 300,
      cashOnlyExpense: 150,
      bankTransferIncome: 200,
      bankTransferExpense: 50,
      lowStockCount: 3,
    );

    final bytes = await ReportPrintService().buildDailyPdf(
      report: report,
      storeName: 'بقالة الاختبار',
    );

    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(1000));
  });

  test('يتعامل مع فترة بلا أصناف وربح غير متاح', () async {
    final report = PeriodReport(
      start: DateTime(2026, 1, 1),
      end: DateTime(2026, 2, 1),
      salesTotal: 0,
      salesCount: 0,
      returnsTotal: 0,
      purchaseTotal: 0,
      purchaseCount: 0,
      supplierReturns: 0,
      products: const [],
      grossProfit: null,
    );

    final bytes = await ReportPrintService().buildPeriodPdf(
      report: report,
      storeName: 'Homi Grocery',
      periodLabel: '2026-01',
    );

    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });
}
