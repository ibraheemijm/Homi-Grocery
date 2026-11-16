import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/data/platform_device_link_service.dart';
import 'package:homi_grocery/screens/platform_device_link_screen.dart';

class FakeDeviceLinkOperations implements PlatformDeviceLinkOperations {
  final List<PlatformDeviceLinkStatus> statuses = [];
  String? requestedEmail;
  var completeCalls = 0;

  @override
  Future<void> requestLink(String email) async {
    requestedEmail = email;
  }

  @override
  Future<PlatformDeviceLinkStatus> completePendingLink() async {
    completeCalls++;
    return statuses.removeAt(0);
  }
}

void main() {
  testWidgets('يطلب البريد فقط ولا يعرض حقل كلمة مرور منصة Homi', (tester) async {
    final service = FakeDeviceLinkOperations();
    await tester.pumpWidget(MaterialApp(
      home: PlatformDeviceLinkScreen(service: service),
    ));

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('كلمة المرور'), findsNothing);
    await tester.enterText(find.byType(TextField), ' customer@example.test ');
    await tester.tap(find.text('إرسال رابط التأكيد'));
    await tester.pumpAndSettle();

    expect(service.requestedEmail, 'customer@example.test');
    expect(find.textContaining('إذا كان البريد مسجلًا ومؤكدًا'), findsOneWidget);
    expect(find.text('أكدت البريد، أكمل الربط'), findsOneWidget);
  });

  testWidgets('يعرض حالات انتظار البريد وتجهيز الترخيص ثم نجاح الربط', (tester) async {
    final service = FakeDeviceLinkOperations()
      ..statuses.addAll([
        PlatformDeviceLinkStatus.waitingForEmail,
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

    await tester.enterText(find.byType(TextField), 'customer@example.test');
    await tester.tap(find.text('إرسال رابط التأكيد'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('أكدت البريد، أكمل الربط'));
    await tester.pumpAndSettle();
    expect(find.textContaining('لم يتم تأكيد البريد بعد'), findsOneWidget);

    await tester.tap(find.text('أكدت البريد، أكمل الربط'));
    await tester.pumpAndSettle();
    expect(find.textContaining('يجري تجهيز الترخيص الموقّع'), findsOneWidget);

    await tester.tap(find.text('أكدت البريد، أكمل الربط'));
    await tester.pumpAndSettle();
    expect(linked, isTrue);
    expect(find.textContaining('أصبح ترخيص Homi جاهزًا'), findsOneWidget);
    expect(find.text('أكدت البريد، أكمل الربط'), findsNothing);
  });

  testWidgets('يرفض الإرسال دون بريد إلكتروني', (tester) async {
    final service = FakeDeviceLinkOperations();
    await tester.pumpWidget(MaterialApp(
      home: PlatformDeviceLinkScreen(service: service),
    ));

    await tester.tap(find.text('إرسال رابط التأكيد'));
    await tester.pumpAndSettle();

    expect(service.requestedEmail, isNull);
    expect(find.text('أدخل البريد الإلكتروني المرتبط بحساب Homi.'), findsOneWidget);
  });
}
