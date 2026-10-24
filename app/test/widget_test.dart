import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/main.dart';

void main() {
  testWidgets('mobile dashboard starts in Arabic', (tester) async {
    await tester.pumpWidget(const HomiGroceryApp());

    expect(find.text('الرئيسية'), findsWidgets);
    expect(find.text('مبيعات اليوم'), findsOneWidget);
    expect(find.text('بدء عملية بيع'), findsOneWidget);
  });
}
