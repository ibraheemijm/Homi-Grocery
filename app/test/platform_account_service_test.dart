import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/data/platform_account_service.dart';
import 'package:homi_grocery/data/platform_api_client.dart';

class MemorySessionStore implements PlatformSessionSecretStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async { values[key] = value; }
  @override
  Future<void> delete(String key) async { values.remove(key); }
}

class QueueTransport implements PlatformHttpTransport {
  QueueTransport(this.responses);
  final List<PlatformHttpResponse> responses;
  final List<({Uri uri, Map<String, String> headers, String? body})> requests = [];
  var _index = 0;

  @override
  Future<PlatformHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    requests.add((uri: uri, headers: headers, body: body));
    return responses[_index++];
  }

  @override
  void close() {}
}

PlatformHttpResponse success(Map<String, Object?> data) => PlatformHttpResponse(
  statusCode: 200,
  body: jsonEncode({'success': true, 'data': data}),
);

void main() {
  test('يحفظ رموز الجلسة ويعيد قراءتها', () async {
    final store = PlatformSessionStore(MemorySessionStore());
    final now = DateTime.utc(2026, 11, 10, 12);
    await store.save(
      accessToken: 'access-test-value',
      refreshToken: 'refresh-test-value',
      expiresInSeconds: 900,
      now: now,
    );
    final saved = await store.read();
    expect(saved!.accessToken, 'access-test-value');
    expect(saved.refreshToken, 'refresh-test-value');
    expect(saved.accessExpiresAt, now.add(const Duration(minutes: 15)));
  });

  test('يجدد الجلسة ويدوّر refresh token قبل انتهاء access token', () async {
    final store = PlatformSessionStore(MemorySessionStore());
    final now = DateTime.utc(2026, 11, 10, 12);
    await store.save(
      accessToken: 'access-before-refresh',
      refreshToken: 'refresh-before-refresh',
      expiresInSeconds: 5,
      now: now,
    );
    final transport = QueueTransport([
      success({
        'access_token': 'access-after-refresh',
        'refresh_token': 'refresh-after-refresh',
        'expires_in': 900,
      }),
    ]);
    final service = PlatformAccountService(
      api: PlatformApiClient(
        baseUri: Uri.parse('https://platform.example.test'),
        transport: transport,
      ),
      sessions: store,
      clock: () => now,
    );

    expect(await service.validAccessToken(), 'access-after-refresh');
    expect(jsonDecode(transport.requests.single.body!)['refresh_token'],
        'refresh-before-refresh');
    expect((await store.read())!.refreshToken, 'refresh-after-refresh');
  });

  test('يحافظ على الجلسة المحلية إذا تعذر الاتصال أثناء التجديد', () async {
    final store = PlatformSessionStore(MemorySessionStore());
    final now = DateTime.utc(2026, 11, 10, 12);
    await store.save(
      accessToken: 'access-before-offline',
      refreshToken: 'refresh-before-offline',
      expiresInSeconds: 1,
      now: now,
    );
    final transport = QueueTransport([
      const PlatformHttpResponse(
        statusCode: 503,
        body: '{"success":false,"error":{"code":"SERVICE_UNAVAILABLE","message":"Offline"}}',
      ),
    ]);
    final service = PlatformAccountService(
      api: PlatformApiClient(
        baseUri: Uri.parse('https://platform.example.test'),
        transport: transport,
      ),
      sessions: store,
      clock: () => now,
    );

    await expectLater(service.validAccessToken(), throwsA(isA<PlatformApiException>()));
    expect((await store.read())!.refreshToken, 'refresh-before-offline');
  });
}
