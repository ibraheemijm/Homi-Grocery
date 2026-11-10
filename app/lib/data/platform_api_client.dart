// عميل HTTP لمنصة Homi مع تحقق TLS وأخطاء API موحدة.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;

class PlatformApiConfigurationException implements Exception {
  const PlatformApiConfigurationException(this.message);
  final String message;

  @override
  String toString() => message;
}

class PlatformApiException implements Exception {
  const PlatformApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.requestId,
  });

  final int statusCode;
  final String code;
  final String message;
  final String? requestId;

  @override
  String toString() => '$code ($statusCode): $message';
}

class PlatformHttpResponse {
  const PlatformHttpResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final String body;
}

abstract interface class PlatformHttpTransport {
  Future<PlatformHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  });

  void close();
}

class IoPlatformHttpTransport implements PlatformHttpTransport {
  IoPlatformHttpTransport({HttpClient? client})
      : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<PlatformHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    final request = await _client.openUrl(method, uri).timeout(
          const Duration(seconds: 15),
        );
    headers.forEach(request.headers.set);
    if (body != null) {
      final bytes = utf8.encode(body);
      request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
    final responseBody = await utf8.decoder.bind(response).join().timeout(
          const Duration(seconds: 30),
        );
    return PlatformHttpResponse(
      statusCode: response.statusCode,
      body: responseBody,
    );
  }

  @override
  void close() => _client.close(force: true);
}

class PlatformApiClient {
  PlatformApiClient({
    required Uri baseUri,
    PlatformHttpTransport? transport,
    this.timeout = const Duration(seconds: 30),
  })  : _baseUri = _validateBaseUri(baseUri),
        _transport = transport ?? IoPlatformHttpTransport();

  static const String apiPrefix = '/api/v1';

  final Uri _baseUri;
  final PlatformHttpTransport _transport;
  final Duration timeout;

  /// يقرأ عنوان المنصة من dart-define؛ لا يوجد عنوان إنتاجي مفترض أو مضمن.
  factory PlatformApiClient.fromEnvironment({
    PlatformHttpTransport? transport,
  }) {
    const configured = String.fromEnvironment('HOMI_PLATFORM_BASE_URL');
    if (configured.trim().isEmpty) {
      throw const PlatformApiConfigurationException(
        'لم يتم إعداد عنوان Homi Platform لهذا الإصدار.',
      );
    }
    final uri = Uri.tryParse(configured.trim());
    if (uri == null) {
      throw const PlatformApiConfigurationException(
        'عنوان Homi Platform غير صالح.',
      );
    }
    return PlatformApiClient(baseUri: uri, transport: transport);
  }

  static Uri _validateBaseUri(Uri uri) {
    final localHost = kDebugMode &&
        const {'localhost', '127.0.0.1', '10.0.2.2'}.contains(uri.host);
    if (!uri.hasAuthority ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && !(uri.scheme == 'http' && localHost)) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const PlatformApiConfigurationException(
        'يجب أن يكون عنوان المنصة HTTPS صالحًا؛ يسمح بـ HTTP لعناوين التطوير المحلية فقط.',
      );
    }
    return uri.replace(path: '/');
  }

  /// يحول مسار API داخليًا إلى URI دون السماح بمضيف خارجي أو مسار خارج v1.
  Uri resolveApiUri(String path) {
    if (!path.startsWith(apiPrefix) ||
        path.contains('..') ||
        path.contains('\\') ||
        path.contains('?') ||
        path.contains('#')) {
      throw const PlatformApiConfigurationException(
        'مسار API غير صالح أو خارج الإصدار v1.',
      );
    }
    return _baseUri.resolve(path.substring(1));
  }

  Future<Map<String, Object?>> getJson(
    String path, {
    Map<String, String> query = const {},
    String? accessToken,
  }) {
    return requestJson(
      method: 'GET',
      path: path,
      query: query,
      accessToken: accessToken,
    );
  }

  Future<Map<String, Object?>> postJson(
    String path, {
    required Map<String, Object?> body,
    String? accessToken,
    String? idempotencyKey,
  }) {
    return requestJson(
      method: 'POST',
      path: path,
      body: body,
      accessToken: accessToken,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<Map<String, Object?>> requestJson({
    required String method,
    required String path,
    Map<String, String> query = const {},
    Map<String, Object?>? body,
    String? accessToken,
    String? idempotencyKey,
  }) async {
    if (!path.startsWith(apiPrefix) ||
        path.contains('..') ||
        path.contains('\\')) {
      throw const PlatformApiConfigurationException(
        'مسار API غير صالح أو خارج الإصدار v1.',
      );
    }
    final uri = _baseUri.resolve(path.substring(1)).replace(
          queryParameters: query.isEmpty ? null : query,
        );
    final headers = <String, String>{
      HttpHeaders.acceptHeader: 'application/json',
    };
    if (accessToken != null && accessToken.isNotEmpty) {
      headers[HttpHeaders.authorizationHeader] = 'Bearer $accessToken';
    }
    if (idempotencyKey != null) {
      if (idempotencyKey.length < 8 || idempotencyKey.length > 128) {
        throw const PlatformApiConfigurationException(
          'مفتاح منع التكرار يجب أن يتراوح بين 8 و128 حرفًا.',
        );
      }
      headers['Idempotency-Key'] = idempotencyKey;
    }

    final response = await _transport
        .send(
          method: method,
          uri: uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        )
        .timeout(timeout);

    Map<String, dynamic> decoded;
    try {
      final value = jsonDecode(response.body);
      if (value is! Map<String, dynamic>) throw const FormatException();
      decoded = value;
    } on FormatException {
      throw PlatformApiException(
        statusCode: response.statusCode,
        code: 'INVALID_SERVER_RESPONSE',
        message: 'استجابة المنصة غير مفهومة.',
      );
    }

    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        decoded['success'] != true) {
      final error = decoded['error'];
      final details = error is Map<String, dynamic> ? error : const {};
      throw PlatformApiException(
        statusCode: response.statusCode,
        code: details['code'] is String
            ? details['code'] as String
            : 'PLATFORM_REQUEST_FAILED',
        message: details['message'] is String
            ? details['message'] as String
            : 'تعذر إكمال الطلب إلى المنصة.',
        requestId: details['request_id'] is String
            ? details['request_id'] as String
            : null,
      );
    }

    final data = decoded['data'];
    if (data is! Map<String, dynamic>) {
      throw PlatformApiException(
        statusCode: response.statusCode,
        code: 'INVALID_SERVER_RESPONSE',
        message: 'صيغة بيانات المنصة غير صالحة.',
        requestId: (decoded['meta'] as Map?)?['request_id'] as String?,
      );
    }
    return Map<String, Object?>.from(data);
  }

  void close() => _transport.close();
}
