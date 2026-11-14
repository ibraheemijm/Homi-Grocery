// التحقق من سلسلة الثقة لمفاتيح توقيع Homi وحفظ آخر Keyset موثوق.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'platform_device_identity.dart';

class TrustedPlatformSigningKey {
  const TrustedPlatformSigningKey({
    required this.keyId,
    required this.purpose,
    required this.publicKey,
    required this.status,
    required this.notBefore,
    required this.notAfter,
  });

  final String keyId;
  final String purpose;
  final SimplePublicKey publicKey;
  final String status;
  final DateTime notBefore;
  final DateTime notAfter;
}

class VerifiedPlatformKeyset {
  const VerifiedPlatformKeyset({
    required this.version,
    required this.issuedAt,
    required this.expiresAt,
    required this.keys,
    required this.signedEnvelope,
  });

  final int version;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final List<TrustedPlatformSigningKey> keys;

  /// الغلاف الأصلي بعد نجاح التحقق، لحفظه واستعادته دون إعادة تشكيل payload.
  final Map<String, Object?> signedEnvelope;

  TrustedPlatformSigningKey keyForVerification({
    required String keyId,
    required String purpose,
    required DateTime at,
  }) {
    final matches = keys.where((key) =>
        key.keyId == keyId &&
        key.purpose == purpose &&
        key.status != 'revoked' &&
        !at.isBefore(key.notBefore) &&
        !at.isAfter(key.notAfter));
    if (matches.length != 1) {
      throw const FormatException(
        'لا يوجد مفتاح توقيع موثوق وصالح لهذا الغرض.',
      );
    }
    return matches.single;
  }
}

/// Root key بصيغة Ed25519 raw (32 bytes) وBase64.
/// لا تضع المفتاح الخاص المقابل في التطبيق أو المستودع.
class PlatformSigningTrust {
  PlatformSigningTrust({
    required PlatformSecretStore store,
    required this.rootKeyId,
    required String rootPublicKeyBase64,
    DateTime Function()? clock,
  })  : _store = store,
        _clock = clock ?? DateTime.now,
        _rootPublicKey = _decodeRootKey(rootPublicKeyBase64) {
    if (!_validIdentifier(rootKeyId)) {
      throw const FormatException('معرّف جذر الثقة غير صالح.');
    }
  }

  static const Duration maxKeysetLifetime = Duration(days: 30);
  static const Duration clockSkew = Duration(minutes: 5);
  static const String _storageKey = 'homi_platform_trusted_keyset_v1';
  static const List<int> _spkiPrefix = [
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
    0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
  ];

  final PlatformSecretStore _store;
  final String rootKeyId;
  final DateTime Function() _clock;
  final SimplePublicKey _rootPublicKey;
  final Ed25519 _ed25519 = Ed25519();

  static SimplePublicKey _decodeRootKey(String value) {
    try {
      final bytes = base64Decode(value);
      if (bytes.length != 32 || base64Encode(bytes) != value) {
        throw const FormatException();
      }
      return SimplePublicKey(bytes, type: KeyPairType.ed25519);
    } on FormatException {
      throw const FormatException(
        'مفتاح جذر الثقة يجب أن يكون Ed25519 raw بطول 32 بايت بصيغة Base64.',
      );
    }
  }

  static bool _validIdentifier(String value) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value);

  /// يتحقق من التوقيع أولًا، ثم المحتوى والتواريخ، ثم يمنع downgrade.
  /// يُحفظ الغلاف كاملًا في كتابة واحدة بعد اجتياز جميع الفحوص.
  Future<VerifiedPlatformKeyset> acceptSignedEnvelope(
    Map<String, Object?> envelope,
  ) async {
    final verified = await _verifyEnvelope(envelope);
    final storedText = await _store.read(_storageKey);
    if (storedText != null) {
      final storedDecoded = jsonDecode(storedText);
      if (storedDecoded is! Map<String, dynamic>) {
        throw StateError('سجل Keyset المحفوظ تالف؛ أوقف التحديث الآمن.');
      }
      final previous = await _verifyEnvelope(
        Map<String, Object?>.from(storedDecoded),
      );
      if (verified.version < previous.version) {
        throw const FormatException('رُفض Keyset أقدم من النسخة الموثوقة.');
      }
      if (verified.version == previous.version &&
          !_sameBytes(
            base64Decode(verified.signedEnvelope['payload']! as String),
            base64Decode(previous.signedEnvelope['payload']! as String),
          )) {
        throw const FormatException(
          'إصدار Keyset نفسه لا يجوز أن يحمل محتوى مختلفًا.',
        );
      }
    }

    await _store.write(_storageKey, jsonEncode(verified.signedEnvelope));
    return verified;
  }

  /// يستعيد النسخة المخبأة مع إعادة التحقق من التوقيع والصلاحية الحالية.
  Future<VerifiedPlatformKeyset?> loadCached() async {
    final text = await _store.read(_storageKey);
    if (text == null) return null;
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('سجل Keyset المحفوظ تالف؛ أوقف التحقق.');
    }
    return _verifyEnvelope(Map<String, Object?>.from(decoded));
  }

  Future<VerifiedPlatformKeyset> _verifyEnvelope(
    Map<String, Object?> envelope,
  ) async {
    if (envelope['root_key_id'] != rootKeyId ||
        envelope['payload'] is! String ||
        envelope['signature'] is! String) {
      throw const FormatException('غلاف Keyset لا يطابق جذر الثقة المثبت.');
    }

    final payloadText = envelope['payload'] as String;
    final signatureText = envelope['signature'] as String;
    late final List<int> payload;
    late final List<int> signature;
    try {
      payload = base64Decode(payloadText);
      signature = base64Decode(signatureText);
      if (base64Encode(payload) != payloadText ||
          base64Encode(signature) != signatureText ||
          signature.length != 64) {
        throw const FormatException();
      }
    } on FormatException {
      throw const FormatException('ترميز payload أو توقيع Keyset غير صالح.');
    }

    final signatureValid = await _ed25519.verify(
      payload,
      signature: Signature(signature, publicKey: _rootPublicKey),
    );
    if (!signatureValid) {
      throw const FormatException('فشل توقيع جذر الثقة لمجموعة المفاتيح.');
    }

    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('محتوى Keyset ليس كائن JSON صالحًا.');
    }
    final schemaVersion = decoded['schema_version'];
    final version = decoded['keyset_version'];
    if (schemaVersion != 1 || version is! int || version < 1) {
      throw const FormatException('إصدار مخطط أو رقم Keyset غير صالح.');
    }

    final issuedAt = _parseTimestamp(decoded['issued_at']);
    final expiresAt = _parseTimestamp(decoded['expires_at']);
    final now = _clock().toUtc();
    if (!expiresAt.isAfter(issuedAt) ||
        expiresAt.difference(issuedAt) > maxKeysetLifetime ||
        issuedAt.isAfter(now.add(clockSkew)) ||
        now.isAfter(expiresAt.add(clockSkew))) {
      throw const FormatException(
        'Keyset منتهي الصلاحية أو بتواريخ خارج السياسة المعتمدة.',
      );
    }

    final rawKeys = decoded['keys'];
    if (rawKeys is! List || rawKeys.isEmpty || rawKeys.length > 100) {
      throw const FormatException('قائمة مفاتيح Keyset غير صالحة.');
    }
    final ids = <String>{};
    final keys = <TrustedPlatformSigningKey>[];
    for (final raw in rawKeys) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('عنصر مفتاح داخل Keyset غير صالح.');
      }
      final keyId = raw['key_id'];
      final purpose = raw['purpose'];
      final algorithm = raw['algorithm'];
      final publicText = raw['public_key'];
      final status = raw['status'];
      if (keyId is! String ||
          !_validIdentifier(keyId) ||
          !ids.add(keyId) ||
          !const {'update_manifest', 'offline_license_grant'}
              .contains(purpose) ||
          algorithm != 'Ed25519' ||
          publicText is! String ||
          !const {'active', 'verify_only', 'revoked'}.contains(status)) {
        throw const FormatException(
          'معرف أو غرض أو خوارزمية أو حالة مفتاح غير صالحة أو مكررة.',
        );
      }

      final notBefore = _parseTimestamp(raw['not_before']);
      final notAfter = _parseTimestamp(raw['not_after']);
      if (!notAfter.isAfter(notBefore)) {
        throw const FormatException('فترة صلاحية المفتاح غير صحيحة.');
      }

      late final List<int> der;
      try {
        der = base64Decode(publicText);
      } on FormatException {
        throw const FormatException('ترميز المفتاح العام غير صالح.');
      }
      if (base64Encode(der) != publicText ||
          der.length != 44 ||
          !_sameBytes(der.sublist(0, 12), _spkiPrefix)) {
        throw const FormatException('صيغة مفتاح Ed25519 العام غير مدعومة.');
      }
      keys.add(TrustedPlatformSigningKey(
        keyId: keyId,
        purpose: purpose as String,
        publicKey: SimplePublicKey(
          der.sublist(12),
          type: KeyPairType.ed25519,
        ),
        status: status as String,
        notBefore: notBefore,
        notAfter: notAfter,
      ));
    }

    return VerifiedPlatformKeyset(
      version: version,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      keys: List.unmodifiable(keys),
      signedEnvelope: Map.unmodifiable(envelope),
    );
  }

  DateTime _parseTimestamp(Object? value) {
    if (value is! String ||
        !RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$')
            .hasMatch(value)) {
      throw const FormatException('تاريخ Keyset يجب أن يتضمن منطقة زمنية.');
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      throw const FormatException('تاريخ Keyset غير صالح.');
    }
    return parsed.toUtc();
  }

  bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var i = 0; i < left.length; i++) {
      difference |= left[i] ^ right[i];
    }
    return difference == 0;
  }
}
