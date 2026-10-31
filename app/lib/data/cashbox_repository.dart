// الخزينة: سجل الحركات النقدية الفعلية وملخص اليوم دون خلطها بإجمالي الديون.
import 'package:sqflite/sqflite.dart';

class CashTransaction {
  const CashTransaction({
    required this.id,
    required this.direction,
    required this.category,
    required this.amount,
    required this.paymentMethod,
    required this.createdAt,
    this.referenceType,
    this.referenceId,
    this.note,
  });

  final int id;
  final String direction;
  final String category;
  final int amount;
  final String paymentMethod;
  final String createdAt;
  final String? referenceType;
  final int? referenceId;
  final String? note;

  bool get isIncome => direction == 'in';

  factory CashTransaction.fromMap(Map<String, Object?> row) => CashTransaction(
        id: row['id'] as int,
        direction: row['direction'] as String,
        category: row['category'] as String,
        amount: (row['amount'] as num).toInt(),
        paymentMethod: row['payment_method'] as String,
        createdAt: row['created_at'] as String,
        referenceType: row['reference_type'] as String?,
        referenceId: row['reference_id'] as int?,
        note: row['note'] as String?,
      );
}

class CashboxSummary {
  const CashboxSummary({
    required this.todayIncome,
    required this.todayExpense,
    required this.totalIncome,
    required this.totalExpense,
    required this.todayCount,
    required this.todayCashIncome,
    required this.todayCashExpense,
    required this.todayBankIncome,
    required this.todayBankExpense,
  });

  final int todayIncome;
  final int todayExpense;
  final int totalIncome;
  final int totalExpense;
  final int todayCount;
  final int todayCashIncome;
  final int todayCashExpense;
  final int todayBankIncome;
  final int todayBankExpense;

  int get todayCashNet => todayCashIncome - todayCashExpense;
  int get todayBankNet => todayBankIncome - todayBankExpense;
  int get todayNet => todayIncome - todayExpense;
  int get currentBalance => totalIncome - totalExpense;
}

class CashboxRepository {
  CashboxRepository(this._database);
  final Database _database;

  Future<CashboxSummary> summary({DateTime? day}) async {
    final selected = day ?? DateTime.now();
    final localStart = DateTime(selected.year, selected.month, selected.day);
    final start = localStart.toUtc().toIso8601String();
    final end = localStart.add(const Duration(days: 1)).toUtc().toIso8601String();
    final rows = await _database.rawQuery('''
      SELECT
        COALESCE(SUM(CASE WHEN created_at >= ? AND created_at < ? AND direction = 'in' THEN amount ELSE 0 END), 0) AS today_income,
        COALESCE(SUM(CASE WHEN created_at >= ? AND created_at < ? AND direction = 'out' THEN amount ELSE 0 END), 0) AS today_expense,
        COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE 0 END), 0) AS total_income,
        COALESCE(SUM(CASE WHEN direction = 'out' THEN amount ELSE 0 END), 0) AS total_expense,
        COALESCE(SUM(CASE WHEN created_at >= ? AND created_at < ? THEN 1 ELSE 0 END), 0) AS today_count,
        COALESCE(SUM(CASE WHEN created_at >= ? AND created_at < ? AND direction = 'in' AND payment_method = 'نقدي' THEN amount ELSE 0 END), 0) AS cash_income,
        COALESCE(SUM(CASE WHEN created_at >= ? AND created_at < ? AND direction = 'out' AND payment_method = 'نقدي' THEN amount ELSE 0 END), 0) AS cash_expense,
        COALESCE(SUM(CASE WHEN created_at >= ? AND created_at < ? AND direction = 'in' AND payment_method = 'تحويل بنكي' THEN amount ELSE 0 END), 0) AS bank_income,
        COALESCE(SUM(CASE WHEN created_at >= ? AND created_at < ? AND direction = 'out' AND payment_method = 'تحويل بنكي' THEN amount ELSE 0 END), 0) AS bank_expense
      FROM cash_transactions
    ''', [start, end, start, end, start, end, start, end, start, end, start, end, start, end]);
    final row = rows.single;
    return CashboxSummary(
      todayIncome: (row['today_income'] as num).toInt(),
      todayExpense: (row['today_expense'] as num).toInt(),
      totalIncome: (row['total_income'] as num).toInt(),
      totalExpense: (row['total_expense'] as num).toInt(),
      todayCount: (row['today_count'] as num).toInt(),
      todayCashIncome: (row['cash_income'] as num).toInt(),
      todayCashExpense: (row['cash_expense'] as num).toInt(),
      todayBankIncome: (row['bank_income'] as num).toInt(),
      todayBankExpense: (row['bank_expense'] as num).toInt(),
    );
  }

  Future<List<CashTransaction>> recent({DateTime? day, String? paymentMethod, int limit = 100}) async {
    final selected = day ?? DateTime.now();
    final localStart = DateTime(selected.year, selected.month, selected.day);
    final start = localStart.toUtc().toIso8601String();
    final end = localStart.add(const Duration(days: 1)).toUtc().toIso8601String();
    final rows = await _database.query(
      'cash_transactions',
      where: paymentMethod == null
          ? 'created_at >= ? AND created_at < ?'
          : 'created_at >= ? AND created_at < ? AND payment_method = ?',
      whereArgs: paymentMethod == null ? [start, end] : [start, end, paymentMethod],
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(CashTransaction.fromMap).toList(growable: false);
  }

  Future<int> recordManualMovement({
    required String direction,
    required String category,
    required int amount,
    String paymentMethod = 'نقدي',
    String? note,
    int? userId,
    int? shiftId,
  }) async {
    if (!const ['in', 'out'].contains(direction)) {
      throw ArgumentError('نوع حركة الخزينة غير صالح.');
    }
    if (category.trim().isEmpty) throw ArgumentError('اسم الحركة مطلوب.');
    if (amount <= 0) throw ArgumentError('المبلغ يجب أن يكون أكبر من صفر.');
    if (paymentMethod.trim().isEmpty) throw ArgumentError('حدد طريقة الدفع.');
    if (shiftId != null && (userId == null || paymentMethod.trim() != 'نقدي')) {
      throw ArgumentError('ربط حركة الخزينة بالوردية يتطلب مستخدمًا وطريقة دفع نقدية.');
    }
    return _database.insert('cash_transactions', {
      'direction': direction,
      'category': category.trim(),
      'amount': amount,
      'payment_method': paymentMethod.trim(),
      'reference_type': 'manual',
      'user_id': userId,
      'shift_id': paymentMethod.trim() == 'نقدي' ? shiftId : null,
      'note': note?.trim().isEmpty == true ? null : note?.trim(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }
}
