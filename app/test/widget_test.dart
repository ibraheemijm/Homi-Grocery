// اختبارات الواجهة تتحقق من ظهور العناصر الأساسية بعد تشغيل التطبيق.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/main.dart';

void main() {
  testWidgets('تظهر اللوحة الرئيسية باللغة العربية على شاشة الهاتف',
      (tester) async {
    await tester.pumpWidget(const HomiGroceryApp());

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

    await tester.pumpWidget(const HomiGroceryApp());
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

    await tester.pumpWidget(const HomiGroceryApp());
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('مبيعات اليوم'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('التقارير'), findsOneWidget);
    expect(find.text('اختيار الأصناف'), findsNothing);
  });

  testWidgets('يفتح قسم النسخ الاحتياطي والاستعادة من قائمة الأقسام الأخرى', (tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const HomiGroceryApp());
    await tester.pump();

    await tester.tap(find.text('المزيد'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('النسخ الاحتياطي والاستعادة'));
    // شاشة النسخ تعرض مؤشر تحميل متحركًا أثناء فتح قاعدة البيانات؛ لا ننتظر سكون كل الرسوم.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('النسخ الاحتياطي والاستعادة'), findsWidgets);
    expect(find.text('إنشاء نسخة احتياطية الآن'), findsOneWidget);
    expect(find.text('اختيار نسخة واستعادتها'), findsOneWidget);
  });
}
