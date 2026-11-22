// إدارة الدخول بالبصمة على Android مع حفظ بيانات الاعتماد في التخزين الآمن.
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

class AndroidBiometricLogin {
  AndroidBiometricLogin._();

  static final AndroidBiometricLogin instance = AndroidBiometricLogin._();

  final LocalAuthentication _authentication = LocalAuthentication();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  static const _usernameKey = 'biometric_login_username';
  static const _passwordKey = 'biometric_login_password';
  // علامة غير حساسة لفحص التفعيل دون فك تشفير بيانات الحساب قبل البصمة.
  static const _enabledKey = 'biometric_login_enabled';

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  Future<bool> get isAvailable async {
    if (!_isAndroid) return false;
    try {
      final supported = await _authentication.isDeviceSupported();
      final biometrics = await _authentication.getAvailableBiometrics();
      return supported && biometrics.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  // نقرأ علامة التفعيل فقط؛ لا نلمس اسم المستخدم أو كلمة المرور قبل البصمة.
  Future<bool> get hasSavedCredentials async {
    if (!_isAndroid) return false;
    try {
      return await _storage.read(key: _enabledKey) == 'true';
    } catch (_) {
      return false;
    }
  }

  Future<void> saveCredentials({
    required String username,
    required String password,
  }) async {
    if (!_isAndroid) return;

    // لا تعتبر بيانات الدخول جاهزة حتى يكتمل حفظ الحقلين.
    await _storage.write(key: _enabledKey, value: 'false');
    await _storage.write(key: _usernameKey, value: username.trim());
    await _storage.write(key: _passwordKey, value: password);
    await _storage.write(key: _enabledKey, value: 'true');
  }

  Future<bool> enableWithBiometrics({
    required String username,
    required String password,
  }) async {
    if (!await isAvailable) return false;
    try {
      final authenticated = await _authentication.authenticate(
        localizedReason: 'فعّل الدخول بالبصمة لهذا الحساب على هذا الجهاز',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
      if (!authenticated) return false;
      await saveCredentials(username: username, password: password);
      return true;
    } catch (_) {
      // فشل إعداد البصمة لا يمنع إكمال تسجيل الدخول بكلمة المرور.
      return false;
    }
  }

  Future<void> clearCredentials() async {
    if (!_isAndroid) return;
    // أوقف الدخول الحيوي أولًا حتى لا تُستخدم بيانات جزئية أثناء المسح.
    await _storage.delete(key: _enabledKey);
    await _storage.delete(key: _usernameKey);
    await _storage.delete(key: _passwordKey);
  }

  // لا تُقرأ بيانات الاعتماد إلا بعد نجاح التحقق الحيوي في هذه المحاولة.
  Future<({String username, String password})?> authenticate() async {
    if (!_isAndroid || !await hasSavedCredentials) return null;
    final available = await isAvailable;
    if (!available) return null;

    final authenticated = await _authentication.authenticate(
      localizedReason: 'تحقق من هويتك لفتح Homi Grocery',
      options: const AuthenticationOptions(
        biometricOnly: true,
        stickyAuth: true,
      ),
    );
    if (!authenticated) return null;

    // هذه أول نقطة تُقرأ فيها بيانات الحساب، بعد نجاح البصمة.
    final username = await _storage.read(key: _usernameKey);
    final password = await _storage.read(key: _passwordKey);
    if (username == null ||
        username.isEmpty ||
        password == null ||
        password.isEmpty) {
      await clearCredentials();
      return null;
    }
    return (username: username, password: password);
  }
}
