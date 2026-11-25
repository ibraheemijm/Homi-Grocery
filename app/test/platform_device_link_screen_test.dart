import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/data/platform_device_link_service.dart';
import 'package:homi_grocery/screens/platform_device_link_screen.dart';

class FakeDeviceLinkOperations implements PlatformDeviceLinkOperations {
  var requestCalls = 0;
  var importCalls = 0;

  @override
  Future<PlatformActivationRequest> requestActivation({
    String? customerName,
    String? customerPhone,
    String? requestedPlan,
    String? customerNotes,
  }) async {
    requestCalls++;
    throw UnimplementedError();
  }

  @override
  Future<PlatformActivationRequestFile> createActivationRequestFile({
    required String customerName,
    required String customerPhone,
    required String requestedPlan,
    String? customerNotes,
  }) async => const PlatformActivationRequestFile(
    requestId: '123e4567-e89b-42d3-a456-426614174001',
    bytes: [1, 2, 3],
  );

  @override
  Future<PlatformActivationRequest?> readPendingActivationRequest() async => null;

  @override
  Future<PlatformDeviceLinkStatus> completePendingActivation() async {
    throw UnimplementedError();
  }

  @override
  Future<PlatformLinkedLicense> importLicenseFile(List<int> fileBytes) async {
    importCalls++;
    return PlatformLinkedLicense(
      licenseId: '123e4567-e89b-42d3-a456-426614174010',
      deviceId: '123e4567-e89b-42d3-a456-426614174011',
      keyId: 'test-key',
      startsAt: DateTime.utc(2026, 11, 25),
      endsAt: DateTime.utc(2026, 12, 25),
      trialEndsAt: null,
      subscriptionEndsAt: DateTime.utc(2026, 12, 25),
      offlineExpiresAt: DateTime.utc(2026, 12, 2),
      graceEndsAt: DateTime.utc(2026, 12, 9),
      accessPolicy: 'full_until_subscription_end_then_read_export_until_grace_end',
      planKey: 'monthly',
      entitlementVersion: 1,
      signedPayload: const [],
      signature: const [],
      publicKeyDer: const [],
    );
  }

  @override
  Future<PlatformLinkedLicense?> readLinkedLicense() async => null;

  @override
  Future<PlatformLinkedLicense?> startLocalTrial() async => null;

  @override
  Future<PlatformLinkedLicense?> refreshOfflineGrant() async => null;

  @override
  Future<PlatformLinkedLicense?> readOfflineGrant() async => null;
}

void main() {
  testWidgets('يعرض مسار الملفات فقط ولا يعرض التفعيل المباشر عبر الإنترنت', (tester) async {
    final service = FakeDeviceLinkOperations();
    await tester.pumpWidget(MaterialApp(
      home: PlatformDeviceLinkScreen(service: service),
    ));

    expect(find.byType(TextField), findsNWidgets(3));
    expect(find.text('اسم العميل أو المتجر'), findsOneWidget);
    expect(find.text('رقم الهاتف الدولي'), findsOneWidget);
    expect(find.text('إنشاء ومشاركة ملف الطلب (.hreq)'), findsOneWidget);
    expect(find.text('استيراد ملف التفعيل (.hlic)'), findsOneWidget);
    expect(find.textContaining('عبر الملفات فقط'), findsOneWidget);
    expect(find.textContaining('إرسال الطلب عبر الإنترنت'), findsNothing);
    expect(find.textContaining('إثبات ملكية الجهاز'), findsNothing);
    expect(find.text('+249 090 469 7455'), findsOneWidget);
    expect(service.requestCalls, 0);
  });
}
