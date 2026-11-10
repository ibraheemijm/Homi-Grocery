// حساب منصة Homi منفصل عن حسابات المدير والكاشير المحلية في قاعدة SQLite.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'platform_api_client.dart';

abstract interface class PlatformSessionSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterPlatformSessionSecretStore implements PlatformSessionSecretStore {
  FlutterPlatformSessionSecretStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class PlatformSessionTokens {
  const PlatformSessionTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime accessExpiresAt;
}

class PlatformSessionStore {
  PlatformSessionStore(this._store);

  final PlatformSessionSecretStore _store;
  static const _accessTokenKey = 'homi_platform_access_token';
  static const _refreshTokenKey = 'homi_platform_refresh_token';
  static const _accessExpiryKey = 'homi_platform_access_expires_at';

  Future<PlatformSessionTokens?> read() async {
    final access = await _store.read(_accessTokenKey);
    final refresh = await _store.read(_refreshTokenKey);
    final expiry = await _store.read(_accessExpiryKey);
    if (access == null || refresh == null || expiry == null) return null;
    final expiresAt = DateTime.tryParse(expiry);
    if (access.isEmpty || refresh.isEmpty || expiresAt == null) return null;
    return PlatformSessionTokens(
      accessToken: access,
      refreshToken: refresh,
      accessExpiresAt: expiresAt.toUtc(),
    );
  }

  Future<void> save({
    required String accessToken,
    required String refreshToken,
    required int expiresInSeconds,
    DateTime? now,
  }) async {
    if (accessToken.isEmpty ||
        refreshToken.isEmpty ||
        expiresInSeconds < 1 ||
        expiresInSeconds > 86400) {
      throw const FormatException('رموز جلسة Homi Platform غير صالحة.');
    }
    final expiry = (now ?? DateTime.now().toUtc())
        .toUtc()
        .add(Duration(seconds: expiresInSeconds))
        .toIso8601String();

    // لا تُعتبر الجلسة مكتملة حتى تُحفظ الرموز الثلاثة.
    await _store.write(_accessExpiryKey, '');
    await _store.write(_accessTokenKey, accessToken);
    await _store.write(_refreshTokenKey, refreshToken);
    await _store.write(_accessExpiryKey, expiry);
  }

  Future<void> clear() async {
    await _store.delete(_accessExpiryKey);
    await _store.delete(_accessTokenKey);
    await _store.delete(_refreshTokenKey);
  }
}

class PlatformAccountService {
  PlatformAccountService({
    required PlatformApiClient api,
    required PlatformSessionStore sessions,
    DateTime Function()? clock,
  })  : _api = api,
        _sessions = sessions,
        _clock = clock ?? DateTime.now;

  final PlatformApiClient _api;
  final PlatformSessionStore _sessions;
  final DateTime Function() _clock;

  Future<Map<String, Object?>> register({
    required String email,
    required String password,
    String? displayName,
  }) {
    return _api.postJson(
      '/api/v1/auth/register',
      body: {
        'email': email.trim(),
        'password': password,
        if (displayName != null && displayName.trim().isNotEmpty)
          'display_name': displayName.trim(),
      },
    );
  }

  Future<Map<String, Object?>> confirmEmail(String token) {
    return _api.postJson(
      '/api/v1/auth/email-verifications/confirm',
      body: {'token': token},
    );
  }

  Future<void> login({
    required String email,
    required String password,
  }) async {
    final data = await _api.postJson(
      '/api/v1/auth/login',
      body: {'email': email.trim(), 'password': password},
    );
    await _saveTokens(data);
  }

  Future<String> validAccessToken({
    Duration refreshBefore = const Duration(minutes: 1),
  }) async {
    final session = await _sessions.read();
    if (session == null) {
      throw const PlatformApiException(
        statusCode: 401,
        code: 'PLATFORM_LOGIN_REQUIRED',
        message: 'سجّل الدخول إلى حساب Homi Platform أولًا.',
      );
    }
    if (session.accessExpiresAt.isAfter(_clock().toUtc().add(refreshBefore))) {
      return session.accessToken;
    }
    await refresh();
    final updated = await _sessions.read();
    if (updated == null) {
      throw const PlatformApiException(
        statusCode: 401,
        code: 'PLATFORM_SESSION_UNAVAILABLE',
        message: 'تعذر استعادة جلسة Homi Platform.',
      );
    }
    return updated.accessToken;
  }

  Future<void> refresh() async {
    final current = await _sessions.read();
    if (current == null) {
      throw const PlatformApiException(
        statusCode: 401,
        code: 'PLATFORM_LOGIN_REQUIRED',
        message: 'لا توجد جلسة منصة محفوظة.',
      );
    }
    try {
      final data = await _api.postJson(
        '/api/v1/auth/refresh',
        body: {'refresh_token': current.refreshToken},
      );
      await _saveTokens(data);
    } on PlatformApiException catch (error) {
      if (error.statusCode == 401) await _sessions.clear();
      rethrow;
    }
  }

  Future<void> logout() async {
    final session = await _sessions.read();
    if (session == null) return;
    try {
      await _api.postJson(
        '/api/v1/auth/logout',
        accessToken: session.accessToken,
        body: const {},
      );
    } finally {
      await _sessions.clear();
    }
  }

  Future<void> _saveTokens(Map<String, Object?> data) async {
    final access = data['access_token'];
    final refresh = data['refresh_token'];
    final expiresIn = data['expires_in'];
    if (access is! String ||
        refresh is! String ||
        expiresIn is! num ||
        !expiresIn.isFinite) {
      throw const FormatException('استجابة تسجيل الدخول لا تحتوي رموز جلسة صالحة.');
    }
    await _sessions.save(
      accessToken: access,
      refreshToken: refresh,
      expiresInSeconds: expiresIn.toInt(),
      now: _clock().toUtc(),
    );
  }
}
