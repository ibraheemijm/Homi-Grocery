import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/data/platform_api_client.dart';
import 'package:homi_grocery/data/platform_update_service.dart';

class QueueTransport implements PlatformHttpTransport {
  QueueTransport(this.responses);
  final List<PlatformHttpResponse> responses;
  final List<Uri> requestedUris = [];
  var _index = 0;

  @override
  Future<PlatformHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    requestedUris.add(uri);
    return responses[_index++];
  }

  @override
  void close() {}
}

PlatformHttpResponse success(Map<String, Object?> data) => PlatformHttpResponse(
  statusCode: 200,
  body: jsonEncode({'success': true, 'data': data}),
);

void main() {
  test('يعيد null عندما لا يوجد إصدار أحدث', () async {
    final transport = QueueTransport([success({'available': false})]);
    final service = PlatformUpdateService(PlatformApiClient(
      baseUri: Uri.parse('https://platform.example.test'),
      transport: transport,
    ));

    final update = await service.checkForUpdate(
      accessToken: 'access-test',
      productKey: 'homi-grocery',
      platform: 'android',
      architecture: 'universal',
      channel: 'stable',
      currentVersionCode: 101,
      licenseId: 'license-1',
      deviceId: 'device-1',
    );

    expect(update, isNull);
    expect(transport.requestedUris.single.queryParameters['current_version_code'], '101');
  });

  test('يتحقق من manifest ومفتاح OTA قبل إرجاع بيانات التحديث', () async {
    const publicationId = 'publication-1';
    const keyId = 'ota-test-key';
    final keyPair = await Ed25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final publicDer = <int>[
      0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
      0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
      ...publicKey.bytes,
    ];
    final claims = <String, Object?>{
      'schema_version': 1,
      'publication_id': publicationId,
      'product_key': 'homi-grocery',
      'platform': 'android',
      'architecture': 'universal',
      'channel': 'stable',
      'version': '1.0.2',
      'version_code': 102,
      'file_name': 'homi-grocery.apk',
      'size_bytes': 123456,
      'sha256': 'a' * 64,
      'release_notes': 'Security fixes',
      'published_at': '2026-11-10T12:00:00.000Z',
      'download_url': '/api/v1/updates/$publicationId/download',
      'key_id': keyId,
    };
    final payload = utf8.encode(jsonEncode(claims));
    final signature = await Ed25519().sign(payload, keyPair: keyPair);
    final transport = QueueTransport([
      success({
        'publication_id': publicationId,
        'key_id': keyId,
        'manifest': base64Encode(payload),
        'signature': base64Encode(signature.bytes),
      }),
      success({
        'items': [{
          'key_id': keyId,
          'public_key': base64Encode(publicDer),
          'status': 'active',
        }],
      }),
    ]);
    final service = PlatformUpdateService(PlatformApiClient(
      baseUri: Uri.parse('https://platform.example.test'),
      transport: transport,
    ));
    const update = PlatformUpdateInfo(
      publicationId: publicationId,
      version: '1.0.2',
      versionCode: 102,
      fileName: 'homi-grocery.apk',
      sizeBytes: 123456,
      sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      signingKeyId: keyId,
    );

    final manifest = await service.fetchVerifiedManifest(
      accessToken: 'access-test',
      update: update,
      licenseId: 'license-1',
      deviceId: 'device-1',
      productKey: 'homi-grocery',
      platform: 'android',
      architecture: 'arm64-v8a',
      channel: 'stable',
    );

    expect(manifest.publicationId, publicationId);
    expect(manifest.keyId, keyId);
    expect(manifest.downloadPath, '/api/v1/updates/$publicationId/download');
    expect(manifest.sha256, update.sha256);
    expect(transport.requestedUris.last.path, '/api/v1/update-signing-keys');
  });

  test('يرفض manifest إذا لم يطابق الإصدار المتوقع حتى لو كان موقعًا', () async {
    final keyPair = await Ed25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final publicDer = <int>[
      0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
      0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
      ...publicKey.bytes,
    ];
    final payload = utf8.encode(jsonEncode({
      'schema_version': 1,
      'publication_id': 'publication-1',
      'product_key': 'another-product',
      'platform': 'android',
      'architecture': 'universal',
      'channel': 'stable',
      'version': '1.0.2',
      'version_code': 102,
      'file_name': 'homi-grocery.apk',
      'size_bytes': 123456,
      'sha256': 'a' * 64,
      'release_notes': null,
      'published_at': '2026-11-10T12:00:00.000Z',
      'download_url': '/api/v1/updates/publication-1/download',
      'key_id': 'ota-test-key',
    }));
    final signature = await Ed25519().sign(payload, keyPair: keyPair);
    final transport = QueueTransport([
      success({
        'publication_id': 'publication-1',
        'key_id': 'ota-test-key',
        'manifest': base64Encode(payload),
        'signature': base64Encode(signature.bytes),
      }),
      success({
        'items': [{
          'key_id': 'ota-test-key',
          'public_key': base64Encode(publicDer),
          'status': 'active',
        }],
      }),
    ]);
    final service = PlatformUpdateService(PlatformApiClient(
      baseUri: Uri.parse('https://platform.example.test'),
      transport: transport,
    ));
    const update = PlatformUpdateInfo(
      publicationId: 'publication-1',
      version: '1.0.2',
      versionCode: 102,
      fileName: 'homi-grocery.apk',
      sizeBytes: 123456,
      sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      signingKeyId: 'ota-test-key',
    );

    await expectLater(
      service.fetchVerifiedManifest(
        accessToken: 'access-test',
        update: update,
        licenseId: 'license-1',
        deviceId: 'device-1',
        productKey: 'homi-grocery',
        platform: 'android',
        architecture: 'universal',
        channel: 'stable',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
