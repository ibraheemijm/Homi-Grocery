import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/data/platform_device_link_service.dart';
import 'package:homi_grocery/screens/platform_device_link_screen.dart';

class FakeDeviceLinkOperations implements PlatformDeviceLinkOperations {
  final List<PlatformDeviceLinkStatus> statuses = [];
  var requestCalls = 0;
  var completeCalls = 0;
  PlatformActivationRequest? pending;

  @override
  Future<PlatformActivationRequest> requestActivation() async {
    requestCalls++;
    pending = PlatformActivationRequest(
      requestId: '123e4567-e89b-42d3-a456-426614174000',
      keyFingerprint: List.filled(64, 'a').join(),
      platform: 'android',
      architecture: 'arm64-v8a',
      challengeExpiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );
    return pending!;
  }

  @override
  Future<PlatformActivationRequest?> readPendingActivationRequest() async => pending;

  @override
  Future<PlatformDeviceLinkStatus> completePendingActivation() async {
    completeCalls++;
    return statuses.removeAt(0);
  }

  @override
  Future<PlatformLinkedLicense?> readLinkedLicense() async => null;

  @override
  Future<PlatformLinkedLicense?> refreshOfflineGrant() async => null;

  @override
  Future<PlatformLinkedLicense?> readOfflineGrant() async => null;
}

void main() {
  testWidgets('لا يطلب بريدًا أو كلمة مرور وينشئ طلب تفعيل مرتبطًا بالجهاز', (tester) async {
    final service = FakeDeviceLinkOperations();
    await tester.pumpWidget(MaterialApp(
      home: PlatformDeviceLinkScreen(service: service),
    ));

    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('بريد إلكتروني'), findsOneWidget);
    expect(find.text('كلمة المرور'), findsNothing);
    await tester.tap(find.text('إنشاء طلب تفعيل'));
    await tester.pumpAndSettle();

    expect(service.requestCalls, 1);
    expect(find.text('رقم الطلب'), findsOneWidget);
    expect(find.text('بصمة الجهاز'), findsOneWidget);
    expect(find.text('نسخ بيانات طلب التفعيل'), findsOneWidget);
    expect(find.text('مشاركة الطلب (اختر WhatsApp)'), findsOneWidget);
    expect(find.text('إثبات ملكية الجهاز والتحقق'), findsOneWidget);
  });

  testWidgets('يعرض انتظار الإدارة ثم تجهيز الترخيص ونجاح التفعيل', (tester) async {
    final service = FakeDeviceLinkOperations()
      ..statuses.addAll([
        PlatformDeviceLinkStatus.waitingForAdmin,
        PlatformDeviceLinkStatus.licensePending,
        PlatformDeviceLinkStatus.linked,
      ]);
    var linked = false;
    await tester.pumpWidget(MaterialApp(
      home: PlatformDeviceLinkScreen(
        service: service,
        onLinked: () => linked = true,
      ),
    ));

    await tester.tap(find.text('إنشاء طلب تفعيل'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('إثبات ملكية الجهاز والتحقق'));
    await tester.tap(find.text('إثبات ملكية الجهاز والتحقق'));
    await tester.pumpAndSettle();
    expect(find.textContaining('تم إثبات امتلاك الجهاز بنجاح'), findsOneWidget);

    await tester.ensureVisible(find.text('التحقق من حالة التفعيل'));
    await tester.tap(find.text('التحقق من حالة التفعيل'));
    await tester.pumpAndSettle();
    expect(find.textContaining('يجري تجهيز ملف الترخيص الموقّع'), findsOneWidget);

    await tester.ensureVisible(find.text('التحقق من حالة التفعيل'));
    await tester.tap(find.text('التحقق من حالة التفعيل'));
    await tester.pumpAndSettle();
    expect(linked, isTrue);
    expect(find.textContaining('اكتمل التفعيل'), findsOneWidget);
  });
}
