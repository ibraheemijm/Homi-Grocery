import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

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

class FakeUpdateDownloader implements PlatformUpdateDownloader {
  FakeUpdateDownloader(this.bytes);
  final List<int> bytes;
  Uri? uri;
  String? token;
  int? expectedSize;

  @override
  Future<File> download({
    required Uri uri,
    required String accessToken,
    required File destination,
    required int expectedSizeBytes,
  }) async {
    this.uri = uri;
    token = accessToken;
    expectedSize = expectedSizeBytes;
    await destination.writeAsBytes(bytes, flush: true);
    return destination;
  }
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
  test('ينزل حزمة OTA ويتحقق من الحجم وبصمة SHA-256 قبل إرجاعها', () async {
    final bytes = utf8.encode('Homi signed update package');
    final transport = QueueTransport([]);
    final service = PlatformUpdateService(PlatformApiClient(
      baseUri: Uri.parse('https://platform.example.test'),
      transport: transport,
    ));
    final downloader = FakeUpdateDownloader(bytes);
    final manifest = VerifiedPlatformUpdateManifest(
      publicationId: 'publication-2',
      keyId: 'ota-key',
      payload: const [],
      signature: const [],
      downloadPath: '/api/v1/updates/publication-2/download',
      version: '1.0.3',
      versionCode: 103,
      fileName: 'homi-update.zip',
      sizeBytes: bytes.length,
      sha256: crypto.sha256.convert(bytes).toString(),
    );

    final file = await service.downloadVerifiedPackage(
      accessToken: 'access-token',
      manifest: manifest,
      downloader: downloader,
    );
    addTearDown(() async {
      if (await file.parent.exists()) await file.parent.delete(recursive: true);
    });

    expect(await file.readAsBytes(), bytes);
    expect(downloader.uri!.origin, 'https://platform.example.test');
    expect(downloader.uri!.path, manifest.downloadPath);
    expect(downloader.token, 'access-token');
    expect(downloader.expectedSize, bytes.length);
  });

  test('يحذف الحزمة إذا لم تطابق SHA-256 المعلن', () async {
    final bytes = utf8.encode('tampered update package');
    final service = PlatformUpdateService(PlatformApiClient(
      baseUri: Uri.parse('https://platform.example.test'),
      transport: QueueTransport([]),
    ));
    final manifest = VerifiedPlatformUpdateManifest(
      publicationId: 'publication-3',
      keyId: 'ota-key',
      payload: const [],
      signature: const [],
      downloadPath: '/api/v1/updates/publication-3/download',
      version: '1.0.4',
      versionCode: 104,
      fileName: 'homi-update.zip',
      sizeBytes: bytes.length,
      sha256: '0' * 64,
    );

    await expectLater(
      service.downloadVerifiedPackage(
        accessToken: 'access-token',
        manifest: manifest,
        downloader: FakeUpdateDownloader(bytes),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('يرفض اسم ملف يحتوي مسارًا قبل بدء التنزيل', () async {
    final service = PlatformUpdateService(PlatformApiClient(
      baseUri: Uri.parse('https://platform.example.test'),
      transport: QueueTransport([]),
    ));
    final manifest = VerifiedPlatformUpdateManifest(
      publicationId: 'publication-4',
      keyId: 'ota-key',
      payload: const [],
      signature: const [],
      downloadPath: '/api/v1/updates/publication-4/download',
      version: '1.0.5',
      versionCode: 105,
      fileName: '../homi-update.zip',
      sizeBytes: 10,
      sha256: 'a' * 64,
    );

    await expectLater(
      service.downloadVerifiedPackage(
        accessToken: 'access-token',
        manifest: manifest,
        downloader: FakeUpdateDownloader(utf8.encode('0123456789')),
      ),
      throwsA(isA<FormatException>()),
    );
  });

}
