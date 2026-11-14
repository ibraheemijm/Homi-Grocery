// فحص إصدارات OTA والتحقق من manifest قبل السماح بتنزيل ملف التحديث.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'package:cryptography/cryptography.dart';

import 'platform_api_client.dart';
import 'platform_signing_trust.dart';

abstract interface class PlatformUpdateDownloader {
  Future<File> download({
    required Uri uri,
    required String accessToken,
    required File destination,
    required int expectedSizeBytes,
  });
}

class IoPlatformUpdateDownloader implements PlatformUpdateDownloader {
  IoPlatformUpdateDownloader({HttpClient? client})
      : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<File> download({
    required Uri uri,
    required String accessToken,
    required File destination,
    required int expectedSizeBytes,
  }) async {
    if (uri.scheme != 'https' ||
        accessToken.isEmpty ||
        expectedSizeBytes < 1 ||
        expectedSizeBytes > 1024 * 1024 * 1024) {
      throw const FormatException('إعدادات تنزيل تحديث Homi غير صالحة.');
    }

    IOSink? sink;
    try {
      final request = await _client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $accessToken',
      );
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/octet-stream',
      );
      final response = await request
          .close()
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok ||
          (response.contentLength >= 0 &&
              response.contentLength != expectedSizeBytes)) {
        throw HttpException(
          'رفض الخادم ملف التحديث أو أعاد حجمًا غير متوقع.',
          uri: uri,
        );
      }

      await destination.parent.create(recursive: true);
      sink = destination.openWrite(mode: FileMode.writeOnly);
      var received = 0;
      await for (final chunk
          in response.timeout(const Duration(seconds: 60))) {
        received += chunk.length;
        if (received > expectedSizeBytes) {
          throw const FormatException(
            'حجم ملف التحديث أكبر من الحجم المعلن.',
          );
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (received != expectedSizeBytes) {
        throw const FormatException(
          'اكتمل التنزيل بحجم لا يطابق بيانات الإصدار.',
        );
      }
      return destination;
    } catch (_) {
      await sink?.close();
      if (await destination.exists()) {
        await destination.delete();
      }
      rethrow;
    } finally {
      _client.close(force: true);
    }
  }
}

class PlatformUpdateInfo {
  const PlatformUpdateInfo({
    required this.publicationId,
    required this.version,
    required this.versionCode,
    required this.fileName,
    required this.sizeBytes,
    required this.sha256,
    required this.signingKeyId,
  });

  final String publicationId;
  final String version;
  final int versionCode;
  final String fileName;
  final int sizeBytes;
  final String sha256;
  final String signingKeyId;
}

class VerifiedPlatformUpdateManifest {
  const VerifiedPlatformUpdateManifest({
    required this.publicationId,
    required this.keyId,
    required this.payload,
    required this.signature,
    required this.downloadPath,
    required this.version,
    required this.versionCode,
    required this.fileName,
    required this.sizeBytes,
    required this.sha256,
    this.releaseNotes,
  });

  final String publicationId;
  final String keyId;
  final List<int> payload;
  final List<int> signature;
  final String downloadPath;
  final String version;
  final int versionCode;
  final String fileName;
  final int sizeBytes;
  final String sha256;
  final String? releaseNotes;
}

class PlatformUpdateService {
  PlatformUpdateService(this._api, {required PlatformSigningTrust signingTrust})
      : _signingTrust = signingTrust;

  final PlatformApiClient _api;
  final PlatformSigningTrust _signingTrust;
  final Ed25519 _ed25519 = Ed25519();

  Future<PlatformUpdateInfo?> checkForUpdate({
    required String accessToken,
    required String productKey,
    required String platform,
    required String architecture,
    required String channel,
    required int currentVersionCode,
    required String licenseId,
    required String deviceId,
  }) async {
    final result = await _api.getJson(
      '/api/v1/updates/check',
      accessToken: accessToken,
      query: {
        'product_key': productKey,
        'platform': platform,
        'architecture': architecture,
        'channel': channel,
        'current_version_code': currentVersionCode.toString(),
        'license_id': licenseId,
        'device_id': deviceId,
      },
    );
    if (result['available'] == false) return null;
    if (result['available'] != true) {
      throw const FormatException('استجابة فحص تحديث Homi غير صالحة.');
    }

    final publicationId = result['publication_id'];
    final version = result['version'];
    final versionCode = result['version_code'];
    final fileName = result['file_name'];
    final sizeBytes = result['size_bytes'];
    final sha256 = result['sha256_hex'];
    final signingKeyId = result['signing_key_id'];
    if (publicationId is! String ||
        version is! String ||
        versionCode is! num ||
        !versionCode.isFinite ||
        versionCode < 1 ||
        versionCode > 0x7fffffff ||
        versionCode.toInt() != versionCode ||
        fileName is! String ||
        sizeBytes is! num ||
        !sizeBytes.isFinite ||
        sizeBytes < 1 ||
        sizeBytes > 1024 * 1024 * 1024 ||
        sizeBytes.toInt() != sizeBytes ||
        sha256 is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) ||
        signingKeyId is! String) {
      throw const FormatException('بيانات الإصدار المتاح غير مكتملة.');
    }
    return PlatformUpdateInfo(
      publicationId: publicationId,
      version: version,
      versionCode: versionCode.toInt(),
      fileName: fileName,
      sizeBytes: sizeBytes.toInt(),
      sha256: sha256,
      signingKeyId: signingKeyId,
    );
  }

  Future<VerifiedPlatformUpdateManifest> fetchVerifiedManifest({
    required String accessToken,
    required PlatformUpdateInfo update,
    required String licenseId,
    required String deviceId,
    required String productKey,
    required String platform,
    required String architecture,
    required String channel,
  }) async {
    final response = await _api.getJson(
      '/api/v1/updates/${update.publicationId}/manifest',
      accessToken: accessToken,
      query: {
        'license_id': licenseId,
        'device_id': deviceId,
      },
    );
    final publicationId = response['publication_id'];
    final keyId = response['key_id'];
    final payloadText = response['manifest'];
    final signatureText = response['signature'];
    if (publicationId != update.publicationId ||
        keyId != update.signingKeyId ||
        payloadText is! String ||
        signatureText is! String) {
      throw const FormatException('بيانات manifest لا تطابق الإصدار المطلوب.');
    }

    late final List<int> payload;
    late final List<int> signature;
    try {
      payload = base64Decode(payloadText);
      signature = base64Decode(signatureText);
      if (base64Encode(payload) != payloadText ||
          base64Encode(signature) != signatureText ||
          payload.isEmpty ||
          payload.length > 64 * 1024 ||
          signature.length != 64) {
        throw const FormatException();
      }
    } on FormatException {
      throw const FormatException('ترميز manifest أو توقيعه غير صالح.');
    }

    // لا نفك JSON ولا نستخدم أي مطالبة قبل التحقق من التوقيع التشغيلي.
    final keyset = await _signingTrust.fetchAndAccept(_api);
    final trustedKey = keyset.keyForVerification(
      keyId: keyId as String,
      purpose: 'update_manifest',
      at: DateTime.now().toUtc(),
    );
    final verified = await _ed25519.verify(
      payload,
      signature: Signature(signature, publicKey: trustedKey.publicKey),
    );
    if (!verified) {
      throw const FormatException('فشل التحقق من توقيع تحديث Homi.');
    }

    final claimsValue = jsonDecode(utf8.decode(payload));
    if (claimsValue is! Map<String, dynamic>) {
      throw const FormatException('محتوى manifest غير صالح.');
    }
    final claims = claimsValue;
    _validateClaims(
      claims,
      update: update,
      productKey: productKey,
      platform: platform,
      architecture: architecture,
      channel: channel,
    );
    final publishedAt = _parseManifestTimestamp(claims['published_at']);
    keyset.validateSignatureTime(
      key: trustedKey,
      signedAt: publishedAt,
      now: DateTime.now().toUtc(),
    );

    return VerifiedPlatformUpdateManifest(
      publicationId: update.publicationId,
      keyId: update.signingKeyId,
      payload: payload,
      signature: signature,
      downloadPath: claims['download_url'] as String,
      version: update.version,
      versionCode: update.versionCode,
      fileName: update.fileName,
      sizeBytes: update.sizeBytes,
      sha256: update.sha256,
      releaseNotes: claims['release_notes'] as String?,
    );
  }

  /// ينزل الحزمة إلى مجلد مؤقت ويتحقق من الحجم وSHA-256 قبل إتاحتها للتثبيت.
  Future<File> downloadVerifiedPackage({
    required String accessToken,
    required VerifiedPlatformUpdateManifest manifest,
    PlatformUpdateDownloader? downloader,
  }) async {
    if (manifest.sizeBytes < 1 ||
        manifest.sizeBytes > 1024 * 1024 * 1024 ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$')
            .hasMatch(manifest.fileName) ||
        manifest.fileName.contains('..') ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(manifest.sha256)) {
      throw const FormatException('بيانات ملف تحديث Homi غير آمنة.');
    }

    final uri = _api.resolveApiUri(manifest.downloadPath);
    final directory = await Directory.systemTemp.createTemp('homi-ota-');
    final file = File('${directory.path}/${manifest.fileName}');
    try {
      final transfer = downloader ?? IoPlatformUpdateDownloader();
      await transfer.download(
        uri: uri,
        accessToken: accessToken,
        destination: file,
        expectedSizeBytes: manifest.sizeBytes,
      );
      final actualLength = await file.length();
      if (actualLength != manifest.sizeBytes) {
        throw const FormatException(
          'حجم حزمة تحديث Homi لا يطابق manifest.',
        );
      }

      final digest = await crypto.sha256.bind(file.openRead()).first;
      if (digest.toString() != manifest.sha256) {
        throw const FormatException(
          'فشل التحقق من SHA-256 لحزمة تحديث Homi.',
        );
      }
      return file;
    } catch (_) {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      rethrow;
    }
  }


  void _validateClaims(
    Map<String, dynamic> claims, {
    required PlatformUpdateInfo update,
    required String productKey,
    required String platform,
    required String architecture,
    required String channel,
  }) {
    final expectedDownloadPath =
        '/api/v1/updates/${update.publicationId}/download';
    if (claims['schema_version'] != 1 ||
        claims['publication_id'] != update.publicationId ||
        claims['product_key'] != productKey ||
        claims['platform'] != platform ||
        (claims['architecture'] != architecture &&
            claims['architecture'] != 'universal') ||
        claims['channel'] != channel ||
        claims['version'] != update.version ||
        claims['version_code'] != update.versionCode ||
        claims['file_name'] != update.fileName ||
        claims['size_bytes'] != update.sizeBytes ||
        claims['sha256'] != update.sha256 ||
        claims['key_id'] != update.signingKeyId ||
        claims['download_url'] != expectedDownloadPath) {
      throw const FormatException('محتوى manifest لا يطابق بيانات الإصدار.');
    }
    final publishedAt = claims['published_at'];
    if (publishedAt is! String || DateTime.tryParse(publishedAt) == null) {
      throw const FormatException('تاريخ نشر manifest غير صالح.');
    }
  }

  DateTime _parseManifestTimestamp(Object? value) {
    if (value is! String ||
        !RegExp(r'^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\d(?:\\.\\d+)?(?:Z|[+-]\\d\\d:\\d\\d)$')
            .hasMatch(value)) {
      throw const FormatException('تاريخ توقيع manifest يجب أن يتضمن منطقة زمنية.');
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      throw const FormatException('تاريخ نشر manifest غير صالح.');
    }
    return parsed.toUtc();
  }

}
)
        signingKeyId is! String) {
      throw const FormatException('بيانات الإصدار المتاح غير مكتملة.');
    }
    return PlatformUpdateInfo(
      publicationId: publicationId,
      version: version,
      versionCode: versionCode.toInt(),
      fileName: fileName,
      sizeBytes: sizeBytes.toInt(),
      sha256: sha256,
      signingKeyId: signingKeyId,
    );
  }

  Future<VerifiedPlatformUpdateManifest> fetchVerifiedManifest({
    required String accessToken,
    required PlatformUpdateInfo update,
    required String licenseId,
    required String deviceId,
    required String productKey,
    required String platform,
    required String architecture,
    required String channel,
  }) async {
    final response = await _api.getJson(
      '/api/v1/updates/${update.publicationId}/manifest',
      accessToken: accessToken,
      query: {
        'license_id': licenseId,
        'device_id': deviceId,
      },
    );
    final publicationId = response['publication_id'];
    final keyId = response['key_id'];
    final payloadText = response['manifest'];
    final signatureText = response['signature'];
    if (publicationId != update.publicationId ||
        keyId != update.signingKeyId ||
        payloadText is! String ||
        signatureText is! String) {
      throw const FormatException('بيانات manifest لا تطابق الإصدار المطلوب.');
    }

    late final List<int> payload;
    late final List<int> signature;
    try {
      payload = base64Decode(payloadText);
      signature = base64Decode(signatureText);
      if (base64Encode(payload) != payloadText ||
          base64Encode(signature) != signatureText ||
          payload.isEmpty ||
          payload.length > 64 * 1024 ||
          signature.length != 64) {
        throw const FormatException();
      }
    } on FormatException {
      throw const FormatException('ترميز manifest أو توقيعه غير صالح.');
    }

    // لا نفك JSON ولا نستخدم أي مطالبة قبل التحقق من التوقيع التشغيلي.
    final keyset = await _signingTrust.fetchAndAccept(_api);
    final trustedKey = keyset.keyForVerification(
      keyId: keyId as String,
      purpose: 'update_manifest',
      at: DateTime.now().toUtc(),
    );
    final verified = await _ed25519.verify(
      payload,
      signature: Signature(signature, publicKey: trustedKey.publicKey),
    );
    if (!verified) {
      throw const FormatException('فشل التحقق من توقيع تحديث Homi.');
    }

    final claimsValue = jsonDecode(utf8.decode(payload));
    if (claimsValue is! Map<String, dynamic>) {
      throw const FormatException('محتوى manifest غير صالح.');
    }
    final claims = claimsValue;
    _validateClaims(
      claims,
      update: update,
      productKey: productKey,
      platform: platform,
      architecture: architecture,
      channel: channel,
    );
    final publishedAt = _parseManifestTimestamp(claims['published_at']);
    keyset.validateSignatureTime(
      key: trustedKey,
      signedAt: publishedAt,
      now: DateTime.now().toUtc(),
    );

    return VerifiedPlatformUpdateManifest(
      publicationId: update.publicationId,
      keyId: update.signingKeyId,
      payload: payload,
      signature: signature,
      downloadPath: claims['download_url'] as String,
      version: update.version,
      versionCode: update.versionCode,
      fileName: update.fileName,
      sizeBytes: update.sizeBytes,
      sha256: update.sha256,
      releaseNotes: claims['release_notes'] as String?,
    );
  }

  /// ينزل الحزمة إلى مجلد مؤقت ويتحقق من الحجم وSHA-256 قبل إتاحتها للتثبيت.
  Future<File> downloadVerifiedPackage({
    required String accessToken,
    required VerifiedPlatformUpdateManifest manifest,
    PlatformUpdateDownloader? downloader,
  }) async {
    if (manifest.sizeBytes < 1 ||
        manifest.sizeBytes > 1024 * 1024 * 1024 ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$')
            .hasMatch(manifest.fileName) ||
        manifest.fileName.contains('..') ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(manifest.sha256)) {
      throw const FormatException('بيانات ملف تحديث Homi غير آمنة.');
    }

    final uri = _api.resolveApiUri(manifest.downloadPath);
    final directory = await Directory.systemTemp.createTemp('homi-ota-');
    final file = File('${directory.path}/${manifest.fileName}');
    try {
      final transfer = downloader ?? IoPlatformUpdateDownloader();
      await transfer.download(
        uri: uri,
        accessToken: accessToken,
        destination: file,
        expectedSizeBytes: manifest.sizeBytes,
      );
      final actualLength = await file.length();
      if (actualLength != manifest.sizeBytes) {
        throw const FormatException(
          'حجم حزمة تحديث Homi لا يطابق manifest.',
        );
      }

      final digest = await crypto.sha256.bind(file.openRead()).first;
      if (digest.toString() != manifest.sha256) {
        throw const FormatException(
          'فشل التحقق من SHA-256 لحزمة تحديث Homi.',
        );
      }
      return file;
    } catch (_) {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      rethrow;
    }
  }


  void _validateClaims(
    Map<String, dynamic> claims, {
    required PlatformUpdateInfo update,
    required String productKey,
    required String platform,
    required String architecture,
    required String channel,
  }) {
    final expectedDownloadPath =
        '/api/v1/updates/${update.publicationId}/download';
    if (claims['schema_version'] != 1 ||
        claims['publication_id'] != update.publicationId ||
        claims['product_key'] != productKey ||
        claims['platform'] != platform ||
        (claims['architecture'] != architecture &&
            claims['architecture'] != 'universal') ||
        claims['channel'] != channel ||
        claims['version'] != update.version ||
        claims['version_code'] != update.versionCode ||
        claims['file_name'] != update.fileName ||
        claims['size_bytes'] != update.sizeBytes ||
        claims['sha256'] != update.sha256 ||
        claims['key_id'] != update.signingKeyId ||
        claims['download_url'] != expectedDownloadPath) {
      throw const FormatException('محتوى manifest لا يطابق بيانات الإصدار.');
    }
    final publishedAt = claims['published_at'];
    if (publishedAt is! String || DateTime.tryParse(publishedAt) == null) {
      throw const FormatException('تاريخ نشر manifest غير صالح.');
    }
  }

  DateTime _parseManifestTimestamp(Object? value) {
    if (value is! String ||
        !RegExp(r'^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\d(?:\\.\\d+)?(?:Z|[+-]\\d\\d:\\d\\d)$')
            .hasMatch(value)) {
      throw const FormatException('تاريخ توقيع manifest يجب أن يتضمن منطقة زمنية.');
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      throw const FormatException('تاريخ نشر manifest غير صالح.');
    }
    return parsed.toUtc();
  }

}
