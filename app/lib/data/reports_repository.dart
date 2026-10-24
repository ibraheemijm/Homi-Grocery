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
    required this.returnRefunds,
    required this.cashIncome,
    required this.cashExpense,
    required this.lowStockCount,
  });

  final DateTime day;
  final int salesTotal;
  final int salesCount;
  final int purchaseTotal;
  final int purchaseCount;
  final int customerCollections;
  final int supplierPayments;
  final int returnRefunds;
  final int cashIncome;
  final int cashExpense;
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
    final refunds = await _database.rawQuery('''
      SELECT COALESCE(SUM(amount), 0) AS total
      FROM sale_return_refunds WHERE created_at >= ? AND created_at < ?
    ''', [start, end]);
    final cash = await _database.rawQuery('''
      SELECT
        COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE 0 END), 0) AS income,
        COALESCE(SUM(CASE WHEN direction = 'out' THEN amount ELSE 0 END), 0) AS expense
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
      returnRefunds: (refunds.single['total'] as num).toInt(),
      cashIncome: (cash.single['income'] as num).toInt(),
      cashExpense: (cash.single['expense'] as num).toInt(),
      lowStockCount: (stock.single['count'] as num).toInt(),
    );
  }
}
