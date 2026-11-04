// اختبارات الواجهة تتحقق من ظهور العناصر الأساسية بعد تشغيل التطبيق.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:homi_grocery/main.dart';
import 'package:homi_grocery/data/grocery_database.dart';
import 'package:homi_grocery/data/auth_repository.dart';
import 'package:homi_grocery/data/customer_repository.dart';
import 'package:homi_grocery/screens/cashier_management_screen.dart';
import 'package:homi_grocery/screens/customers_screen.dart';
import 'package:homi_grocery/screens/sales_screen.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
late Directory _testSupportDirectory;

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

class _CollectionOnlyCustomerSource implements CustomerDataSource {
  @override
  Future<List<CustomerBalance>> balances({
    required int userId,
    String query = '',
  }) async => const [
    CustomerBalance(
      id: 12,
      name: 'عميل اختبار التحصيل',
      salesCount: 1,
      totalDebt: 400,
      totalPaid: 0,
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _testSupportDirectory =
        await Directory.systemTemp.createTemp('homi-widget-tests-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      if (call.method == 'getApplicationSupportDirectory') {
        return _testSupportDirectory.path;
      }
      return null;
    });

    // حساب مدير ثابت للاختبارات التي تقرأ صلاحيات اللوحة والتقارير.
    final database = await GroceryDatabase.open();
    await database.insert('users', {
      'id': 1,
      'username': 'widget_test_manager',
      'display_name': 'مدير الاختبار',
      'password_hash': 'test-hash',
      'password_salt': 'dGVzdA==',
      'password_iterations': 100000,
      'role': 'manager',
      'is_active': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  });

  tearDownAll(() async {
    await GroceryDatabase.closeForMaintenance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    if (await _testSupportDirectory.exists()) {
      await _testSupportDirectory.delete(recursive: true);
    }
  });

  testWidgets('تظهر اللوحة الرئيسية باللغة العربية على شاشة الهاتف',
      (tester) async {
    await tester.pumpWidget(_dashboardApp());

    expect(find.text('الرئيسية'), findsWidgets);
    expect(find.text('مبيعات اليوم'), findsOneWidget);
    expect(find.text('بدء عملية بيع'), findsWidgets);
  });

  testWidgets('تثبت شاشة بيع Android ملخص الفاتورة أسفل قائمة الأصناف',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SalesScreen(userId: 1)),
        ),
      );
      // انتظر انتهاء تهيئة شاشة البيع نفسها بدل الاعتماد على تأخير زمني ثابت.
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );

      expect(find.text('اختيار الأصناف'), findsOneWidget);
      expect(find.text('عرض الفاتورة'), findsOneWidget);
      expect(find.text('0 صنف في الفاتورة'), findsOneWidget);

      await tester.tap(find.text('عرض الفاتورة'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('الفاتورة الحالية'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('تعرض لوحة المدير على Android تحديث السحب ومحتوى الهاتف',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // يعاد ضبط متغير المنصة قبل انتهاء جسم الاختبار حتى لا يتسرب إلى اختبارات Flutter التالية.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(_dashboardApp());
      await tester.pump();

      expect(find.byType(RefreshIndicator), findsOneWidget);
      expect(find.text('مرحبًا، مدير الاختبار'), findsOneWidget);
      expect(find.text('الوصول السريع'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('آخر الفواتير'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('آخر الفواتير'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
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

  testWidgets('يعرض قسم المصروفات دون إجمالي الخزينة للكاشير', (tester) async {
    const cashier = AuthUser(id: 43, username: 'cashier_operations', displayName: 'كاشير العمليات', role: 'cashier');
    await tester.pumpWidget(MaterialApp(home: CashierWorkspaceScreen(cashier: cashier, shiftId: 9, onLogout: () {}, permissionLoader: () async => <String>{'supplier_purchases', 'supplier_payments', 'cash_expenses'}, salesScreenBuilder: (_) => const Center(child: Text('بيع تجريبي')))));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('الأقسام المسموح بها'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('الموردون والمشتريات'), findsOneWidget);
    expect(find.text('المصروفات'), findsOneWidget);
    expect(find.text('الخزينة'), findsNothing);
    expect(find.text('التقارير'), findsNothing);
  });

  testWidgets('يعرض مساحة الكاشير أقسامه المسموح بها دون أدوات المدير',
      (tester) async {
    const cashier = AuthUser(
      id: 42,
      username: 'cashier_one',
      displayName: 'الكاشير الأول',
      role: 'cashier',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: CashierWorkspaceScreen(
          cashier: cashier,
          shiftId: 8,
          onLogout: () {},
          // اختبار الأقسام لا يحتاج فتح قاعدة البيانات أو تهيئة شاشة البيع.
          permissionLoader: () async => <String>{},
          salesScreenBuilder: (_) =>
              const Center(child: Text('محتوى البيع التجريبي')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Homi Grocery'), findsOneWidget);
    expect(find.byTooltip('الأقسام المسموح بها'), findsOneWidget);
    // اسم القسم يظهر ضمن العنوان الفرعي مع اسم الكاشير.
    expect(find.textContaining('المبيعات • الكاشير الأول'), findsOneWidget);
    expect(find.text('محتوى البيع التجريبي'), findsOneWidget);
    await tester.tap(find.byTooltip('الأقسام المسموح بها'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('أقسام الكاشير'), findsOneWidget);
    expect(find.text('المبيعات'), findsWidgets);
    expect(find.text('مبيعات اليوم'), findsNothing);
    expect(find.text('إدارة الكاشيرين'), findsNothing);
    expect(find.text('التقارير'), findsNothing);
    expect(find.byTooltip('تسجيل الخروج وتسليم الوردية'), findsOneWidget);
  });
  testWidgets('يخفي تفاصيل دفتر الزبون عن الكاشير المصرح له بالتحصيل فقط',
      (tester) async {
    final repository = _CollectionOnlyCustomerSource();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomersScreen(
          userId: 7,
          cashierPermissions: const {'customer_collections'},
          repository: repository,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('عميل اختبار التحصيل'), findsOneWidget);
    expect(find.text('400 ج.س'), findsOneWidget);
    expect(find.text('الرصيد المستحق'), findsOneWidget);
    expect(find.textContaining('الفواتير:'), findsNothing);
    expect(find.byTooltip('كشف الحساب'), findsNothing);
    expect(find.byTooltip('تسجيل تحصيل'), findsOneWidget);
  });

}
