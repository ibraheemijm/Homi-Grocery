// هوية جهاز مستقرة ومفتاح Ed25519 محفوظان في سجل واحد داخل التخزين الآمن.
import 'dart:convert';
import 'dart:io';
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

class _StoredDeviceIdentity {
  const _StoredDeviceIdentity({
    required this.deviceKey,
    required this.privateSeed,
  });

  final String deviceKey;
  final List<int> privateSeed;
}

class PlatformDeviceIdentity {
  PlatformDeviceIdentity(this._store, {bool Function()? isAndroid})
      : _isAndroid = isAndroid ?? (() => Platform.isAndroid);

  final PlatformSecretStore _store;
  final bool Function() _isAndroid;
  static const _identityRecordName = 'homi_platform_device_identity_v1';
  static const _spkiPrefix = <int>[
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65,
    0x70, 0x03, 0x21, 0x00,
  ];

  final Ed25519 _algorithm = Ed25519();

  Future<PlatformDeviceIdentityData> loadOrCreate() async {
    if (!_isAndroid()) {
      throw UnsupportedError('ربط الترخيص متاح على Android في هذه المرحلة فقط.');
    }
    final stored = await _readOrCreate();
    final keyPair = await _algorithm.newKeyPairFromSeed(stored.privateSeed);
    final publicKey = await keyPair.extractPublicKey();
    if (publicKey.bytes.length != 32) {
      throw StateError('Ed25519 public key must contain exactly 32 bytes.');
    }

    return PlatformDeviceIdentityData(
      deviceKey: stored.deviceKey,
      publicKeyDer: <int>[..._spkiPrefix, ...publicKey.bytes],
      platform: 'android',
      // كتالوج Homi Grocery يسجل Android بمعمارية universal حاليًا.
      architecture: 'universal',
    );
  }

  Future<String> signNonce(String nonceBase64Url) async {
    if (!_isAndroid()) {
      throw UnsupportedError('توقيع تحديات الترخيص متاح على Android فقط.');
    }
    final nonce = base64Url.decode(base64Url.normalize(nonceBase64Url));
    if (nonce.length != 32 ||
        base64UrlEncode(nonce).replaceAll('=', '') != nonceBase64Url) {
      throw const FormatException('Device challenge nonce is invalid.');
    }

    final stored = await _readOrCreate();
    final keyPair = await _algorithm.newKeyPairFromSeed(stored.privateSeed);
    final signature = await _algorithm.sign(nonce, keyPair: keyPair);
    return base64UrlEncode(signature.bytes).replaceAll('=', '');
  }

  Future<_StoredDeviceIdentity> _readOrCreate() async {
    final record = await _store.read(_identityRecordName);
    if (record == null || record.isEmpty) {
      final keyPair = await _algorithm.newKeyPair();
      final extracted = await keyPair.extract();
      final seed = extracted.bytes;
      if (seed.length != 32) {
        throw StateError('Ed25519 private seed must contain exactly 32 bytes.');
      }
      final identity = _StoredDeviceIdentity(
        deviceKey: _createUuid(),
        privateSeed: seed,
      );
      // سجل واحد يمنع ربط معرف جهاز بمفتاح جديد بعد كتابة جزئية.
      await _store.write(_identityRecordName, jsonEncode({
        'device_key': identity.deviceKey,
        'private_seed': base64Encode(identity.privateSeed),
      }));
      return identity;
    }

    try {
      final decoded = jsonDecode(record);
      if (decoded is! Map<String, dynamic> ||
          decoded['device_key'] is! String ||
          decoded['private_seed'] is! String) {
        throw const FormatException();
      }
      final deviceKey = decoded['device_key'] as String;
      final seed = base64Decode(decoded['private_seed'] as String);
      if (!RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(deviceKey) || seed.length != 32) {
        throw const FormatException();
      }
      return _StoredDeviceIdentity(deviceKey: deviceKey, privateSeed: seed);
    } on FormatException {
      throw StateError('سجل هوية الجهاز تالف؛ أوقف الربط بدل إنشاء هوية مختلفة بصمت.');
    }
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
