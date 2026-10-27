// إنشاء تقرير PDF للفترة المحددة مع دعم العربية وخط المستندات المحفوظ.
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'font_preferences.dart';
import 'reports_repository.dart';

class ReportPrintService {
  /// يبني نسخة قابلة للطباعة من التقرير الشهري أو السنوي.
  Future<Uint8List> buildPeriodPdf({
    required PeriodReport report,
    required String storeName,
    required String periodLabel,
  }) async {
    final fonts = await _loadTheme();
    final document = pw.Document(theme: fonts);
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        textDirection: pw.TextDirection.rtl,
        build: (_) => [
          pw.Center(
            child: pw.Column(
              children: [
                pw.Text(
                  storeName.trim().isEmpty ? 'Homi Grocery' : storeName.trim(),
                  style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
                ),
                pw.SizedBox(height: 6),
                pw.Text('تقرير المبيعات والأصناف', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
                pw.Text('الفترة: $periodLabel'),
              ],
            ),
          ),
          pw.SizedBox(height: 20),
          _summaryRow('عدد الفواتير', report.salesCount.toString()),
          _summaryRow('إجمالي المبيعات', '${report.salesTotal} ج.س'),
          _summaryRow('قيمة المرتجعات', '${report.returnsTotal} ج.س'),
          _summaryRow('صافي المبيعات بعد المرتجعات', '${report.netSalesTotal} ج.س'),
          _summaryRow(
            'مجمل الربح',
            report.grossProfit == null ? 'غير متاح — توجد تكاليف تاريخية مفقودة' : '${report.grossProfit} ج.س',
          ),
          pw.SizedBox(height: 18),
          pw.Text('الأصناف الأكثر مبيعًا', style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 8),
          if (report.products.isEmpty)
            pw.Text('لا توجد مبيعات أو مرتجعات مسجلة لهذه الفترة.')
          else
            pw.TableHelper.fromTextArray(
              headers: const ['الصنف', 'الوحدة', 'المباع', 'المرتجع', 'الصافي'],
              data: report.products.map((product) => [
                product.name,
                product.unit,
                _quantity(product.soldQuantity),
                _quantity(product.returnedQuantity),
                _quantity(product.netQuantity),
              ]).toList(growable: false),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              cellAlignment: pw.Alignment.centerRight,
              headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFE8EFEA)),
              border: pw.TableBorder.all(color: const PdfColor.fromInt(0xFFB8C6BE), width: 0.5),
              cellPadding: const pw.EdgeInsets.all(6),
            ),
          pw.SizedBox(height: 18),
          pw.Text('تم إنشاء التقرير من بيانات البرنامج المحلية.'),
        ],
      ),
    );
    return document.save();
  }

  pw.Widget _summaryRow(String label, String value) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 5),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Expanded(child: pw.Text(label, textAlign: pw.TextAlign.right)),
            pw.SizedBox(width: 12),
            pw.Text(value, textAlign: pw.TextAlign.left),
          ],
        ),
      );

  String _quantity(double value) => value == value.truncateToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(2);

  Future<pw.ThemeData> _loadTheme() async {
    Uint8List? baseBytes;
    Uint8List? boldBytes;
    final selected = FontPreferences.documentFont;
    if (selected == 'Cairo') {
      baseBytes = (await rootBundle.load('assets/fonts/Cairo.ttf')).buffer.asUint8List();
      boldBytes = baseBytes;
    } else if (selected == 'Amiri') {
      baseBytes = (await rootBundle.load('assets/fonts/Amiri-Regular.ttf')).buffer.asUint8List();
      boldBytes = (await rootBundle.load('assets/fonts/Amiri-Bold.ttf')).buffer.asUint8List();
    } else if (selected == FontPreferences.importedFontFamily) {
      baseBytes = await FontPreferences.importedFontBytes();
      boldBytes = baseBytes;
    }
    // Arial أو خط مستورد غير متوافق مع محرك PDF: استخدم خطًا عربيًا مضمنًا.
    try {
      baseBytes ??= (await rootBundle.load('assets/fonts/Amiri-Regular.ttf')).buffer.asUint8List();
      boldBytes ??= (await rootBundle.load('assets/fonts/Amiri-Bold.ttf')).buffer.asUint8List();
      return pw.ThemeData.withFont(
        base: pw.Font.ttf(ByteData.sublistView(baseBytes)),
        bold: pw.Font.ttf(ByteData.sublistView(boldBytes)),
      );
    } on Object {
      final base = pw.Font.ttf(await rootBundle.load('assets/fonts/Amiri-Regular.ttf'));
      final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Amiri-Bold.ttf'));
      return pw.ThemeData.withFont(base: base, bold: bold);
    }
  }
}
