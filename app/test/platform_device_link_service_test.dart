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
String _fingerprint(PlatformDeviceIdentityData identity) {
  final raw = base64Url.decode(base64Url.normalize(identity.publicKeyRawBase64Url));
  return crypto.sha256.convert(raw).toString();
}

Map<String, Object?> _activationCreated(
  PlatformDeviceIdentityData identity,
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
    final identityData = await identity.loadOrCreate();
    const requestId = '123e4567-e89b-42d3-a456-426614174000';
    final challenge = _b64url(List<int>.generate(32, (i) => i));
    final transport = QueueTransport([
      success(_activationCreated(identityData, requestId, challenge), statusCode: 201),
    ]);
    final service = PlatformDeviceLinkService(
      api: PlatformApiClient(baseUri: Uri.parse('https://platform.example.test'), transport: transport),
      deviceIdentity: identity,
      store: store,
      trustedPublicKeys: {},
    );

    final activation = await service.requestActivation(
      customerName: 'متجر الاختبار',
      customerPhone: '+2490904697455',
      requestedPlan: 'annual',
      customerNotes: 'ملاحظة',
    );
    final request = transport.requests.single;
    expect(request.method, 'POST');
    expect(request.uri.path, '/api/v1/public/activation-requests');
    final body = jsonDecode(request.body!) as Map<String, dynamic>;
    expect(body['product_key'], 'homi-grocery');
    expect(body['device_id'], identityData.deviceKey);
    expect(body['customer_name'], 'متجر الاختبار');
    expect(body['customer_phone'], '+2490904697455');
    expect(body['requested_plan'], 'annual');
    expect(body['customer_notes'], 'ملاحظة');
    expect(body['platform_key'], 'linux');
    expect(body['architecture_key'], isNotEmpty);
    expect(body['public_key'], identityData.publicKeyRawBase64Url);
    expect(base64Url.decode(base64Url.normalize(body['public_key'] as String)), hasLength(32));
    expect(body.containsKey('email'), isFalse);
    expect(body.containsKey('password'), isFalse);
    expect(request.headers.containsKey('authorization'), isFalse);
    expect(activation.requestId, requestId);
    expect(activation.keyFingerprint, _fingerprint(identityData));
    expect(activation.supportWhatsApp, '249900000000');
    expect(store.values['homi_platform_pending_device_link_v1'], contains('request_id'));
  });

  test('ينشئ ملف HREQ موقعًا بمفتاح الجهاز ويحتوي بيانات العميل المطلوبة', () async {
    final store = MemorySecretStore();
    final identity = PlatformDeviceIdentity(store, platformOverride: () => 'linux');
    final identityData = await identity.loadOrCreate();
    final service = PlatformDeviceLinkService(
      api: PlatformApiClient(
        baseUri: Uri.parse('https://platform.example.test'),
        transport: QueueTransport([]),
      ),
      deviceIdentity: identity,
      store: store,
      trustedPublicKeys: {},
    );

    final requestFile = await service.createActivationRequestFile(
      customerName: 'متجر الاختبار',
      customerPhone: '+2490904697455',
      requestedPlan: 'annual',
      customerNotes: 'ملاحظة اختبار',
    );
    final envelope = jsonDecode(utf8.decode(requestFile.bytes)) as Map<String, dynamic>;
    expect(envelope['format'], 'HOMI_ACTIVATION_REQUEST');
    expect(envelope['format_version'], 1);

    final payloadBytes = base64Url.decode(
      base64Url.normalize(envelope['payload'] as String),
    );
    final payload = jsonDecode(utf8.decode(payloadBytes)) as Map<String, dynamic>;
    expect(payload['request_id'], requestFile.requestId);
    expect(payload['product_key'], 'homi-grocery');
    expect(payload['customer']['display_name'], 'متجر الاختبار');
    expect(payload['customer']['phone'], '+2490904697455');
    expect(payload['customer']['requested_plan'], 'annual');
    expect(payload['device']['device_id'], identityData.deviceKey);
    expect(payload['device']['public_key'], identityData.publicKeyRawBase64Url);
    expect(payload['device']['key_fingerprint'], _fingerprint(identityData));
    expect(payload.containsKey('email'), isFalse);
    expect(payload.containsKey('password'), isFalse);

    final digest = crypto.sha256.convert(payloadBytes).toString();
    final signature = base64Url.decode(
      base64Url.normalize(envelope['signature'] as String),
    );
    final publicKey = SimplePublicKey(
      base64Url.decode(base64Url.normalize(identityData.publicKeyRawBase64Url)),
      type: KeyPairType.ed25519,
    );
    expect(
      await Ed25519().verify(
        utf8.encode('HOMI_HREQ_V1\n$digest'),
        signature: Signature(signature, publicKey: publicKey),
      ),
      isTrue,
    );
  });

  test('يوقع التحدي بصيغة البروتوكول ويرجع انتظار مراجعة الإدارة', () async {
    final store = MemorySecretStore();
    final identity = PlatformDeviceIdentity(store, platformOverride: () => 'windows');
    final identityData = await identity.loadOrCreate();
    const requestId = '123e4567-e89b-42d3-a456-426614174001';
    final challenge = _b64url(List<int>.generate(32, (i) => 31 - i));
    final transport = QueueTransport([
      success(_activationCreated(identityData, requestId, challenge), statusCode: 201),
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
      identityData.architecture,
      challenge,
    ].join('\n');
    final signature = base64Url.decode(base64Url.normalize(proofBody['signature'] as String));
    final publicKey = SimplePublicKey(
      base64Url.decode(base64Url.normalize(identityData.publicKeyRawBase64Url)),
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
    final identityData = await identity.loadOrCreate();
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
      'product_key': 'homi-grocery',
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
      'device_fingerprints': [_fingerprint(identityData)],
      'entitlement_version': 1,
      'issued_at': issuedAt.toIso8601String(),
      'key_id': keyId,
    }));
    final signed = await Ed25519().sign(payload, keyPair: keyPair);
    final transport = QueueTransport([
      success(_activationCreated(identityData, requestId, challenge), statusCode: 201),
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

  test('يستورد ملف Homi موقعًا ويربطه بالجهاز دون اتصال بالمنصة', () async {
    final store = MemorySecretStore();
    final identity = PlatformDeviceIdentity(store, platformOverride: () => 'android');
    final identityData = await identity.loadOrCreate();
    const licenseId = '123e4567-e89b-42d3-a456-426614174041';
    const deviceId = '123e4567-e89b-42d3-a456-426614174042';
    const keyId = 'homi-license-file-test';
    final keyPair = await Ed25519().newKeyPair();
    final signingPublicKey = await keyPair.extractPublicKey();
    final publicDer = <int>[...spkiPrefix, ...signingPublicKey.bytes];
    final issuedAt = DateTime.now().toUtc();
    final endsAt = issuedAt.add(const Duration(days: 14));
    final payload = utf8.encode(jsonEncode({
      'schema_version': 1,
      'license_id': licenseId,
      'organization_id': '123e4567-e89b-42d3-a456-426614174043',
      'user_id': '123e4567-e89b-42d3-a456-426614174044',
      'product_id': '123e4567-e89b-42d3-a456-426614174045',
      'product_key': 'homi-grocery',
      'origin_trial_id': '123e4567-e89b-42d3-a456-426614174046',
      'subscription_id': null,
      'trial_id': '123e4567-e89b-42d3-a456-426614174046',
      'plan_key': 'trial',
      'starts_at': issuedAt.toIso8601String(),
      'ends_at': endsAt.toIso8601String(),
      'trial_ends_at': endsAt.toIso8601String(),
      'subscription_ends_at': null,
      'offline_expires_at': issuedAt.add(const Duration(days: 7)).toIso8601String(),
      'grace_ends_at': null,
      'grace_period_days': 0,
      'access_policy': 'full_until_offline_expiry_or_trial_end_then_read_export',
      'max_devices': 2,
      'device_fingerprints': [_fingerprint(identityData)],
      'entitlement_version': 1,
      'issued_at': issuedAt.toIso8601String(),
      'key_id': keyId,
    }));
    final signature = await Ed25519().sign(payload, keyPair: keyPair);
    final service = PlatformDeviceLinkService(
      api: PlatformApiClient(
        baseUri: Uri.parse('https://platform.example.test'),
        transport: QueueTransport([]),
      ),
      deviceIdentity: identity,
      store: store,
      trustedPublicKeys: {keyId: base64Encode(publicDer)},
      apiUnavailableReason: 'لم يتم إعداد عنوان المنصة لهذا الإصدار.',
    );

    final imported = await service.importLicenseFile(utf8.encode(jsonEncode({
      'format': 'HOMI_LICENSE_FILE',
      'format_version': 1,
      'status': 'active',
      'license_id': licenseId,
      'device_id': deviceId,
      'key_id': keyId,
      'payload': base64Encode(payload),
      'signature': base64Encode(signature.bytes),
    })));

    expect(imported.licenseId, licenseId);
    expect(imported.deviceId, deviceId);
    expect(imported.planKey, 'trial');
    final offlineAccess = await service.refreshOfflineGrant();
    expect(offlineAccess, isNotNull);
    expect(offlineAccess!.licenseId, licenseId);
    expect(offlineAccess.planKey, 'trial');
    expect(await service.readLinkedLicense(), isNotNull);
    expect(store.values['homi_platform_signed_license_v1'], contains(licenseId));
  });

  test('يرفض ملف ترخيص صحيح التوقيع لكنه لا يتضمن بصمة هذا الجهاز', () async {
    final store = MemorySecretStore();
    final identity = PlatformDeviceIdentity(store, platformOverride: () => 'android');
    final identityData = await identity.loadOrCreate();
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
      'product_key': 'homi-grocery',
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
      success(_activationCreated(identityData, requestId, challenge), statusCode: 201),
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

  test('يجدد تصريح العمل دون اتصال عبر إثبات مفتاح الجهاز دون حساب عميل', () async {
    final store = MemorySecretStore();
    final identity = PlatformDeviceIdentity(store, platformOverride: () => 'android');
    final identityData = await identity.loadOrCreate();
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
      'product_key': 'homi-grocery',
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
      'device_fingerprints': [_fingerprint(identityData)],
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
      'product_key': 'homi-grocery',
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
      'device_fingerprints': [_fingerprint(identityData)],
      'key_id': keyId,
      'entitlement_version': 1,
      'issued_at': issuedAt.toIso8601String(),
      'expires_at': offlineExpiresAt.toIso8601String(),
    }));
    final grantSignature = await Ed25519().sign(grantPayload, keyPair: keyPair);
    final transport = QueueTransport([
      success(_activationCreated(identityData, requestId, activationChallenge), statusCode: 201),
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
    expect(grant!.isLocalTrial, isFalse);
    expect(grant.licenseId, licenseId);
    expect(grant.deviceId, deviceId);
    expect(transport.requests[3].uri.path, '/api/v1/public/devices/$deviceId/challenges');
    expect(transport.requests[4].uri.path, '/api/v1/public/licenses/$licenseId/devices/$deviceId/offline-grants');
    expect(transport.requests[3].headers.containsKey('authorization'), isFalse);
    expect(transport.requests[4].headers.containsKey('authorization'), isFalse);
    expect(await service.readOfflineGrant(), isNotNull);
  });

  test('يبدأ تجربة محلية لمدة 14 يومًا عند أول استخدام وتعمل دون اتصال', () async {
    final store = MemorySecretStore();
    final identity = PlatformDeviceIdentity(store, platformOverride: () => 'linux');
    var now = DateTime.utc(2026, 11, 21, 10);
    final transport = QueueTransport([]);
    final service = PlatformDeviceLinkService(
      api: PlatformApiClient(
        baseUri: Uri.parse('https://platform.example.test'),
        transport: transport,
      ),
      deviceIdentity: identity,
      store: store,
      trustedPublicKeys: {},
      clock: () => now,
    );

    expect(await service.readLinkedLicense(), isNull);
    final first = await service.startLocalTrial();
    expect(first, isNotNull);
    final trial = first!;
    expect(trial.planKey, 'trial');
    expect(trial.isLocalTrial, isTrue);
    expect(trial.startsAt, now);
    expect(trial.trialEndsAt, now.add(const Duration(days: 14)));
    expect(trial.offlineExpiresAt, now.add(const Duration(days: 14)));
    expect(trial.signedPayload, isEmpty);

    now = now.add(const Duration(days: 5));
    final second = await service.readLinkedLicense();
    expect(second, isNotNull);
    final continuedTrial = second!;
    expect(continuedTrial.licenseId, trial.licenseId);
    expect(continuedTrial.startsAt, trial.startsAt);
    expect(continuedTrial.trialEndsAt, trial.trialEndsAt);
    expect(await service.refreshOfflineGrant(), isNotNull);
    expect(transport.requests, isEmpty);

    now = now.subtract(const Duration(days: 6));
    final rollback = await service.readLinkedLicense();
    expect(rollback, isNotNull);
    final rolledBackTrial = rollback!;
    expect(rolledBackTrial.offlineExpiresAt, now);
    expect(rolledBackTrial.trialEndsAt, trial.trialEndsAt);
  });

}
