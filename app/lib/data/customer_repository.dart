// مستودع الزبائن: حساب الأرصدة وتسجيل التحصيلات دون حذف سجل الفواتير.
import 'package:sqflite/sqflite.dart';

class CustomerBalance {
  const CustomerBalance({required this.id, required this.name, required this.salesCount, required this.totalDebt, required this.totalPaid});
  final int id;
  final String name;
  final int salesCount;
  final int totalDebt;
  final int totalPaid;
  int get balance => (totalDebt - totalPaid).clamp(0, 1 << 62).toInt();
}

class CustomerLedgerEntry {
  const CustomerLedgerEntry({
    required this.title,
    required this.amount,
    required this.isCredit,
    required this.createdAt,
    this.note,
  });

  final String title;
  final int amount;
  final bool isCredit;
  final String createdAt;
  final String? note;
}

class CustomerRepository {
  CustomerRepository(this._database);
  final Database _database;

  // يعرض الأرصدة المحسوبة من الفواتير والتحصيلات الفعلية.
  Future<List<CustomerBalance>> balances({String query = ''}) async {
    final rows = await _database.rawQuery('''
      SELECT c.id, c.name, COUNT(DISTINCT s.id) AS sales_count,
        MAX(0, COALESCE(SUM(CASE WHEN s.id IS NULL THEN 0 ELSE s.total - s.paid_amount END), 0) - COALESCE((SELECT SUM(sr.amount) FROM sale_returns sr JOIN sales rs ON rs.id = sr.sale_id WHERE rs.customer_id = c.id), 0)) AS total_debt,
        COALESCE((SELECT SUM(cp.amount) FROM customer_payments cp WHERE cp.customer_id = c.id), 0) AS total_paid
      FROM customers c
      LEFT JOIN sales s ON s.customer_id = c.id
      WHERE c.name LIKE ?
      GROUP BY c.id, c.name
      ORDER BY (COALESCE(SUM(CASE WHEN s.id IS NULL THEN 0 ELSE s.total - s.paid_amount END), 0)
        - COALESCE((SELECT SUM(sr.amount) FROM sale_returns sr JOIN sales rs ON rs.id = sr.sale_id WHERE rs.customer_id = c.id), 0)
        - COALESCE((SELECT SUM(cp.amount) FROM customer_payments cp WHERE cp.customer_id = c.id), 0)) DESC,
        c.name COLLATE NOCASE ASC
    ''', ['%${query.trim()}%']);
    return rows.map((row) => CustomerBalance(
      id: row['id'] as int,
      name: row['name'] as String,
      salesCount: (row['sales_count'] as num).toInt(),
      totalDebt: (row['total_debt'] as num).toInt(),
      totalPaid: (row['total_paid'] as num).toInt(),
    )).toList(growable: false);
  }

  /// كشف حساب موحد مرتب زمنيًا من الفواتير والمرتجعات والتحصيلات.
  Future<List<CustomerLedgerEntry>> ledger(int customerId) async {
    final rows = await _database.rawQuery('''
      SELECT 'فاتورة ' || s.invoice_number AS title,
        MAX(0, s.total - s.paid_amount) AS amount,
        0 AS is_credit, s.created_at AS created_at,
        ('الإجمالي: ' || s.total || ' ج.س • المدفوع عند البيع: ' || s.paid_amount || ' ج.س') AS note
      FROM sales s
      WHERE s.customer_id = ?
      UNION ALL
      SELECT 'مرتجع فاتورة ' || s.invoice_number AS title,
        sr.amount AS amount, 1 AS is_credit,
        sr.created_at AS created_at, sr.note AS note
      FROM sale_returns sr
      JOIN sales s ON s.id = sr.sale_id
      WHERE s.customer_id = ?
      UNION ALL
      SELECT 'تحصيل من الزبون' AS title, cp.amount AS amount,
        1 AS is_credit, cp.created_at AS created_at, cp.note AS note
      FROM customer_payments cp
      WHERE cp.customer_id = ?
      ORDER BY created_at ASC
    ''', [customerId, customerId, customerId]);
    return rows.map((row) => CustomerLedgerEntry(
      title: row['title'] as String,
      amount: (row['amount'] as num).toInt(),
      isCredit: (row['is_credit'] as num).toInt() == 1,
      createdAt: row['created_at'] as String,
      note: row['note'] as String?,
    )).toList(growable: false);
  }

  // إضافة زبون يدويًا مع منع تكرار الاسم دون قصد.
  Future<int> addCustomer({required String name, String? phone, String? notes}) async {
    final normalized = name.trim();
    if (normalized.isEmpty) throw ArgumentError('اسم الزبون مطلوب.');
    final id = await _database.insert('customers', {
      'name': normalized,
      'phone': phone?.trim().isEmpty == true ? null : phone?.trim(),
      'notes': notes?.trim().isEmpty == true ? null : notes?.trim(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    if (id != 0) return id;
    final rows = await _database.query('customers', columns: ['id'],
      where: 'name = ? COLLATE NOCASE', whereArgs: [normalized], limit: 1);
    if (rows.isEmpty) throw StateError('تعذر حفظ الزبون.');
    return rows.first['id'] as int;
  }

  // تسجيل تحصيل مع التحقق من الرصيد داخل معاملة لمنع تجاوز المبلغ المستحق.
  Future<void> recordPayment({required int customerId, required int amount, String? note}) async {
    if (amount <= 0) throw ArgumentError('قيمة التحصيل يجب أن تكون أكبر من صفر.');
    await _database.transaction((txn) async {
      final customers = await txn.query('customers', columns: ['id'], where: 'id = ?', whereArgs: [customerId], limit: 1);
      if (customers.isEmpty) throw StateError('الزبون غير موجود.');
      final result = await txn.rawQuery('''
        SELECT COALESCE(SUM(total - paid_amount), 0) AS debt,
          COALESCE((SELECT SUM(amount) FROM customer_payments WHERE customer_id = ?), 0) AS collected,
          COALESCE((SELECT SUM(sr.amount) FROM sale_returns sr JOIN sales rs ON rs.id = sr.sale_id WHERE rs.customer_id = ?), 0) AS returned
        FROM sales WHERE customer_id = ?
      ''', [customerId, customerId, customerId]);
      final debt = (result.first['debt'] as num).toInt();
      final collected = (result.first['collected'] as num).toInt();
      final returned = (result.first['returned'] as num).toInt();
      final outstanding = debt - returned - collected;
      if (amount > outstanding) {
        throw ArgumentError('قيمة التحصيل تتجاوز الرصيد المستحق (${outstanding < 0 ? 0 : outstanding} ج.س).');
      }
      await txn.insert('customer_payments', {
        'customer_id': customerId,
        'amount': amount,
        'note': note?.trim().isEmpty == true ? null : note?.trim(),
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }
}
