// تسليم APK موثوق إلى مثبّت Android الرسمي؛ لا ينفذ تثبيتًا صامتًا.
import 'dart:io';

import 'package:flutter/services.dart';

class AndroidApkInstaller {
  AndroidApkInstaller({MethodChannel? channel, bool? isAndroid})
      : _channel = channel ?? const MethodChannel('com.homi.grocery/apk_installer'),
        _isAndroid = isAndroid ?? Platform.isAndroid;

  final MethodChannel _channel;
  final bool _isAndroid;

  Future<bool> canRequestPackageInstalls() async {
    if (!_isAndroid) {
      throw UnsupportedError('تثبيت APK متاح على Android فقط.');
    }
    return await _channel.invokeMethod<bool>('canRequestPackageInstalls') ?? false;
  }

  /// يفتح إعداد السماح لهذا التطبيق بتثبيت ملفات APK على Android 8+.
  Future<void> openInstallPermissionSettings() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('إعداد تثبيت APK متاح على Android فقط.');
    }
    await _channel.invokeMethod<void>('openInstallPermissionSettings');
  }

  /// يفتح واجهة Android Package Installer؛ القرار النهائي للمستخدم.
  Future<void> installVerifiedApk(File apk) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('تثبيت APK متاح على Android فقط.');
    }
    if (!await apk.exists() ||
        !apk.path.toLowerCase().endsWith('.apk') ||
        await apk.length() < 1) {
      throw const FormatException('ملف APK غير موجود أو غير صالح.');
    }
    await _channel.invokeMethod<void>(
      'installApk',
      <String, Object>{'path': apk.absolute.path},
    );
  }

  /// يعيد الإصدار المثبت من PackageManager بعد عودة المستخدم من المثبّت.
  Future<int> installedVersionCode() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('قراءة إصدار Android متاحة على Android فقط.');
    }
    final version = await _channel.invokeMethod<int>('installedVersionCode');
    if (version == null || version < 1) {
      throw const FormatException('تعذر قراءة رقم إصدار Homi المثبت.');
    }
    return version;
  }
}
