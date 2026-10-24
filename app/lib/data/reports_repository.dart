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

class ReportsRepository {
  ReportsRepository(this._database);
  final Database _database;

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
