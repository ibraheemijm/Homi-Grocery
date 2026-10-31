import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/data/purchase_pricing.dart';

void main() {
  group('حساب سعر البيع في فاتورة الشراء', () {
    test('زيادة 20% على تكلفة 1000 تعطي 1200', () {
      expect(
        calculatePurchaseSellingPrice(
          cost: 1000,
          percentage: 20,
          mode: 'markup',
        ),
        1200,
      );
    });

    test('هامش 20% من سعر البيع يعطي 1250 لتكلفة 1000', () {
      expect(
        calculatePurchaseSellingPrice(
          cost: 1000,
          percentage: 20,
          mode: 'margin',
        ),
        1250,
      );
    });

    test('يعكس سعر البيع اليدوي إلى نسبة الزيادة على التكلفة', () {
      expect(
        calculatePurchaseProfitPercentage(
          cost: 1000,
          sellingPrice: 1200,
          mode: 'markup',
        ),
        20,
      );
    });

    test('يعكس سعر البيع اليدوي إلى هامش الربح من سعر البيع', () {
      expect(
        calculatePurchaseProfitPercentage(
          cost: 1000,
          sellingPrice: 1250,
          mode: 'margin',
        ),
        20,
      );
    });

    test('يرفض هامشًا يساوي 100% لتجنب القسمة على صفر', () {
      expect(
        calculatePurchaseSellingPrice(
          cost: 1000,
          percentage: 100,
          mode: 'margin',
        ),
        isNull,
      );
    });
  });
}
