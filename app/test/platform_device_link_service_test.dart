import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/data/platform_api_client.dart';
import 'package:homi_grocery/data/platform_device_identity.dart';
import 'package:homi_grocery/data/platform_device_link_service.dart';

class MemorySecretStore implements PlatformSecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class QueueTransport implements PlatformHttpTransport {
  QueueTransport(this.responses);

  final List<PlatformHttpResponse> responses;
  final List<({String method, Uri uri, Map<String, String> headers, String? body})> requests = [];
  var _index = 0;

  @override
  Future<PlatformHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    requests.add((method: method, uri: uri, headers: headers, body: body));
    return responses[_index++];
  }

  @override
  void close() {}
}

PlatformHttpResponse success(
  Map<String, Object?> data, {
  int statusCode = 200,
}) =>
    PlatformHttpResponse(
      statusCode: statusCode,
      body: jsonEncode({'success': true, 'data': data}),
    );

PlatformHttpResponse failure(
  String code, {
  int statusCode = 409,
}) =>
    PlatformHttpResponse(
      statusCode: statusCode,
      body: jsonEncode({
        'success': false,
        'error': {'code': code, 'message': 'Device link is not ready.'},
      }),
    );

const spkiPrefix = <int>[
  0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
  0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
];

void main() {
  test('يطلب ربط البريد دون كلمة مرور أو جلسة منصة ويحفظ التحدي', () async {
    final store = MemorySecretStore();
    final identity = PlatformDeviceIdentity(
      store,
      platformOverride: () => 'linux',
    );
    final transport = QueueTransport([
      success({
        'accepted': true,
        'challenge_id': '123e4567-e89b-42d3-a456-426614174000',
        'nonce': base64UrlEncode(List<int>.generate(32, (i) => i)).replaceAll('=', ''),
        'expires_at': DateTime.now().toUtc().add(const Duration(minutes: 5)).toIso8601String(),
      }, statusCode: 202),
    ]);
    final service = PlatformDeviceLinkService(
      api: PlatformApiClient(
        baseUri: Uri.parse('https://platform.example.test'),
        transport: transport,
      ),
      deviceIdentity: identity,
      store: store,
      trustedPublicKeys: {},
    );

    await service.requestLink(' Customer@example.test ');

    final request = transport.requests.single;
    expect(request.uri.path, '/api/v1/products/homi-grocery/device-links');
    final body = jsonDecode(request.body!) as Map<String, dynamic>;
    expect(body['email'], 'customer@example.test');
    expect(body['platform'], 'linux');
    expect(body['architecture'], isNotEmpty);
    expect(body['public_key'], isNotEmpty);
    expect(body.containsKey('password'), isFalse);
    expect(request.headers.containsKey('authorization'), isFalse);
    expect(store.values['homi_platform_pending_device_link_v1'], contains('challenge_id'));
  });

  test('ينتظر تأكيد البريد عند عدم جاهزية الرابط ولا يطلب كلمة مرور', () async {
    final store = MemorySecretStore();
    final identity = PlatformDeviceIdentity(
      store,
      platformOverride: () => 'windows',
    );
    final nonce = base64UrlEncode(List<int>.generate(32, (i) => 31 - i)).replaceAll('=', '');
    final transport = QueueTransport([
      success({
        'accepted': true,
        'challenge_id': '123e4567-e89b-42d3-a456-426614174001',
        'nonce': nonce,
        'expires_at': DateTime.now().toUtc().add(const Duration(minutes: 5)).toIso8601String(),
      }, statusCode: 202),
      failure('DEVICE_LINK_NOT_READY'),
    ]);
    final service = PlatformDeviceLinkService(
      api: PlatformApiClient(
        baseUri: Uri.parse('https://platform.example.test'),
        transport: transport,
      ),
      deviceIdentity: identity,
      store: store,
      trustedPublicKeys: {},
    );

    await service.requestLink('customer@example.test');
    expect(
      await service.completePendingLink(),
      PlatformDeviceLinkStatus.waitingForEmail,
    );

    final completion = jsonDecode(transport.requests.last.body!) as Map<String, dynamic>;
    expect(completion['challenge_id'], '123e4567-e89b-42d3-a456-426614174001');
    expect(completion['nonce'], nonce);
    expect(completion['signature'], isNotEmpty);
    expect(completion.containsKey('password'), isFalse);
  });

  test('يتحقق من توقيع الرخصة قبل حفظ اكتمال الربط', () async {
    final store = MemorySecretStore();
    final identity = PlatformDeviceIdentity(
      store,
      platformOverride: () => 'android',
    );
    const licenseId = '123e4567-e89b-42d3-a456-426614174010';
    const keyId = 'homi-license-test-key';
    final keyPair = await Ed25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final publicDer = <int>[...spkiPrefix, ...publicKey.bytes];
    final issuedAt = DateTime.now().toUtc();
    final startsAt = issuedAt.subtract(const Duration(seconds: 1));
    final endsAt = issuedAt.add(const Duration(days: 14));
    final payload = utf8.encode(jsonEncode({
      'schema_version': 1,
      'license_id': licenseId,
      'organization_id': '123e4567-e89b-42d3-a456-426614174011',
      'user_id': '123e4567-e89b-42d3-a456-426614174012',
      'product_id': '123e4567-e89b-42d3-a456-426614174013',
      'origin_trial_id': '123e4567-e89b-42d3-a456-426614174014',
      'subscription_id': null,
      'trial_id': '123e4567-e89b-42d3-a456-426614174014',
      'plan_key': 'trial',
      'starts_at': startsAt.toIso8601String(),
      'ends_at': endsAt.toIso8601String(),
      'max_devices': 2,
      'entitlement_version': 1,
      'issued_at': issuedAt.toIso8601String(),
      'key_id': keyId,
    }));
    final signed = await Ed25519().sign(payload, keyPair: keyPair);
    final nonce = base64UrlEncode(List<int>.generate(32, (i) => i + 1)).replaceAll('=', '');
    final transport = QueueTransport([
      success({
        'accepted': true,
        'challenge_id': '123e4567-e89b-42d3-a456-426614174015',
        'nonce': nonce,
        'expires_at': DateTime.now().toUtc().add(const Duration(minutes: 5)).toIso8601String(),
      }, statusCode: 202),
      success({
        'status': 'active',
        'license': {
          'id': licenseId,
          'status': 'active',
          'key_id': keyId,
          'payload': base64Encode(payload),
          'signature': base64Encode(signed.bytes),
          'issued_at': issuedAt.toIso8601String(),
          'starts_at': startsAt.toIso8601String(),
          'ends_at': endsAt.toIso8601String(),
        }
      }),
      success({
        'items': [{
          'key_id': keyId,
          'status': 'active',
          'public_key': base64Encode(publicDer),
        }]
      }),
    ]);
    final service = PlatformDeviceLinkService(
      api: PlatformApiClient(
        baseUri: Uri.parse('https://platform.example.test'),
        transport: transport,
      ),
      deviceIdentity: identity,
      store: store,
      trustedPublicKeys: {keyId: base64Encode(publicDer)},
    );

    await service.requestLink('customer@example.test');
    expect(
      await service.completePendingLink(),
      PlatformDeviceLinkStatus.linked,
    );
    final saved = await service.readLinkedLicense();
    expect(saved!.licenseId, licenseId);
    expect(saved.keyId, keyId);
    expect(saved.planKey, 'trial');
    expect(saved.endsAt, endsAt);
    expect(store.values['homi_platform_pending_device_link_v1'], '');
    expect(transport.requests, hasLength(2));
    expect(
      transport.requests.map((request) => request.uri.path),
      isNot(contains('/api/v1/license-signing-keys')),
    );
    final storedLicense = jsonDecode(
      store.values['homi_platform_signed_license_v1']!,
    ) as Map<String, dynamic>;
    expect(storedLicense.containsKey('public_key'), isFalse);
  });

  test('يرفض مفتاح توقيع غير مثبت دون جلب مفتاح بديل من الخادم', () async {
    final store = MemorySecretStore();
    final identity = PlatformDeviceIdentity(
      store,
      platformOverride: () => 'android',
    );
    final nonce = base64UrlEncode(List<int>.generate(32, (i) => i + 1))
        .replaceAll('=', '');
    final transport = QueueTransport([
      success({
        'accepted': true,
        'challenge_id': '123e4567-e89b-42d3-a456-426614174030',
        'nonce': nonce,
        'expires_at': DateTime.now().toUtc().add(const Duration(minutes: 5)).toIso8601String(),
      }, statusCode: 202),
      success({
        'status': 'active',
        'license': {
          'id': '123e4567-e89b-42d3-a456-426614174031',
          'key_id': 'unknown-key',
          'payload': base64Encode([1, 2, 3]),
          'signature': base64Encode(List<int>.filled(64, 0)),
        }
      }),
    ]);
    final service = PlatformDeviceLinkService(
      api: PlatformApiClient(
        baseUri: Uri.parse('https://platform.example.test'),
        transport: transport,
      ),
      deviceIdentity: identity,
      store: store,
      trustedPublicKeys: {},
    );

    await service.requestLink('customer@example.test');
    await expectLater(
      service.completePendingLink(),
      throwsA(isA<FormatException>()),
    );

    expect(transport.requests, hasLength(2));
    expect(
      transport.requests.map((request) => request.uri.path),
      isNot(contains('/api/v1/license-signing-keys')),
    );
    expect(store.values['homi_platform_signed_license_v1'], isNull);
  });

  test('يرفض توقيع ترخيص معدل قبل اعتباره مرتبطًا', () async {
    final store = MemorySecretStore();
    final identity = PlatformDeviceIdentity(
      store,
      platformOverride: () => 'linux',
    );
    final keyPair = await Ed25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final publicDer = <int>[...spkiPrefix, ...publicKey.bytes];
    final issuedAt = DateTime.now().toUtc();
    final payload = utf8.encode(jsonEncode({
      'schema_version': 1,
      'license_id': '123e4567-e89b-42d3-a456-426614174020',
      'organization_id': '123e4567-e89b-42d3-a456-426614174021',
      'user_id': '123e4567-e89b-42d3-a456-426614174022',
      'product_id': '123e4567-e89b-42d3-a456-426614174023',
      'plan_key': 'trial',
      'starts_at': issuedAt.toIso8601String(),
      'ends_at': issuedAt.add(const Duration(days: 14)).toIso8601String(),
      'issued_at': issuedAt.toIso8601String(),
      'entitlement_version': 1,
      'key_id': 'homi-license-test-key',
    }));
    final transport = QueueTransport([
      success({
        'accepted': true,
        'challenge_id': '123e4567-e89b-42d3-a456-426614174024',
        'nonce': base64UrlEncode(List<int>.generate(32, (i) => i)).replaceAll('=', ''),
        'expires_at': DateTime.now().toUtc().add(const Duration(minutes: 5)).toIso8601String(),
      }, statusCode: 202),
      success({
        'status': 'active',
        'license': {
          'id': '123e4567-e89b-42d3-a456-426614174020',
          'status': 'active',
          'key_id': 'homi-license-test-key',
          'payload': base64Encode(payload),
          'signature': base64Encode(List<int>.filled(64, 0)),
        }
      }),
      success({
        'items': [{
          'key_id': 'homi-license-test-key',
          'status': 'active',
          'public_key': base64Encode(publicDer),
        }]
      }),
    ]);
    final service = PlatformDeviceLinkService(
      api: PlatformApiClient(
        baseUri: Uri.parse('https://platform.example.test'),
        transport: transport,
      ),
      deviceIdentity: identity,
      store: store,
      trustedPublicKeys: {'homi-license-test-key': base64Encode(publicDer)},
    );

    await service.requestLink('customer@example.test');
    await expectLater(
      service.completePendingLink(),
      throwsA(isA<FormatException>()),
    );
    expect(store.values['homi_platform_signed_license_v1'], isNull);
  });
}
