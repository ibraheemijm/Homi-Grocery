// ربط البريد المؤكد بهوية الجهاز دون طلب كلمة مرور Homi Platform.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;

import 'platform_api_client.dart';
import 'platform_device_identity.dart';

enum PlatformDeviceLinkStatus {
  waitingForAdmin,
  licensePending,
  linked,
}

class PlatformActivationRequest {
  const PlatformActivationRequest({
    required this.requestId,
    required this.keyFingerprint,
    required this.platform,
    required this.architecture,
    required this.challengeExpiresAt,
    this.proofVerified = false,
    this.supportWhatsApp,
  });

  final String requestId;
  final String keyFingerprint;
  final String platform;
  final String architecture;
  final DateTime challengeExpiresAt;
  final bool proofVerified;
  final String? supportWhatsApp;

  String toSupportMessage({bool proofVerified = false}) => [
    'طلب تفعيل Homi Grocery',
    'رقم الطلب: $requestId',
    'المنصة: $platform',
    'المعمارية: $architecture',
    'بصمة الجهاز: $keyFingerprint',
    'إثبات الملكية: ${proofVerified ? "مكتمل" : "بانتظار الإكمال"}',
  ].join('\n');
}

class PlatformLinkedLicense {
  const PlatformLinkedLicense({
    required this.licenseId,
    required this.deviceId,
    required this.keyId,
    required this.startsAt,
    required this.endsAt,
    required this.trialEndsAt,
    required this.subscriptionEndsAt,
    required this.offlineExpiresAt,
    required this.graceEndsAt,
    required this.accessPolicy,
    required this.planKey,
    required this.entitlementVersion,
    required this.signedPayload,
    required this.signature,
    required this.publicKeyDer,
  });

  final String licenseId;
  final String deviceId;
  final String keyId;
  final DateTime startsAt;
  final DateTime? endsAt;
  final DateTime? trialEndsAt;
  final DateTime? subscriptionEndsAt;
  final DateTime? offlineExpiresAt;
  final DateTime? graceEndsAt;
  final String accessPolicy;
  final String planKey;
  final int entitlementVersion;
  final List<int> signedPayload;
  final List<int> signature;
  final List<int> publicKeyDer;
}

abstract interface class PlatformDeviceLinkOperations {
  Future<PlatformActivationRequest> requestActivation();
  Future<PlatformActivationRequest?> readPendingActivationRequest();
  Future<PlatformDeviceLinkStatus> completePendingActivation();
  Future<PlatformLinkedLicense?> readLinkedLicense();
  Future<PlatformLinkedLicense?> refreshOfflineGrant();
  Future<PlatformLinkedLicense?> readOfflineGrant();
}

class UnavailablePlatformDeviceLinkService
    implements PlatformDeviceLinkOperations {
  const UnavailablePlatformDeviceLinkService(this.reason);

  final String reason;

  @override
  Future<PlatformActivationRequest> requestActivation() async {
    throw PlatformApiConfigurationException(reason);
  }

  @override
  Future<PlatformActivationRequest?> readPendingActivationRequest() async => null;

  @override
  Future<PlatformDeviceLinkStatus> completePendingActivation() async {
    throw PlatformApiConfigurationException(reason);
  }

  @override
  Future<PlatformLinkedLicense?> readLinkedLicense() async => null;

  @override
  Future<PlatformLinkedLicense?> refreshOfflineGrant() async {
    throw PlatformApiConfigurationException(reason);
  }

  @override
  Future<PlatformLinkedLicense?> readOfflineGrant() async => null;
}

class PlatformDeviceLinkService implements PlatformDeviceLinkOperations {
  PlatformDeviceLinkService({
    required PlatformApiClient api,
    required PlatformDeviceIdentity deviceIdentity,
    required PlatformSecretStore store,
    Map<String, String>? trustedPublicKeys,
    DateTime Function()? clock,
  })  : _api = api,
        _deviceIdentity = deviceIdentity,
        _store = store,
        _trustedPublicKeys = _loadTrustedPublicKeys(trustedPublicKeys),
        _clock = clock ?? DateTime.now;

  final PlatformApiClient _api;
  final PlatformDeviceIdentity _deviceIdentity;
  final PlatformSecretStore _store;
  final Map<String, List<int>> _trustedPublicKeys;
  final DateTime Function() _clock;
  final Ed25519 _ed25519 = Ed25519();

  static const _pendingKey = 'homi_platform_pending_device_link_v1';
  static const _licenseKey = 'homi_platform_signed_license_v1';
  static const _offlineGrantKey = 'homi_platform_signed_offline_grant_v1';
  static const _trustedKeysEnvironmentBase64 =
      String.fromEnvironment('HOMI_LICENSE_TRUSTED_PUBLIC_KEYS_B64');
  static const _spkiPrefix = <int>[
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65,
    0x70, 0x03, 0x21, 0x00,
  ];

  static Map<String, List<int>> _loadTrustedPublicKeys(
    Map<String, String>? supplied,
  ) {
    Map<String, String> source;
    if (supplied != null) {
      source = supplied;
    } else {
      if (_trustedKeysEnvironmentBase64.trim().isEmpty) {
        return const {};
      }
      final encoded = base64Decode(_trustedKeysEnvironmentBase64);
      if (base64Encode(encoded) != _trustedKeysEnvironmentBase64) {
        throw const FormatException('ترميز إعداد مفاتيح الثقة غير صالح.');
      }
      final decoded = jsonDecode(utf8.decode(encoded));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'إعداد مفاتيح الثقة المضمّنة في التطبيق غير صالح.',
        );
      }
      source = decoded.map((key, value) {
        if (value is! String) {
          throw const FormatException('قيمة مفتاح الثقة غير صالحة.');
        }
        return MapEntry(key, value);
      });
    }

    final result = <String, List<int>>{};
    for (final entry in source.entries) {
      if (!RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(entry.key)) {
        throw const FormatException('معرّف مفتاح الثقة غير صالح.');
      }
      final bytes = base64Decode(entry.value);
      if (base64Encode(bytes) != entry.value ||
          bytes.length != 44 ||
          !_sameStaticBytes(bytes.sublist(0, 12), _spkiPrefix)) {
        throw const FormatException('صيغة مفتاح الثقة Ed25519 غير صالحة.');
      }
      result[entry.key] = List<int>.unmodifiable(bytes);
    }
    return Map<String, List<int>>.unmodifiable(result);
  }

  static bool _sameStaticBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }


  @override
  Future<PlatformActivationRequest> requestActivation() async {
    final identity = await _deviceIdentity.loadOrCreate();
    final response = await _api.postJson(
      '/api/v1/public/activation-requests',
      body: {
        'product_key': 'homi-grocery',
        'platform_key': identity.platform,
        'architecture_key': identity.architecture,
        'device_label': 'Homi Grocery - ${identity.platform}',
        'public_key': identity.publicKeyRawBase64Url,
      },
    );
    final requestId = response['activation_request_id'];
    final challenge = response['challenge'];
    final expiresAtText = response['challenge_expires_at'];
    final fingerprint = response['key_fingerprint'];
    final supportWhatsAppValue = response['support_whatsapp'];
    final supportWhatsApp = supportWhatsAppValue is String &&
            RegExp(r'^\\d{8,15}
    final expiresAt = expiresAtText is String ? DateTime.tryParse(expiresAtText) : null;
    if (requestId is! String ||
        !_isUuid(requestId) ||
        challenge is! String ||
        !_isValidNonce(challenge) ||
        fingerprint is! String ||
        !RegExp(r'^[0-9a-f]{64}
        expiresAt == null ||
        !expiresAt.isAfter(_clock().toUtc())) {
      throw const FormatException('استجابة طلب تفعيل الجهاز من المنصة غير صالحة.');
    }

    await _store.write(_pendingKey, jsonEncode({
      'request_id': requestId,
      'challenge': challenge,
      'challenge_expires_at': expiresAt.toUtc().toIso8601String(),
      'device_key': identity.deviceKey,
      'platform': identity.platform,
      'architecture': identity.architecture,
      'key_fingerprint': fingerprint,
      'support_whatsapp': supportWhatsApp ?? '',
      'proof_completed': false,
    }));
    return PlatformActivationRequest(
      requestId: requestId,
      keyFingerprint: fingerprint,
      platform: identity.platform,
      architecture: identity.architecture,
      challengeExpiresAt: expiresAt.toUtc(),
      supportWhatsApp: supportWhatsApp,
    );
  }

  @override
  Future<PlatformActivationRequest?> readPendingActivationRequest() async {
    final pending = await _readPending();
    if (pending == null) return null;
    return PlatformActivationRequest(
      requestId: pending['request_id']!,
      keyFingerprint: pending['key_fingerprint']!,
      platform: pending['platform']!,
      architecture: pending['architecture']!,
      challengeExpiresAt: DateTime.parse(pending['challenge_expires_at']!).toUtc(),
      proofVerified: pending['proof_completed'] == 'true',
      supportWhatsApp: pending['support_whatsapp']?.isNotEmpty == true
          ? pending['support_whatsapp']
          : null,
    );
  }

  @override
  Future<PlatformDeviceLinkStatus> completePendingActivation() async {
    final pending = await _readPending();
    if (pending == null) {
      throw const PlatformApiException(
        statusCode: 400,
        code: 'ACTIVATION_REQUEST_NOT_CREATED',
        message: 'أنشئ طلب التفعيل أولًا.',
      );
    }
    final identity = await _deviceIdentity.loadOrCreate();
    if (identity.deviceKey != pending['device_key'] ||
        identity.platform != pending['platform'] ||
        identity.architecture != pending['architecture']) {
      await clearPendingLink();
      throw StateError('هوية الجهاز تغيرت؛ أوقف التفعيل وأنشئ طلبًا جديدًا.');
    }

    if (pending['proof_completed'] != 'true') {
      final challengeExpiresAt = DateTime.parse(pending['challenge_expires_at']!).toUtc();
      if (!challengeExpiresAt.isAfter(_clock().toUtc())) {
        await clearPendingLink();
        throw const PlatformApiException(
          statusCode: 410,
          code: 'ACTIVATION_CHALLENGE_EXPIRED',
          message: 'انتهت صلاحية إثبات الجهاز. أنشئ طلب تفعيل جديدًا.',
        );
      }
      final requestId = pending['request_id']!;
      final challenge = pending['challenge']!;
      final proofMessage = [
        'HOMI_DEVICE_PROOF_V1',
        requestId.toLowerCase(),
        'homi-grocery',
        identity.platform,
        identity.architecture,
        challenge,
      ].join('\n');
      final signature = await _deviceIdentity.signMessage(proofMessage);
      await _api.postJson(
        '/api/v1/public/activation-requests/$requestId/proof',
        body: {'challenge': challenge, 'signature': signature},
      );
      pending['proof_completed'] = 'true';
      await _store.write(_pendingKey, jsonEncode(pending));
    }

    final requestId = pending['request_id']!;
    final status = await _api.getJson(
      '/api/v1/public/activation-requests/$requestId/status',
    );
    final requestStatus = status['status'];
    if (requestStatus == 'proof_verified') {
      return PlatformDeviceLinkStatus.waitingForAdmin;
    }
    if (requestStatus == 'rejected' || requestStatus == 'cancelled' ||
        requestStatus == 'expired') {
      await clearPendingLink();
      throw PlatformApiException(
        statusCode: 409,
        code: 'ACTIVATION_REQUEST_${requestStatus.toString().toUpperCase()}',
        message: 'طلب التفعيل ${requestStatus == 'rejected' ? 'مرفوض' : 'غير صالح'}؛ راجع إدارة Homi.',
      );
    }
    if (status['license_status'] == 'revoked' ||
        status['license_status'] == 'suspended') {
      throw const PlatformApiException(
        statusCode: 403,
        code: 'LICENSE_NOT_ACTIVE',
        message: 'الترخيص موقوف أو ملغى. تواصل مع إدارة Homi.',
      );
    }
    if (requestStatus != 'approved' || status['license'] is! Map) {
      return PlatformDeviceLinkStatus.licensePending;
    }
    final license = Map<String, Object?>.from(status['license'] as Map);
    if (license['status'] != 'active') {
      return PlatformDeviceLinkStatus.licensePending;
    }
    final verified = await _verifyIssuedLicense(license);
    await _store.write(_licenseKey, jsonEncode({
      'license_id': verified.licenseId,
      'device_id': verified.deviceId,
      'key_id': verified.keyId,
      'starts_at': verified.startsAt.toUtc().toIso8601String(),
      'ends_at': verified.endsAt?.toUtc().toIso8601String(),
      'plan_key': verified.planKey,
      'entitlement_version': verified.entitlementVersion,
      'payload': base64Encode(verified.signedPayload),
      'signature': base64Encode(verified.signature),
    }));
    await clearPendingLink();
    return PlatformDeviceLinkStatus.linked;
  }

  @override
  Future<PlatformLinkedLicense?> readLinkedLicense() async {
    final stored = await _store.read(_licenseKey);
    if (stored == null || stored.isEmpty) return null;
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException();
      }
      final license = Map<String, Object?>.from(decoded);
      final payload = base64Decode(license['payload'] as String);
      final signature = base64Decode(license['signature'] as String);
      final deviceId = license['device_id'];
      if (deviceId is! String || !_isUuid(deviceId)) {
        throw const FormatException('هوية الجهاز المرتبطة بالترخيص غير صالحة.');
      }
      return _verifyLicenseMaterial(
        licenseId: license['license_id'] as String,
        deviceId: deviceId,
        keyId: license['key_id'] as String,
        payload: payload,
        signature: signature,
      );
    } on Object {
      // لا نعيد إنشاء هوية أو ترخيص عند تلف السجل؛ نوقف التشغيل الآمن.
      rethrow;
    }
  }

  @override
  Future<PlatformLinkedLicense?> refreshOfflineGrant() async {
    final license = await readLinkedLicense();
    if (license == null) return null;

    try {
      final challenge = await _api.postJson(
        '/api/v1/devices/${license.deviceId}/challenges',
        body: {
          'license_id': license.licenseId,
          'purpose': 'offline_grant',
        },
      );
      final challengeId = challenge['challenge_id'];
      final nonce = challenge['nonce'];
      final expiresAt = DateTime.tryParse(challenge['expires_at'] as String? ?? '');
      if (challengeId is! String ||
          !_isUuid(challengeId) ||
          nonce is! String ||
          !_isValidNonce(nonce) ||
          expiresAt == null ||
          !expiresAt.isAfter(_clock().toUtc())) {
        throw const FormatException('تحدي تجديد تصريح العمل دون اتصال غير صالح.');
      }

      final deviceSignature = await _deviceIdentity.signNonce(nonce);
      final response = await _api.postJson(
        '/api/v1/licenses/${license.licenseId}/offline-grants',
        body: {
          'challenge_id': challengeId,
          'nonce': nonce,
          'signature': deviceSignature,
        },
      );
      final keyId = response['key_id'];
      final payloadText = response['payload'];
      final signatureText = response['signature'];
      if (keyId is! String ||
          payloadText is! String ||
          signatureText is! String) {
        throw const FormatException('استجابة تصريح العمل دون اتصال غير مكتملة.');
      }
      final verified = await _verifyLicenseMaterial(
        licenseId: license.licenseId,
        deviceId: license.deviceId,
        keyId: keyId,
        payload: _decodeCanonicalBase64(payloadText),
        signature: _decodeCanonicalBase64(signatureText),
      );
      await _store.write(_offlineGrantKey, jsonEncode({
        'license_id': verified.licenseId,
        'device_id': verified.deviceId,
        'key_id': verified.keyId,
        'payload': base64Encode(verified.signedPayload),
        'signature': base64Encode(verified.signature),
      }));
      return verified;
    } on PlatformApiException catch (error) {
      if (error.code == 'DEVICE_NOT_LINKED' ||
          error.code == 'DEVICE_PROOF_INVALID' ||
          error.code == 'LICENSE_REVOKED' ||
          error.code == 'LICENSE_SUSPENDED' ||
          error.code == 'ACCOUNT_INACTIVE') {
        await _store.write(_offlineGrantKey, '');
        return null;
      }
      return readOfflineGrant();
    } on Object {
      // عند انقطاع الشبكة نستخدم آخر تصريح موقّع محفوظ، ولا نمدد صلاحيته محليًا.
      return readOfflineGrant();
    }
  }

  @override
  Future<PlatformLinkedLicense?> readOfflineGrant() async {
    final stored = await _store.read(_offlineGrantKey);
    if (stored == null || stored.isEmpty) return null;
    final linkedLicense = await readLinkedLicense();
    if (linkedLicense == null) return null;
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('سجل تصريح العمل دون اتصال تالف.');
    }
    final grant = Map<String, Object?>.from(decoded);
    if (grant['license_id'] != linkedLicense.licenseId ||
        grant['device_id'] != linkedLicense.deviceId) {
      throw const FormatException('تصريح العمل دون اتصال لا يطابق الجهاز والترخيص المرتبطين.');
    }
    final keyId = grant['key_id'];
    final payloadText = grant['payload'];
    final signatureText = grant['signature'];
    if (keyId is! String || payloadText is! String || signatureText is! String) {
      throw const FormatException('بيانات تصريح العمل دون اتصال غير مكتملة.');
    }
    return _verifyLicenseMaterial(
      licenseId: linkedLicense.licenseId,
      deviceId: linkedLicense.deviceId,
      keyId: keyId,
      payload: _decodeCanonicalBase64(payloadText),
      signature: _decodeCanonicalBase64(signatureText),
    );
  }

  Future<void> clearPendingLink() => _store.write(_pendingKey, '');

  Future<Map<String, String>?> _readPending() async {
    final stored = await _store.read(_pendingKey);
    if (stored == null || stored.isEmpty) return null;
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('سجل طلب تفعيل الجهاز تالف.');
    }
    final requestId = decoded['request_id'];
    final challenge = decoded['challenge'];
    final expiresAt = decoded['challenge_expires_at'];
    final deviceKey = decoded['device_key'];
    final platform = decoded['platform'];
    final architecture = decoded['architecture'];
    final fingerprint = decoded['key_fingerprint'];
    final proofCompleted = decoded['proof_completed'];
    final supportWhatsApp = decoded['support_whatsapp'];
    if (requestId is! String ||
        challenge is! String ||
        expiresAt is! String ||
        deviceKey is! String ||
        platform is! String ||
        architecture is! String ||
        fingerprint is! String ||
        proofCompleted is! bool ||
        (supportWhatsApp != null && supportWhatsApp is! String) ||
        !_isUuid(requestId) ||
        !_isUuid(deviceKey) ||
        !_isValidNonce(challenge) ||
        !RegExp(r'^[a-z0-9][a-z0-9._-]{1,31}$').hasMatch(platform) ||
        !RegExp(r'^[a-z0-9][a-z0-9._-]{1,31}$').hasMatch(architecture) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint) ||
        DateTime.tryParse(expiresAt) == null) {
      throw StateError('حقول طلب تفعيل الجهاز المحفوظ غير صالحة.');
    }
    return {
      'request_id': requestId,
      'challenge': challenge,
      'challenge_expires_at': expiresAt,
      'device_key': deviceKey,
      'platform': platform,
      'architecture': architecture,
      'key_fingerprint': fingerprint,
      'support_whatsapp': supportWhatsApp is String ? supportWhatsApp : '',
      'proof_completed': proofCompleted.toString(),
    };
  }

  Future<PlatformLinkedLicense> _verifyIssuedLicense(
    Map<String, Object?> license,
  ) async {
    final licenseId = license['id'];
    final keyId = license['key_id'];
    final payloadText = license['payload'];
    final signatureText = license['signature'];
    if (licenseId is! String ||
        keyId is! String ||
        payloadText is! String ||
        signatureText is! String) {
      throw const FormatException('بيانات الترخيص الموقّع غير مكتملة.');
    }

    if (!_trustedPublicKeys.containsKey(keyId)) {
      throw const FormatException(
        'مفتاح توقيع الترخيص غير موجود ضمن مفاتيح الثقة المعتمدة في هذا الإصدار.',
      );
    }

    final payload = _decodeCanonicalBase64(payloadText);
    final signature = _decodeCanonicalBase64(signatureText);
    final deviceId = license['device_id'];
    if (deviceId is! String || !_isUuid(deviceId)) {
      throw const FormatException('استجابة ربط الجهاز لا تحتوي على معرّف جهاز صالح.');
    }
    return _verifyLicenseMaterial(
      licenseId: licenseId,
      deviceId: deviceId,
      keyId: keyId,
      payload: payload,
      signature: signature,
    );
  }

  Future<PlatformLinkedLicense> _verifyLicenseMaterial({
    required String licenseId,
    required String deviceId,
    required String keyId,
    required List<int> payload,
    required List<int> signature,
  }) async {
    final publicDer = _trustedPublicKeys[keyId];
    if (signature.length != 64 || publicDer == null ||
        publicDer.length != 44 ||
        !_sameBytes(publicDer.sublist(0, 12), _spkiPrefix)) {
      throw const FormatException(
        'مفتاح توقيع الترخيص غير موثوق أو صيغة التوقيع غير صالحة.',
      );
    }
    final publicKey = SimplePublicKey(
      publicDer.sublist(12),
      type: KeyPairType.ed25519,
    );
    final valid = await _ed25519.verify(
      payload,
      signature: Signature(signature, publicKey: publicKey),
    );
    if (!valid) {
      throw const FormatException('فشل التحقق من توقيع ترخيص Homi.');
    }

    final claims = jsonDecode(utf8.decode(payload));
    if (claims is! Map<String, dynamic> ||
        claims['schema_version'] != 1 ||
        claims['license_id'] != licenseId ||
        (claims['device_id'] != null && claims['device_id'] != deviceId) ||
        claims['key_id'] != keyId ||
        claims['product_id'] is! String ||
        claims['organization_id'] is! String ||
        claims['user_id'] is! String ||
        claims['plan_key'] is! String ||
        claims['entitlement_version'] is! num) {
      throw const FormatException('مطالبات الترخيص الموقّع غير صالحة.');
    }
    if (claims['grant_id'] is String) {
      if (claims['device_id'] != deviceId) {
        throw const FormatException('تصريح العمل دون اتصال لا يخص هذا الجهاز.');
      }
    } else if (claims['license_id'] is String) {
      final localIdentity = await _deviceIdentity.loadOrCreate();
      final localFingerprint = crypto.sha256
          .convert(localIdentity.publicKeyDer.sublist(12))
          .toString();
      final deviceFingerprints = claims['device_fingerprints'];
      if (deviceFingerprints is! List ||
          deviceFingerprints.any((value) => value is! String) ||
          !deviceFingerprints.contains(localFingerprint)) {
        throw const FormatException(
          'ملف الترخيص لا يتضمن بصمة مفتاح هذا الجهاز؛ لا يمكن نقله إلى جهاز آخر.',
        );
      }
    }
    DateTime? parseOptionalDate(String key) {
      final value = claims[key];
      if (value == null) return null;
      if (value is! String) {
        throw FormatException('قيمة التاريخ $key غير صالحة.');
      }
      final parsed = DateTime.tryParse(value);
      if (parsed == null) {
        throw FormatException('قيمة التاريخ $key غير صالحة.');
      }
      return parsed.toUtc();
    }

    final startsAt = DateTime.tryParse(claims['starts_at'] as String? ?? '');
    final issuedAt = DateTime.tryParse(claims['issued_at'] as String? ?? '');
    final endsAt = parseOptionalDate('ends_at');
    final trialEndsAt = parseOptionalDate('trial_ends_at');
    final subscriptionEndsAt = parseOptionalDate('subscription_ends_at');
    final offlineExpiresAt = parseOptionalDate('offline_expires_at');
    final graceEndsAt = parseOptionalDate('grace_ends_at');
    final planKey = claims['plan_key'] as String;
    final accessPolicy = claims['access_policy'];
    if (startsAt == null ||
        issuedAt == null ||
        startsAt.isAfter(issuedAt.add(const Duration(minutes: 5))) ||
        (endsAt != null && !endsAt.isAfter(startsAt))) {
      throw const FormatException('تواريخ صلاحية الترخيص غير صالحة.');
    }

    final issuedUtc = issuedAt.toUtc();
    if (planKey == 'trial') {
      if (trialEndsAt == null ||
          subscriptionEndsAt != null ||
          graceEndsAt != null ||
          offlineExpiresAt == null ||
          endsAt != trialEndsAt ||
          accessPolicy !=
              'full_until_offline_expiry_or_trial_end_then_read_export' ||
          !offlineExpiresAt.isAfter(issuedUtc) ||
          offlineExpiresAt.isAfter(
            issuedUtc.add(const Duration(days: 7)),
          ) ||
          offlineExpiresAt.isAfter(trialEndsAt)) {
        throw const FormatException('سياسة العمل دون اتصال للتجربة غير صالحة.');
      }
    } else if (planKey == 'monthly' || planKey == 'annual') {
      final expectedGraceEnd = endsAt?.add(const Duration(days: 7));
      if (trialEndsAt != null ||
          subscriptionEndsAt == null ||
          subscriptionEndsAt != endsAt ||
          offlineExpiresAt == null ||
          graceEndsAt == null ||
          graceEndsAt != expectedGraceEnd ||
          offlineExpiresAt != graceEndsAt ||
          accessPolicy !=
              'full_until_subscription_end_then_read_export_until_grace_end') {
        throw const FormatException('سياسة مهلة الاشتراك المدفوع غير صالحة.');
      }
    } else if (planKey == 'lifetime') {
      if (endsAt != null ||
          trialEndsAt != null ||
          subscriptionEndsAt != null ||
          offlineExpiresAt != null ||
          graceEndsAt != null ||
          accessPolicy != 'full_forever') {
        throw const FormatException('سياسة الترخيص الدائم غير صالحة.');
      }
    } else {
      throw const FormatException('نوع خطة الترخيص غير مدعوم.');
    }

    return PlatformLinkedLicense(
      licenseId: licenseId,
      deviceId: deviceId,
      keyId: keyId,
      startsAt: startsAt.toUtc(),
      endsAt: endsAt,
      trialEndsAt: trialEndsAt,
      subscriptionEndsAt: subscriptionEndsAt,
      offlineExpiresAt: offlineExpiresAt,
      graceEndsAt: graceEndsAt,
      accessPolicy: accessPolicy as String,
      planKey: planKey,
      entitlementVersion: (claims['entitlement_version'] as num).toInt(),
      signedPayload: payload,
      signature: signature,
      publicKeyDer: List<int>.unmodifiable(publicDer),
    );
  }

  List<int> _decodeCanonicalBase64(String value) {
    final decoded = base64Decode(value);
    if (base64Encode(decoded) != value) {
      throw const FormatException('ترميز Base64 غير قياسي.');
    }
    return decoded;
  }

  bool _isValidNonce(String value) {
    try {
      final decoded = base64Url.decode(base64Url.normalize(value));
      return decoded.length == 32 &&
          base64UrlEncode(decoded).replaceAll('=', '') == value;
    } on FormatException {
      return false;
    }
  }

  bool _isUuid(String value) =>
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$', caseSensitive: false)
          .hasMatch(value);

  bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}
).hasMatch(supportWhatsAppValue)
        ? supportWhatsAppValue
        : null;
    final expiresAt = expiresAtText is String ? DateTime.tryParse(expiresAtText) : null;
    if (requestId is! String ||
        !_isUuid(requestId) ||
        challenge is! String ||
        !_isValidNonce(challenge) ||
        fingerprint is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint) ||
        expiresAt == null ||
        !expiresAt.isAfter(_clock().toUtc())) {
      throw const FormatException('استجابة طلب تفعيل الجهاز من المنصة غير صالحة.');
    }

    await _store.write(_pendingKey, jsonEncode({
      'request_id': requestId,
      'challenge': challenge,
      'challenge_expires_at': expiresAt.toUtc().toIso8601String(),
      'device_key': identity.deviceKey,
      'platform': identity.platform,
      'architecture': identity.architecture,
      'key_fingerprint': fingerprint,
      'proof_completed': false,
    }));
    return PlatformActivationRequest(
      requestId: requestId,
      keyFingerprint: fingerprint,
      platform: identity.platform,
      architecture: identity.architecture,
      challengeExpiresAt: expiresAt.toUtc(),
    );
  }

  @override
  Future<PlatformActivationRequest?> readPendingActivationRequest() async {
    final pending = await _readPending();
    if (pending == null) return null;
    return PlatformActivationRequest(
      requestId: pending['request_id']!,
      keyFingerprint: pending['key_fingerprint']!,
      platform: pending['platform']!,
      architecture: pending['architecture']!,
      challengeExpiresAt: DateTime.parse(pending['challenge_expires_at']!).toUtc(),
      proofVerified: pending['proof_completed'] == 'true',
    );
  }

  @override
  Future<PlatformDeviceLinkStatus> completePendingActivation() async {
    final pending = await _readPending();
    if (pending == null) {
      throw const PlatformApiException(
        statusCode: 400,
        code: 'ACTIVATION_REQUEST_NOT_CREATED',
        message: 'أنشئ طلب التفعيل أولًا.',
      );
    }
    final identity = await _deviceIdentity.loadOrCreate();
    if (identity.deviceKey != pending['device_key'] ||
        identity.platform != pending['platform'] ||
        identity.architecture != pending['architecture']) {
      await clearPendingLink();
      throw StateError('هوية الجهاز تغيرت؛ أوقف التفعيل وأنشئ طلبًا جديدًا.');
    }

    if (pending['proof_completed'] != 'true') {
      final challengeExpiresAt = DateTime.parse(pending['challenge_expires_at']!).toUtc();
      if (!challengeExpiresAt.isAfter(_clock().toUtc())) {
        await clearPendingLink();
        throw const PlatformApiException(
          statusCode: 410,
          code: 'ACTIVATION_CHALLENGE_EXPIRED',
          message: 'انتهت صلاحية إثبات الجهاز. أنشئ طلب تفعيل جديدًا.',
        );
      }
      final requestId = pending['request_id']!;
      final challenge = pending['challenge']!;
      final proofMessage = [
        'HOMI_DEVICE_PROOF_V1',
        requestId.toLowerCase(),
        'homi-grocery',
        identity.platform,
        identity.architecture,
        challenge,
      ].join('\n');
      final signature = await _deviceIdentity.signMessage(proofMessage);
      await _api.postJson(
        '/api/v1/public/activation-requests/$requestId/proof',
        body: {'challenge': challenge, 'signature': signature},
      );
      pending['proof_completed'] = 'true';
      await _store.write(_pendingKey, jsonEncode(pending));
    }

    final requestId = pending['request_id']!;
    final status = await _api.getJson(
      '/api/v1/public/activation-requests/$requestId/status',
    );
    final requestStatus = status['status'];
    if (requestStatus == 'proof_verified') {
      return PlatformDeviceLinkStatus.waitingForAdmin;
    }
    if (requestStatus == 'rejected' || requestStatus == 'cancelled' ||
        requestStatus == 'expired') {
      throw PlatformApiException(
        statusCode: 409,
        code: 'ACTIVATION_REQUEST_${requestStatus.toString().toUpperCase()}',
        message: 'طلب التفعيل ${requestStatus == 'rejected' ? 'مرفوض' : 'غير صالح'}؛ راجع إدارة Homi.',
      );
    }
    if (requestStatus != 'approved' || status['license'] is! Map) {
      return PlatformDeviceLinkStatus.licensePending;
    }
    final license = Map<String, Object?>.from(status['license'] as Map);
    if (license['status'] != 'active') {
      return PlatformDeviceLinkStatus.licensePending;
    }
    final verified = await _verifyIssuedLicense(license);
    await _store.write(_licenseKey, jsonEncode({
      'license_id': verified.licenseId,
      'device_id': verified.deviceId,
      'key_id': verified.keyId,
      'starts_at': verified.startsAt.toUtc().toIso8601String(),
      'ends_at': verified.endsAt?.toUtc().toIso8601String(),
      'plan_key': verified.planKey,
      'entitlement_version': verified.entitlementVersion,
      'payload': base64Encode(verified.signedPayload),
      'signature': base64Encode(verified.signature),
    }));
    await clearPendingLink();
    return PlatformDeviceLinkStatus.linked;
  }

  @override
  Future<PlatformLinkedLicense?> readLinkedLicense() async {
    final stored = await _store.read(_licenseKey);
    if (stored == null || stored.isEmpty) return null;
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException();
      }
      final license = Map<String, Object?>.from(decoded);
      final payload = base64Decode(license['payload'] as String);
      final signature = base64Decode(license['signature'] as String);
      final deviceId = license['device_id'];
      if (deviceId is! String || !_isUuid(deviceId)) {
        throw const FormatException('هوية الجهاز المرتبطة بالترخيص غير صالحة.');
      }
      return _verifyLicenseMaterial(
        licenseId: license['license_id'] as String,
        deviceId: deviceId,
        keyId: license['key_id'] as String,
        payload: payload,
        signature: signature,
      );
    } on Object {
      // لا نعيد إنشاء هوية أو ترخيص عند تلف السجل؛ نوقف التشغيل الآمن.
      rethrow;
    }
  }

  @override
  Future<PlatformLinkedLicense?> refreshOfflineGrant() async {
    final license = await readLinkedLicense();
    if (license == null) return null;

    try {
      final challenge = await _api.postJson(
        '/api/v1/devices/${license.deviceId}/challenges',
        body: {
          'license_id': license.licenseId,
          'purpose': 'offline_grant',
        },
      );
      final challengeId = challenge['challenge_id'];
      final nonce = challenge['nonce'];
      final expiresAt = DateTime.tryParse(challenge['expires_at'] as String? ?? '');
      if (challengeId is! String ||
          !_isUuid(challengeId) ||
          nonce is! String ||
          !_isValidNonce(nonce) ||
          expiresAt == null ||
          !expiresAt.isAfter(_clock().toUtc())) {
        throw const FormatException('تحدي تجديد تصريح العمل دون اتصال غير صالح.');
      }

      final deviceSignature = await _deviceIdentity.signNonce(nonce);
      final response = await _api.postJson(
        '/api/v1/licenses/${license.licenseId}/offline-grants',
        body: {
          'challenge_id': challengeId,
          'nonce': nonce,
          'signature': deviceSignature,
        },
      );
      final keyId = response['key_id'];
      final payloadText = response['payload'];
      final signatureText = response['signature'];
      if (keyId is! String ||
          payloadText is! String ||
          signatureText is! String) {
        throw const FormatException('استجابة تصريح العمل دون اتصال غير مكتملة.');
      }
      final verified = await _verifyLicenseMaterial(
        licenseId: license.licenseId,
        deviceId: license.deviceId,
        keyId: keyId,
        payload: _decodeCanonicalBase64(payloadText),
        signature: _decodeCanonicalBase64(signatureText),
      );
      await _store.write(_offlineGrantKey, jsonEncode({
        'license_id': verified.licenseId,
        'device_id': verified.deviceId,
        'key_id': verified.keyId,
        'payload': base64Encode(verified.signedPayload),
        'signature': base64Encode(verified.signature),
      }));
      return verified;
    } on PlatformApiException catch (error) {
      if (error.code == 'DEVICE_NOT_LINKED' ||
          error.code == 'DEVICE_PROOF_INVALID' ||
          error.code == 'LICENSE_REVOKED' ||
          error.code == 'LICENSE_SUSPENDED' ||
          error.code == 'ACCOUNT_INACTIVE') {
        await _store.write(_offlineGrantKey, '');
        return null;
      }
      return readOfflineGrant();
    } on Object {
      // عند انقطاع الشبكة نستخدم آخر تصريح موقّع محفوظ، ولا نمدد صلاحيته محليًا.
      return readOfflineGrant();
    }
  }

  @override
  Future<PlatformLinkedLicense?> readOfflineGrant() async {
    final stored = await _store.read(_offlineGrantKey);
    if (stored == null || stored.isEmpty) return null;
    final linkedLicense = await readLinkedLicense();
    if (linkedLicense == null) return null;
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('سجل تصريح العمل دون اتصال تالف.');
    }
    final grant = Map<String, Object?>.from(decoded);
    if (grant['license_id'] != linkedLicense.licenseId ||
        grant['device_id'] != linkedLicense.deviceId) {
      throw const FormatException('تصريح العمل دون اتصال لا يطابق الجهاز والترخيص المرتبطين.');
    }
    final keyId = grant['key_id'];
    final payloadText = grant['payload'];
    final signatureText = grant['signature'];
    if (keyId is! String || payloadText is! String || signatureText is! String) {
      throw const FormatException('بيانات تصريح العمل دون اتصال غير مكتملة.');
    }
    return _verifyLicenseMaterial(
      licenseId: linkedLicense.licenseId,
      deviceId: linkedLicense.deviceId,
      keyId: keyId,
      payload: _decodeCanonicalBase64(payloadText),
      signature: _decodeCanonicalBase64(signatureText),
    );
  }

  Future<void> clearPendingLink() => _store.write(_pendingKey, '');

  Future<Map<String, String>?> _readPending() async {
    final stored = await _store.read(_pendingKey);
    if (stored == null || stored.isEmpty) return null;
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('سجل طلب تفعيل الجهاز تالف.');
    }
    final requestId = decoded['request_id'];
    final challenge = decoded['challenge'];
    final expiresAt = decoded['challenge_expires_at'];
    final deviceKey = decoded['device_key'];
    final platform = decoded['platform'];
    final architecture = decoded['architecture'];
    final fingerprint = decoded['key_fingerprint'];
    final proofCompleted = decoded['proof_completed'];
    if (requestId is! String ||
        challenge is! String ||
        expiresAt is! String ||
        deviceKey is! String ||
        platform is! String ||
        architecture is! String ||
        fingerprint is! String ||
        proofCompleted is! bool ||
        !_isUuid(requestId) ||
        !_isUuid(deviceKey) ||
        !_isValidNonce(challenge) ||
        !RegExp(r'^[a-z0-9][a-z0-9._-]{1,31}$').hasMatch(platform) ||
        !RegExp(r'^[a-z0-9][a-z0-9._-]{1,31}$').hasMatch(architecture) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint) ||
        DateTime.tryParse(expiresAt) == null) {
      throw StateError('حقول طلب تفعيل الجهاز المحفوظ غير صالحة.');
    }
    return {
      'request_id': requestId,
      'challenge': challenge,
      'challenge_expires_at': expiresAt,
      'device_key': deviceKey,
      'platform': platform,
      'architecture': architecture,
      'key_fingerprint': fingerprint,
      'proof_completed': proofCompleted.toString(),
    };
  }

  Future<PlatformLinkedLicense> _verifyIssuedLicense(
    Map<String, Object?> license,
  ) async {
    final licenseId = license['id'];
    final keyId = license['key_id'];
    final payloadText = license['payload'];
    final signatureText = license['signature'];
    if (licenseId is! String ||
        keyId is! String ||
        payloadText is! String ||
        signatureText is! String) {
      throw const FormatException('بيانات الترخيص الموقّع غير مكتملة.');
    }

    if (!_trustedPublicKeys.containsKey(keyId)) {
      throw const FormatException(
        'مفتاح توقيع الترخيص غير موجود ضمن مفاتيح الثقة المعتمدة في هذا الإصدار.',
      );
    }

    final payload = _decodeCanonicalBase64(payloadText);
    final signature = _decodeCanonicalBase64(signatureText);
    final deviceId = license['device_id'];
    if (deviceId is! String || !_isUuid(deviceId)) {
      throw const FormatException('استجابة ربط الجهاز لا تحتوي على معرّف جهاز صالح.');
    }
    return _verifyLicenseMaterial(
      licenseId: licenseId,
      deviceId: deviceId,
      keyId: keyId,
      payload: payload,
      signature: signature,
    );
  }

  Future<PlatformLinkedLicense> _verifyLicenseMaterial({
    required String licenseId,
    required String deviceId,
    required String keyId,
    required List<int> payload,
    required List<int> signature,
  }) async {
    final publicDer = _trustedPublicKeys[keyId];
    if (signature.length != 64 || publicDer == null ||
        publicDer.length != 44 ||
        !_sameBytes(publicDer.sublist(0, 12), _spkiPrefix)) {
      throw const FormatException(
        'مفتاح توقيع الترخيص غير موثوق أو صيغة التوقيع غير صالحة.',
      );
    }
    final publicKey = SimplePublicKey(
      publicDer.sublist(12),
      type: KeyPairType.ed25519,
    );
    final valid = await _ed25519.verify(
      payload,
      signature: Signature(signature, publicKey: publicKey),
    );
    if (!valid) {
      throw const FormatException('فشل التحقق من توقيع ترخيص Homi.');
    }

    final claims = jsonDecode(utf8.decode(payload));
    if (claims is! Map<String, dynamic> ||
        claims['schema_version'] != 1 ||
        claims['license_id'] != licenseId ||
        (claims['device_id'] != null && claims['device_id'] != deviceId) ||
        claims['key_id'] != keyId ||
        claims['product_id'] is! String ||
        claims['organization_id'] is! String ||
        claims['user_id'] is! String ||
        claims['plan_key'] is! String ||
        claims['entitlement_version'] is! num) {
      throw const FormatException('مطالبات الترخيص الموقّع غير صالحة.');
    }
    if (claims['license_id'] is String) {
      final localIdentity = await _deviceIdentity.loadOrCreate();
      final localFingerprint = crypto.sha256
          .convert(localIdentity.publicKeyDer.sublist(12))
          .toString();
      final deviceFingerprints = claims['device_fingerprints'];
      if (deviceFingerprints is! List ||
          deviceFingerprints.any((value) => value is! String) ||
          !deviceFingerprints.contains(localFingerprint)) {
        throw const FormatException(
          'ملف الترخيص لا يتضمن بصمة مفتاح هذا الجهاز؛ لا يمكن نقله إلى جهاز آخر.',
        );
      }
    } else if (claims['grant_id'] is String && claims['device_id'] != deviceId) {
      throw const FormatException('تصريح العمل دون اتصال لا يخص هذا الجهاز.');
    }
    DateTime? parseOptionalDate(String key) {
      final value = claims[key];
      if (value == null) return null;
      if (value is! String) {
        throw FormatException('قيمة التاريخ $key غير صالحة.');
      }
      final parsed = DateTime.tryParse(value);
      if (parsed == null) {
        throw FormatException('قيمة التاريخ $key غير صالحة.');
      }
      return parsed.toUtc();
    }

    final startsAt = DateTime.tryParse(claims['starts_at'] as String? ?? '');
    final issuedAt = DateTime.tryParse(claims['issued_at'] as String? ?? '');
    final endsAt = parseOptionalDate('ends_at');
    final trialEndsAt = parseOptionalDate('trial_ends_at');
    final subscriptionEndsAt = parseOptionalDate('subscription_ends_at');
    final offlineExpiresAt = parseOptionalDate('offline_expires_at');
    final graceEndsAt = parseOptionalDate('grace_ends_at');
    final planKey = claims['plan_key'] as String;
    final accessPolicy = claims['access_policy'];
    if (startsAt == null ||
        issuedAt == null ||
        startsAt.isAfter(issuedAt.add(const Duration(minutes: 5))) ||
        (endsAt != null && !endsAt.isAfter(startsAt))) {
      throw const FormatException('تواريخ صلاحية الترخيص غير صالحة.');
    }

    final issuedUtc = issuedAt.toUtc();
    if (planKey == 'trial') {
      if (trialEndsAt == null ||
          subscriptionEndsAt != null ||
          graceEndsAt != null ||
          offlineExpiresAt == null ||
          endsAt != trialEndsAt ||
          accessPolicy !=
              'full_until_offline_expiry_or_trial_end_then_read_export' ||
          !offlineExpiresAt.isAfter(issuedUtc) ||
          offlineExpiresAt.isAfter(
            issuedUtc.add(const Duration(days: 7)),
          ) ||
          offlineExpiresAt.isAfter(trialEndsAt)) {
        throw const FormatException('سياسة العمل دون اتصال للتجربة غير صالحة.');
      }
    } else if (planKey == 'monthly' || planKey == 'annual') {
      final expectedGraceEnd = endsAt?.add(const Duration(days: 7));
      if (trialEndsAt != null ||
          subscriptionEndsAt == null ||
          subscriptionEndsAt != endsAt ||
          offlineExpiresAt == null ||
          graceEndsAt == null ||
          graceEndsAt != expectedGraceEnd ||
          offlineExpiresAt != graceEndsAt ||
          accessPolicy !=
              'full_until_subscription_end_then_read_export_until_grace_end') {
        throw const FormatException('سياسة مهلة الاشتراك المدفوع غير صالحة.');
      }
    } else if (planKey == 'lifetime') {
      if (endsAt != null ||
          trialEndsAt != null ||
          subscriptionEndsAt != null ||
          offlineExpiresAt != null ||
          graceEndsAt != null ||
          accessPolicy != 'full_forever') {
        throw const FormatException('سياسة الترخيص الدائم غير صالحة.');
      }
    } else {
      throw const FormatException('نوع خطة الترخيص غير مدعوم.');
    }

    return PlatformLinkedLicense(
      licenseId: licenseId,
      deviceId: deviceId,
      keyId: keyId,
      startsAt: startsAt.toUtc(),
      endsAt: endsAt,
      trialEndsAt: trialEndsAt,
      subscriptionEndsAt: subscriptionEndsAt,
      offlineExpiresAt: offlineExpiresAt,
      graceEndsAt: graceEndsAt,
      accessPolicy: accessPolicy as String,
      planKey: planKey,
      entitlementVersion: (claims['entitlement_version'] as num).toInt(),
      signedPayload: payload,
      signature: signature,
      publicKeyDer: List<int>.unmodifiable(publicDer),
    );
  }

  List<int> _decodeCanonicalBase64(String value) {
    final decoded = base64Decode(value);
    if (base64Encode(decoded) != value) {
      throw const FormatException('ترميز Base64 غير قياسي.');
    }
    return decoded;
  }

  bool _isValidNonce(String value) {
    try {
      final decoded = base64Url.decode(base64Url.normalize(value));
      return decoded.length == 32 &&
          base64UrlEncode(decoded).replaceAll('=', '') == value;
    } on FormatException {
      return false;
    }
  }

  bool _isUuid(String value) =>
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$', caseSensitive: false)
          .hasMatch(value);

  bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}
).hasMatch(fingerprint) ||
        (supportWhatsApp is String && supportWhatsApp.isNotEmpty &&
            !RegExp(r'^\\d{8,15}
        expiresAt == null ||
        !expiresAt.isAfter(_clock().toUtc())) {
      throw const FormatException('استجابة طلب تفعيل الجهاز من المنصة غير صالحة.');
    }

    await _store.write(_pendingKey, jsonEncode({
      'request_id': requestId,
      'challenge': challenge,
      'challenge_expires_at': expiresAt.toUtc().toIso8601String(),
      'device_key': identity.deviceKey,
      'platform': identity.platform,
      'architecture': identity.architecture,
      'key_fingerprint': fingerprint,
      'support_whatsapp': supportWhatsApp ?? '',
      'proof_completed': false,
    }));
    return PlatformActivationRequest(
      requestId: requestId,
      keyFingerprint: fingerprint,
      platform: identity.platform,
      architecture: identity.architecture,
      challengeExpiresAt: expiresAt.toUtc(),
      supportWhatsApp: supportWhatsApp,
    );
  }

  @override
  Future<PlatformActivationRequest?> readPendingActivationRequest() async {
    final pending = await _readPending();
    if (pending == null) return null;
    return PlatformActivationRequest(
      requestId: pending['request_id']!,
      keyFingerprint: pending['key_fingerprint']!,
      platform: pending['platform']!,
      architecture: pending['architecture']!,
      challengeExpiresAt: DateTime.parse(pending['challenge_expires_at']!).toUtc(),
      proofVerified: pending['proof_completed'] == 'true',
      supportWhatsApp: pending['support_whatsapp']?.isNotEmpty == true
          ? pending['support_whatsapp']
          : null,
    );
  }

  @override
  Future<PlatformDeviceLinkStatus> completePendingActivation() async {
    final pending = await _readPending();
    if (pending == null) {
      throw const PlatformApiException(
        statusCode: 400,
        code: 'ACTIVATION_REQUEST_NOT_CREATED',
        message: 'أنشئ طلب التفعيل أولًا.',
      );
    }
    final identity = await _deviceIdentity.loadOrCreate();
    if (identity.deviceKey != pending['device_key'] ||
        identity.platform != pending['platform'] ||
        identity.architecture != pending['architecture']) {
      await clearPendingLink();
      throw StateError('هوية الجهاز تغيرت؛ أوقف التفعيل وأنشئ طلبًا جديدًا.');
    }

    if (pending['proof_completed'] != 'true') {
      final challengeExpiresAt = DateTime.parse(pending['challenge_expires_at']!).toUtc();
      if (!challengeExpiresAt.isAfter(_clock().toUtc())) {
        await clearPendingLink();
        throw const PlatformApiException(
          statusCode: 410,
          code: 'ACTIVATION_CHALLENGE_EXPIRED',
          message: 'انتهت صلاحية إثبات الجهاز. أنشئ طلب تفعيل جديدًا.',
        );
      }
      final requestId = pending['request_id']!;
      final challenge = pending['challenge']!;
      final proofMessage = [
        'HOMI_DEVICE_PROOF_V1',
        requestId.toLowerCase(),
        'homi-grocery',
        identity.platform,
        identity.architecture,
        challenge,
      ].join('\n');
      final signature = await _deviceIdentity.signMessage(proofMessage);
      await _api.postJson(
        '/api/v1/public/activation-requests/$requestId/proof',
        body: {'challenge': challenge, 'signature': signature},
      );
      pending['proof_completed'] = 'true';
      await _store.write(_pendingKey, jsonEncode(pending));
    }

    final requestId = pending['request_id']!;
    final status = await _api.getJson(
      '/api/v1/public/activation-requests/$requestId/status',
    );
    final requestStatus = status['status'];
    if (requestStatus == 'proof_verified') {
      return PlatformDeviceLinkStatus.waitingForAdmin;
    }
    if (requestStatus == 'rejected' || requestStatus == 'cancelled' ||
        requestStatus == 'expired') {
      throw PlatformApiException(
        statusCode: 409,
        code: 'ACTIVATION_REQUEST_${requestStatus.toString().toUpperCase()}',
        message: 'طلب التفعيل ${requestStatus == 'rejected' ? 'مرفوض' : 'غير صالح'}؛ راجع إدارة Homi.',
      );
    }
    if (requestStatus != 'approved' || status['license'] is! Map) {
      return PlatformDeviceLinkStatus.licensePending;
    }
    final license = Map<String, Object?>.from(status['license'] as Map);
    if (license['status'] != 'active') {
      return PlatformDeviceLinkStatus.licensePending;
    }
    final verified = await _verifyIssuedLicense(license);
    await _store.write(_licenseKey, jsonEncode({
      'license_id': verified.licenseId,
      'device_id': verified.deviceId,
      'key_id': verified.keyId,
      'starts_at': verified.startsAt.toUtc().toIso8601String(),
      'ends_at': verified.endsAt?.toUtc().toIso8601String(),
      'plan_key': verified.planKey,
      'entitlement_version': verified.entitlementVersion,
      'payload': base64Encode(verified.signedPayload),
      'signature': base64Encode(verified.signature),
    }));
    await clearPendingLink();
    return PlatformDeviceLinkStatus.linked;
  }

  @override
  Future<PlatformLinkedLicense?> readLinkedLicense() async {
    final stored = await _store.read(_licenseKey);
    if (stored == null || stored.isEmpty) return null;
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException();
      }
      final license = Map<String, Object?>.from(decoded);
      final payload = base64Decode(license['payload'] as String);
      final signature = base64Decode(license['signature'] as String);
      final deviceId = license['device_id'];
      if (deviceId is! String || !_isUuid(deviceId)) {
        throw const FormatException('هوية الجهاز المرتبطة بالترخيص غير صالحة.');
      }
      return _verifyLicenseMaterial(
        licenseId: license['license_id'] as String,
        deviceId: deviceId,
        keyId: license['key_id'] as String,
        payload: payload,
        signature: signature,
      );
    } on Object {
      // لا نعيد إنشاء هوية أو ترخيص عند تلف السجل؛ نوقف التشغيل الآمن.
      rethrow;
    }
  }

  @override
  Future<PlatformLinkedLicense?> refreshOfflineGrant() async {
    final license = await readLinkedLicense();
    if (license == null) return null;

    try {
      final challenge = await _api.postJson(
        '/api/v1/devices/${license.deviceId}/challenges',
        body: {
          'license_id': license.licenseId,
          'purpose': 'offline_grant',
        },
      );
      final challengeId = challenge['challenge_id'];
      final nonce = challenge['nonce'];
      final expiresAt = DateTime.tryParse(challenge['expires_at'] as String? ?? '');
      if (challengeId is! String ||
          !_isUuid(challengeId) ||
          nonce is! String ||
          !_isValidNonce(nonce) ||
          expiresAt == null ||
          !expiresAt.isAfter(_clock().toUtc())) {
        throw const FormatException('تحدي تجديد تصريح العمل دون اتصال غير صالح.');
      }

      final deviceSignature = await _deviceIdentity.signNonce(nonce);
      final response = await _api.postJson(
        '/api/v1/licenses/${license.licenseId}/offline-grants',
        body: {
          'challenge_id': challengeId,
          'nonce': nonce,
          'signature': deviceSignature,
        },
      );
      final keyId = response['key_id'];
      final payloadText = response['payload'];
      final signatureText = response['signature'];
      if (keyId is! String ||
          payloadText is! String ||
          signatureText is! String) {
        throw const FormatException('استجابة تصريح العمل دون اتصال غير مكتملة.');
      }
      final verified = await _verifyLicenseMaterial(
        licenseId: license.licenseId,
        deviceId: license.deviceId,
        keyId: keyId,
        payload: _decodeCanonicalBase64(payloadText),
        signature: _decodeCanonicalBase64(signatureText),
      );
      await _store.write(_offlineGrantKey, jsonEncode({
        'license_id': verified.licenseId,
        'device_id': verified.deviceId,
        'key_id': verified.keyId,
        'payload': base64Encode(verified.signedPayload),
        'signature': base64Encode(verified.signature),
      }));
      return verified;
    } on PlatformApiException catch (error) {
      if (error.code == 'DEVICE_NOT_LINKED' ||
          error.code == 'DEVICE_PROOF_INVALID' ||
          error.code == 'LICENSE_REVOKED' ||
          error.code == 'LICENSE_SUSPENDED' ||
          error.code == 'ACCOUNT_INACTIVE') {
        await _store.write(_offlineGrantKey, '');
        return null;
      }
      return readOfflineGrant();
    } on Object {
      // عند انقطاع الشبكة نستخدم آخر تصريح موقّع محفوظ، ولا نمدد صلاحيته محليًا.
      return readOfflineGrant();
    }
  }

  @override
  Future<PlatformLinkedLicense?> readOfflineGrant() async {
    final stored = await _store.read(_offlineGrantKey);
    if (stored == null || stored.isEmpty) return null;
    final linkedLicense = await readLinkedLicense();
    if (linkedLicense == null) return null;
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('سجل تصريح العمل دون اتصال تالف.');
    }
    final grant = Map<String, Object?>.from(decoded);
    if (grant['license_id'] != linkedLicense.licenseId ||
        grant['device_id'] != linkedLicense.deviceId) {
      throw const FormatException('تصريح العمل دون اتصال لا يطابق الجهاز والترخيص المرتبطين.');
    }
    final keyId = grant['key_id'];
    final payloadText = grant['payload'];
    final signatureText = grant['signature'];
    if (keyId is! String || payloadText is! String || signatureText is! String) {
      throw const FormatException('بيانات تصريح العمل دون اتصال غير مكتملة.');
    }
    return _verifyLicenseMaterial(
      licenseId: linkedLicense.licenseId,
      deviceId: linkedLicense.deviceId,
      keyId: keyId,
      payload: _decodeCanonicalBase64(payloadText),
      signature: _decodeCanonicalBase64(signatureText),
    );
  }

  Future<void> clearPendingLink() => _store.write(_pendingKey, '');

  Future<Map<String, String>?> _readPending() async {
    final stored = await _store.read(_pendingKey);
    if (stored == null || stored.isEmpty) return null;
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('سجل طلب تفعيل الجهاز تالف.');
    }
    final requestId = decoded['request_id'];
    final challenge = decoded['challenge'];
    final expiresAt = decoded['challenge_expires_at'];
    final deviceKey = decoded['device_key'];
    final platform = decoded['platform'];
    final architecture = decoded['architecture'];
    final fingerprint = decoded['key_fingerprint'];
    final proofCompleted = decoded['proof_completed'];
    final supportWhatsApp = decoded['support_whatsapp'];
    if (requestId is! String ||
        challenge is! String ||
        expiresAt is! String ||
        deviceKey is! String ||
        platform is! String ||
        architecture is! String ||
        fingerprint is! String ||
        proofCompleted is! bool ||
        (supportWhatsApp != null && supportWhatsApp is! String) ||
        !_isUuid(requestId) ||
        !_isUuid(deviceKey) ||
        !_isValidNonce(challenge) ||
        !RegExp(r'^[a-z0-9][a-z0-9._-]{1,31}$').hasMatch(platform) ||
        !RegExp(r'^[a-z0-9][a-z0-9._-]{1,31}$').hasMatch(architecture) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint) ||
        DateTime.tryParse(expiresAt) == null) {
      throw StateError('حقول طلب تفعيل الجهاز المحفوظ غير صالحة.');
    }
    return {
      'request_id': requestId,
      'challenge': challenge,
      'challenge_expires_at': expiresAt,
      'device_key': deviceKey,
      'platform': platform,
      'architecture': architecture,
      'key_fingerprint': fingerprint,
      'proof_completed': proofCompleted.toString(),
    };
  }

  Future<PlatformLinkedLicense> _verifyIssuedLicense(
    Map<String, Object?> license,
  ) async {
    final licenseId = license['id'];
    final keyId = license['key_id'];
    final payloadText = license['payload'];
    final signatureText = license['signature'];
    if (licenseId is! String ||
        keyId is! String ||
        payloadText is! String ||
        signatureText is! String) {
      throw const FormatException('بيانات الترخيص الموقّع غير مكتملة.');
    }

    if (!_trustedPublicKeys.containsKey(keyId)) {
      throw const FormatException(
        'مفتاح توقيع الترخيص غير موجود ضمن مفاتيح الثقة المعتمدة في هذا الإصدار.',
      );
    }

    final payload = _decodeCanonicalBase64(payloadText);
    final signature = _decodeCanonicalBase64(signatureText);
    final deviceId = license['device_id'];
    if (deviceId is! String || !_isUuid(deviceId)) {
      throw const FormatException('استجابة ربط الجهاز لا تحتوي على معرّف جهاز صالح.');
    }
    return _verifyLicenseMaterial(
      licenseId: licenseId,
      deviceId: deviceId,
      keyId: keyId,
      payload: payload,
      signature: signature,
    );
  }

  Future<PlatformLinkedLicense> _verifyLicenseMaterial({
    required String licenseId,
    required String deviceId,
    required String keyId,
    required List<int> payload,
    required List<int> signature,
  }) async {
    final publicDer = _trustedPublicKeys[keyId];
    if (signature.length != 64 || publicDer == null ||
        publicDer.length != 44 ||
        !_sameBytes(publicDer.sublist(0, 12), _spkiPrefix)) {
      throw const FormatException(
        'مفتاح توقيع الترخيص غير موثوق أو صيغة التوقيع غير صالحة.',
      );
    }
    final publicKey = SimplePublicKey(
      publicDer.sublist(12),
      type: KeyPairType.ed25519,
    );
    final valid = await _ed25519.verify(
      payload,
      signature: Signature(signature, publicKey: publicKey),
    );
    if (!valid) {
      throw const FormatException('فشل التحقق من توقيع ترخيص Homi.');
    }

    final claims = jsonDecode(utf8.decode(payload));
    if (claims is! Map<String, dynamic> ||
        claims['schema_version'] != 1 ||
        claims['license_id'] != licenseId ||
        (claims['device_id'] != null && claims['device_id'] != deviceId) ||
        claims['key_id'] != keyId ||
        claims['product_id'] is! String ||
        claims['organization_id'] is! String ||
        claims['user_id'] is! String ||
        claims['plan_key'] is! String ||
        claims['entitlement_version'] is! num) {
      throw const FormatException('مطالبات الترخيص الموقّع غير صالحة.');
    }
    if (claims['license_id'] is String) {
      final localIdentity = await _deviceIdentity.loadOrCreate();
      final localFingerprint = crypto.sha256
          .convert(localIdentity.publicKeyDer.sublist(12))
          .toString();
      final deviceFingerprints = claims['device_fingerprints'];
      if (deviceFingerprints is! List ||
          deviceFingerprints.any((value) => value is! String) ||
          !deviceFingerprints.contains(localFingerprint)) {
        throw const FormatException(
          'ملف الترخيص لا يتضمن بصمة مفتاح هذا الجهاز؛ لا يمكن نقله إلى جهاز آخر.',
        );
      }
    } else if (claims['grant_id'] is String && claims['device_id'] != deviceId) {
      throw const FormatException('تصريح العمل دون اتصال لا يخص هذا الجهاز.');
    }
    DateTime? parseOptionalDate(String key) {
      final value = claims[key];
      if (value == null) return null;
      if (value is! String) {
        throw FormatException('قيمة التاريخ $key غير صالحة.');
      }
      final parsed = DateTime.tryParse(value);
      if (parsed == null) {
        throw FormatException('قيمة التاريخ $key غير صالحة.');
      }
      return parsed.toUtc();
    }

    final startsAt = DateTime.tryParse(claims['starts_at'] as String? ?? '');
    final issuedAt = DateTime.tryParse(claims['issued_at'] as String? ?? '');
    final endsAt = parseOptionalDate('ends_at');
    final trialEndsAt = parseOptionalDate('trial_ends_at');
    final subscriptionEndsAt = parseOptionalDate('subscription_ends_at');
    final offlineExpiresAt = parseOptionalDate('offline_expires_at');
    final graceEndsAt = parseOptionalDate('grace_ends_at');
    final planKey = claims['plan_key'] as String;
    final accessPolicy = claims['access_policy'];
    if (startsAt == null ||
        issuedAt == null ||
        startsAt.isAfter(issuedAt.add(const Duration(minutes: 5))) ||
        (endsAt != null && !endsAt.isAfter(startsAt))) {
      throw const FormatException('تواريخ صلاحية الترخيص غير صالحة.');
    }

    final issuedUtc = issuedAt.toUtc();
    if (planKey == 'trial') {
      if (trialEndsAt == null ||
          subscriptionEndsAt != null ||
          graceEndsAt != null ||
          offlineExpiresAt == null ||
          endsAt != trialEndsAt ||
          accessPolicy !=
              'full_until_offline_expiry_or_trial_end_then_read_export' ||
          !offlineExpiresAt.isAfter(issuedUtc) ||
          offlineExpiresAt.isAfter(
            issuedUtc.add(const Duration(days: 7)),
          ) ||
          offlineExpiresAt.isAfter(trialEndsAt)) {
        throw const FormatException('سياسة العمل دون اتصال للتجربة غير صالحة.');
      }
    } else if (planKey == 'monthly' || planKey == 'annual') {
      final expectedGraceEnd = endsAt?.add(const Duration(days: 7));
      if (trialEndsAt != null ||
          subscriptionEndsAt == null ||
          subscriptionEndsAt != endsAt ||
          offlineExpiresAt == null ||
          graceEndsAt == null ||
          graceEndsAt != expectedGraceEnd ||
          offlineExpiresAt != graceEndsAt ||
          accessPolicy !=
              'full_until_subscription_end_then_read_export_until_grace_end') {
        throw const FormatException('سياسة مهلة الاشتراك المدفوع غير صالحة.');
      }
    } else if (planKey == 'lifetime') {
      if (endsAt != null ||
          trialEndsAt != null ||
          subscriptionEndsAt != null ||
          offlineExpiresAt != null ||
          graceEndsAt != null ||
          accessPolicy != 'full_forever') {
        throw const FormatException('سياسة الترخيص الدائم غير صالحة.');
      }
    } else {
      throw const FormatException('نوع خطة الترخيص غير مدعوم.');
    }

    return PlatformLinkedLicense(
      licenseId: licenseId,
      deviceId: deviceId,
      keyId: keyId,
      startsAt: startsAt.toUtc(),
      endsAt: endsAt,
      trialEndsAt: trialEndsAt,
      subscriptionEndsAt: subscriptionEndsAt,
      offlineExpiresAt: offlineExpiresAt,
      graceEndsAt: graceEndsAt,
      accessPolicy: accessPolicy as String,
      planKey: planKey,
      entitlementVersion: (claims['entitlement_version'] as num).toInt(),
      signedPayload: payload,
      signature: signature,
      publicKeyDer: List<int>.unmodifiable(publicDer),
    );
  }

  List<int> _decodeCanonicalBase64(String value) {
    final decoded = base64Decode(value);
    if (base64Encode(decoded) != value) {
      throw const FormatException('ترميز Base64 غير قياسي.');
    }
    return decoded;
  }

  bool _isValidNonce(String value) {
    try {
      final decoded = base64Url.decode(base64Url.normalize(value));
      return decoded.length == 32 &&
          base64UrlEncode(decoded).replaceAll('=', '') == value;
    } on FormatException {
      return false;
    }
  }

  bool _isUuid(String value) =>
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$', caseSensitive: false)
          .hasMatch(value);

  bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}
).hasMatch(supportWhatsAppValue)
        ? supportWhatsAppValue
        : null;
    final expiresAt = expiresAtText is String ? DateTime.tryParse(expiresAtText) : null;
    if (requestId is! String ||
        !_isUuid(requestId) ||
        challenge is! String ||
        !_isValidNonce(challenge) ||
        fingerprint is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint) ||
        expiresAt == null ||
        !expiresAt.isAfter(_clock().toUtc())) {
      throw const FormatException('استجابة طلب تفعيل الجهاز من المنصة غير صالحة.');
    }

    await _store.write(_pendingKey, jsonEncode({
      'request_id': requestId,
      'challenge': challenge,
      'challenge_expires_at': expiresAt.toUtc().toIso8601String(),
      'device_key': identity.deviceKey,
      'platform': identity.platform,
      'architecture': identity.architecture,
      'key_fingerprint': fingerprint,
      'proof_completed': false,
    }));
    return PlatformActivationRequest(
      requestId: requestId,
      keyFingerprint: fingerprint,
      platform: identity.platform,
      architecture: identity.architecture,
      challengeExpiresAt: expiresAt.toUtc(),
    );
  }

  @override
  Future<PlatformActivationRequest?> readPendingActivationRequest() async {
    final pending = await _readPending();
    if (pending == null) return null;
    return PlatformActivationRequest(
      requestId: pending['request_id']!,
      keyFingerprint: pending['key_fingerprint']!,
      platform: pending['platform']!,
      architecture: pending['architecture']!,
      challengeExpiresAt: DateTime.parse(pending['challenge_expires_at']!).toUtc(),
      proofVerified: pending['proof_completed'] == 'true',
    );
  }

  @override
  Future<PlatformDeviceLinkStatus> completePendingActivation() async {
    final pending = await _readPending();
    if (pending == null) {
      throw const PlatformApiException(
        statusCode: 400,
        code: 'ACTIVATION_REQUEST_NOT_CREATED',
        message: 'أنشئ طلب التفعيل أولًا.',
      );
    }
    final identity = await _deviceIdentity.loadOrCreate();
    if (identity.deviceKey != pending['device_key'] ||
        identity.platform != pending['platform'] ||
        identity.architecture != pending['architecture']) {
      await clearPendingLink();
      throw StateError('هوية الجهاز تغيرت؛ أوقف التفعيل وأنشئ طلبًا جديدًا.');
    }

    if (pending['proof_completed'] != 'true') {
      final challengeExpiresAt = DateTime.parse(pending['challenge_expires_at']!).toUtc();
      if (!challengeExpiresAt.isAfter(_clock().toUtc())) {
        await clearPendingLink();
        throw const PlatformApiException(
          statusCode: 410,
          code: 'ACTIVATION_CHALLENGE_EXPIRED',
          message: 'انتهت صلاحية إثبات الجهاز. أنشئ طلب تفعيل جديدًا.',
        );
      }
      final requestId = pending['request_id']!;
      final challenge = pending['challenge']!;
      final proofMessage = [
        'HOMI_DEVICE_PROOF_V1',
        requestId.toLowerCase(),
        'homi-grocery',
        identity.platform,
        identity.architecture,
        challenge,
      ].join('\n');
      final signature = await _deviceIdentity.signMessage(proofMessage);
      await _api.postJson(
        '/api/v1/public/activation-requests/$requestId/proof',
        body: {'challenge': challenge, 'signature': signature},
      );
      pending['proof_completed'] = 'true';
      await _store.write(_pendingKey, jsonEncode(pending));
    }

    final requestId = pending['request_id']!;
    final status = await _api.getJson(
      '/api/v1/public/activation-requests/$requestId/status',
    );
    final requestStatus = status['status'];
    if (requestStatus == 'proof_verified') {
      return PlatformDeviceLinkStatus.waitingForAdmin;
    }
    if (requestStatus == 'rejected' || requestStatus == 'cancelled' ||
        requestStatus == 'expired') {
      throw PlatformApiException(
        statusCode: 409,
        code: 'ACTIVATION_REQUEST_${requestStatus.toString().toUpperCase()}',
        message: 'طلب التفعيل ${requestStatus == 'rejected' ? 'مرفوض' : 'غير صالح'}؛ راجع إدارة Homi.',
      );
    }
    if (requestStatus != 'approved' || status['license'] is! Map) {
      return PlatformDeviceLinkStatus.licensePending;
    }
    final license = Map<String, Object?>.from(status['license'] as Map);
    if (license['status'] != 'active') {
      return PlatformDeviceLinkStatus.licensePending;
    }
    final verified = await _verifyIssuedLicense(license);
    await _store.write(_licenseKey, jsonEncode({
      'license_id': verified.licenseId,
      'device_id': verified.deviceId,
      'key_id': verified.keyId,
      'starts_at': verified.startsAt.toUtc().toIso8601String(),
      'ends_at': verified.endsAt?.toUtc().toIso8601String(),
      'plan_key': verified.planKey,
      'entitlement_version': verified.entitlementVersion,
      'payload': base64Encode(verified.signedPayload),
      'signature': base64Encode(verified.signature),
    }));
    await clearPendingLink();
    return PlatformDeviceLinkStatus.linked;
  }

  @override
  Future<PlatformLinkedLicense?> readLinkedLicense() async {
    final stored = await _store.read(_licenseKey);
    if (stored == null || stored.isEmpty) return null;
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException();
      }
      final license = Map<String, Object?>.from(decoded);
      final payload = base64Decode(license['payload'] as String);
      final signature = base64Decode(license['signature'] as String);
      final deviceId = license['device_id'];
      if (deviceId is! String || !_isUuid(deviceId)) {
        throw const FormatException('هوية الجهاز المرتبطة بالترخيص غير صالحة.');
      }
      return _verifyLicenseMaterial(
        licenseId: license['license_id'] as String,
        deviceId: deviceId,
        keyId: license['key_id'] as String,
        payload: payload,
        signature: signature,
      );
    } on Object {
      // لا نعيد إنشاء هوية أو ترخيص عند تلف السجل؛ نوقف التشغيل الآمن.
      rethrow;
    }
  }

  @override
  Future<PlatformLinkedLicense?> refreshOfflineGrant() async {
    final license = await readLinkedLicense();
    if (license == null) return null;

    try {
      final challenge = await _api.postJson(
        '/api/v1/devices/${license.deviceId}/challenges',
        body: {
          'license_id': license.licenseId,
          'purpose': 'offline_grant',
        },
      );
      final challengeId = challenge['challenge_id'];
      final nonce = challenge['nonce'];
      final expiresAt = DateTime.tryParse(challenge['expires_at'] as String? ?? '');
      if (challengeId is! String ||
          !_isUuid(challengeId) ||
          nonce is! String ||
          !_isValidNonce(nonce) ||
          expiresAt == null ||
          !expiresAt.isAfter(_clock().toUtc())) {
        throw const FormatException('تحدي تجديد تصريح العمل دون اتصال غير صالح.');
      }

      final deviceSignature = await _deviceIdentity.signNonce(nonce);
      final response = await _api.postJson(
        '/api/v1/licenses/${license.licenseId}/offline-grants',
        body: {
          'challenge_id': challengeId,
          'nonce': nonce,
          'signature': deviceSignature,
        },
      );
      final keyId = response['key_id'];
      final payloadText = response['payload'];
      final signatureText = response['signature'];
      if (keyId is! String ||
          payloadText is! String ||
          signatureText is! String) {
        throw const FormatException('استجابة تصريح العمل دون اتصال غير مكتملة.');
      }
      final verified = await _verifyLicenseMaterial(
        licenseId: license.licenseId,
        deviceId: license.deviceId,
        keyId: keyId,
        payload: _decodeCanonicalBase64(payloadText),
        signature: _decodeCanonicalBase64(signatureText),
      );
      await _store.write(_offlineGrantKey, jsonEncode({
        'license_id': verified.licenseId,
        'device_id': verified.deviceId,
        'key_id': verified.keyId,
        'payload': base64Encode(verified.signedPayload),
        'signature': base64Encode(verified.signature),
      }));
      return verified;
    } on PlatformApiException catch (error) {
      if (error.code == 'DEVICE_NOT_LINKED' ||
          error.code == 'DEVICE_PROOF_INVALID' ||
          error.code == 'LICENSE_REVOKED' ||
          error.code == 'LICENSE_SUSPENDED' ||
          error.code == 'ACCOUNT_INACTIVE') {
        await _store.write(_offlineGrantKey, '');
        return null;
      }
      return readOfflineGrant();
    } on Object {
      // عند انقطاع الشبكة نستخدم آخر تصريح موقّع محفوظ، ولا نمدد صلاحيته محليًا.
      return readOfflineGrant();
    }
  }

  @override
  Future<PlatformLinkedLicense?> readOfflineGrant() async {
    final stored = await _store.read(_offlineGrantKey);
    if (stored == null || stored.isEmpty) return null;
    final linkedLicense = await readLinkedLicense();
    if (linkedLicense == null) return null;
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('سجل تصريح العمل دون اتصال تالف.');
    }
    final grant = Map<String, Object?>.from(decoded);
    if (grant['license_id'] != linkedLicense.licenseId ||
        grant['device_id'] != linkedLicense.deviceId) {
      throw const FormatException('تصريح العمل دون اتصال لا يطابق الجهاز والترخيص المرتبطين.');
    }
    final keyId = grant['key_id'];
    final payloadText = grant['payload'];
    final signatureText = grant['signature'];
    if (keyId is! String || payloadText is! String || signatureText is! String) {
      throw const FormatException('بيانات تصريح العمل دون اتصال غير مكتملة.');
    }
    return _verifyLicenseMaterial(
      licenseId: linkedLicense.licenseId,
      deviceId: linkedLicense.deviceId,
      keyId: keyId,
      payload: _decodeCanonicalBase64(payloadText),
      signature: _decodeCanonicalBase64(signatureText),
    );
  }

  Future<void> clearPendingLink() => _store.write(_pendingKey, '');

  Future<Map<String, String>?> _readPending() async {
    final stored = await _store.read(_pendingKey);
    if (stored == null || stored.isEmpty) return null;
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('سجل طلب تفعيل الجهاز تالف.');
    }
    final requestId = decoded['request_id'];
    final challenge = decoded['challenge'];
    final expiresAt = decoded['challenge_expires_at'];
    final deviceKey = decoded['device_key'];
    final platform = decoded['platform'];
    final architecture = decoded['architecture'];
    final fingerprint = decoded['key_fingerprint'];
    final proofCompleted = decoded['proof_completed'];
    if (requestId is! String ||
        challenge is! String ||
        expiresAt is! String ||
        deviceKey is! String ||
        platform is! String ||
        architecture is! String ||
        fingerprint is! String ||
        proofCompleted is! bool ||
        !_isUuid(requestId) ||
        !_isUuid(deviceKey) ||
        !_isValidNonce(challenge) ||
        !RegExp(r'^[a-z0-9][a-z0-9._-]{1,31}$').hasMatch(platform) ||
        !RegExp(r'^[a-z0-9][a-z0-9._-]{1,31}$').hasMatch(architecture) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint) ||
        DateTime.tryParse(expiresAt) == null) {
      throw StateError('حقول طلب تفعيل الجهاز المحفوظ غير صالحة.');
    }
    return {
      'request_id': requestId,
      'challenge': challenge,
      'challenge_expires_at': expiresAt,
      'device_key': deviceKey,
      'platform': platform,
      'architecture': architecture,
      'key_fingerprint': fingerprint,
      'proof_completed': proofCompleted.toString(),
    };
  }

  Future<PlatformLinkedLicense> _verifyIssuedLicense(
    Map<String, Object?> license,
  ) async {
    final licenseId = license['id'];
    final keyId = license['key_id'];
    final payloadText = license['payload'];
    final signatureText = license['signature'];
    if (licenseId is! String ||
        keyId is! String ||
        payloadText is! String ||
        signatureText is! String) {
      throw const FormatException('بيانات الترخيص الموقّع غير مكتملة.');
    }

    if (!_trustedPublicKeys.containsKey(keyId)) {
      throw const FormatException(
        'مفتاح توقيع الترخيص غير موجود ضمن مفاتيح الثقة المعتمدة في هذا الإصدار.',
      );
    }

    final payload = _decodeCanonicalBase64(payloadText);
    final signature = _decodeCanonicalBase64(signatureText);
    final deviceId = license['device_id'];
    if (deviceId is! String || !_isUuid(deviceId)) {
      throw const FormatException('استجابة ربط الجهاز لا تحتوي على معرّف جهاز صالح.');
    }
    return _verifyLicenseMaterial(
      licenseId: licenseId,
      deviceId: deviceId,
      keyId: keyId,
      payload: payload,
      signature: signature,
    );
  }

  Future<PlatformLinkedLicense> _verifyLicenseMaterial({
    required String licenseId,
    required String deviceId,
    required String keyId,
    required List<int> payload,
    required List<int> signature,
  }) async {
    final publicDer = _trustedPublicKeys[keyId];
    if (signature.length != 64 || publicDer == null ||
        publicDer.length != 44 ||
        !_sameBytes(publicDer.sublist(0, 12), _spkiPrefix)) {
      throw const FormatException(
        'مفتاح توقيع الترخيص غير موثوق أو صيغة التوقيع غير صالحة.',
      );
    }
    final publicKey = SimplePublicKey(
      publicDer.sublist(12),
      type: KeyPairType.ed25519,
    );
    final valid = await _ed25519.verify(
      payload,
      signature: Signature(signature, publicKey: publicKey),
    );
    if (!valid) {
      throw const FormatException('فشل التحقق من توقيع ترخيص Homi.');
    }

    final claims = jsonDecode(utf8.decode(payload));
    if (claims is! Map<String, dynamic> ||
        claims['schema_version'] != 1 ||
        claims['license_id'] != licenseId ||
        (claims['device_id'] != null && claims['device_id'] != deviceId) ||
        claims['key_id'] != keyId ||
        claims['product_id'] is! String ||
        claims['organization_id'] is! String ||
        claims['user_id'] is! String ||
        claims['plan_key'] is! String ||
        claims['entitlement_version'] is! num) {
      throw const FormatException('مطالبات الترخيص الموقّع غير صالحة.');
    }
    if (claims['license_id'] is String) {
      final localIdentity = await _deviceIdentity.loadOrCreate();
      final localFingerprint = crypto.sha256
          .convert(localIdentity.publicKeyDer.sublist(12))
          .toString();
      final deviceFingerprints = claims['device_fingerprints'];
      if (deviceFingerprints is! List ||
          deviceFingerprints.any((value) => value is! String) ||
          !deviceFingerprints.contains(localFingerprint)) {
        throw const FormatException(
          'ملف الترخيص لا يتضمن بصمة مفتاح هذا الجهاز؛ لا يمكن نقله إلى جهاز آخر.',
        );
      }
    } else if (claims['grant_id'] is String && claims['device_id'] != deviceId) {
      throw const FormatException('تصريح العمل دون اتصال لا يخص هذا الجهاز.');
    }
    DateTime? parseOptionalDate(String key) {
      final value = claims[key];
      if (value == null) return null;
      if (value is! String) {
        throw FormatException('قيمة التاريخ $key غير صالحة.');
      }
      final parsed = DateTime.tryParse(value);
      if (parsed == null) {
        throw FormatException('قيمة التاريخ $key غير صالحة.');
      }
      return parsed.toUtc();
    }

    final startsAt = DateTime.tryParse(claims['starts_at'] as String? ?? '');
    final issuedAt = DateTime.tryParse(claims['issued_at'] as String? ?? '');
    final endsAt = parseOptionalDate('ends_at');
    final trialEndsAt = parseOptionalDate('trial_ends_at');
    final subscriptionEndsAt = parseOptionalDate('subscription_ends_at');
    final offlineExpiresAt = parseOptionalDate('offline_expires_at');
    final graceEndsAt = parseOptionalDate('grace_ends_at');
    final planKey = claims['plan_key'] as String;
    final accessPolicy = claims['access_policy'];
    if (startsAt == null ||
        issuedAt == null ||
        startsAt.isAfter(issuedAt.add(const Duration(minutes: 5))) ||
        (endsAt != null && !endsAt.isAfter(startsAt))) {
      throw const FormatException('تواريخ صلاحية الترخيص غير صالحة.');
    }

    final issuedUtc = issuedAt.toUtc();
    if (planKey == 'trial') {
      if (trialEndsAt == null ||
          subscriptionEndsAt != null ||
          graceEndsAt != null ||
          offlineExpiresAt == null ||
          endsAt != trialEndsAt ||
          accessPolicy !=
              'full_until_offline_expiry_or_trial_end_then_read_export' ||
          !offlineExpiresAt.isAfter(issuedUtc) ||
          offlineExpiresAt.isAfter(
            issuedUtc.add(const Duration(days: 7)),
          ) ||
          offlineExpiresAt.isAfter(trialEndsAt)) {
        throw const FormatException('سياسة العمل دون اتصال للتجربة غير صالحة.');
      }
    } else if (planKey == 'monthly' || planKey == 'annual') {
      final expectedGraceEnd = endsAt?.add(const Duration(days: 7));
      if (trialEndsAt != null ||
          subscriptionEndsAt == null ||
          subscriptionEndsAt != endsAt ||
          offlineExpiresAt == null ||
          graceEndsAt == null ||
          graceEndsAt != expectedGraceEnd ||
          offlineExpiresAt != graceEndsAt ||
          accessPolicy !=
              'full_until_subscription_end_then_read_export_until_grace_end') {
        throw const FormatException('سياسة مهلة الاشتراك المدفوع غير صالحة.');
      }
    } else if (planKey == 'lifetime') {
      if (endsAt != null ||
          trialEndsAt != null ||
          subscriptionEndsAt != null ||
          offlineExpiresAt != null ||
          graceEndsAt != null ||
          accessPolicy != 'full_forever') {
        throw const FormatException('سياسة الترخيص الدائم غير صالحة.');
      }
    } else {
      throw const FormatException('نوع خطة الترخيص غير مدعوم.');
    }

    return PlatformLinkedLicense(
      licenseId: licenseId,
      deviceId: deviceId,
      keyId: keyId,
      startsAt: startsAt.toUtc(),
      endsAt: endsAt,
      trialEndsAt: trialEndsAt,
      subscriptionEndsAt: subscriptionEndsAt,
      offlineExpiresAt: offlineExpiresAt,
      graceEndsAt: graceEndsAt,
      accessPolicy: accessPolicy as String,
      planKey: planKey,
      entitlementVersion: (claims['entitlement_version'] as num).toInt(),
      signedPayload: payload,
      signature: signature,
      publicKeyDer: List<int>.unmodifiable(publicDer),
    );
  }

  List<int> _decodeCanonicalBase64(String value) {
    final decoded = base64Decode(value);
    if (base64Encode(decoded) != value) {
      throw const FormatException('ترميز Base64 غير قياسي.');
    }
    return decoded;
  }

  bool _isValidNonce(String value) {
    try {
      final decoded = base64Url.decode(base64Url.normalize(value));
      return decoded.length == 32 &&
          base64UrlEncode(decoded).replaceAll('=', '') == value;
    } on FormatException {
      return false;
    }
  }

  bool _isUuid(String value) =>
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$', caseSensitive: false)
          .hasMatch(value);

  bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}
).hasMatch(supportWhatsApp)) ||
        expiresAt == null ||
        !expiresAt.isAfter(_clock().toUtc())) {
      throw const FormatException('استجابة طلب تفعيل الجهاز من المنصة غير صالحة.');
    }

    await _store.write(_pendingKey, jsonEncode({
      'request_id': requestId,
      'challenge': challenge,
      'challenge_expires_at': expiresAt.toUtc().toIso8601String(),
      'device_key': identity.deviceKey,
      'platform': identity.platform,
      'architecture': identity.architecture,
      'key_fingerprint': fingerprint,
      'support_whatsapp': supportWhatsApp ?? '',
      'proof_completed': false,
    }));
    return PlatformActivationRequest(
      requestId: requestId,
      keyFingerprint: fingerprint,
      platform: identity.platform,
      architecture: identity.architecture,
      challengeExpiresAt: expiresAt.toUtc(),
      supportWhatsApp: supportWhatsApp,
    );
  }

  @override
  Future<PlatformActivationRequest?> readPendingActivationRequest() async {
    final pending = await _readPending();
    if (pending == null) return null;
    return PlatformActivationRequest(
      requestId: pending['request_id']!,
      keyFingerprint: pending['key_fingerprint']!,
      platform: pending['platform']!,
      architecture: pending['architecture']!,
      challengeExpiresAt: DateTime.parse(pending['challenge_expires_at']!).toUtc(),
      proofVerified: pending['proof_completed'] == 'true',
      supportWhatsApp: pending['support_whatsapp']?.isNotEmpty == true
          ? pending['support_whatsapp']
          : null,
    );
  }

  @override
  Future<PlatformDeviceLinkStatus> completePendingActivation() async {
    final pending = await _readPending();
    if (pending == null) {
      throw const PlatformApiException(
        statusCode: 400,
        code: 'ACTIVATION_REQUEST_NOT_CREATED',
        message: 'أنشئ طلب التفعيل أولًا.',
      );
    }
    final identity = await _deviceIdentity.loadOrCreate();
    if (identity.deviceKey != pending['device_key'] ||
        identity.platform != pending['platform'] ||
        identity.architecture != pending['architecture']) {
      await clearPendingLink();
      throw StateError('هوية الجهاز تغيرت؛ أوقف التفعيل وأنشئ طلبًا جديدًا.');
    }

    if (pending['proof_completed'] != 'true') {
      final challengeExpiresAt = DateTime.parse(pending['challenge_expires_at']!).toUtc();
      if (!challengeExpiresAt.isAfter(_clock().toUtc())) {
        await clearPendingLink();
        throw const PlatformApiException(
          statusCode: 410,
          code: 'ACTIVATION_CHALLENGE_EXPIRED',
          message: 'انتهت صلاحية إثبات الجهاز. أنشئ طلب تفعيل جديدًا.',
        );
      }
      final requestId = pending['request_id']!;
      final challenge = pending['challenge']!;
      final proofMessage = [
        'HOMI_DEVICE_PROOF_V1',
        requestId.toLowerCase(),
        'homi-grocery',
        identity.platform,
        identity.architecture,
        challenge,
      ].join('\n');
      final signature = await _deviceIdentity.signMessage(proofMessage);
      await _api.postJson(
        '/api/v1/public/activation-requests/$requestId/proof',
        body: {'challenge': challenge, 'signature': signature},
      );
      pending['proof_completed'] = 'true';
      await _store.write(_pendingKey, jsonEncode(pending));
    }

    final requestId = pending['request_id']!;
    final status = await _api.getJson(
      '/api/v1/public/activation-requests/$requestId/status',
    );
    final requestStatus = status['status'];
    if (requestStatus == 'proof_verified') {
      return PlatformDeviceLinkStatus.waitingForAdmin;
    }
    if (requestStatus == 'rejected' || requestStatus == 'cancelled' ||
        requestStatus == 'expired') {
      throw PlatformApiException(
        statusCode: 409,
        code: 'ACTIVATION_REQUEST_${requestStatus.toString().toUpperCase()}',
        message: 'طلب التفعيل ${requestStatus == 'rejected' ? 'مرفوض' : 'غير صالح'}؛ راجع إدارة Homi.',
      );
    }
    if (requestStatus != 'approved' || status['license'] is! Map) {
      return PlatformDeviceLinkStatus.licensePending;
    }
    final license = Map<String, Object?>.from(status['license'] as Map);
    if (license['status'] != 'active') {
      return PlatformDeviceLinkStatus.licensePending;
    }
    final verified = await _verifyIssuedLicense(license);
    await _store.write(_licenseKey, jsonEncode({
      'license_id': verified.licenseId,
      'device_id': verified.deviceId,
      'key_id': verified.keyId,
      'starts_at': verified.startsAt.toUtc().toIso8601String(),
      'ends_at': verified.endsAt?.toUtc().toIso8601String(),
      'plan_key': verified.planKey,
      'entitlement_version': verified.entitlementVersion,
      'payload': base64Encode(verified.signedPayload),
      'signature': base64Encode(verified.signature),
    }));
    await clearPendingLink();
    return PlatformDeviceLinkStatus.linked;
  }

  @override
  Future<PlatformLinkedLicense?> readLinkedLicense() async {
    final stored = await _store.read(_licenseKey);
    if (stored == null || stored.isEmpty) return null;
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException();
      }
      final license = Map<String, Object?>.from(decoded);
      final payload = base64Decode(license['payload'] as String);
      final signature = base64Decode(license['signature'] as String);
      final deviceId = license['device_id'];
      if (deviceId is! String || !_isUuid(deviceId)) {
        throw const FormatException('هوية الجهاز المرتبطة بالترخيص غير صالحة.');
      }
      return _verifyLicenseMaterial(
        licenseId: license['license_id'] as String,
        deviceId: deviceId,
        keyId: license['key_id'] as String,
        payload: payload,
        signature: signature,
      );
    } on Object {
      // لا نعيد إنشاء هوية أو ترخيص عند تلف السجل؛ نوقف التشغيل الآمن.
      rethrow;
    }
  }

  @override
  Future<PlatformLinkedLicense?> refreshOfflineGrant() async {
    final license = await readLinkedLicense();
    if (license == null) return null;

    try {
      final challenge = await _api.postJson(
        '/api/v1/devices/${license.deviceId}/challenges',
        body: {
          'license_id': license.licenseId,
          'purpose': 'offline_grant',
        },
      );
      final challengeId = challenge['challenge_id'];
      final nonce = challenge['nonce'];
      final expiresAt = DateTime.tryParse(challenge['expires_at'] as String? ?? '');
      if (challengeId is! String ||
          !_isUuid(challengeId) ||
          nonce is! String ||
          !_isValidNonce(nonce) ||
          expiresAt == null ||
          !expiresAt.isAfter(_clock().toUtc())) {
        throw const FormatException('تحدي تجديد تصريح العمل دون اتصال غير صالح.');
      }

      final deviceSignature = await _deviceIdentity.signNonce(nonce);
      final response = await _api.postJson(
        '/api/v1/licenses/${license.licenseId}/offline-grants',
        body: {
          'challenge_id': challengeId,
          'nonce': nonce,
          'signature': deviceSignature,
        },
      );
      final keyId = response['key_id'];
      final payloadText = response['payload'];
      final signatureText = response['signature'];
      if (keyId is! String ||
          payloadText is! String ||
          signatureText is! String) {
        throw const FormatException('استجابة تصريح العمل دون اتصال غير مكتملة.');
      }
      final verified = await _verifyLicenseMaterial(
        licenseId: license.licenseId,
        deviceId: license.deviceId,
        keyId: keyId,
        payload: _decodeCanonicalBase64(payloadText),
        signature: _decodeCanonicalBase64(signatureText),
      );
      await _store.write(_offlineGrantKey, jsonEncode({
        'license_id': verified.licenseId,
        'device_id': verified.deviceId,
        'key_id': verified.keyId,
        'payload': base64Encode(verified.signedPayload),
        'signature': base64Encode(verified.signature),
      }));
      return verified;
    } on PlatformApiException catch (error) {
      if (error.code == 'DEVICE_NOT_LINKED' ||
          error.code == 'DEVICE_PROOF_INVALID' ||
          error.code == 'LICENSE_REVOKED' ||
          error.code == 'LICENSE_SUSPENDED' ||
          error.code == 'ACCOUNT_INACTIVE') {
        await _store.write(_offlineGrantKey, '');
        return null;
      }
      return readOfflineGrant();
    } on Object {
      // عند انقطاع الشبكة نستخدم آخر تصريح موقّع محفوظ، ولا نمدد صلاحيته محليًا.
      return readOfflineGrant();
    }
  }

  @override
  Future<PlatformLinkedLicense?> readOfflineGrant() async {
    final stored = await _store.read(_offlineGrantKey);
    if (stored == null || stored.isEmpty) return null;
    final linkedLicense = await readLinkedLicense();
    if (linkedLicense == null) return null;
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('سجل تصريح العمل دون اتصال تالف.');
    }
    final grant = Map<String, Object?>.from(decoded);
    if (grant['license_id'] != linkedLicense.licenseId ||
        grant['device_id'] != linkedLicense.deviceId) {
      throw const FormatException('تصريح العمل دون اتصال لا يطابق الجهاز والترخيص المرتبطين.');
    }
    final keyId = grant['key_id'];
    final payloadText = grant['payload'];
    final signatureText = grant['signature'];
    if (keyId is! String || payloadText is! String || signatureText is! String) {
      throw const FormatException('بيانات تصريح العمل دون اتصال غير مكتملة.');
    }
    return _verifyLicenseMaterial(
      licenseId: linkedLicense.licenseId,
      deviceId: linkedLicense.deviceId,
      keyId: keyId,
      payload: _decodeCanonicalBase64(payloadText),
      signature: _decodeCanonicalBase64(signatureText),
    );
  }

  Future<void> clearPendingLink() => _store.write(_pendingKey, '');

  Future<Map<String, String>?> _readPending() async {
    final stored = await _store.read(_pendingKey);
    if (stored == null || stored.isEmpty) return null;
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('سجل طلب تفعيل الجهاز تالف.');
    }
    final requestId = decoded['request_id'];
    final challenge = decoded['challenge'];
    final expiresAt = decoded['challenge_expires_at'];
    final deviceKey = decoded['device_key'];
    final platform = decoded['platform'];
    final architecture = decoded['architecture'];
    final fingerprint = decoded['key_fingerprint'];
    final proofCompleted = decoded['proof_completed'];
    final supportWhatsApp = decoded['support_whatsapp'];
    if (requestId is! String ||
        challenge is! String ||
        expiresAt is! String ||
        deviceKey is! String ||
        platform is! String ||
        architecture is! String ||
        fingerprint is! String ||
        proofCompleted is! bool ||
        (supportWhatsApp != null && supportWhatsApp is! String) ||
        !_isUuid(requestId) ||
        !_isUuid(deviceKey) ||
        !_isValidNonce(challenge) ||
        !RegExp(r'^[a-z0-9][a-z0-9._-]{1,31}$').hasMatch(platform) ||
        !RegExp(r'^[a-z0-9][a-z0-9._-]{1,31}$').hasMatch(architecture) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint) ||
        DateTime.tryParse(expiresAt) == null) {
      throw StateError('حقول طلب تفعيل الجهاز المحفوظ غير صالحة.');
    }
    return {
      'request_id': requestId,
      'challenge': challenge,
      'challenge_expires_at': expiresAt,
      'device_key': deviceKey,
      'platform': platform,
      'architecture': architecture,
      'key_fingerprint': fingerprint,
      'proof_completed': proofCompleted.toString(),
    };
  }

  Future<PlatformLinkedLicense> _verifyIssuedLicense(
    Map<String, Object?> license,
  ) async {
    final licenseId = license['id'];
    final keyId = license['key_id'];
    final payloadText = license['payload'];
    final signatureText = license['signature'];
    if (licenseId is! String ||
        keyId is! String ||
        payloadText is! String ||
        signatureText is! String) {
      throw const FormatException('بيانات الترخيص الموقّع غير مكتملة.');
    }

    if (!_trustedPublicKeys.containsKey(keyId)) {
      throw const FormatException(
        'مفتاح توقيع الترخيص غير موجود ضمن مفاتيح الثقة المعتمدة في هذا الإصدار.',
      );
    }

    final payload = _decodeCanonicalBase64(payloadText);
    final signature = _decodeCanonicalBase64(signatureText);
    final deviceId = license['device_id'];
    if (deviceId is! String || !_isUuid(deviceId)) {
      throw const FormatException('استجابة ربط الجهاز لا تحتوي على معرّف جهاز صالح.');
    }
    return _verifyLicenseMaterial(
      licenseId: licenseId,
      deviceId: deviceId,
      keyId: keyId,
      payload: payload,
      signature: signature,
    );
  }

  Future<PlatformLinkedLicense> _verifyLicenseMaterial({
    required String licenseId,
    required String deviceId,
    required String keyId,
    required List<int> payload,
    required List<int> signature,
  }) async {
    final publicDer = _trustedPublicKeys[keyId];
    if (signature.length != 64 || publicDer == null ||
        publicDer.length != 44 ||
        !_sameBytes(publicDer.sublist(0, 12), _spkiPrefix)) {
      throw const FormatException(
        'مفتاح توقيع الترخيص غير موثوق أو صيغة التوقيع غير صالحة.',
      );
    }
    final publicKey = SimplePublicKey(
      publicDer.sublist(12),
      type: KeyPairType.ed25519,
    );
    final valid = await _ed25519.verify(
      payload,
      signature: Signature(signature, publicKey: publicKey),
    );
    if (!valid) {
      throw const FormatException('فشل التحقق من توقيع ترخيص Homi.');
    }

    final claims = jsonDecode(utf8.decode(payload));
    if (claims is! Map<String, dynamic> ||
        claims['schema_version'] != 1 ||
        claims['license_id'] != licenseId ||
        (claims['device_id'] != null && claims['device_id'] != deviceId) ||
        claims['key_id'] != keyId ||
        claims['product_id'] is! String ||
        claims['organization_id'] is! String ||
        claims['user_id'] is! String ||
        claims['plan_key'] is! String ||
        claims['entitlement_version'] is! num) {
      throw const FormatException('مطالبات الترخيص الموقّع غير صالحة.');
    }
    if (claims['license_id'] is String) {
      final localIdentity = await _deviceIdentity.loadOrCreate();
      final localFingerprint = crypto.sha256
          .convert(localIdentity.publicKeyDer.sublist(12))
          .toString();
      final deviceFingerprints = claims['device_fingerprints'];
      if (deviceFingerprints is! List ||
          deviceFingerprints.any((value) => value is! String) ||
          !deviceFingerprints.contains(localFingerprint)) {
        throw const FormatException(
          'ملف الترخيص لا يتضمن بصمة مفتاح هذا الجهاز؛ لا يمكن نقله إلى جهاز آخر.',
        );
      }
    } else if (claims['grant_id'] is String && claims['device_id'] != deviceId) {
      throw const FormatException('تصريح العمل دون اتصال لا يخص هذا الجهاز.');
    }
    DateTime? parseOptionalDate(String key) {
      final value = claims[key];
      if (value == null) return null;
      if (value is! String) {
        throw FormatException('قيمة التاريخ $key غير صالحة.');
      }
      final parsed = DateTime.tryParse(value);
      if (parsed == null) {
        throw FormatException('قيمة التاريخ $key غير صالحة.');
      }
      return parsed.toUtc();
    }

    final startsAt = DateTime.tryParse(claims['starts_at'] as String? ?? '');
    final issuedAt = DateTime.tryParse(claims['issued_at'] as String? ?? '');
    final endsAt = parseOptionalDate('ends_at');
    final trialEndsAt = parseOptionalDate('trial_ends_at');
    final subscriptionEndsAt = parseOptionalDate('subscription_ends_at');
    final offlineExpiresAt = parseOptionalDate('offline_expires_at');
    final graceEndsAt = parseOptionalDate('grace_ends_at');
    final planKey = claims['plan_key'] as String;
    final accessPolicy = claims['access_policy'];
    if (startsAt == null ||
        issuedAt == null ||
        startsAt.isAfter(issuedAt.add(const Duration(minutes: 5))) ||
        (endsAt != null && !endsAt.isAfter(startsAt))) {
      throw const FormatException('تواريخ صلاحية الترخيص غير صالحة.');
    }

    final issuedUtc = issuedAt.toUtc();
    if (planKey == 'trial') {
      if (trialEndsAt == null ||
          subscriptionEndsAt != null ||
          graceEndsAt != null ||
          offlineExpiresAt == null ||
          endsAt != trialEndsAt ||
          accessPolicy !=
              'full_until_offline_expiry_or_trial_end_then_read_export' ||
          !offlineExpiresAt.isAfter(issuedUtc) ||
          offlineExpiresAt.isAfter(
            issuedUtc.add(const Duration(days: 7)),
          ) ||
          offlineExpiresAt.isAfter(trialEndsAt)) {
        throw const FormatException('سياسة العمل دون اتصال للتجربة غير صالحة.');
      }
    } else if (planKey == 'monthly' || planKey == 'annual') {
      final expectedGraceEnd = endsAt?.add(const Duration(days: 7));
      if (trialEndsAt != null ||
          subscriptionEndsAt == null ||
          subscriptionEndsAt != endsAt ||
          offlineExpiresAt == null ||
          graceEndsAt == null ||
          graceEndsAt != expectedGraceEnd ||
          offlineExpiresAt != graceEndsAt ||
          accessPolicy !=
              'full_until_subscription_end_then_read_export_until_grace_end') {
        throw const FormatException('سياسة مهلة الاشتراك المدفوع غير صالحة.');
      }
    } else if (planKey == 'lifetime') {
      if (endsAt != null ||
          trialEndsAt != null ||
          subscriptionEndsAt != null ||
          offlineExpiresAt != null ||
          graceEndsAt != null ||
          accessPolicy != 'full_forever') {
        throw const FormatException('سياسة الترخيص الدائم غير صالحة.');
      }
    } else {
      throw const FormatException('نوع خطة الترخيص غير مدعوم.');
    }

    return PlatformLinkedLicense(
      licenseId: licenseId,
      deviceId: deviceId,
      keyId: keyId,
      startsAt: startsAt.toUtc(),
      endsAt: endsAt,
      trialEndsAt: trialEndsAt,
      subscriptionEndsAt: subscriptionEndsAt,
      offlineExpiresAt: offlineExpiresAt,
      graceEndsAt: graceEndsAt,
      accessPolicy: accessPolicy as String,
      planKey: planKey,
      entitlementVersion: (claims['entitlement_version'] as num).toInt(),
      signedPayload: payload,
      signature: signature,
      publicKeyDer: List<int>.unmodifiable(publicDer),
    );
  }

  List<int> _decodeCanonicalBase64(String value) {
    final decoded = base64Decode(value);
    if (base64Encode(decoded) != value) {
      throw const FormatException('ترميز Base64 غير قياسي.');
    }
    return decoded;
  }

  bool _isValidNonce(String value) {
    try {
      final decoded = base64Url.decode(base64Url.normalize(value));
      return decoded.length == 32 &&
          base64UrlEncode(decoded).replaceAll('=', '') == value;
    } on FormatException {
      return false;
    }
  }

  bool _isUuid(String value) =>
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$', caseSensitive: false)
          .hasMatch(value);

  bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}
).hasMatch(supportWhatsAppValue)
        ? supportWhatsAppValue
        : null;
    final expiresAt = expiresAtText is String ? DateTime.tryParse(expiresAtText) : null;
    if (requestId is! String ||
        !_isUuid(requestId) ||
        challenge is! String ||
        !_isValidNonce(challenge) ||
        fingerprint is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint) ||
        expiresAt == null ||
        !expiresAt.isAfter(_clock().toUtc())) {
      throw const FormatException('استجابة طلب تفعيل الجهاز من المنصة غير صالحة.');
    }

    await _store.write(_pendingKey, jsonEncode({
      'request_id': requestId,
      'challenge': challenge,
      'challenge_expires_at': expiresAt.toUtc().toIso8601String(),
      'device_key': identity.deviceKey,
      'platform': identity.platform,
      'architecture': identity.architecture,
      'key_fingerprint': fingerprint,
      'proof_completed': false,
    }));
    return PlatformActivationRequest(
      requestId: requestId,
      keyFingerprint: fingerprint,
      platform: identity.platform,
      architecture: identity.architecture,
      challengeExpiresAt: expiresAt.toUtc(),
    );
  }

  @override
  Future<PlatformActivationRequest?> readPendingActivationRequest() async {
    final pending = await _readPending();
    if (pending == null) return null;
    return PlatformActivationRequest(
      requestId: pending['request_id']!,
      keyFingerprint: pending['key_fingerprint']!,
      platform: pending['platform']!,
      architecture: pending['architecture']!,
      challengeExpiresAt: DateTime.parse(pending['challenge_expires_at']!).toUtc(),
      proofVerified: pending['proof_completed'] == 'true',
    );
  }

  @override
  Future<PlatformDeviceLinkStatus> completePendingActivation() async {
    final pending = await _readPending();
    if (pending == null) {
      throw const PlatformApiException(
        statusCode: 400,
        code: 'ACTIVATION_REQUEST_NOT_CREATED',
        message: 'أنشئ طلب التفعيل أولًا.',
      );
    }
    final identity = await _deviceIdentity.loadOrCreate();
    if (identity.deviceKey != pending['device_key'] ||
        identity.platform != pending['platform'] ||
        identity.architecture != pending['architecture']) {
      await clearPendingLink();
      throw StateError('هوية الجهاز تغيرت؛ أوقف التفعيل وأنشئ طلبًا جديدًا.');
    }

    if (pending['proof_completed'] != 'true') {
      final challengeExpiresAt = DateTime.parse(pending['challenge_expires_at']!).toUtc();
      if (!challengeExpiresAt.isAfter(_clock().toUtc())) {
        await clearPendingLink();
        throw const PlatformApiException(
          statusCode: 410,
          code: 'ACTIVATION_CHALLENGE_EXPIRED',
          message: 'انتهت صلاحية إثبات الجهاز. أنشئ طلب تفعيل جديدًا.',
        );
      }
      final requestId = pending['request_id']!;
      final challenge = pending['challenge']!;
      final proofMessage = [
        'HOMI_DEVICE_PROOF_V1',
        requestId.toLowerCase(),
        'homi-grocery',
        identity.platform,
        identity.architecture,
        challenge,
      ].join('\n');
      final signature = await _deviceIdentity.signMessage(proofMessage);
      await _api.postJson(
        '/api/v1/public/activation-requests/$requestId/proof',
        body: {'challenge': challenge, 'signature': signature},
      );
      pending['proof_completed'] = 'true';
      await _store.write(_pendingKey, jsonEncode(pending));
    }

    final requestId = pending['request_id']!;
    final status = await _api.getJson(
      '/api/v1/public/activation-requests/$requestId/status',
    );
    final requestStatus = status['status'];
    if (requestStatus == 'proof_verified') {
      return PlatformDeviceLinkStatus.waitingForAdmin;
    }
    if (requestStatus == 'rejected' || requestStatus == 'cancelled' ||
        requestStatus == 'expired') {
      throw PlatformApiException(
        statusCode: 409,
        code: 'ACTIVATION_REQUEST_${requestStatus.toString().toUpperCase()}',
        message: 'طلب التفعيل ${requestStatus == 'rejected' ? 'مرفوض' : 'غير صالح'}؛ راجع إدارة Homi.',
      );
    }
    if (requestStatus != 'approved' || status['license'] is! Map) {
      return PlatformDeviceLinkStatus.licensePending;
    }
    final license = Map<String, Object?>.from(status['license'] as Map);
    if (license['status'] != 'active') {
      return PlatformDeviceLinkStatus.licensePending;
    }
    final verified = await _verifyIssuedLicense(license);
    await _store.write(_licenseKey, jsonEncode({
      'license_id': verified.licenseId,
      'device_id': verified.deviceId,
      'key_id': verified.keyId,
      'starts_at': verified.startsAt.toUtc().toIso8601String(),
      'ends_at': verified.endsAt?.toUtc().toIso8601String(),
      'plan_key': verified.planKey,
      'entitlement_version': verified.entitlementVersion,
      'payload': base64Encode(verified.signedPayload),
      'signature': base64Encode(verified.signature),
    }));
    await clearPendingLink();
    return PlatformDeviceLinkStatus.linked;
  }

  @override
  Future<PlatformLinkedLicense?> readLinkedLicense() async {
    final stored = await _store.read(_licenseKey);
    if (stored == null || stored.isEmpty) return null;
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException();
      }
      final license = Map<String, Object?>.from(decoded);
      final payload = base64Decode(license['payload'] as String);
      final signature = base64Decode(license['signature'] as String);
      final deviceId = license['device_id'];
      if (deviceId is! String || !_isUuid(deviceId)) {
        throw const FormatException('هوية الجهاز المرتبطة بالترخيص غير صالحة.');
      }
      return _verifyLicenseMaterial(
        licenseId: license['license_id'] as String,
        deviceId: deviceId,
        keyId: license['key_id'] as String,
        payload: payload,
        signature: signature,
      );
    } on Object {
      // لا نعيد إنشاء هوية أو ترخيص عند تلف السجل؛ نوقف التشغيل الآمن.
      rethrow;
    }
  }

  @override
  Future<PlatformLinkedLicense?> refreshOfflineGrant() async {
    final license = await readLinkedLicense();
    if (license == null) return null;

    try {
      final challenge = await _api.postJson(
        '/api/v1/devices/${license.deviceId}/challenges',
        body: {
          'license_id': license.licenseId,
          'purpose': 'offline_grant',
        },
      );
      final challengeId = challenge['challenge_id'];
      final nonce = challenge['nonce'];
      final expiresAt = DateTime.tryParse(challenge['expires_at'] as String? ?? '');
      if (challengeId is! String ||
          !_isUuid(challengeId) ||
          nonce is! String ||
          !_isValidNonce(nonce) ||
          expiresAt == null ||
          !expiresAt.isAfter(_clock().toUtc())) {
        throw const FormatException('تحدي تجديد تصريح العمل دون اتصال غير صالح.');
      }

      final deviceSignature = await _deviceIdentity.signNonce(nonce);
      final response = await _api.postJson(
        '/api/v1/licenses/${license.licenseId}/offline-grants',
        body: {
          'challenge_id': challengeId,
          'nonce': nonce,
          'signature': deviceSignature,
        },
      );
      final keyId = response['key_id'];
      final payloadText = response['payload'];
      final signatureText = response['signature'];
      if (keyId is! String ||
          payloadText is! String ||
          signatureText is! String) {
        throw const FormatException('استجابة تصريح العمل دون اتصال غير مكتملة.');
      }
      final verified = await _verifyLicenseMaterial(
        licenseId: license.licenseId,
        deviceId: license.deviceId,
        keyId: keyId,
        payload: _decodeCanonicalBase64(payloadText),
        signature: _decodeCanonicalBase64(signatureText),
      );
      await _store.write(_offlineGrantKey, jsonEncode({
        'license_id': verified.licenseId,
        'device_id': verified.deviceId,
        'key_id': verified.keyId,
        'payload': base64Encode(verified.signedPayload),
        'signature': base64Encode(verified.signature),
      }));
      return verified;
    } on PlatformApiException catch (error) {
      if (error.code == 'DEVICE_NOT_LINKED' ||
          error.code == 'DEVICE_PROOF_INVALID' ||
          error.code == 'LICENSE_REVOKED' ||
          error.code == 'LICENSE_SUSPENDED' ||
          error.code == 'ACCOUNT_INACTIVE') {
        await _store.write(_offlineGrantKey, '');
        return null;
      }
      return readOfflineGrant();
    } on Object {
      // عند انقطاع الشبكة نستخدم آخر تصريح موقّع محفوظ، ولا نمدد صلاحيته محليًا.
      return readOfflineGrant();
    }
  }

  @override
  Future<PlatformLinkedLicense?> readOfflineGrant() async {
    final stored = await _store.read(_offlineGrantKey);
    if (stored == null || stored.isEmpty) return null;
    final linkedLicense = await readLinkedLicense();
    if (linkedLicense == null) return null;
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('سجل تصريح العمل دون اتصال تالف.');
    }
    final grant = Map<String, Object?>.from(decoded);
    if (grant['license_id'] != linkedLicense.licenseId ||
        grant['device_id'] != linkedLicense.deviceId) {
      throw const FormatException('تصريح العمل دون اتصال لا يطابق الجهاز والترخيص المرتبطين.');
    }
    final keyId = grant['key_id'];
    final payloadText = grant['payload'];
    final signatureText = grant['signature'];
    if (keyId is! String || payloadText is! String || signatureText is! String) {
      throw const FormatException('بيانات تصريح العمل دون اتصال غير مكتملة.');
    }
    return _verifyLicenseMaterial(
      licenseId: linkedLicense.licenseId,
      deviceId: linkedLicense.deviceId,
      keyId: keyId,
      payload: _decodeCanonicalBase64(payloadText),
      signature: _decodeCanonicalBase64(signatureText),
    );
  }

  Future<void> clearPendingLink() => _store.write(_pendingKey, '');

  Future<Map<String, String>?> _readPending() async {
    final stored = await _store.read(_pendingKey);
    if (stored == null || stored.isEmpty) return null;
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('سجل طلب تفعيل الجهاز تالف.');
    }
    final requestId = decoded['request_id'];
    final challenge = decoded['challenge'];
    final expiresAt = decoded['challenge_expires_at'];
    final deviceKey = decoded['device_key'];
    final platform = decoded['platform'];
    final architecture = decoded['architecture'];
    final fingerprint = decoded['key_fingerprint'];
    final proofCompleted = decoded['proof_completed'];
    if (requestId is! String ||
        challenge is! String ||
        expiresAt is! String ||
        deviceKey is! String ||
        platform is! String ||
        architecture is! String ||
        fingerprint is! String ||
        proofCompleted is! bool ||
        !_isUuid(requestId) ||
        !_isUuid(deviceKey) ||
        !_isValidNonce(challenge) ||
        !RegExp(r'^[a-z0-9][a-z0-9._-]{1,31}$').hasMatch(platform) ||
        !RegExp(r'^[a-z0-9][a-z0-9._-]{1,31}$').hasMatch(architecture) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint) ||
        DateTime.tryParse(expiresAt) == null) {
      throw StateError('حقول طلب تفعيل الجهاز المحفوظ غير صالحة.');
    }
    return {
      'request_id': requestId,
      'challenge': challenge,
      'challenge_expires_at': expiresAt,
      'device_key': deviceKey,
      'platform': platform,
      'architecture': architecture,
      'key_fingerprint': fingerprint,
      'proof_completed': proofCompleted.toString(),
    };
  }

  Future<PlatformLinkedLicense> _verifyIssuedLicense(
    Map<String, Object?> license,
  ) async {
    final licenseId = license['id'];
    final keyId = license['key_id'];
    final payloadText = license['payload'];
    final signatureText = license['signature'];
    if (licenseId is! String ||
        keyId is! String ||
        payloadText is! String ||
        signatureText is! String) {
      throw const FormatException('بيانات الترخيص الموقّع غير مكتملة.');
    }

    if (!_trustedPublicKeys.containsKey(keyId)) {
      throw const FormatException(
        'مفتاح توقيع الترخيص غير موجود ضمن مفاتيح الثقة المعتمدة في هذا الإصدار.',
      );
    }

    final payload = _decodeCanonicalBase64(payloadText);
    final signature = _decodeCanonicalBase64(signatureText);
    final deviceId = license['device_id'];
    if (deviceId is! String || !_isUuid(deviceId)) {
      throw const FormatException('استجابة ربط الجهاز لا تحتوي على معرّف جهاز صالح.');
    }
    return _verifyLicenseMaterial(
      licenseId: licenseId,
      deviceId: deviceId,
      keyId: keyId,
      payload: payload,
      signature: signature,
    );
  }

  Future<PlatformLinkedLicense> _verifyLicenseMaterial({
    required String licenseId,
    required String deviceId,
    required String keyId,
    required List<int> payload,
    required List<int> signature,
  }) async {
    final publicDer = _trustedPublicKeys[keyId];
    if (signature.length != 64 || publicDer == null ||
        publicDer.length != 44 ||
        !_sameBytes(publicDer.sublist(0, 12), _spkiPrefix)) {
      throw const FormatException(
        'مفتاح توقيع الترخيص غير موثوق أو صيغة التوقيع غير صالحة.',
      );
    }
    final publicKey = SimplePublicKey(
      publicDer.sublist(12),
      type: KeyPairType.ed25519,
    );
    final valid = await _ed25519.verify(
      payload,
      signature: Signature(signature, publicKey: publicKey),
    );
    if (!valid) {
      throw const FormatException('فشل التحقق من توقيع ترخيص Homi.');
    }

    final claims = jsonDecode(utf8.decode(payload));
    if (claims is! Map<String, dynamic> ||
        claims['schema_version'] != 1 ||
        claims['license_id'] != licenseId ||
        (claims['device_id'] != null && claims['device_id'] != deviceId) ||
        claims['key_id'] != keyId ||
        claims['product_id'] is! String ||
        claims['organization_id'] is! String ||
        claims['user_id'] is! String ||
        claims['plan_key'] is! String ||
        claims['entitlement_version'] is! num) {
      throw const FormatException('مطالبات الترخيص الموقّع غير صالحة.');
    }
    if (claims['license_id'] is String) {
      final localIdentity = await _deviceIdentity.loadOrCreate();
      final localFingerprint = crypto.sha256
          .convert(localIdentity.publicKeyDer.sublist(12))
          .toString();
      final deviceFingerprints = claims['device_fingerprints'];
      if (deviceFingerprints is! List ||
          deviceFingerprints.any((value) => value is! String) ||
          !deviceFingerprints.contains(localFingerprint)) {
        throw const FormatException(
          'ملف الترخيص لا يتضمن بصمة مفتاح هذا الجهاز؛ لا يمكن نقله إلى جهاز آخر.',
        );
      }
    } else if (claims['grant_id'] is String && claims['device_id'] != deviceId) {
      throw const FormatException('تصريح العمل دون اتصال لا يخص هذا الجهاز.');
    }
    DateTime? parseOptionalDate(String key) {
      final value = claims[key];
      if (value == null) return null;
      if (value is! String) {
        throw FormatException('قيمة التاريخ $key غير صالحة.');
      }
      final parsed = DateTime.tryParse(value);
      if (parsed == null) {
        throw FormatException('قيمة التاريخ $key غير صالحة.');
      }
      return parsed.toUtc();
    }

    final startsAt = DateTime.tryParse(claims['starts_at'] as String? ?? '');
    final issuedAt = DateTime.tryParse(claims['issued_at'] as String? ?? '');
    final endsAt = parseOptionalDate('ends_at');
    final trialEndsAt = parseOptionalDate('trial_ends_at');
    final subscriptionEndsAt = parseOptionalDate('subscription_ends_at');
    final offlineExpiresAt = parseOptionalDate('offline_expires_at');
    final graceEndsAt = parseOptionalDate('grace_ends_at');
    final planKey = claims['plan_key'] as String;
    final accessPolicy = claims['access_policy'];
    if (startsAt == null ||
        issuedAt == null ||
        startsAt.isAfter(issuedAt.add(const Duration(minutes: 5))) ||
        (endsAt != null && !endsAt.isAfter(startsAt))) {
      throw const FormatException('تواريخ صلاحية الترخيص غير صالحة.');
    }

    final issuedUtc = issuedAt.toUtc();
    if (planKey == 'trial') {
      if (trialEndsAt == null ||
          subscriptionEndsAt != null ||
          graceEndsAt != null ||
          offlineExpiresAt == null ||
          endsAt != trialEndsAt ||
          accessPolicy !=
              'full_until_offline_expiry_or_trial_end_then_read_export' ||
          !offlineExpiresAt.isAfter(issuedUtc) ||
          offlineExpiresAt.isAfter(
            issuedUtc.add(const Duration(days: 7)),
          ) ||
          offlineExpiresAt.isAfter(trialEndsAt)) {
        throw const FormatException('سياسة العمل دون اتصال للتجربة غير صالحة.');
      }
    } else if (planKey == 'monthly' || planKey == 'annual') {
      final expectedGraceEnd = endsAt?.add(const Duration(days: 7));
      if (trialEndsAt != null ||
          subscriptionEndsAt == null ||
          subscriptionEndsAt != endsAt ||
          offlineExpiresAt == null ||
          graceEndsAt == null ||
          graceEndsAt != expectedGraceEnd ||
          offlineExpiresAt != graceEndsAt ||
          accessPolicy !=
              'full_until_subscription_end_then_read_export_until_grace_end') {
        throw const FormatException('سياسة مهلة الاشتراك المدفوع غير صالحة.');
      }
    } else if (planKey == 'lifetime') {
      if (endsAt != null ||
          trialEndsAt != null ||
          subscriptionEndsAt != null ||
          offlineExpiresAt != null ||
          graceEndsAt != null ||
          accessPolicy != 'full_forever') {
        throw const FormatException('سياسة الترخيص الدائم غير صالحة.');
      }
    } else {
      throw const FormatException('نوع خطة الترخيص غير مدعوم.');
    }

    return PlatformLinkedLicense(
      licenseId: licenseId,
      deviceId: deviceId,
      keyId: keyId,
      startsAt: startsAt.toUtc(),
      endsAt: endsAt,
      trialEndsAt: trialEndsAt,
      subscriptionEndsAt: subscriptionEndsAt,
      offlineExpiresAt: offlineExpiresAt,
      graceEndsAt: graceEndsAt,
      accessPolicy: accessPolicy as String,
      planKey: planKey,
      entitlementVersion: (claims['entitlement_version'] as num).toInt(),
      signedPayload: payload,
      signature: signature,
      publicKeyDer: List<int>.unmodifiable(publicDer),
    );
  }

  List<int> _decodeCanonicalBase64(String value) {
    final decoded = base64Decode(value);
    if (base64Encode(decoded) != value) {
      throw const FormatException('ترميز Base64 غير قياسي.');
    }
    return decoded;
  }

  bool _isValidNonce(String value) {
    try {
      final decoded = base64Url.decode(base64Url.normalize(value));
      return decoded.length == 32 &&
          base64UrlEncode(decoded).replaceAll('=', '') == value;
    } on FormatException {
      return false;
    }
  }

  bool _isUuid(String value) =>
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$', caseSensitive: false)
          .hasMatch(value);

  bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}
