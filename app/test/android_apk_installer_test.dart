import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/data/android_apk_installer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.homi.grocery/apk_installer');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('يقرأ حالة السماح بتثبيت التطبيقات من هذا المصدر', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'canRequestPackageInstalls');
      return true;
    });

    expect(await AndroidApkInstaller(channel: channel).canRequestPackageInstalls(), isTrue);
  });

  test('يفتح إعداد السماح بالتثبيت من المصدر الحالي', () async {
    var invoked = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'openInstallPermissionSettings');
      invoked = true;
      return null;
    });

    await AndroidApkInstaller(channel: channel).openInstallPermissionSettings();
    expect(invoked, isTrue);
  });

  test('يسلم APK موجودًا إلى المثبّت ولا يرسل ملفًا مفقودًا', () async {
    final directory = await Directory.systemTemp.createTemp('homi-installer-test-');
    addTearDown(() => directory.delete(recursive: true));
    final apk = File('${directory.path}/candidate.apk');
    await apk.writeAsBytes([1, 2, 3], flush: true);
    String? receivedPath;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'installApk');
      receivedPath = (call.arguments as Map)['path'] as String;
      return null;
    });

    await AndroidApkInstaller(channel: channel).installVerifiedApk(apk);
    expect(receivedPath, apk.absolute.path);

    await expectLater(
      AndroidApkInstaller(channel: channel).installVerifiedApk(
        File('${directory.path}/missing.apk'),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('يعيد versionCode من PackageManager', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'installedVersionCode');
      return 207;
    });

    expect(await AndroidApkInstaller(channel: channel).installedVersionCode(), 207);
  });
}
