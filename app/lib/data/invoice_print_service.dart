// خدمة طباعة فواتير المبيعات بصيغتي A4 والإيصال الحراري.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:sqflite/sqflite.dart';

import 'font_preferences.dart';

/// تجمع بيانات الفاتورة من قاعدة البيانات وتعرض نافذة الطباعة أو الحفظ PDF.
class InvoicePrintSummary {
  const InvoicePrintSummary({
    required this.sale,
    required this.returnedAmount,
    required this.refundedAmount,
    required this.outstandingAfterReturns,
  });

  final Map<String, Object?> sale;
  final int returnedAmount;
  final int refundedAmount;
  final int outstandingAfterReturns;
}

class InvoicePrintService {
  InvoicePrintService(this._database);

  final Database _database;

  /// تحميل ملخص الفاتورة مع المرتجعات وردود النقد المسجلة لاحقًا.
  /// التحصيلات العامة لا تُنسب إلى فاتورة بعينها في المخطط الحالي.
  Future<InvoicePrintSummary> loadSummary(int saleId) async {
    final sales = await _database.query(
      'sales',
      where: 'id = ?',
      whereArgs: [saleId],
      limit: 1,
    );
    if (sales.isEmpty) throw StateError('الفاتورة غير موجودة.');
    final sale = sales.single;
    final returns = await _database.rawQuery(
      'SELECT COALESCE(SUM(amount), 0) AS amount FROM sale_returns WHERE sale_id = ?',
      [saleId],
    );
    final refunds = await _database.rawQuery(
      'SELECT COALESCE(SUM(amount), 0) AS amount FROM sale_return_refunds WHERE sale_id = ?',
      [saleId],
    );
    final returnedAmount = (returns.single['amount'] as num).toInt();
    final refundedAmount = (refunds.single['amount'] as num).toInt();
    final total = (sale['total'] as num).toInt();
    final paid = (sale['paid_amount'] as num).toInt();
    final originalBalance = (total - paid).clamp(0, total).toInt();
    final debtCoveredByReturns = returnedAmount.clamp(0, originalBalance).toInt();
    return InvoicePrintSummary(
      sale: sale,
      returnedAmount: returnedAmount,
      refundedAmount: refundedAmount,
      outstandingAfterReturns: originalBalance - debtCoveredByReturns,
    );
  }

  Future<void> printInvoice(int saleId, {required bool thermal}) async {
    final summary = await loadSummary(saleId);
    final sale = summary.sale;
    final items = await _database.query(
      'sale_items',
      where: 'sale_id = ?',
      whereArgs: [saleId],
      orderBy: 'id ASC',
    );

    // تضمين ملف الخط في PDF نفسه حتى لا يعتمد عرض الفاتورة على جهاز المستلم.
    final document = pw.Document(theme: await _loadDocumentTheme());
    final pageFormat = thermal
        ? const PdfPageFormat(80 * PdfPageFormat.mm, 300 * PdfPageFormat.mm,
            marginAll: 4 * PdfPageFormat.mm)
        : PdfPageFormat.a4.copyWith(
            marginLeft: 18 * PdfPageFormat.mm,
            marginRight: 18 * PdfPageFormat.mm,
            marginTop: 16 * PdfPageFormat.mm,
            marginBottom: 16 * PdfPageFormat.mm,
          );

    document.addPage(
      pw.MultiPage(
        pageFormat: pageFormat,
        textDirection: pw.TextDirection.rtl,
        build: (context) => [
          pw.Center(
            child: pw.Column(children: [
              pw.Text('Homi Grocery',
                  style: pw.TextStyle(fontSize: thermal ? 16 : 24, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 4),
              pw.Text('فاتورة مبيعات', style: pw.TextStyle(fontSize: thermal ? 12 : 18, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 8),
            ]),
          ),
          pw.Divider(),
          pw.Text('رقم الفاتورة: ${sale['invoice_number']}'),
          pw.Text('التاريخ: ${_dateLabel(sale['created_at'] as String)}'),
          pw.Text('الزبون: ${(sale['customer_name'] as String?)?.trim().isNotEmpty == true ? sale['customer_name'] : 'زبون نقدي'}'),
          pw.SizedBox(height: 12),
          pw.TableHelper.fromTextArray(
            headers: const ['الصنف', 'الكمية', 'السعر', 'الإجمالي'],
            data: items.map((item) => [
              item['product_name']?.toString() ?? '',
              _quantity((item['quantity'] as num).toDouble()),
              item['unit_price'].toString(),
              item['line_total'].toString(),
            ]).toList(),
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: thermal ? 8 : 10),
            cellStyle: pw.TextStyle(fontSize: thermal ? 8 : 10),
            cellAlignment: pw.Alignment.centerRight,
            headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFE8EFEA)),
            border: pw.TableBorder.all(color: const PdfColor.fromInt(0xFFB8C6BE), width: 0.5),
            cellPadding: pw.EdgeInsets.all(thermal ? 3 : 6),
          ),
          pw.SizedBox(height: 12),
          _amountRow('الإجمالي قبل الخصم', sale['subtotal'] as int, thermal),
          _amountRow('الخصم', sale['discount'] as int, thermal),
          pw.Divider(),
          _amountRow('الإجمالي النهائي', sale['total'] as int, thermal, bold: true),
          _amountRow('المبلغ المستلم عند البيع', (sale['paid_amount'] as num).toInt(), thermal),
          if (summary.returnedAmount > 0)
            _amountRow('قيمة المرتجعات المسجلة', summary.returnedAmount, thermal),
          if (summary.refundedAmount > 0)
            _amountRow('رد نقدي مسجل للزبون', summary.refundedAmount, thermal),
          _amountRow(
            'المتبقي بعد المرتجعات (قبل التحصيلات اللاحقة)',
            summary.outstandingAfterReturns,
            thermal,
            bold: true,
          ),
          pw.SizedBox(height: 18),
          pw.Center(child: pw.Text('شكرًا لتعاملكم معنا', style: pw.TextStyle(fontSize: thermal ? 9 : 12))),
        ],
      ),
    );

    await Printing.layoutPdf(
      name: 'invoice-${sale['invoice_number']}${thermal ? '-thermal' : '-A4'}.pdf',
      format: pageFormat,
      onLayout: (_) async => document.save(),
    );
  }

  Future<pw.ThemeData> _loadDocumentTheme() async {
    final selected = FontPreferences.documentFont;
    Uint8List? baseBytes;
    Uint8List? boldBytes;

    if (selected == 'Cairo') {
      baseBytes = (await rootBundle.load('assets/fonts/Cairo.ttf')).buffer.asUint8List();
      boldBytes = baseBytes;
    } else if (selected == 'Amiri') {
      baseBytes = (await rootBundle.load('assets/fonts/Amiri-Regular.ttf')).buffer.asUint8List();
      boldBytes = (await rootBundle.load('assets/fonts/Amiri-Bold.ttf')).buffer.asUint8List();
    } else if (selected == FontPreferences.importedFontFamily) {
      baseBytes = await FontPreferences.importedFontBytes();
      // الخط المستورد قد لا يحتوي على وزن عريض منفصل.
      boldBytes = baseBytes;
    } else if (selected == 'Arial') {
      final paths = Platform.isWindows
          ? [r'C:\Windows\Fonts\arial.ttf', r'C:\Windows\Fonts\arialbd.ttf']
          : Platform.isLinux
              ? ['/usr/share/fonts/truetype/msttcorefonts/Arial.ttf',
                  '/usr/share/fonts/truetype/msttcorefonts/arial.ttf',
                  '/usr/share/fonts/truetype/msttcorefonts/Arial_Bold.ttf']
              : <String>[];
      for (final path in paths) {
        final file = File(path);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (baseBytes == null) {
            baseBytes = bytes;
          } else {
            boldBytes = bytes;
            break;
          }
        }
      }
    }

    // Arial غير موجود على بعض الأنظمة، لذا نعود إلى Amiri بدل إنتاج PDF عربي بخط غير مناسب.
    baseBytes ??= (await rootBundle.load('assets/fonts/Amiri-Regular.ttf')).buffer.asUint8List();
    boldBytes ??= (await rootBundle.load('assets/fonts/Amiri-Bold.ttf')).buffer.asUint8List();
    try {
      final base = pw.Font.ttf(ByteData.sublistView(baseBytes));
      final bold = pw.Font.ttf(ByteData.sublistView(boldBytes));
      return pw.ThemeData.withFont(base: base, bold: bold);
    } catch (_) {
      // بعض ملفات OTF لا يقبلها محرك PDF؛ لا نفشل طباعة الفاتورة بسبب خط مستورد.
      final fallbackBase = pw.Font.ttf(
        await rootBundle.load('assets/fonts/Amiri-Regular.ttf'),
      );
      final fallbackBold = pw.Font.ttf(
        await rootBundle.load('assets/fonts/Amiri-Bold.ttf'),
      );
      return pw.ThemeData.withFont(base: fallbackBase, bold: fallbackBold);
    }
  }

  pw.Widget _amountRow(String label, int amount, bool thermal, {bool bold = false}) {
    return pw.Padding(
      padding: pw.EdgeInsets.symmetric(vertical: thermal ? 2 : 4),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Expanded(
            child: pw.Text(
              label,
              textAlign: pw.TextAlign.right,
              style: pw.TextStyle(
                fontSize: thermal ? 9 : 11,
                fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
              ),
            ),
          ),
          pw.SizedBox(width: 4),
          pw.Text(
            '$amount ج.س',
            textAlign: pw.TextAlign.left,
            style: pw.TextStyle(
              fontSize: thermal ? 9 : 11,
              fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  String _dateLabel(String value) {
    final date = DateTime.tryParse(value)?.toLocal();
    if (date == null) return value;
    return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  String _quantity(double value) => value == value.truncateToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(2);
}
