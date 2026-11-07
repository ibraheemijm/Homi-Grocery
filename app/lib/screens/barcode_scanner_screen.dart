// شاشة مسح الباركود بالكاميرا، تُفتح من نقطة البيع على Android فقط.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../data/android_diagnostic_log.dart';

class BarcodeScannerScreen extends StatefulWidget {
  const BarcodeScannerScreen({super.key});

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen> {
  bool _barcodeHandled = false;
  bool _scannerErrorRecorded = false;

  void _recordScannerError(MobileScannerException error) {
    if (_scannerErrorRecorded) return;
    _scannerErrorRecorded = true;

    // أخطاء MobileScanner قد تأتي من طبقة Android/CameraX ولا تمر عبر معالج Flutter العام.
    unawaited(AndroidDiagnosticLog.record(
      error,
      StackTrace.current,
      source: 'MobileScanner / Android camera startup',
    ));
  }

  void _handleDetection(BarcodeCapture capture) {
    if (_barcodeHandled) return;

    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value == null || value.isEmpty) continue;

      _barcodeHandled = true;
      Navigator.of(context).pop(value);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('مسح الباركود'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            onDetect: _handleDetection,
            // إظهار حالة تهيئة الكاميرا أو سبب فشلها بدل ترك مساحة سوداء بلا تفسير.
            placeholderBuilder: (context, child) => const ColoredBox(
              color: Colors.black,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFFC7A35A)),
                    SizedBox(height: 16),
                    Text(
                      'جارٍ تشغيل الكاميرا...',
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
            errorBuilder: (context, error, child) {
              _recordScannerError(error);
              return ColoredBox(
                color: Colors.black,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                      const Icon(
                        Icons.camera_alt_outlined,
                        color: Color(0xFFC7A35A),
                        size: 48,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'تعذر تشغيل الكاميرا',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        error.errorDetails?.message ?? error.errorCode.message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'تحقق من السماح للتطبيق باستخدام الكاميرا من إعدادات Android.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70),
                      ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 290,
                height: 170,
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFC7A35A), width: 3),
                  borderRadius: BorderRadius.circular(22),
                ),
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 28,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Text(
                'وجّه الكاميرا نحو باركود الصنف. ستعود إلى الفاتورة تلقائيًا عند قراءته.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
