import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/data/platform_device_identity.dart';

class MemorySecretStore implements PlatformSecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  test('ينشئ هوية ثابتة ومفتاح Ed25519 داخل التخزين الآمن', () async {
    final store = MemorySecretStore();
    final identity = PlatformDeviceIdentity(store, isAndroid: () => true);

    final first = await identity.loadOrCreate();
    final second = await identity.loadOrCreate();

    expect(first.deviceKey, matches(RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    )));
    expect(second.deviceKey, first.deviceKey);
    expect(second.publicKeyDer, first.publicKeyDer);
    expect(first.platform, 'android');
    expect(first.architecture, 'universal');
    expect(first.publicKeyDer.length, 44);
    expect(first.publicKeyDer.take(12).toList(), [
      0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
      0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
    ]);
    expect(store.values.keys, containsAll([
      'homi_platform_device_identity_v1',
    ]));
    expect(store.values.values, isNot(contains(first.publicKeyBase64)));
  });

  test('يرفض سجل هوية تالفًا بدل إنشاء مفتاح جديد لنفس الجهاز', () async {
    final store = MemorySecretStore();
    store.values['homi_platform_device_identity_v1'] = '{"device_key":"bad","private_seed":"broken"}';
    final identity = PlatformDeviceIdentity(store, isAndroid: () => true);

    await expectLater(identity.loadOrCreate(), throwsA(isA<StateError>()));
  });

  test('يوقع nonce بالمفتاح الخاص ولا يرسل المفتاح الخاص', () async {
    final store = MemorySecretStore();
    final identity = PlatformDeviceIdentity(store, isAndroid: () => true);
    final data = await identity.loadOrCreate();
    final nonce = List<int>.generate(32, (index) => index);
    final nonceText = base64UrlEncode(nonce).replaceAll('=', '');

    final signatureText = await identity.signNonce(nonceText);
    final signature = base64Url.decode(base64Url.normalize(signatureText));
    final publicKey = SimplePublicKey(
      data.publicKeyDer.sublist(12),
      type: KeyPairType.ed25519,
    );

    expect(
      await Ed25519().verify(
        nonce,
        signature: Signature(signature, publicKey: publicKey),
      ),
      isTrue,
    );
    expect(signature.length, 64);
    expect(signatureText, isNot(contains('=')));
  });

  test('ينشئ هوية Windows مستقرة بمعمارية الجهاز', () async {
    final identity = PlatformDeviceIdentity(
      MemorySecretStore(),
      platformOverride: () => 'windows',
    );
    final data = await identity.loadOrCreate();
    expect(data.platform, 'windows');
    expect(data.architecture, isNotEmpty);
    expect(data.publicKeyDer, hasLength(44));
  });

  test('يرفض nonce غير صحيح قبل إجراء التوقيع', () async {
    final identity = PlatformDeviceIdentity(
      MemorySecretStore(),
      platformOverride: () => 'android',
    );
    await identity.loadOrCreate();

    await expectLater(
      identity.signNonce('not-a-valid-nonce'),
      throwsA(isA<FormatException>()),
    );
  });
}
