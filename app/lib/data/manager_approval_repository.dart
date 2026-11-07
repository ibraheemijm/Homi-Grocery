// إصدار موافقات مدير مؤقتة ومقيدة بعملية واحدة، واستهلاكها داخل معاملة العملية.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import 'auth_repository.dart';
import 'cash_shift_repository.dart';

/// مفاتيح الكتابة التي يمكن أن تحصل على موافقة استثنائية؛ مفاتيح القراءة مستبعدة.
const Set<String> managerApprovalPermissionKeys = {
  'credit_sales', 'discounts', 'returns', 'return_refunds',
  'customer_collections', 'cash_expenses', 'supplier_purchases',
  'supplier_payments', 'supplier_returns', 'supplier_return_refunds',
  'stock_adjustments',
};

class ManagerApprovalException implements Exception {
  const ManagerApprovalException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// النطاق الكامل الذي لا يجوز إعادة استخدام الموافقة خارجه.
class ManagerApprovalScope {
  const ManagerApprovalScope({
    required this.cashierUserId,
    required this.shiftId,
    required this.permissionKey,
    required this.operationType,
    this.amount,
    this.referenceType,
    this.referenceId,
  });

  final int cashierUserId;
  final int shiftId;
  final String permissionKey;
  final String operationType;
  final int? amount;
  final String? referenceType;
  final int? referenceId;

  bool matches(Map<String, Object?> row) =>
      row['cashier_user_id'] == cashierUserId &&
      row['shift_id'] == shiftId &&
      row['permission_key'] == permissionKey &&
      row['operation_type'] == operationType &&
      row['amount'] == amount &&
      row['reference_type'] == referenceType &&
      row['reference_id'] == referenceId;
}

class ManagerApprovalGrant {
  const ManagerApprovalGrant({required this.token, required this.expiresAt});
  /// الرمز الخام يعاد مرة واحدة للواجهة ولا يُحفظ في قاعدة البيانات.
  final String token;
  final DateTime expiresAt;
}

enum ManagerApprovalConsumeResult {
  consumed, notFound, alreadyUsed, expired, scopeMismatch, inactiveAccount, invalidShift,
}

/// إصدار الموافقة لا يغير جلسة الكاشير ولا يمنح صلاحية دائمة.
class ManagerApprovalRepository {
  ManagerApprovalRepository(
    this._database,
    this._authRepository, {
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Database _database;
  final AuthRepository _authRepository;
  final DateTime Function() _clock;
  static const Duration approvalLifetime = Duration(minutes: 2);

  /// يتحقق من كلمة مرور المدير ثم ينشئ موافقة مرتبطة بكاشير ووردية وعملية محددة.
  Future<ManagerApprovalGrant> issueApproval({
    required AuthUser manager,
    required String managerPassword,
    required ManagerApprovalScope scope,
  }) async {
    _validateScope(scope);
    if (!manager.isManager) {
      throw const ManagerApprovalException('الموافقة متاحة لحساب مدير فقط.');
    }

    // يعيد التحقق من بيانات المدير عبر مسار المصادقة المعتاد دون تبديل جلسة التطبيق.
    final verifiedManager = await _authRepository.login(
      username: manager.username,
      password: managerPassword,
    );
    if (verifiedManager.id != manager.id || !verifiedManager.isManager) {
      throw const ManagerApprovalException('تعذر التحقق من هوية المدير.');
    }

    final now = _clock().toUtc();
    final expiresAt = now.add(approvalLifetime);
    final token = _generateToken();
    final tokenHash = _hashToken(token);

    await _database.transaction((txn) async {
      final managers = await txn.query(
        'users',
        columns: ['id', 'username'],
        where: "id = ? AND role = 'manager' AND is_active = 1",
        whereArgs: [manager.id],
        limit: 1,
      );
      final cashiers = await txn.query(
        'users',
        columns: ['id', 'username'],
        where: "id = ? AND role = 'cashier' AND is_active = 1",
        whereArgs: [scope.cashierUserId],
        limit: 1,
      );
      if (managers.isEmpty || cashiers.isEmpty) {
        throw const ManagerApprovalException('المدير أو الكاشير غير نشط أو غير موجود.');
      }

      // لا تمنح موافقة قبل التأكد من أن الوردية ما زالت تخص الكاشير ومفتوحة.
      try {
        await CashShiftRepository.validateActiveShift(
          txn,
          shiftId: scope.shiftId,
          userId: scope.cashierUserId,
        );
      } on CashShiftException {
        throw const ManagerApprovalException('وردية الكاشير غير نشطة أو لا تخصه.');
      }

      final permissions = await txn.query(
        'cashier_permissions',
        columns: ['is_allowed', 'max_amount'],
        where: 'user_id = ? AND permission_key = ?',
        whereArgs: [scope.cashierUserId, scope.permissionKey],
        limit: 1,
      );
      final permission = permissions.isEmpty ? null : permissions.single;
      final isAllowed = permission?['is_allowed'] == 1;
      final maxAmount = (permission?['max_amount'] as num?)?.toInt();
      final exceedsLimit = scope.amount != null &&
          maxAmount != null &&
          scope.amount! > maxAmount;
      if (isAllowed && !exceedsLimit) {
        throw const ManagerApprovalException('لا تحتاج هذه العملية إلى موافقة استثنائية.');
      }

      final approvalId = await txn.insert('manager_approvals', {
        'token_hash': tokenHash,
        'manager_user_id': manager.id,
        'cashier_user_id': scope.cashierUserId,
        'shift_id': scope.shiftId,
        'permission_key': scope.permissionKey,
        'operation_type': scope.operationType,
        'amount': scope.amount,
        'reference_type': scope.referenceType,
        'reference_id': scope.referenceId,
        'status': 'pending',
        'created_at': now.toIso8601String(),
        'expires_at': expiresAt.toIso8601String(),
      });

      await _writeAudit(
        txn,
        userId: scope.cashierUserId,
        username: cashiers.single['username'] as String,
        action: 'manager_approval_requested:$approvalId:${scope.permissionKey}:${scope.operationType}',
        createdAt: now,
      );
      await _writeAudit(
        txn,
        userId: manager.id,
        username: managers.single['username'] as String,
        action: 'manager_approval_granted:$approvalId:cashier=${scope.cashierUserId}:shift=${scope.shiftId}:${scope.permissionKey}:${scope.operationType}:amount=${scope.amount ?? 'none'}',
        createdAt: now,
      );
    });

    return ManagerApprovalGrant(token: token, expiresAt: expiresAt);
  }

  /// يجب استدعاؤها داخل معاملة العملية المالية نفسها.
  ///
  /// تعيد نتيجة بدل رمي استثناء حتى يستطيع المستدعي تسجيل الرفض/الانتهاء
  /// في المعاملة ثم إيقاف العملية بعد إتمام المعاملة دون حفظ أي كتابة مالية.
  Future<ManagerApprovalConsumeResult> consumeWithinTransaction(
    Transaction txn, {
    required String token,
    required int executingUserId,
    required ManagerApprovalScope scope,
  }) async {
    _validateScope(scope);
    if (token.isEmpty) return ManagerApprovalConsumeResult.notFound;

    final now = _clock().toUtc();
    final rows = await txn.query(
      'manager_approvals',
      where: 'token_hash = ?',
      whereArgs: [_hashToken(token)],
      limit: 1,
    );
    if (rows.isEmpty) return ManagerApprovalConsumeResult.notFound;

    final approval = rows.single;
    final approvalId = approval['id'] as int;
    if (approval['status'] != 'pending') {
      return ManagerApprovalConsumeResult.alreadyUsed;
    }

    final managerId = approval['manager_user_id'] as int;
    final cashierId = approval['cashier_user_id'] as int;
    final managerRows = await txn.query(
      'users',
      columns: ['username'],
      where: "id = ? AND role = 'manager' AND is_active = 1",
      whereArgs: [managerId],
      limit: 1,
    );
    final cashierRows = await txn.query(
      'users',
      columns: ['username'],
      where: "id = ? AND role = 'cashier' AND is_active = 1",
      whereArgs: [cashierId],
      limit: 1,
    );

    if (managerRows.isEmpty || cashierRows.isEmpty) {
      await _rejectApproval(
        txn,
        approvalId: approvalId,
        managerId: managerId,
        cashierId: cashierId,
        managerUsername: managerRows.isEmpty ? null : managerRows.single['username'] as String,
        cashierUsername: cashierRows.isEmpty ? null : cashierRows.single['username'] as String,
        reason: 'inactive_account',
        now: now,
      );
      return ManagerApprovalConsumeResult.inactiveAccount;
    }

    final expiresAt = DateTime.tryParse(approval['expires_at'] as String);
    if (expiresAt == null || !expiresAt.isAfter(now)) {
      await txn.update(
        'manager_approvals',
        {'status': 'expired', 'expired_at': now.toIso8601String()},
        where: "id = ? AND status = 'pending'",
        whereArgs: [approvalId],
      );
      await _writeAudit(
        txn,
        userId: managerId,
        username: managerRows.single['username'] as String,
        action: 'manager_approval_expired:$approvalId',
        createdAt: now,
      );
      return ManagerApprovalConsumeResult.expired;
    }

    if (executingUserId != cashierId || !scope.matches(approval)) {
      await _rejectApproval(
        txn,
        approvalId: approvalId,
        managerId: managerId,
        cashierId: cashierId,
        managerUsername: managerRows.single['username'] as String,
        cashierUsername: cashierRows.single['username'] as String,
        reason: 'scope_mismatch',
        now: now,
      );
      return ManagerApprovalConsumeResult.scopeMismatch;
    }

    try {
      await CashShiftRepository.validateActiveShift(
        txn,
        shiftId: scope.shiftId,
        userId: scope.cashierUserId,
      );
    } on CashShiftException {
      await _rejectApproval(
        txn,
        approvalId: approvalId,
        managerId: managerId,
        cashierId: cashierId,
        managerUsername: managerRows.single['username'] as String,
        cashierUsername: cashierRows.single['username'] as String,
        reason: 'invalid_shift',
        now: now,
      );
      return ManagerApprovalConsumeResult.invalidShift;
    }

    final updated = await txn.update(
      'manager_approvals',
      {'status': 'consumed', 'consumed_at': now.toIso8601String()},
      where: "id = ? AND status = 'pending' AND expires_at > ?",
      whereArgs: [approvalId, now.toIso8601String()],
    );
    if (updated != 1) return ManagerApprovalConsumeResult.alreadyUsed;

    await _writeAudit(
      txn,
      userId: managerId,
      username: managerRows.single['username'] as String,
      action: 'manager_approval_consumed:$approvalId:cashier=$cashierId',
      createdAt: now,
    );
    await _writeAudit(
      txn,
      userId: cashierId,
      username: cashierRows.single['username'] as String,
      action: 'manager_approval_used:$approvalId:${scope.permissionKey}:${scope.operationType}:amount=${scope.amount ?? 'none'}',
      createdAt: now,
    );
    return ManagerApprovalConsumeResult.consumed;
  }

  void _validateScope(ManagerApprovalScope scope) {
    if (scope.cashierUserId <= 0 ||
        scope.shiftId <= 0 ||
        !managerApprovalPermissionKeys.contains(scope.permissionKey) ||
        scope.operationType.trim().isEmpty ||
        scope.operationType.length > 80 ||
        (scope.amount != null && scope.amount! < 0) ||
        (scope.referenceType == null) != (scope.referenceId == null) ||
        (scope.referenceType != null &&
            (scope.referenceType!.trim().isEmpty ||
                scope.referenceType!.length > 40 ||
                scope.referenceId! <= 0))) {
      throw const ManagerApprovalException('نطاق الموافقة غير صالح أو غير مدعوم.');
    }
  }

  Future<void> _rejectApproval(
    Transaction txn, {
    required int approvalId,
    required int managerId,
    required int cashierId,
    required String? managerUsername,
    required String? cashierUsername,
    required String reason,
    required DateTime now,
  }) async {
    await txn.update(
      'manager_approvals',
      {'status': 'rejected', 'rejected_at': now.toIso8601String()},
      where: "id = ? AND status = 'pending'",
      whereArgs: [approvalId],
    );
    if (managerUsername != null) {
      await _writeAudit(
        txn,
        userId: managerId,
        username: managerUsername,
        action: 'manager_approval_rejected:$approvalId:$reason',
        createdAt: now,
      );
    }
    if (cashierUsername != null) {
      await _writeAudit(
        txn,
        userId: cashierId,
        username: cashierUsername,
        action: 'manager_approval_denied:$approvalId:$reason',
        createdAt: now,
      );
    }
  }

  String _generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  String _hashToken(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  Future<void> _writeAudit(
    DatabaseExecutor executor, {
    required int userId,
    required String username,
    required String action,
    required DateTime createdAt,
  }) async {
    await executor.insert('auth_audit_log', {
      'user_id': userId,
      'username_snapshot': username,
      'action': action,
      'created_at': createdAt.toIso8601String(),
    });
  }
}
