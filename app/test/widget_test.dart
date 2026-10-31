// اختبارات الواجهة تتحقق من ظهور العناصر الأساسية بعد تشغيل التطبيق.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/main.dart';
import 'package:homi_grocery/data/auth_repository.dart';
import 'package:homi_grocery/screens/cashier_management_screen.dart';

class _TestDashboardApp extends StatefulWidget {
  const _TestDashboardApp();

  @override
  State<_TestDashboardApp> createState() => _TestDashboardAppState();
}

class _TestDashboardAppState extends State<_TestDashboardApp> {
  ThemeMode _themeMode = ThemeMode.light;

  @override
  Widget build(BuildContext context) => MaterialApp(
        themeMode: _themeMode,
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        home: DashboardScreen(
          isDark: _themeMode == ThemeMode.dark,
          onToggleTheme: () => setState(() {
            _themeMode = _themeMode == ThemeMode.light
                ? ThemeMode.dark
                : ThemeMode.light;
          }),
          user: const AuthUser(
            id: 1,
            username: 'manager',
            displayName: 'مدير الاختبار',
            role: 'manager',
          ),
          shiftId: 1,
          onLogout: () {},
        ),
      );
}

Widget _dashboardApp() => const _TestDashboardApp();

void main() {
  testWidgets('تظهر اللوحة الرئيسية باللغة العربية على شاشة الهاتف',
      (tester) async {
    await tester.pumpWidget(_dashboardApp());

    expect(find.text('الرئيسية'), findsWidgets);
    expect(find.text('مبيعات اليوم'), findsOneWidget);
    expect(find.text('بدء عملية بيع'), findsWidgets);
  });

  testWidgets('يحافظ عنصر التنقل المحدد على تباين واضح في المظهر الداكن',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_dashboardApp());
    await tester.pump();

    await tester.tap(find.byTooltip('المظهر الداكن'));
    await tester.pump();

    final selectedTileFinder = find.widgetWithText(ListTile, 'الرئيسية');
    final selectedTile = tester.widget<ListTile>(selectedTileFinder);
    expect(selectedTile.selectedTileColor, const Color(0xFF315047));

    final selectedTextFinder = find.descendant(
      of: selectedTileFinder,
      matching: find.text('الرئيسية'),
    );
    final selectedText = tester.widget<Text>(selectedTextFinder);
    expect(selectedText.style?.color, Colors.white);
  });

  testWidgets('تفتح بطاقة مبيعات اليوم شاشة التقارير لا شاشة البيع',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_dashboardApp());
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('مبيعات اليوم'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('التقارير'), findsOneWidget);
    expect(find.text('اختيار الأصناف'), findsNothing);
  });

  testWidgets('يفتح قسم النسخ الاحتياطي والاستعادة من قائمة الأقسام الأخرى',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_dashboardApp());
    await tester.pump();

    // نحدد تسمية «المزيد» داخل شريط التنقل السفلي نفسه، لا أي عنصر مشابه في محتوى الصفحة.
    final moreDestination = find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('المزيد'),
    );
    expect(moreDestination, findsOneWidget);
    await tester.tap(moreDestination);
    // رسوم التطبيق المستمرة تمنع pumpAndSettle؛ ننتظر انتقال القائمة على دفعات.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('الأقسام الأخرى'), findsOneWidget);

    // قد يكون خيار النسخ أسفل الجزء المرئي من القائمة؛ نمرر قائمة النافذة نفسها إليه.
    final moreSheet = find.byType(BottomSheet);
    final sheetScrollable = find.descendant(
      of: moreSheet,
      matching: find.byType(Scrollable),
    ).first;
    await tester.scrollUntilVisible(
      find.text('النسخ الاحتياطي والاستعادة'),
      220,
      scrollable: sheetScrollable,
    );
    expect(find.text('النسخ الاحتياطي والاستعادة'), findsOneWidget);

    await tester.tap(find.text('النسخ الاحتياطي والاستعادة'));
    // شاشة النسخ تعرض مؤشر تحميل متحركًا أثناء فتح قاعدة البيانات؛ لا ننتظر سكون كل الرسوم.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('النسخ الاحتياطي والاستعادة'), findsWidgets);
    expect(find.text('إنشاء نسخة احتياطية الآن'), findsOneWidget);
    expect(find.text('اختيار نسخة واستعادتها'), findsOneWidget);
  });

  testWidgets('يفتح الكاشير نقطة بيع مبسطة دون أدوات المدير', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CashierWorkspaceScreen(
          cashier: const AuthUser(
            id: 2,
            username: 'cashier_one',
            displayName: 'الكاشير الأول',
            role: 'cashier',
          ),
          shiftId: 8,
          onLogout: () {},
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('نقطة البيع'), findsOneWidget);
    expect(find.byTooltip('تسجيل الخروج وتسليم الوردية'), findsOneWidget);
    expect(find.text('مبيعات اليوم'), findsNothing);
    expect(find.text('إدارة الكاشيرين'), findsNothing);
    expect(find.text('التقارير'), findsNothing);
  });

}
