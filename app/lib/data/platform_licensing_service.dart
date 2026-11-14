// ربط أجهزة Homi بالترخيص وإصدار تصريح offline بعد التحقق من توقيع الخادم.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'platform_api_client.dart';
import 'platform_device_identity.dart';
import 'platform_signing_trust.dart';

class VerifiedOfflineGrant {
  const VerifiedOfflineGrant({
    required this.id,
    required this.licenseId,
    required this.deviceId,
    required this.keyId,
    required this.payload,
    required this.signature,
    required this.issuedAt,
    required this.expiresAt,
    required this.entitlementVersion,
  });

  final String id;
  final String licenseId;
  final String deviceId;
  final String keyId;
  final List<int> payload;
  final List<int> signature;
  final DateTime issuedAt;
  final DateTime? expiresAt;
  final int entitlementVersion;
}

class PlatformLicensingService {
  PlatformLicensingService({
    required PlatformApiClient api,
    required PlatformDeviceIdentity deviceIdentity,
    required PlatformSigningTrust signingTrust,
  })  : _api = api,
        _deviceIdentity = deviceIdentity,
        _signingTrust = signingTrust;

  final PlatformApiClient _api;
  final PlatformDeviceIdentity _deviceIdentity;
  final PlatformSigningTrust _signingTrust;
  final Ed25519 _ed25519 = Ed25519();

  /// يسجل الجهاز بمفتاحه العام؛ لا يغادر المفتاح الخاص التخزين الآمن.
  Future<Map<String, Object?>> registerDevice({
    required String accessToken,
    required String licenseId,
    required String productKey,
  }) async {
    final identity = await _deviceIdentity.loadOrCreate();
    final challenge = await _api.postJson(
      '/api/v1/devices/challenges',
      accessToken: accessToken,
      body: {
        'license_id': licenseId,
        'product_key': productKey,
        'device_key': identity.deviceKey,
        'platform': identity.platform,
        'architecture': identity.architecture,
        'public_key': identity.publicKeyBase64,
      },
    );
    final challengeId = challenge['challenge_id'];
    final nonce = challenge['nonce'];
    if (challengeId is! String || nonce is! String) {
      throw const FormatException('منصة Homi أعادت تحديًا غير مكتمل للجهاز.');
    }

    final signature = await _deviceIdentity.signNonce(nonce);
    return _api.postJson(
      '/api/v1/licenses/$licenseId/devices',
      accessToken: accessToken,
      body: {
        'challenge_id': challengeId,
        'nonce': nonce,
        'signature': signature,
      },
    );
  }

  /// يصدر تصريحًا مرتبطًا بالجهاز ويتحقق محليًا من Ed25519 قبل إعادته للتخزين.
  Future<VerifiedOfflineGrant> issueOfflineGrant({
    required String accessToken,
    required String licenseId,
    required String deviceId,
  }) async {
    final challenge = await _api.postJson(
      '/api/v1/devices/$deviceId/challenges',
      accessToken: accessToken,
      body: {
        'license_id': licenseId,
        'purpose': 'offline_grant',
      },
    );
    final challengeId = challenge['challenge_id'];
    final nonce = challenge['nonce'];
    if (challengeId is! String || nonce is! String) {
      throw const FormatException('منصة Homi أعادت تحديًا غير مكتمل للتصريح.');
    }

    final deviceSignature = await _deviceIdentity.signNonce(nonce);
    final grant = await _api.postJson(
      '/api/v1/licenses/$licenseId/offline-grants',
      accessToken: accessToken,
      body: {
        'challenge_id': challengeId,
        'nonce': nonce,
        'signature': deviceSignature,
      },
    );

    final grantId = grant['id'];
    final keyId = grant['key_id'];
    final payloadText = grant['payload'];
    final signatureText = grant['signature'];
    if (grantId is! String ||
        keyId is! String ||
        payloadText is! String ||
        signatureText is! String) {
      throw const FormatException('بيانات تصريح offline غير مكتملة.');
    }

    final payload = base64Decode(payloadText);
    final signature = base64Decode(signatureText);
    final claims = jsonDecode(utf8.decode(payload));
    if (claims is! Map<String, dynamic> ||
        claims['grant_id'] != grantId ||
        claims['license_id'] != licenseId ||
        claims['device_id'] != deviceId ||
        claims['key_id'] != keyId) {
      throw const FormatException('بيانات التصريح لا تطابق الجهاز أو الترخيص.');
    }

    final keyset = await _signingTrust.fetchAndAccept(_api);
    final trustedKey = keyset.keyForVerification(
      keyId: keyId,
      purpose: 'offline_license_grant',
      at: DateTime.now().toUtc(),
    );
    final isValid = await _ed25519.verify(
      payload,
      signature: Signature(signature, publicKey: trustedKey.publicKey),
    );
    if (!isValid) {
      throw const FormatException('فشل التحقق من توقيع تصريح offline.');
    }

    final issuedAt = DateTime.tryParse(claims['issued_at'] as String? ?? '');
    final expiresAtText = claims['expires_at'];
    final expiresAt = expiresAtText == null
        ? null
        : DateTime.tryParse(expiresAtText as String);
    final entitlementVersion = claims['entitlement_version'];
    if (issuedAt == null ||
        (expiresAtText != null && expiresAt == null) ||
        entitlementVersion is! num ||
        !entitlementVersion.isFinite) {
      throw const FormatException('حقول صلاحية التصريح غير صالحة.');
    }

    return VerifiedOfflineGrant(
      id: grantId,
      licenseId: licenseId,
      deviceId: deviceId,
      keyId: keyId,
      payload: payload,
      signature: signature,
      issuedAt: issuedAt.toUtc(),
      expiresAt: expiresAt?.toUtc(),
      entitlementVersion: entitlementVersion.toInt(),
    );
  }

}
