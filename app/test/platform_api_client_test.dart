import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/data/platform_api_client.dart';

class FakeTransport implements PlatformHttpTransport {
  FakeTransport(this.response);

  final PlatformHttpResponse response;
  Uri? requestedUri;
  Map<String, String>? requestedHeaders;
  String? requestedBody;
  String? requestedMethod;
  bool closed = false;

  @override
  Future<PlatformHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    requestedMethod = method;
    requestedUri = uri;
    requestedHeaders = headers;
    requestedBody = body;
    return response;
  }

  @override
  void close() => closed = true;
}

void main() {
  test('يرفض عنوان HTTP غير محلي ولا يفترض عنوان خادم إنتاجي', () {
    expect(
      () => PlatformApiClient(baseUri: Uri.parse('http://platform.example.com')),
      throwsA(isA<PlatformApiConfigurationException>()),
    );
    expect(
      () => PlatformApiClient.fromEnvironment(),
      throwsA(isA<PlatformApiConfigurationException>()),
    );
    expect(
      () => PlatformApiClient(baseUri: Uri.parse('http://10.0.2.2:8787')),
      returnsNormally,
    );
  });

  test('يرسل طلب API بمسار v1 وترويسة المصادقة ومفتاح منع التكرار', () async {
    final transport = FakeTransport(const PlatformHttpResponse(
      statusCode: 201,
      body: '{"success":true,"data":{"created":true},"meta":{"request_id":"req-1"}}',
    ));
    final api = PlatformApiClient(
      baseUri: Uri.parse('https://platform.example.test/'),
      transport: transport,
    );

    final result = await api.postJson(
      '/api/v1/subscription-requests',
      accessToken: 'access-token',
      idempotencyKey: 'request-key-0001',
      body: {'plan_key': 'monthly'},
    );

    expect(result['created'], isTrue);
    expect(transport.requestedMethod, 'POST');
    expect(transport.requestedUri!.path, '/api/v1/subscription-requests');
    expect(transport.requestedHeaders!['authorization'], 'Bearer access-token');
    expect(transport.requestedHeaders!['Idempotency-Key'], 'request-key-0001');
    expect(jsonDecode(transport.requestedBody!), {'plan_key': 'monthly'});
    api.close();
    expect(transport.closed, isTrue);
  });


  test('لا يتبع تحويلات HTTP إلى وجهة أخرى', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requestCount = 0;
    final serving = server.listen((request) async {
      requestCount++;
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(HttpHeaders.locationHeader, '/redirect-target');
      await request.response.close();
    });
    final transport = IoPlatformHttpTransport();
    try {
      final response = await transport.send(
        method: 'GET',
        uri: Uri.parse('http://127.0.0.1:${server.port}/api/v1/test'),
        headers: const {'authorization': 'Bearer secret-test'},
      );
      expect(response.statusCode, HttpStatus.found);
      expect(requestCount, 1);
    } finally {
      transport.close();
      await serving.cancel();
      await server.close(force: true);
    }
  });

  test('يعرض رمز الخطأ ومعرف الطلب دون كشف تفاصيل داخلية', () async {
    final transport = FakeTransport(const PlatformHttpResponse(
      statusCode: 403,
      body: '{"success":false,"error":{"code":"LICENSE_NOT_ACTIVE","message":"License is not active.","request_id":"req-2"}}',
    ));
    final api = PlatformApiClient(
      baseUri: Uri.parse('https://platform.example.test'),
      transport: transport,
    );

    await expectLater(
      api.getJson('/api/v1/licenses'),
      throwsA(
        isA<PlatformApiException>()
            .having((error) => error.code, 'code', 'LICENSE_NOT_ACTIVE')
            .having((error) => error.statusCode, 'status', 403)
            .having((error) => error.requestId, 'requestId', 'req-2'),
      ),
    );
  });

  test('يرفض المسارات خارج API v1 ومفاتيح منع التكرار غير الصالحة', () async {
    final transport = FakeTransport(const PlatformHttpResponse(
      statusCode: 200,
      body: '{"success":true,"data":{}}',
    ));
    final api = PlatformApiClient(
      baseUri: Uri.parse('https://platform.example.test'),
      transport: transport,
    );

    await expectLater(
      api.getJson('/admin/users'),
      throwsA(isA<PlatformApiConfigurationException>()),
    );
    await expectLater(
      api.postJson(
        '/api/v1/subscription-requests',
        body: const {},
        idempotencyKey: 'short',
      ),
      throwsA(isA<PlatformApiConfigurationException>()),
    );
  });

  test('يرفض مسارات API الملتبسة وطرق HTTP غير المدعومة', () async {
    final api = PlatformApiClient(
      baseUri: Uri.parse('https://platform.example.test'),
      transport: FakeTransport(const PlatformHttpResponse(
        statusCode: 200,
        body: '{"success":true,"data":{}}',
      )),
    );

    for (final path in [
      '/api/v10/users',
      '/api/v1/users?admin=true',
      '/api/v1/../admin',
      '/api/v1/users/encoded%2fadmin',
    ]) {
      await expectLater(
        api.getJson(path),
        throwsA(isA<PlatformApiConfigurationException>()),
      );
    }
    expect(
      () => api.resolveApiUri('/api/v1/../admin'),
      throwsA(isA<PlatformApiConfigurationException>()),
    );
    await expectLater(
      api.requestJson(method: 'TRACE', path: '/api/v1/test'),
      throwsA(isA<PlatformApiConfigurationException>()),
    );
  });

  test('يوقف قراءة استجابة HTTP التي تتجاوز الحد الأقصى', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serving = server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = PlatformApiClient.maxResponseBytes + 1;
      request.response.add(
        List<int>.filled(PlatformApiClient.maxResponseBytes + 1, 65),
      );
      await request.response.close();
    });
    final transport = IoPlatformHttpTransport();
    try {
      await expectLater(
        transport.send(
          method: 'GET',
          uri: Uri.parse('http://127.0.0.1:${server.port}/api/v1/test'),
          headers: const {},
        ),
        throwsA(isA<FormatException>()),
      );
    } finally {
      transport.close();
      await serving.cancel();
      await server.close(force: true);
    }
  });

}
