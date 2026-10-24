import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/main.dart';

void main() {
  testWidgets('dashboard starts in Arabic and shows Homi Grocery', (tester) async {
    await tester.pumpWidget(const HomiGroceryApp());

    expect(find.text('الرئيسية'), findsWidgets);
    expect(find.text('Homi Grocery'), findsOneWidget);
    expect(find.text('مبيعات اليوم'), findsOneWidget);
  });
}
