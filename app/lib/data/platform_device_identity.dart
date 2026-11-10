// هوية جهاز مستقرة ومفتاح Ed25519 محفوظان في التخزين الآمن على الجهاز.
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class PlatformSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class FlutterPlatformSecretStore implements PlatformSecretStore {
  FlutterPlatformSecretStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

class PlatformDeviceIdentityData {
  const PlatformDeviceIdentityData({
    required this.deviceKey,
    required this.publicKeyDer,
    required this.platform,
    required this.architecture,
  });

  final String deviceKey;
  final List<int> publicKeyDer;
  final String platform;
  final String architecture;

  String get publicKeyBase64 => base64Encode(publicKeyDer);
}

class PlatformDeviceIdentity {
  PlatformDeviceIdentity(this._store);

  final PlatformSecretStore _store;
  static const _deviceKeyName = 'homi_platform_device_key';
  static const _privateSeedName = 'homi_platform_ed25519_seed';
  static const _spkiPrefix = <int>[
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65,
    0x70, 0x03, 0x21, 0x00,
  ];

  final Ed25519 _algorithm = Ed25519();

  Future<PlatformDeviceIdentityData> loadOrCreate() async {
    var deviceKey = await _store.read(_deviceKeyName);
    var seedText = await _store.read(_privateSeedName);

    if (deviceKey == null || deviceKey.isEmpty) {
      deviceKey = _createUuid();
      await _store.write(_deviceKeyName, deviceKey);
    }

    if (seedText == null || seedText.isEmpty) {
      final generated = await _algorithm.newKeyPair();
      final extracted = await generated.extract();
      final seed = extracted.bytes;
      if (seed.length != 32) {
        throw StateError('Ed25519 private seed must contain exactly 32 bytes.');
      }
      seedText = base64Encode(seed);
      await _store.write(_privateSeedName, seedText);
    }

    final seed = base64Decode(seedText);
    if (seed.length != 32) {
      throw StateError('The stored Ed25519 private seed is invalid.');
    }
    final keyPair = await _algorithm.newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    if (publicKey.bytes.length != 32) {
      throw StateError('Ed25519 public key must contain exactly 32 bytes.');
    }

    return PlatformDeviceIdentityData(
      deviceKey: deviceKey,
      publicKeyDer: <int>[..._spkiPrefix, ...publicKey.bytes],
      platform: 'android',
      // كتالوج Homi Grocery يسجل Android بمعمارية universal حاليًا.
      architecture: 'universal',
    );
  }

  Future<String> signNonce(String nonceBase64Url) async {
    final nonce = base64Url.decode(base64Url.normalize(nonceBase64Url));
    if (nonce.length != 32 ||
        base64UrlEncode(nonce).replaceAll('=', '') != nonceBase64Url) {
      throw const FormatException('Device challenge nonce is invalid.');
    }

    final seedText = await _store.read(_privateSeedName);
    if (seedText == null || seedText.isEmpty) {
      throw StateError('The device signing key has not been initialized.');
    }
    final seed = base64Decode(seedText);
    if (seed.length != 32) {
      throw StateError('The stored Ed25519 private seed is invalid.');
    }
    final keyPair = await _algorithm.newKeyPairFromSeed(seed);
    final signature = await _algorithm.sign(nonce, keyPair: keyPair);
    return base64UrlEncode(signature.bytes).replaceAll('=', '');
  }

  String _createUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}
