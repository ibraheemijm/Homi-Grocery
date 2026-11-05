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

  Future<bool> get hasSavedCredentials async {
    if (!_isAndroid) return false;
    try {
      final username = await _storage.read(key: _usernameKey);
      final password = await _storage.read(key: _passwordKey);
      return username != null &&
          username.isNotEmpty &&
          password != null &&
          password.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> saveCredentials({
    required String username,
    required String password,
  }) async {
    if (!_isAndroid) return;
    await _storage.write(key: _usernameKey, value: username.trim());
    await _storage.write(key: _passwordKey, value: password);
  }

  Future<void> clearCredentials() async {
    if (!_isAndroid) return;
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

    final username = await _storage.read(key: _usernameKey);
    final password = await _storage.read(key: _passwordKey);
    if (username == null ||
        username.isEmpty ||
        password == null ||
        password.isEmpty) {
      return null;
    }
    return (username: username, password: password);
  }
}
