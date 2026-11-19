import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
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
  Future<void> write(String key, String value) async => values[key] = value;
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

PlatformHttpResponse success(Map<String, Object?> data, {int statusCode = 200}) =>
    PlatformHttpResponse(
      statusCode: statusCode,
      body: jsonEncode({'success': true, 'data': data}),
    );

const spkiPrefix = <int>[
  0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
  0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
];

String _b64url(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');
String _fingerprint(PlatformDeviceIdentity identity) {
  final raw = base64Url.decode(base64Url.normalize(identity.publicKeyRawBase64Url));
  return crypto.sha256.convert(raw).toString();
}

Map<String, Object?> _activationCreated(
  PlatformDeviceIdentity identity,
  String requestId,
  String challenge,
) => {
  'activation_request_id': requestId,
  'challenge': challenge,
  'challenge_expires_at': DateTime.now().toUtc().add(const Duration(minutes: 5)).toIso8601String(),
  'key_fingerprint': _fingerprint(identity),
  'support_whatsapp': '249900000000',
  'status': 'pending_proof',
};

void main() {
  test('ينشئ طلب تفعيل دون بريد أو حساب ويرسل المفتاح العام الخام فقط', () async {
    final store = MemorySecretStore();
    final identity = PlatformDeviceIdentity(store, platformOverride: () => 'linux');
    const requestId = '123e4567-e89b-42d3-a456-426614174000';
    final challenge = _b64url(List<int>.generate(32, (i) => i));
    final transport = QueueTransport([
      success(_activationCreated(identity, requestId, challenge), statusCode: 201),
    ]);
    final service = PlatformDeviceLinkService(
      api: PlatformApiClient(baseUri: Uri.parse('https://platform.example.test'), transport: transport),
      deviceIdentity: identity,
      store: store,
      trustedPublicKeys: {},
    );

    final activation = await service.requestActivation();
    final request = transport.requests.single;
    expect(request.method, 'POST');
    expect(request.uri.path, '/api/v1/public/activation-requests');
    final body = jsonDecode(request.body!) as Map<String, dynamic>;
    expect(body['product_key'], 'homi-grocery');
    expect(body['platform_key'], 'linux');
    expect(body['architecture_key'], isNotEmpty);
    expect(body['public_key'], identity.publicKeyRawBase64Url);
    expect(base64Url.decode(base64Url.normalize(body['public_key'] as String)), hasLength(32));
    expect(body.containsKey('email'), isFalse);
    expect(body.containsKey('password'), isFalse);
    expect(request.headers.containsKey('authorization'), isFalse);
    expect(activation.requestId, requestId);
    expect(activation.keyFingerprint, _fingerprint(identity));
    expect(activation.supportWhatsApp, '249900000000');
    expect(store.values['homi_platform_pending_device_link_v1'], contains('request_id'));
  });

  test('يوقع التحدي بصيغة البروتوكول ويرجع انتظار مراجعة الإدارة', () async {
    final store = MemorySecretStore();
    final identity = PlatformDeviceIdentity(store, platformOverride: () => 'windows');
    const requestId = '123e4567-e89b-42d3-a456-426614174001';
    final challenge = _b64url(List<int>.generate(32, (i) => 31 - i));
    final transport = QueueTransport([
      success(_activationCreated(identity, requestId, challenge), statusCode: 201),
      success({'activation_request_id': requestId, 'proof_verified': true, 'status': 'proof_verified'}),
      success({'status': 'proof_verified'}),
    ]);
    final service = PlatformDeviceLinkService(
      api: PlatformApiClient(baseUri: Uri.parse('https://platform.example.test'), transport: transport),
      deviceIdentity: identity,
      store: store,
      trustedPublicKeys: {},
    );

    await service.requestActivation();
    expect(await service.completePendingActivation(), PlatformDeviceLinkStatus.waitingForAdmin);
    final proofRequest = transport.requests[1];
    expect(proofRequest.uri.path, '/api/v1/public/activation-requests/$requestId/proof');
    final proofBody = jsonDecode(proofRequest.body!) as Map<String, dynamic>;
    expect(proofBody['challenge'], challenge);
    final message = [
      'HOMI_DEVICE_PROOF_V1',
      requestId,
      'homi-grocery',
      'windows',
      identity.architecture,
      challenge,
    ].join('\n');
    final signature = base64Url.decode(base64Url.normalize(proofBody['signature'] as String));
    final publicKey = SimplePublicKey(
      base64Url.decode(base64Url.normalize(identity.publicKeyRawBase64Url)),
      type: KeyPairType.ed25519,
    );
    expect(
      await Ed25519().verify(
        utf8.encode(message),
        signature: Signature(signature, publicKey: publicKey),
      ),
      isTrue,
    );
    expect(transport.requests[2].uri.path, '/api/v1/public/activation-requests/$requestId/status');
    final pending = await service.readPendingActivationRequest();
    expect(pending!.proofVerified, isTrue);
    expect(pending.supportWhatsApp, '249900000000');
  });

  test('يحفظ الترخيص الموقع فقط بعد تطابق بصمة مفتاح الجهاز', () async {
    final store = MemorySecretStore();
    final identity = PlatformDeviceIdentity(store, platformOverride: () => 'android');
    const requestId = '123e4567-e89b-42d3-a456-426614174010';
    const licenseId = '123e4567-e89b-42d3-a456-426614174011';
    const deviceId = '123e4567-e89b-42d3-a456-426614174012';
    const keyId = 'homi-license-test-key';
    final challenge = _b64url(List<int>.generate(32, (i) => i + 1));
    final keyPair = await Ed25519().newKeyPair();
    final signingPublicKey = await keyPair.extractPublicKey();
    final signingPublicDer = <int>[...spkiPrefix, ...signingPublicKey.bytes];
    final issuedAt = DateTime.now().toUtc();
    final startsAt = issuedAt.subtract(const Duration(seconds: 1));
    final endsAt = issuedAt.add(const Duration(days: 14));
    final payload = utf8.encode(jsonEncode({
      'schema_version': 1,
      'license_id': licenseId,
      'organization_id': '123e4567-e89b-42d3-a456-426614174013',
      'user_id': '123e4567-e89b-42d3-a456-426614174014',
      'product_id': '123e4567-e89b-42d3-a456-426614174015',
      'origin_trial_id': '123e4567-e89b-42d3-a456-426614174016',
      'subscription_id': null,
      'trial_id': '123e4567-e89b-42d3-a456-426614174016',
      'plan_key': 'trial',
      'starts_at': startsAt.toIso8601String(),
      'ends_at': endsAt.toIso8601String(),
      'trial_ends_at': endsAt.toIso8601String(),
      'subscription_ends_at': null,
      'offline_expires_at': issuedAt.add(const Duration(days: 7)).toIso8601String(),
      'grace_ends_at': null,
      'access_policy': 'full_until_offline_expiry_or_trial_end_then_read_export',
      'max_devices': 2,
      'device_fingerprints': [_fingerprint(identity)],
      'entitlement_version': 1,
      'issued_at': issuedAt.toIso8601String(),
      'key_id': keyId,
    }));
    final signed = await Ed25519().sign(payload, keyPair: keyPair);
    final transport = QueueTransport([
      success(_activationCreated(identity, requestId, challenge), statusCode: 201),
      success({'activation_request_id': requestId, 'proof_verified': true, 'status': 'proof_verified'}),
      success({
        'status': 'approved',
        'license': {
          'id': licenseId,
          'device_id': deviceId,
          'status': 'active',
          'key_id': keyId,
          'payload': base64Encode(payload),
          'signature': base64Encode(signed.bytes),
          'issued_at': issuedAt.toIso8601String(),
          'starts_at': startsAt.toIso8601String(),
          'ends_at': endsAt.toIso8601String(),
        }
      }),
    ]);
    final service = PlatformDeviceLinkService(
      api: PlatformApiClient(baseUri: Uri.parse('https://platform.example.test'), transport: transport),
      deviceIdentity: identity,
      store: store,
      trustedPublicKeys: {keyId: base64Encode(signingPublicDer)},
    );

    await service.requestActivation();
    expect(await service.completePendingActivation(), PlatformDeviceLinkStatus.linked);
    final saved = await service.readLinkedLicense();
    expect(saved!.licenseId, licenseId);
    expect(saved.deviceId, deviceId);
    expect(saved.keyId, keyId);
    expect(saved.planKey, 'trial');
    expect(saved.endsAt, endsAt);
    expect(store.values['homi_platform_pending_device_link_v1'], '');
    expect(transport.requests.map((request) => request.uri.path), isNot(contains('/api/v1/license-signing-keys')));
  });

  test('يرفض ملف ترخيص صحيح التوقيع لكنه لا يتضمن بصمة هذا الجهاز', () async {
    final store = MemorySecretStore();
    final identity = PlatformDeviceIdentity(store, platformOverride: () => 'android');
    const requestId = '123e4567-e89b-42d3-a456-426614174020';
    const licenseId = '123e4567-e89b-42d3-a456-426614174021';
    const deviceId = '123e4567-e89b-42d3-a456-426614174022';
    const keyId = 'homi-license-other-device';
    final challenge = _b64url(List<int>.generate(32, (i) => i + 2));
    final keyPair = await Ed25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final publicDer = <int>[...spkiPrefix, ...publicKey.bytes];
    final issuedAt = DateTime.now().toUtc();
    final payload = utf8.encode(jsonEncode({
      'schema_version': 1,
      'license_id': licenseId,
      'organization_id': '123e4567-e89b-42d3-a456-426614174023',
      'user_id': '123e4567-e89b-42d3-a456-426614174024',
      'product_id': '123e4567-e89b-42d3-a456-426614174025',
      'plan_key': 'trial',
      'starts_at': issuedAt.toIso8601String(),
      'ends_at': issuedAt.add(const Duration(days: 14)).toIso8601String(),
      'offline_expires_at': issuedAt.add(const Duration(days: 7)).toIso8601String(),
      'device_fingerprints': [List.filled(64, 'f').join()],
      'entitlement_version': 1,
      'issued_at': issuedAt.toIso8601String(),
      'key_id': keyId,
    }));
    final signature = await Ed25519().sign(payload, keyPair: keyPair);
    final transport = QueueTransport([
      success(_activationCreated(identity, requestId, challenge), statusCode: 201),
      success({'activation_request_id': requestId, 'proof_verified': true, 'status': 'proof_verified'}),
      success({
        'status': 'approved',
        'license': {
          'id': licenseId,
          'device_id': deviceId,
          'status': 'active',
          'key_id': keyId,
          'payload': base64Encode(payload),
          'signature': base64Encode(signature.bytes),
        }
      }),
    ]);
    final service = PlatformDeviceLinkService(
      api: PlatformApiClient(baseUri: Uri.parse('https://platform.example.test'), transport: transport),
      deviceIdentity: identity,
      store: store,
      trustedPublicKeys: {keyId: base64Encode(publicDer)},
    );

    await service.requestActivation();
    await expectLater(
      service.completePendingActivation(),
      throwsA(isA<FormatException>()),
    );
    expect(store.values['homi_platform_signed_license_v1'], isNull);
  });
}


  test('يجدد تصريح العمل دون اتصال عبر إثبات مفتاح الجهاز دون حساب عميل', () async {
    final store = MemorySecretStore();
    final identity = PlatformDeviceIdentity(store, platformOverride: () => 'android');
    const requestId = '123e4567-e89b-42d3-a456-426614174030';
    const licenseId = '123e4567-e89b-42d3-a456-426614174031';
    const deviceId = '123e4567-e89b-42d3-a456-426614174032';
    const keyId = 'homi-license-offline-key';
    const grantId = '123e4567-e89b-42d3-a456-426614174033';
    const challengeId = '123e4567-e89b-42d3-a456-426614174034';
    final activationChallenge = _b64url(List<int>.generate(32, (i) => i + 3));
    final offlineNonce = _b64url(List<int>.generate(32, (i) => 63 - i));
    final keyPair = await Ed25519().newKeyPair();
    final signingPublicKey = await keyPair.extractPublicKey();
    final signingPublicDer = <int>[...spkiPrefix, ...signingPublicKey.bytes];
    final issuedAt = DateTime.now().toUtc();
    final startsAt = issuedAt.subtract(const Duration(minutes: 1));
    final trialEndsAt = issuedAt.add(const Duration(days: 14));
    final offlineExpiresAt = issuedAt.add(const Duration(days: 7));
    final licensePayload = utf8.encode(jsonEncode({
      'schema_version': 1,
      'license_id': licenseId,
      'organization_id': '123e4567-e89b-42d3-a456-426614174035',
      'user_id': '123e4567-e89b-42d3-a456-426614174036',
      'product_id': '123e4567-e89b-42d3-a456-426614174037',
      'origin_trial_id': '123e4567-e89b-42d3-a456-426614174038',
      'subscription_id': null,
      'trial_id': '123e4567-e89b-42d3-a456-426614174038',
      'plan_key': 'trial',
      'starts_at': startsAt.toIso8601String(),
      'ends_at': trialEndsAt.toIso8601String(),
      'trial_ends_at': trialEndsAt.toIso8601String(),
      'subscription_ends_at': null,
      'offline_expires_at': offlineExpiresAt.toIso8601String(),
      'grace_ends_at': null,
      'access_policy': 'full_until_offline_expiry_or_trial_end_then_read_export',
      'max_devices': 2,
      'device_fingerprints': [_fingerprint(identity)],
      'entitlement_version': 1,
      'issued_at': issuedAt.toIso8601String(),
      'key_id': keyId,
    }));
    final licenseSignature = await Ed25519().sign(licensePayload, keyPair: keyPair);
    final grantPayload = utf8.encode(jsonEncode({
      'schema_version': 1,
      'grant_id': grantId,
      'license_id': licenseId,
      'organization_id': '123e4567-e89b-42d3-a456-426614174035',
      'user_id': '123e4567-e89b-42d3-a456-426614174036',
      'product_id': '123e4567-e89b-42d3-a456-426614174037',
      'device_id': deviceId,
      'plan_key': 'trial',
      'starts_at': startsAt.toIso8601String(),
      'ends_at': trialEndsAt.toIso8601String(),
      'trial_ends_at': trialEndsAt.toIso8601String(),
      'subscription_ends_at': null,
      'offline_expires_at': offlineExpiresAt.toIso8601String(),
      'grace_ends_at': null,
      'grace_period_days': 0,
      'access_policy': 'full_until_offline_expiry_or_trial_end_then_read_export',
      'max_devices': 2,
      'device_fingerprints': [_fingerprint(identity)],
      'key_id': keyId,
      'entitlement_version': 1,
      'issued_at': issuedAt.toIso8601String(),
      'expires_at': offlineExpiresAt.toIso8601String(),
    }));
    final grantSignature = await Ed25519().sign(grantPayload, keyPair: keyPair);
    final transport = QueueTransport([
      success(_activationCreated(identity, requestId, activationChallenge), statusCode: 201),
      success({'activation_request_id': requestId, 'proof_verified': true, 'status': 'proof_verified'}),
      success({
        'status': 'approved',
        'license': {
          'id': licenseId, 'device_id': deviceId, 'status': 'active',
          'key_id': keyId, 'payload': base64Encode(licensePayload),
          'signature': base64Encode(licenseSignature.bytes),
        }
      }),
      success({
        'challenge_id': challengeId,
        'nonce': offlineNonce,
        'expires_at': DateTime.now().toUtc().add(const Duration(minutes: 5)).toIso8601String(),
      }, statusCode: 201),
      success({
        'id': grantId,
        'key_id': keyId,
        'payload': base64Encode(grantPayload),
        'signature': base64Encode(grantSignature.bytes),
      }, statusCode: 201),
    ]);
    final service = PlatformDeviceLinkService(
      api: PlatformApiClient(baseUri: Uri.parse('https://platform.example.test'), transport: transport),
      deviceIdentity: identity,
      store: store,
      trustedPublicKeys: {keyId: base64Encode(signingPublicDer)},
    );

    await service.requestActivation();
    expect(await service.completePendingActivation(), PlatformDeviceLinkStatus.linked);
    final grant = await service.refreshOfflineGrant();
    expect(grant, isNotNull);
    expect(grant!.licenseId, licenseId);
    expect(grant.deviceId, deviceId);
    expect(transport.requests[3].uri.path, '/api/v1/public/devices/$deviceId/challenges');
    expect(transport.requests[4].uri.path, '/api/v1/public/licenses/$licenseId/devices/$deviceId/offline-grants');
    expect(transport.requests[3].headers.containsKey('authorization'), isFalse);
    expect(transport.requests[4].headers.containsKey('authorization'), isFalse);
    expect(await service.readOfflineGrant(), isNotNull);
  });
