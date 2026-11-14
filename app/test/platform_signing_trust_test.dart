import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/data/platform_device_identity.dart';
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

const _now = '2026-11-14T12:00:00.000Z';
final _clockNow = DateTime.utc(2026, 11, 14, 12);

Future<({Map<String, Object?> envelope, SimpleKeyPair rootPair})>
    _signedKeyset({
  int version = 1,
  String issuedAt = _now,
  String expiresAt = '2026-12-14T12:00:00.000Z',
  bool duplicateIds = false,
  bool invalidPurpose = false,
  SimpleKeyPair? rootPair,
}) async {
  final algorithm = Ed25519();
  final signingRootPair = rootPair ?? await algorithm.newKeyPair();
  final operationalPair = await algorithm.newKeyPair();
  final operationalPublic = await operationalPair.extractPublicKey();
  final der = <int>[
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
    0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
    ...operationalPublic.bytes,
  ];
  final key = <String, Object?>{
    'key_id': 'ota-key-1',
    'purpose': invalidPurpose ? 'license' : 'update_manifest',
    'algorithm': 'Ed25519',
    'public_key': base64Encode(der),
    'not_before': '2026-11-01T00:00:00.000Z',
    'not_after': '2027-01-01T00:00:00.000Z',
    'status': 'active',
  };
  final keys = <Map<String, Object?>>[key];
  if (duplicateIds) keys.add(Map<String, Object?>.from(key));
  final payload = utf8.encode(jsonEncode({
    'schema_version': 1,
    'keyset_version': version,
    'issued_at': issuedAt,
    'expires_at': expiresAt,
    'keys': keys,
  }));
  final signature = await algorithm.sign(payload, keyPair: signingRootPair);
  return (
    envelope: {
      'root_key_id': 'homi-root-1',
      'payload': base64Encode(payload),
      'signature': base64Encode(signature.bytes),
    },
    rootPair: signingRootPair,
  );
}

Future<PlatformSigningTrust> _trust(
  MemorySecretStore store,
  SimpleKeyPair rootPair,
) async {
  final publicKey = await rootPair.extractPublicKey();
  return PlatformSigningTrust(
    store: store,
    rootKeyId: 'homi-root-1',
    rootPublicKeyBase64: base64Encode(publicKey.bytes),
    clock: () => _clockNow,
  );
}

void main() {
  test('يتحقق من توقيع الجذر ويحفظ Keyset ثم يستعيده من التخزين الآمن',
      () async {
    final signed = await _signedKeyset();
    final store = MemorySecretStore();
    final trust = await _trust(store, signed.rootPair);

    final accepted = await trust.acceptSignedEnvelope(signed.envelope);
    final cached = await trust.loadCached();

    expect(accepted.version, 1);
    expect(cached?.version, 1);
    expect(
      cached!.keyForVerification(
        keyId: 'ota-key-1',
        purpose: 'update_manifest',
        at: _clockNow,
      ).status,
      'active',
    );
    expect(store.values, hasLength(1));
  });

  test('يرفض توقيعًا مزورًا ولا يحفظه', () async {
    final signed = await _signedKeyset();
    final store = MemorySecretStore();
    final trust = await _trust(store, signed.rootPair);
    final tampered = Map<String, Object?>.from(signed.envelope)
      ..['payload'] = base64Encode(utf8.encode('{"schema_version":1}'));

    await expectLater(
      trust.acceptSignedEnvelope(tampered),
      throwsA(isA<FormatException>()),
    );
    expect(store.values, isEmpty);
  });

  test('يرفض Keyset الذي تتجاوز صلاحيته 30 يومًا أو انتهى', () async {
    final longLived = await _signedKeyset(
      expiresAt: '2027-01-01T12:00:00.000Z',
    );
    final expired = await _signedKeyset(
      expiresAt: '2026-11-14T11:00:00.000Z',
    );
    for (final signed in [longLived, expired]) {
      final trust = await _trust(MemorySecretStore(), signed.rootPair);
      await expectLater(
        trust.acceptSignedEnvelope(signed.envelope),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('يرفض downgrade وإعادة استخدام الإصدار نفسه بمحتوى مختلف', () async {
    final first = await _signedKeyset(version: 2);
    final lower = await _signedKeyset(version: 1);
    final sameVersionChanged = await _signedKeyset(
      version: 2,
      issuedAt: '2026-11-14T12:01:00.000Z',
    );
    final store = MemorySecretStore();
    final trust = await _trust(store, first.rootPair);
    await trust.acceptSignedEnvelope(first.envelope);

    // يوقع الاختبار كل envelope بمفتاح جذر مستقل؛ نعيد توقيع الحالات
    // المرفوضة بمفتاح الجذر المثبت نفسه لضمان اختبار downgrade لا root mismatch.
    final lowerPayload = base64Decode(lower.envelope['payload']! as String);
    final lowerSignature = await Ed25519().sign(
      lowerPayload,
      keyPair: first.rootPair,
    );
    lower.envelope['signature'] = base64Encode(lowerSignature.bytes);
    lower.envelope['root_key_id'] = 'homi-root-1';

    final changedPayload =
        base64Decode(sameVersionChanged.envelope['payload']! as String);
    final changedSignature = await Ed25519().sign(
      changedPayload,
      keyPair: first.rootPair,
    );
    sameVersionChanged.envelope['signature'] =
        base64Encode(changedSignature.bytes);
    sameVersionChanged.envelope['root_key_id'] = 'homi-root-1';

    await expectLater(
      trust.acceptSignedEnvelope(lower.envelope),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      trust.acceptSignedEnvelope(sameVersionChanged.envelope),
      throwsA(isA<FormatException>()),
    );
    expect((await trust.loadCached())?.version, 2);
  });


  test('يسمح بتجديد Keyset بعد انتهاء المخزن دون إسقاط رقم الإصدار الموثوق',
      () async {
    var now = _clockNow;
    final initial = await _signedKeyset(
      version: 1,
      expiresAt: '2026-11-14T12:00:00.000Z',
    );
    final rootPublic = await initial.rootPair.extractPublicKey();
    final store = MemorySecretStore();
    final trust = PlatformSigningTrust(
      store: store,
      rootKeyId: 'homi-root-1',
      rootPublicKeyBase64: base64Encode(rootPublic.bytes),
      clock: () => now,
    );
    await trust.acceptSignedEnvelope(initial.envelope);

    now = DateTime.utc(2026, 11, 15, 12);
    final renewed = await _signedKeyset(
      version: 2,
      issuedAt: '2026-11-15T12:00:00.000Z',
      expiresAt: '2026-12-15T12:00:00.000Z',
      rootPair: initial.rootPair,
    );
    final accepted = await trust.acceptSignedEnvelope(renewed.envelope);
    expect(accepted.version, 2);
  });

  test('يرفض معرفات المفاتيح المكررة والغرض غير المدعوم', () async {
    final duplicate = await _signedKeyset(duplicateIds: true);
    final wrongPurpose = await _signedKeyset(invalidPurpose: true);
    for (final signed in [duplicate, wrongPurpose]) {
      final trust = await _trust(MemorySecretStore(), signed.rootPair);
      await expectLater(
        trust.acceptSignedEnvelope(signed.envelope),
        throwsA(isA<FormatException>()),
      );
    }
  });
}
