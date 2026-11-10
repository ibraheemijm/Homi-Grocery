import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/data/pdf_file_name.dart';

void main() {
  final exportedAt = DateTime(2026, 10, 31, 9, 48, 30);

  test('ينشئ اسم PDF عربيًا مع التاريخ والوقت', () {
    expect(
      buildPdfFileName(
        language: 'ar',
        arabicLabel: 'فاتورة-رقم',
        englishLabel: 'Invoice',
        sharedSuffix: '125',
        exportedAt: exportedAt,
      ),
      'فاتورة-رقم-125-20261031-094830.pdf',
    );
  });

  test('ينشئ اسم PDF إنجليزيًا مع التاريخ والوقت', () {
    expect(
      buildPdfFileName(
        language: 'en',
        arabicLabel: 'تقرير يومي',
        englishLabel: 'Daily Report',
        exportedAt: exportedAt,
      ),
      'Daily-Report-20261031-094830.pdf',
    );
  });

  test('يدمج الاسمين عند اختيار اللغتين', () {
    expect(
      buildPdfFileName(
        language: 'both',
        arabicLabel: 'تقرير يومي',
        englishLabel: 'Daily Report',
        exportedAt: exportedAt,
      ),
      'تقرير-يومي-Daily-Report-20261031-094830.pdf',
    );
  });
  test('يسمي التقرير اليومي بتاريخ التقرير ووقت التصدير دون تكرار التاريخ', () {
    expect(
      buildPdfFileName(
        language: 'both',
        arabicLabel: 'تقرير-يومي',
        englishLabel: 'Daily-Report',
        sharedSuffix: '20261031',
        exportedAt: exportedAt,
        includeExportDate: false,
      ),
      'تقرير-يومي-Daily-Report-20261031-094830.pdf',
    );
  });

}
