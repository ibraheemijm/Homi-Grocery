// خدمة طباعة فواتير المبيعات بصيغتي A4 والإيصال الحراري.
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:sqflite_common/sqlite_api.dart';

/// تجمع بيانات الفاتورة من قاعدة البيانات وتعرض نافذة الطباعة أو الحفظ PDF.
class InvoicePrintService {
  InvoicePrintService(this._database);

  final Database _database;

  Future<void> printInvoice(int saleId, {required bool thermal}) async {
    final sales = await _database.query(
      'sales',
      where: 'id = ?',
      whereArgs: [saleId],
      limit: 1,
    );
    if (sales.isEmpty) throw StateError('الفاتورة غير موجودة.');
    final sale = sales.single;
    final items = await _database.query(
      'sale_items',
      where: 'sale_id = ?',
      whereArgs: [saleId],
      orderBy: 'id ASC',
    );

    // تضمين خط عربي يدعم الحروف المتصلة داخل PDF بدل الاعتماد على خط النظام.
    final arabicFont = await PdfGoogleFonts.cairoRegular();
    final arabicBold = await PdfGoogleFonts.cairoBold();
    final document = pw.Document(
      theme: pw.ThemeData.withFont(base: arabicFont, bold: arabicBold),
    );
    final pageFormat = thermal
        ? PdfPageFormat(80 * PdfPageFormat.mm, 300 * PdfPageFormat.mm,
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
            border: pw.TableBorder.all(color: PdfColor.fromInt(0xFFB8C6BE), width: 0.5),
            cellPadding: pw.EdgeInsets.all(thermal ? 3 : 6),
          ),
          pw.SizedBox(height: 12),
          _amountRow('الإجمالي قبل الخصم', sale['subtotal'] as int, thermal),
          _amountRow('الخصم', sale['discount'] as int, thermal),
          pw.Divider(),
          _amountRow('الإجمالي النهائي', sale['total'] as int, thermal, bold: true),
          _amountRow('المبلغ المستلم', sale['paid_amount'] as int, thermal),
          _amountRow('المتبقي', (sale['total'] as int) - (sale['paid_amount'] as int), thermal, bold: true),
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

  pw.Widget _amountRow(String label, int amount, bool thermal, {bool bold = false}) {
    return pw.Padding(
      padding: pw.EdgeInsets.symmetric(vertical: thermal ? 2 : 4),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: pw.TextStyle(fontSize: thermal ? 9 : 11, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
          pw.Text('$amount ج.س', style: pw.TextStyle(fontSize: thermal ? 9 : 11, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
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
