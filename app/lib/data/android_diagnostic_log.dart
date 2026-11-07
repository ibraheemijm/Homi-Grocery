// تسجيل أخطاء Flutter على Android محليًا لمساعدة التشخيص دون الحاجة إلى USB.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class AndroidDiagnosticLog {
  AndroidDiagnosticLog._();

  static Future<void> _writeQueue = Future<void>.value();
  static bool _initialized = false;

  static void initialize() {
    if (_initialized || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _initialized = true;

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      unawaited(record(
        details.exception,
        details.stack ?? StackTrace.current,
        source: 'Flutter framework',
      ));
    };

    final previousHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(record(error, stack, source: 'Uncaught platform error'));
      return previousHandler?.call(error, stack) ?? false;
    };
  }

  static Future<File> _logFile() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/homi_flutter_errors.log');
  }

  static Future<void> record(
    Object error,
    StackTrace stack, {
    required String source,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;

    _writeQueue = _writeQueue.then((_) async {
      try {
        final file = await _logFile();
        final timestamp = DateTime.now().toIso8601String();
        await file.writeAsString(
          '\n===== $timestamp | $source =====\n$error\n$stack\n',
          mode: FileMode.append,
          flush: true,
        );
      } catch (_) {
        // لا ينبغي أن يؤدي فشل حفظ سجل التشخيص إلى تعطيل التطبيق.
      }
    });
    await _writeQueue;
  }

  static Future<bool> shareLogs() async {
    await _writeQueue;
    final file = await _logFile();
    if (!await file.exists() || await file.length() == 0) return false;

    await Share.shareXFiles(
      [XFile(file.path)],
      text: 'سجل تشخيص أخطاء Homi Grocery على Android',
    );
    return true;
  }
}
