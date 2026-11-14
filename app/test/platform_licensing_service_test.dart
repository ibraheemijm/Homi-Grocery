import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/data/platform_api_client.dart';
import 'package:homi_grocery/data/platform_device_identity.dart';
import 'package:homi_grocery/data/platform_licensing_service.dart';
import 'package:homi_grocery/data/platform_signing_trust.dart';

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

PlatformHttpResponse success(Map<String, Object?> data) => PlatformHttpResponse(
      statusCode: 200,
      body: jsonEncode({'success': true, 'data': data}),
    );


Future<Map<String, Object?>> signedKeyset({
  required SimpleKeyPair rootPair,
  required String keyId,
  required List<int> publicDer,
}) async {
  final payload = utf8.encode(jsonEncode({
    'schema_version': 1,
    'keyset_version': 1,
    'issued_at': '2026-11-10T12:00:00.000Z',
    'expires_at': '2026-12-10T12:00:00.000Z',
    'keys': [{
      'key_id': keyId,
      'purpose': 'offline_license_grant',
      'algorithm': 'Ed25519',
      'public_key': base64Encode(publicDer),
      'not_before': '2026-11-01T00:00:00.000Z',
      'not_after': '2027-01-01T00:00:00.000Z',
      'status': 'active',
    }],
  }));
  final signature = await Ed25519().sign(payload, keyPair: rootPair);
  return {
    'root_key_id': 'homi-root-test',
    'payload': base64Encode(payload),
    'signature': base64Encode(signature.bytes),
  };
}

Future<PlatformSigningTrust> testTrust(
  MemorySecretStore store,
  SimpleKeyPair rootPair,
) async {
  final publicKey = await rootPair.extractPublicKey();
  return PlatformSigningTrust(
    store: store,
    rootKeyId: 'homi-root-test',
    rootPublicKeyBase64: base64Encode(publicKey.bytes),
  );
}


Future<void> expectGrantRejected(Map<String, Object?> claims) async {
  const licenseId = 'e5a1e20a-5c30-4b58-a430-1cb2c4bbef17';
  const deviceId = 'f5a1e20a-5c30-4b58-a430-1cb2c4bbef17';
  const challengeId = 'd5a1e20a-5c30-4b58-a430-1cb2c4bbef17';
  const grantId = 'a5a1e20a-5c30-4b58-a430-1cb2c4bbef17';
  const keyId = 'license-key-test';
  final nonce = List<int>.generate(32, (index) => 255 - index);
  final nonceText = base64UrlEncode(nonce).replaceAll('=', '');
  final signingKeyPair = await Ed25519().newKeyPair();
  final signingPublicKey = await signingKeyPair.extractPublicKey();
  final publicDer = <int>[
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
    0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
    ...signingPublicKey.bytes,
  ];
  final payload = utf8.encode(jsonEncode(claims));
  final signature = await Ed25519().sign(payload, keyPair: signingKeyPair);
  final rootPair = await Ed25519().newKeyPair();
  final store = MemorySecretStore();
  final transport = QueueTransport([
    success({'challenge_id': challengeId, 'nonce': nonceText}),
    success({
      'id': grantId,
      'key_id': keyId,
      'payload': base64Encode(payload),
      'signature': base64Encode(signature.bytes),
      'issued_at': '2026-11-10T15:00:00.000000Z',
      'expires_at': null,
      'entitlement_version': 4,
    }),
    success(await signedKeyset(
      rootPair: rootPair,
      keyId: keyId,
      publicDer: publicDer,
    )),
  ]);
  final api = PlatformApiClient(
    baseUri: Uri.parse('https://platform.example.test'),
    transport: transport,
  );
  final service = PlatformLicensingService(
    api: api,
    deviceIdentity: PlatformDeviceIdentity(MemorySecretStore(), isAndroid: () => true),
    signingTrust: await testTrust(store, rootPair),
  );

  await expectLater(
    service.issueOfflineGrant(
      accessToken: 'user-token',
      licenseId: licenseId,
      deviceId: deviceId,
    ),
    throwsA(isA<FormatException>()),
  );
}

void main() {
  test('يسجل الجهاز بتحدٍ قصير العمر وتوقيع مفتاح الجهاز', () async {
    const challengeId = 'd5a1e20a-5c30-4b58-a430-1cb2c4bbef17';
    const licenseId = 'e5a1e20a-5c30-4b58-a430-1cb2c4bbef17';
    final nonce = List<int>.generate(32, (index) => index + 1);
    final nonceText = base64UrlEncode(nonce).replaceAll('=', '');
    final transport = QueueTransport([
      success({'challenge_id': challengeId, 'nonce': nonceText}),
      success({'id': 'f5a1e20a-5c30-4b58-a430-1cb2c4bbef17'}),
    ]);
    final identity = PlatformDeviceIdentity(MemorySecretStore(), isAndroid: () => true);
    final api = PlatformApiClient(
      baseUri: Uri.parse('https://platform.example.test'),
      transport: transport,
    );
    final rootPair = await Ed25519().newKeyPair();
    final service = PlatformLicensingService(
      api: api,
      deviceIdentity: identity,
      signingTrust: await testTrust(MemorySecretStore(), rootPair),
    );

    final registered = await service.registerDevice(
      accessToken: 'user-token',
      licenseId: licenseId,
      productKey: 'homi-grocery',
    );

    expect(registered['id'], isA<String>());
    expect(transport.requests, hasLength(2));
    expect(transport.requests.first.uri.path, '/api/v1/devices/challenges');
    expect(transport.requests.last.uri.path, '/api/v1/licenses/$licenseId/devices');
    expect(transport.requests.every(
      (request) => request.headers['authorization'] == 'Bearer user-token',
    ), isTrue);

    final firstBody = jsonDecode(transport.requests.first.body!) as Map<String, dynamic>;
    final secondBody = jsonDecode(transport.requests.last.body!) as Map<String, dynamic>;
    expect(firstBody['public_key'], isA<String>());
    expect(secondBody['challenge_id'], challengeId);
    expect(secondBody['nonce'], nonceText);
    final identityData = await identity.loadOrCreate();
    final publicKey = SimplePublicKey(
      identityData.publicKeyDer.sublist(12),
      type: KeyPairType.ed25519,
    );
    final signature = base64Url.decode(
      base64Url.normalize(secondBody['signature'] as String),
    );
    expect(
      await Ed25519().verify(
        nonce,
        signature: Signature(signature, publicKey: publicKey),
      ),
      isTrue,
    );
  });

  test('لا يعيد تصريح offline قبل التحقق من توقيع Ed25519 ومطابقة الجهاز', () async {
    const licenseId = 'e5a1e20a-5c30-4b58-a430-1cb2c4bbef17';
    const deviceId = 'f5a1e20a-5c30-4b58-a430-1cb2c4bbef17';
    const challengeId = 'd5a1e20a-5c30-4b58-a430-1cb2c4bbef17';
    const grantId = 'a5a1e20a-5c30-4b58-a430-1cb2c4bbef17';
    const keyId = 'license-key-test';
    final nonce = List<int>.generate(32, (index) => 255 - index);
    final nonceText = base64UrlEncode(nonce).replaceAll('=', '');
    final signingKeyPair = await Ed25519().newKeyPair();
    final signingPublicKey = await signingKeyPair.extractPublicKey();
    final publicDer = <int>[
      0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
      0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
      ...signingPublicKey.bytes,
    ];
    final payload = utf8.encode(jsonEncode({
      'schema_version': 1,
      'grant_id': grantId,
      'license_id': licenseId,
      'user_id': 'user-1',
      'product_id': 'product-1',
      'device_id': deviceId,
      'plan_key': 'monthly',
      'key_id': keyId,
      'entitlement_version': 4,
      'issued_at': '2026-11-10T15:00:00.000000Z',
      'expires_at': null,
    }));
    final signature = await Ed25519().sign(payload, keyPair: signingKeyPair);
    final rootPair = await Ed25519().newKeyPair();
    final store = MemorySecretStore();
    final transport = QueueTransport([
      success({'challenge_id': challengeId, 'nonce': nonceText}),
      success({
        'id': grantId,
        'key_id': keyId,
        'payload': base64Encode(payload),
        'signature': base64Encode(signature.bytes),
        'issued_at': '2026-11-10T15:00:00.000000Z',
        'expires_at': null,
        'entitlement_version': 4,
      }),
      success(await signedKeyset(
        rootPair: rootPair,
        keyId: keyId,
        publicDer: publicDer,
      )),
    ]);
    final api = PlatformApiClient(
      baseUri: Uri.parse('https://platform.example.test'),
      transport: transport,
    );
    final service = PlatformLicensingService(
      api: api,
      deviceIdentity: PlatformDeviceIdentity(MemorySecretStore(), isAndroid: () => true),
      signingTrust: await testTrust(store, rootPair),
    );

    final grant = await service.issueOfflineGrant(
      accessToken: 'user-token',
      licenseId: licenseId,
      deviceId: deviceId,
    );

    expect(grant.id, grantId);
    expect(grant.licenseId, licenseId);
    expect(grant.deviceId, deviceId);
    expect(grant.keyId, keyId);
    expect(grant.expiresAt, isNull);
    expect(grant.entitlementVersion, 4);
    expect(transport.requests.map((request) => request.uri.path), [
      '/api/v1/devices/$deviceId/challenges',
      '/api/v1/licenses/$licenseId/offline-grants',
      '/api/v1/signing-keyset',
    ]);
  });

  test('يرفض entitlement_version غير الصحيح حتى لو كان رقمًا موجبًا', () async {
    await expectGrantRejected({
      'schema_version': 1,
      'grant_id': 'a5a1e20a-5c30-4b58-a430-1cb2c4bbef17',
      'license_id': 'e5a1e20a-5c30-4b58-a430-1cb2c4bbef17',
      'user_id': 'user-1',
      'product_id': 'product-1',
      'device_id': 'f5a1e20a-5c30-4b58-a430-1cb2c4bbef17',
      'plan_key': 'monthly',
      'key_id': 'license-key-test',
      'entitlement_version': 4.5,
      'issued_at': '2026-11-10T15:00:00.000000Z',
      'expires_at': null,
    });
  });

  test('يرفض issued_at الذي لا يتضمن منطقة زمنية', () async {
    await expectGrantRejected({
      'schema_version': 1,
      'grant_id': 'a5a1e20a-5c30-4b58-a430-1cb2c4bbef17',
      'license_id': 'e5a1e20a-5c30-4b58-a430-1cb2c4bbef17',
      'user_id': 'user-1',
      'product_id': 'product-1',
      'device_id': 'f5a1e20a-5c30-4b58-a430-1cb2c4bbef17',
      'plan_key': 'monthly',
      'key_id': 'license-key-test',
      'entitlement_version': 4,
      'issued_at': '2026-11-10T15:00:00',
      'expires_at': null,
    });
  });

  test('يرفض expires_at المساوي أو السابق لـ issued_at', () async {
    await expectGrantRejected({
      'schema_version': 1,
      'grant_id': 'a5a1e20a-5c30-4b58-a430-1cb2c4bbef17',
      'license_id': 'e5a1e20a-5c30-4b58-a430-1cb2c4bbef17',
      'user_id': 'user-1',
      'product_id': 'product-1',
      'device_id': 'f5a1e20a-5c30-4b58-a430-1cb2c4bbef17',
      'plan_key': 'monthly',
      'key_id': 'license-key-test',
      'entitlement_version': 4,
      'issued_at': '2026-11-10T15:00:00.000000Z',
      'expires_at': '2026-11-10T15:00:00.000000Z',
    });
  });

}
