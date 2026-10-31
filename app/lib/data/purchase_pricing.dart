// دوال حساب سعر البيع ونسبة الربح في فاتورة الشراء دون الاعتماد على عناصر الواجهة.

int? calculatePurchaseSellingPrice({
  required int cost,
  required double percentage,
  required String mode,
}) {
  if (cost < 0 || !percentage.isFinite) return null;
  double selling;
  if (mode == 'markup') {
    selling = cost * (1 + percentage / 100);
  } else if (mode == 'margin') {
    if (percentage >= 100) return null;
    selling = cost / (1 - percentage / 100);
  } else {
    return null;
  }
  if (!selling.isFinite || selling < 0 || selling > 9000000000000000) {
    return null;
  }
  return selling.round();
}

double? calculatePurchaseProfitPercentage({
  required int cost,
  required int sellingPrice,
  required String mode,
}) {
  if (cost < 0 || sellingPrice < 0) return null;
  if (mode == 'markup') {
    if (cost == 0) return null;
    return (sellingPrice - cost) / cost * 100;
  }
  if (mode == 'margin') {
    if (sellingPrice == 0) return null;
    return (sellingPrice - cost) / sellingPrice * 100;
  }
  return null;
}
