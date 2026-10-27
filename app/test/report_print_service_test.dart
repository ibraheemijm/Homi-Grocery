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

  test('يتعامل مع فترة بلا أصناف وربح غير متاح', () async {
    final report = PeriodReport(
      start: DateTime(2026, 1, 1),
      end: DateTime(2026, 2, 1),
      salesTotal: 0,
      salesCount: 0,
      returnsTotal: 0,
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
