// إحصاءات اللوحة الرئيسية محسوبة مباشرة من بيانات SQLite المحلية.
import 'package:sqflite/sqflite.dart';

class DashboardStats {
  const DashboardStats({
    required this.todaySales,
    required this.todayPaid,
    required this.customerDebt,
    required this.lowStockCount,
  });

  final int todaySales;
  final int todayPaid;
  final int customerDebt;
  final int lowStockCount;
}

class DashboardRepository {
  DashboardRepository(this._database);
  final Database _database;

  Future<void> _requireReadPermission(int userId, String permissionKey) async {
    final users = await _database.query(
      'users', columns: ['role', 'is_active'],
      where: 'id = ?', whereArgs: [userId], limit: 1,
    );
    if (users.isEmpty || users.single['is_active'] != 1) {
      throw StateError('الحساب غير نشط أو غير موجود.');
    }
    final role = users.single['role'];
    if (role == 'manager') return;
    if (role != 'cashier') throw StateError('نوع الحساب غير مصرح له بقراءة بيانات اللوحة.');
    final permissions = await _database.query(
      'cashier_permissions', columns: ['is_allowed'],
      where: 'user_id = ? AND permission_key = ?',
      whereArgs: [userId, permissionKey], limit: 1,
    );
    if (permissions.isEmpty || permissions.single['is_allowed'] != 1) {
      throw StateError('لا يملك الكاشير صلاحية قراءة هذه البيانات.');
    }
  }

  Future<DashboardStats> load({required int userId, DateTime? now}) async {
    await _requireReadPermission(userId, 'view_reports');
    final localNow = now ?? DateTime.now();
    final start = DateTime(localNow.year, localNow.month, localNow.day).toUtc();
    final end = start.add(const Duration(days: 1));
    final today = await _database.rawQuery('''
      SELECT
        COALESCE((SELECT SUM(total) FROM sales
          WHERE created_at >= ? AND created_at < ?), 0)
        - COALESCE((SELECT SUM(amount) FROM sale_returns
          WHERE created_at >= ? AND created_at < ?), 0) AS sales,
        COALESCE((SELECT SUM(paid_amount) FROM sales
          WHERE created_at >= ? AND created_at < ?), 0)
        - COALESCE((SELECT SUM(amount) FROM sale_return_refunds
          WHERE created_at >= ? AND created_at < ?), 0) AS paid
    ''', [
      start.toIso8601String(), end.toIso8601String(),
      start.toIso8601String(), end.toIso8601String(),
      start.toIso8601String(), end.toIso8601String(),
      start.toIso8601String(), end.toIso8601String(),
    ]);
    final debt = await _database.rawQuery('''
      SELECT
        COALESCE((SELECT SUM(total - paid_amount) FROM sales), 0) -
        COALESCE((SELECT SUM(amount) FROM customer_payments), 0) AS balance
    ''');
    final lowStock = await _database.rawQuery('''
      SELECT COUNT(*) AS count FROM products
      WHERE is_active = 1 AND stock_quantity <= minimum_quantity
    ''');
    return DashboardStats(
      todaySales: (today.first['sales'] as num).toInt(),
      todayPaid: (today.first['paid'] as num).toInt(),
      customerDebt: (debt.first['balance'] as num).toInt().clamp(0, 1 << 62),
      lowStockCount: (lowStock.first['count'] as num).toInt(),
    );
  }
}


/// فاتورة مختصرة لعرض أحدث عمليات البيع في لوحة التحكم.
class RecentInvoice {
  const RecentInvoice({
    required this.id,
    required this.invoiceNumber,
    required this.customerName,
    required this.total,
    required this.paidAmount,
    required this.createdAt,
  });

  final int id;
  final String invoiceNumber;
  final String customerName;
  final int total;
  final int paidAmount;
  final String createdAt;

  int get remaining => (total - paidAmount).clamp(0, 1 << 62);

  static RecentInvoice fromRow(Map<String, Object?> row) => RecentInvoice(
        id: row['id'] as int,
        invoiceNumber: row['invoice_number'] as String,
        customerName: (row['customer_name'] as String?)?.trim().isNotEmpty == true
            ? (row['customer_name'] as String).trim()
            : 'زبون نقدي',
        total: (row['total'] as num).toInt(),
        paidAmount: (row['paid_amount'] as num).toInt(),
        createdAt: row['created_at'] as String,
      );
}

/// قراءة أحدث الفواتير الحقيقية بدل عرض حالة فارغة ثابتة.
extension RecentInvoicesLoader on DashboardRepository {
  Future<List<RecentInvoice>> loadRecentInvoices({required int userId, int limit = 5}) async {
    await _requireReadPermission(userId, 'view_invoice_history');
    final safeLimit = limit.clamp(1, 20);
    final rows = await _database.rawQuery('''
      SELECT id, invoice_number, customer_name, total, paid_amount, created_at
      FROM sales
      ORDER BY created_at DESC, id DESC
      LIMIT ?
    ''', [safeLimit]);
    return rows.map(RecentInvoice.fromRow).toList(growable: false);
  }
}
