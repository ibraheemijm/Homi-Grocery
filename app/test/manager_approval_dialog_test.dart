import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homi_grocery/widgets/manager_approval_dialog.dart';

void main() {
  testWidgets('يتحقق من الحقول ويعيد بيانات المدير بعد الإكمال', (tester) async {
    ManagerApprovalCredentials? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<ManagerApprovalCredentials>(
                  context: context,
                  builder: (_) => const ManagerApprovalDialog(
                    discountAmount: 125,
                  ),
                );
              },
              child: const Text('فتح نافذة الموافقة'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('فتح نافذة الموافقة'));
    await tester.pumpAndSettle();
    expect(find.text('الخصم الحالي: 125 ج.س'), findsOneWidget);

    await tester.tap(find.text('التحقق والموافقة'));
    await tester.pumpAndSettle();
    expect(
      find.text('أدخل اسم المستخدم وكلمة المرور.'),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('manager-approval-username')),
      'store_manager',
    );
    await tester.enterText(
      find.byKey(const ValueKey('manager-approval-password')),
      'StrongPass!2026',
    );
    final passwordField = tester.widget<TextField>(
      find.byKey(const ValueKey('manager-approval-password')),
    );
    expect(passwordField.obscureText, isTrue);

    await tester.tap(find.text('التحقق والموافقة'));
    await tester.pumpAndSettle();

    expect(result?.username, 'store_manager');
    expect(result?.password, 'StrongPass!2026');
    expect(find.text('موافقة المدير مطلوبة'), findsNothing);
  });

  testWidgets('يسمح بإلغاء طلب الموافقة دون إرجاع بيانات اعتماد', (tester) async {
    ManagerApprovalCredentials? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<ManagerApprovalCredentials>(
                  context: context,
                  builder: (_) => const ManagerApprovalDialog(
                    discountAmount: 80,
                  ),
                );
              },
              child: const Text('فتح نافذة الموافقة'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('فتح نافذة الموافقة'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إلغاء البيع'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.text('موافقة المدير مطلوبة'), findsNothing);
  });
}
