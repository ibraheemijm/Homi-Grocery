// إدارة ورديات درج النقدية وربطها بهوية المستخدم على الجهاز الحالي.
import 'package:sqflite/sqflite.dart';

class CashShiftException implements Exception {
  const CashShiftException(this.message);
  final String message;

  @override
  String toString() => message;
}

class CashShift {
  const CashShift({
    required this.id,
    required this.userId,
    required this.userName,
    required this.openingCash,
    required this.openedAt,
    required this.status,
    this.closingCash,
    this.expectedCash,
    this.difference,
    this.closedAt,
  });

  final int id;
  final int userId;
  final String userName;
  final int openingCash;
  final int? closingCash;
  final int? expectedCash;
  final int? difference;
  final String status;
  final DateTime openedAt;
  final DateTime? closedAt;

  bool get isOpen => status == 'open';

  factory CashShift.fromMap(Map<String, Object?> row) => CashShift(
        id: row['id'] as int,
        userId: row['user_id'] as int,
        userName: row['display_name'] as String,
        openingCash: (row['opening_cash'] as num).toInt(),
        closingCash: (row['closing_cash'] as num?)?.toInt(),
        expectedCash: (row['expected_cash'] as num?)?.toInt(),
        difference: (row['difference'] as num?)?.toInt(),
        status: row['status'] as String,
        openedAt: DateTime.parse(row['opened_at'] as String),
        closedAt: row['closed_at'] == null
            ? null
            : DateTime.tryParse(row['closed_at'] as String),
      );
}

class CashShiftRepository {
  CashShiftRepository(this._database);

  final Database _database;

  /// يتحقق من ملكية الوردية وحالتها قبل أي حركة نقدية مرتبطة بمستخدم.
  /// يسمح بغياب المستخدم والوردية فقط للاستدعاءات القديمة غير المرتبطة بجلسة.
  static Future<void> validateActiveShift(
    DatabaseExecutor executor, {
    required int? shiftId,
    required int? userId,
  }) async {
    if (shiftId == null && userId == null) return;
    if (shiftId == null || userId == null) {
      throw const CashShiftException('الحركة النقدية تتطلب مستخدمًا ووردية نشطة.');
    }
    final rows = await executor.query(
      'cash_shifts',
      columns: ['id'],
      where: "id = ? AND user_id = ? AND status = 'open'",
      whereArgs: [shiftId, userId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const CashShiftException('الوردية غير نشطة أو لا تخص المستخدم الحالي.');
    }
  }

  static const String _selectShift = '''
    SELECT s.*, u.display_name
    FROM cash_shifts s
    JOIN users u ON u.id = s.user_id
  ''';

  /// إرجاع الوردية المفتوحة على هذا الجهاز لاستئنافها بعد إعادة تشغيل التطبيق.
  Future<CashShift?> getOpenShift() async {
    final rows = await _database.rawQuery(
      '$_selectShift WHERE s.status = ? LIMIT 1',
      ['open'],
    );
    return rows.isEmpty ? null : CashShift.fromMap(rows.single);
  }

  /// فتح درج جديد بعد إدخال النقدية الفعلية الموجودة فيه عند بداية العمل.
  Future<CashShift> openShift({
    required int userId,
    required int openingCash,
  }) async {
    if (openingCash < 0) {
      throw const CashShiftException('رصيد بداية الدرج لا يمكن أن يكون سالبًا.');
    }

    final now = DateTime.now().toUtc().toIso8601String();
    return _database.transaction((txn) async {
      final users = await txn.query(
        'users',
        columns: ['id', 'username', 'display_name'],
        where: 'id = ? AND is_active = 1',
        whereArgs: [userId],
        limit: 1,
      );
      if (users.isEmpty) {
        throw const CashShiftException('حساب المستخدم غير موجود أو موقوف.');
      }

      final existing = await txn.query(
        'cash_shifts',
        columns: ['id', 'user_id'],
        where: "status = 'open'",
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final ownerId = existing.single['user_id'] as int;
        throw CashShiftException(
          ownerId == userId
              ? 'لديك وردية مفتوحة بالفعل. سيتم استئنافها دون إدخال رصيد جديد.'
              : 'توجد وردية مفتوحة لمستخدم آخر. أغلقها أولًا قبل تبديل المستخدم.',
        );
      }

      final user = users.single;
      final id = await txn.insert('cash_shifts', {
        'user_id': userId,
        'opening_cash': openingCash,
        'status': 'open',
        'opened_at': now,
      });
      await txn.insert('auth_audit_log', {
        'user_id': userId,
        'username_snapshot': user['username'],
        'action': 'cash_shift_opened:$id:opening=$openingCash',
        'created_at': now,
      });
      return CashShift(
        id: id,
        userId: userId,
        userName: user['display_name'] as String,
        openingCash: openingCash,
        openedAt: DateTime.parse(now),
        status: 'open',
      );
    });
  }

  /// إغلاق الوردية ومقارنة النقد الفعلي بما يجب أن يكون في الدرج.
  Future<CashShift> closeShift({
    required int shiftId,
    required int userId,
    required int closingCash,
  }) async {
    if (closingCash < 0) {
      throw const CashShiftException('النقد الفعلي لا يمكن أن يكون سالبًا.');
    }
    final now = DateTime.now().toUtc().toIso8601String();

    return _database.transaction((txn) async {
      final rows = await txn.rawQuery(
        '$_selectShift WHERE s.id = ? AND s.status = ? LIMIT 1',
        [shiftId, 'open'],
      );
      if (rows.isEmpty) {
        throw const CashShiftException('الوردية غير موجودة أو أُغلقت مسبقًا.');
      }
      final shift = CashShift.fromMap(rows.single);
      if (shift.userId != userId) {
        throw const CashShiftException('لا يمكن إغلاق وردية مستخدم آخر.');
      }

      final totals = await txn.rawQuery('''
        SELECT
          COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE 0 END), 0) AS cash_in,
          COALESCE(SUM(CASE WHEN direction = 'out' THEN amount ELSE 0 END), 0) AS cash_out
        FROM cash_transactions
        WHERE shift_id = ? AND payment_method = 'نقدي'
      ''', [shiftId]);
      final cashIn = (totals.single['cash_in'] as num).toInt();
      final cashOut = (totals.single['cash_out'] as num).toInt();
      final expected = shift.openingCash + cashIn - cashOut;
      final difference = closingCash - expected;

      await txn.update(
        'cash_shifts',
        {
          'closing_cash': closingCash,
          'expected_cash': expected,
          'difference': difference,
          'status': 'closed',
          'closed_at': now,
        },
        where: "id = ? AND status = 'open'",
        whereArgs: [shiftId],
      );
      final users = await txn.query(
        'users',
        columns: ['username'],
        where: 'id = ?',
        whereArgs: [userId],
        limit: 1,
      );
      await txn.insert('auth_audit_log', {
        'user_id': userId,
        'username_snapshot': users.single['username'],
        'action': 'cash_shift_closed:$shiftId:expected=$expected:actual=$closingCash:difference=$difference',
        'created_at': now,
      });

      return CashShift(
        id: shift.id,
        userId: shift.userId,
        userName: shift.userName,
        openingCash: shift.openingCash,
        closingCash: closingCash,
        expectedCash: expected,
        difference: difference,
        status: 'closed',
        openedAt: shift.openedAt,
        closedAt: DateTime.parse(now),
      );
    });
  }
}
