// اختبارات الواجهة تتحقق من ظهور العناصر الأساسية بعد تشغيل التطبيق.
// أضف اختبارات جديدة عند تنفيذ كل وظيفة، خصوصًا الحسابات المالية والمخزون.
import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/main.dart';

void main() {
  testWidgets('تظهر اللوحة الرئيسية باللغة العربية على شاشة الهاتف',
      (tester) async {
    // تشغيل التطبيق داخل بيئة الاختبار دون الحاجة إلى جهاز فعلي.
    await tester.pumpWidget(const HomiGroceryApp());

    // التحقق من أهم العناصر التي يجب ألا تختفي أثناء تعديل التصميم.
    expect(find.text('الرئيسية'), findsWidgets);
    expect(find.text('مبيعات اليوم'), findsOneWidget);
    expect(find.text('بدء عملية بيع'), findsWidgets);
  });
}
