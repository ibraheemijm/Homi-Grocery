// تقارير يومية من بيانات الفواتير والتحصيلات وحركات الخزينة المسجلة.
import 'package:sqflite/sqflite.dart';

class DailyReport {
  const DailyReport({
    required this.day,
    required this.salesTotal,
    required this.salesCount,
    required this.purchaseTotal,
    required this.purchaseCount,
    required this.customerCollections,
    required this.supplierPayments,
    required this.supplierRefunds,
    required this.returnRefunds,
    required this.saleReturns,
    required this.grossProfit,
    required this.cashIncome,
    required this.cashExpense,
    required this.cashOnlyIncome,
    required this.cashOnlyExpense,
    required this.bankTransferIncome,
    required this.bankTransferExpense,
    required this.lowStockCount,
  });

  final DateTime day;
  final int salesTotal;
  final int salesCount;
  final int purchaseTotal;
  final int purchaseCount;
  final int customerCollections;
  final int supplierPayments;
  final int supplierRefunds;
  final int returnRefunds;
  final int saleReturns;
  /// null إذا كانت هناك فواتير قديمة بلا تكلفة محفوظة وقت البيع.
  final int? grossProfit;
  final int cashIncome;
  final int cashExpense;
  final int cashOnlyIncome;
  final int cashOnlyExpense;
  final int bankTransferIncome;
  final int bankTransferExpense;
  final int lowStockCount;
  int get cashNet => cashIncome - cashExpense;
}

class BestSellingProduct {
  const BestSellingProduct({
    required this.productId,
    required this.name,
    required this.unit,
    required this.soldQuantity,
    required this.returnedQuantity,
  });

  final int productId;
  final String name;
  final String unit;
  final double soldQuantity;
  final double returnedQuantity;
  double get netQuantity => soldQuantity - returnedQuantity;
}

class PeriodReport {
  const PeriodReport({
    required this.start,
    required this.end,
    required this.salesTotal,
    required this.salesCount,
    required this.returnsTotal,
    required this.products,
    required this.grossProfit,
  });

  final DateTime start;
  /// Exclusive end boundary.
  final DateTime end;
  final int salesTotal;
  final int salesCount;
  final int returnsTotal;
  final List<BestSellingProduct> products;
  /// null عندما تتضمن الفترة تكلفة تاريخية مجهولة لأي بيع أو مرتجع.
  final int? grossProfit;
  int get netSalesTotal => salesTotal - returnsTotal;
}

class ReportsRepository {
  ReportsRepository(this._database);
  final Database _database;

  /// تقرير فترة تقويمية؛ الكميات الصافية = المبيعات خلال الفترة ناقص
  /// المرتجعات المسجلة خلالها، مع إبقاء المرتجعات ظاهرة حتى إن تجاوزت المبيعات.
  /// يجمع سجل الأصناف بمعرّف الصنف والوحدة، لا بالاسم التاريخي وحده.
  Future<PeriodReport> loadPeriod({
    required DateTime start,
    required DateTime end,
    int topLimit = 10,
  }) async {
    if (!end.isAfter(start)) {
      throw ArgumentError('نهاية الفترة يجب أن تأتي بعد بدايتها.');
    }
    if (topLimit < 1) {
      throw ArgumentError('عدد الأصناف المعروضة يجب أن يكون أكبر من صفر.');
    }
    final utcStart = start.toUtc().toIso8601String();
    final utcEnd = end.toUtc().toIso8601String();
    final totals = await _database.rawQuery('''
      SELECT
        COALESCE((SELECT SUM(total) FROM sales
          WHERE created_at >= ? AND created_at < ?), 0) AS sales_total,
        (SELECT COUNT(*) FROM sales
          WHERE created_at >= ? AND created_at < ?) AS sales_count,
        COALESCE((SELECT SUM(amount) FROM sale_returns
          WHERE created_at >= ? AND created_at < ?), 0) AS returns_total
    ''', [utcStart, utcEnd, utcStart, utcEnd, utcStart, utcEnd]);
    final cost = await _database.rawQuery('''
      SELECT
        COALESCE(SUM(si.cost_price * si.quantity), 0) AS sold_cost,
        SUM(CASE WHEN si.cost_price IS NULL THEN 1 ELSE 0 END) AS missing_costs
      FROM sale_items si
      JOIN sales s ON s.id = si.sale_id
      WHERE s.created_at >= ? AND s.created_at < ?
    ''', [utcStart, utcEnd]);
    final returnedCost = await _database.rawQuery('''
      SELECT
        COALESCE(SUM(sri.quantity * si.cost_price), 0) AS cost,
        SUM(CASE WHEN si.cost_price IS NULL THEN 1 ELSE 0 END) AS missing_costs
      FROM sale_return_items sri
      JOIN sale_returns sr ON sr.id = sri.return_id
      JOIN sale_items si ON si.id = sri.sale_item_id
      WHERE sr.created_at >= ? AND sr.created_at < ?
    ''', [utcStart, utcEnd]);
    final rows = await _database.rawQuery('''
      WITH activity AS (
        SELECT
          si.product_id AS product_id,
          si.product_name AS product_name,
          si.unit AS unit,
          SUM(si.quantity) AS sold_quantity,
          0.0 AS returned_quantity
        FROM sale_items si
        JOIN sales s ON s.id = si.sale_id
        WHERE s.created_at >= ? AND s.created_at < ?
        GROUP BY si.product_id, si.product_name, si.unit

        UNION ALL

        SELECT
          si.product_id AS product_id,
          si.product_name AS product_name,
          si.unit AS unit,
          0.0 AS sold_quantity,
          SUM(sri.quantity) AS returned_quantity
        FROM sale_return_items sri
        JOIN sale_returns sr ON sr.id = sri.return_id
        JOIN sale_items si ON si.id = sri.sale_item_id
        WHERE sr.created_at >= ? AND sr.created_at < ?
        GROUP BY si.product_id, si.product_name, si.unit
      )
      SELECT product_id, MAX(product_name) AS product_name, unit,
        SUM(sold_quantity) AS sold_quantity,
        SUM(returned_quantity) AS returned_quantity
      FROM activity
      GROUP BY product_id, unit
      ORDER BY (SUM(sold_quantity) - SUM(returned_quantity)) DESC,
        SUM(sold_quantity) DESC, MAX(product_name) COLLATE NOCASE ASC
      LIMIT ?
    ''', [utcStart, utcEnd, utcStart, utcEnd, topLimit]);

    return PeriodReport(
      start: start,
      end: end,
      salesTotal: (totals.single['sales_total'] as num).toInt(),
      salesCount: (totals.single['sales_count'] as num).toInt(),
      returnsTotal: (totals.single['returns_total'] as num).toInt(),
      grossProfit: ((cost.single['missing_costs'] as num? ?? 0).toInt() > 0 ||
              (returnedCost.single['missing_costs'] as num? ?? 0).toInt() > 0)
          ? null
          : (totals.single['sales_total'] as num).toInt() -
              (totals.single['returns_total'] as num).toInt() -
              (cost.single['sold_cost'] as num).round() +
              (returnedCost.single['cost'] as num).round(),
      products: rows.map((row) => BestSellingProduct(
        productId: (row['product_id'] as num).toInt(),
        name: row['product_name'] as String,
        unit: row['unit'] as String,
        soldQuantity: (row['sold_quantity'] as num).toDouble(),
        returnedQuantity: (row['returned_quantity'] as num).toDouble(),
      )).toList(growable: false),
    );
  }

  Future<DailyReport> load({DateTime? day}) async {
    final selected = day ?? DateTime.now();
    final localStart = DateTime(selected.year, selected.month, selected.day);
    final start = localStart.toUtc().toIso8601String();
    final end = localStart.add(const Duration(days: 1)).toUtc().toIso8601String();

    final sales = await _database.rawQuery('''
      SELECT COALESCE(SUM(total), 0) AS total, COUNT(*) AS count
      FROM sales WHERE created_at >= ? AND created_at < ?
    ''', [start, end]);
    final saleReturns = await _database.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) AS total
      FROM sale_returns WHERE created_at >= ? AND created_at < ?
    ''', [start, end]);
    final cost = await _database.rawQuery('''
      SELECT
        COALESCE(SUM(si.cost_price * si.quantity), 0) AS sold_cost,
        SUM(CASE WHEN si.cost_price IS NULL THEN 1 ELSE 0 END) AS missing_costs
      FROM sale_items si
      JOIN sales s ON s.id = si.sale_id
      WHERE s.created_at >= ? AND s.created_at < ?
    ''', [start, end]);
    final returnedCost = await _database.rawQuery('''
      SELECT
        COALESCE(SUM(sri.quantity * si.cost_price), 0) AS cost,
        SUM(CASE WHEN si.cost_price IS NULL THEN 1 ELSE 0 END) AS missing_costs
      FROM sale_return_items sri
      JOIN sale_returns sr ON sr.id = sri.return_id
      JOIN sale_items si ON si.id = sri.sale_item_id
      WHERE sr.created_at >= ? AND sr.created_at < ?
    ''', [start, end]);
    final purchases = await _database.rawQuery('''
      SELECT COALESCE(SUM(total), 0) AS total, COUNT(*) AS count
      FROM purchases WHERE created_at >= ? AND created_at < ?
    ''', [start, end]);
    final customerCollections = await _database.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) AS total
      FROM customer_payments WHERE created_at >= ? AND created_at < ?
    ''', [start, end]);
    final supplierPayments = await _database.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) AS total
      FROM supplier_payments WHERE created_at >= ? AND created_at < ?
    ''', [start, end]);
    final supplierRefunds = await _database.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) AS total
      FROM supplier_return_refunds WHERE created_at >= ? AND created_at < ?
    ''', [start, end]);
    final refunds = await _database.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) AS total
      FROM sale_return_refunds WHERE created_at >= ? AND created_at < ?
    ''', [start, end]);
    final cash = await _database.rawQuery('''
      SELECT
        COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE 0 END), 0) AS income,
        COALESCE(SUM(CASE WHEN direction = 'out' THEN amount ELSE 0 END), 0) AS expense,
        COALESCE(SUM(CASE WHEN direction = 'in' AND payment_method = 'نقدي' THEN amount ELSE 0 END), 0) AS cash_income,
        COALESCE(SUM(CASE WHEN direction = 'out' AND payment_method = 'نقدي' THEN amount ELSE 0 END), 0) AS cash_expense,
        COALESCE(SUM(CASE WHEN direction = 'in' AND payment_method = 'تحويل بنكي' THEN amount ELSE 0 END), 0) AS bank_income,
        COALESCE(SUM(CASE WHEN direction = 'out' AND payment_method = 'تحويل بنكي' THEN amount ELSE 0 END), 0) AS bank_expense
      FROM cash_transactions WHERE created_at >= ? AND created_at < ?
    ''', [start, end]);
    final stock = await _database.rawQuery('''
      SELECT COUNT(*) AS count FROM products
      WHERE is_active = 1 AND stock_quantity <= minimum_quantity
    ''');

    return DailyReport(
      day: localStart,
      salesTotal: (sales.single['total'] as num).toInt(),
      salesCount: (sales.single['count'] as num).toInt(),
      purchaseTotal: (purchases.single['total'] as num).toInt(),
      purchaseCount: (purchases.single['count'] as num).toInt(),
      customerCollections: (customerCollections.single['total'] as num).toInt(),
      supplierPayments: (supplierPayments.single['total'] as num).toInt(),
      supplierRefunds: (supplierRefunds.single['total'] as num).toInt(),
      returnRefunds: (refunds.single['total'] as num).toInt(),
      saleReturns: (saleReturns.single['total'] as num).toInt(),
      grossProfit: ((cost.single['missing_costs'] as num? ?? 0).toInt() > 0 ||
              (returnedCost.single['missing_costs'] as num? ?? 0).toInt() > 0)
          ? null
          : (sales.single['total'] as num).toInt() -
              (saleReturns.single['total'] as num).toInt() -
              (cost.single['sold_cost'] as num).round() +
              (returnedCost.single['cost'] as num).round(),
      cashIncome: (cash.single['income'] as num).toInt(),
      cashExpense: (cash.single['expense'] as num).toInt(),
      cashOnlyIncome: (cash.single['cash_income'] as num).toInt(),
      cashOnlyExpense: (cash.single['cash_expense'] as num).toInt(),
      bankTransferIncome: (cash.single['bank_income'] as num).toInt(),
      bankTransferExpense: (cash.single['bank_expense'] as num).toInt(),
      lowStockCount: (stock.single['count'] as num).toInt(),
    );
  }
}
