// إدارة الحسابات المحلية وتسجيل الدخول دون إرسال بيانات الاعتماد إلى أي خادم.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

class AuthUser {
  const AuthUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.role,
  });

  final int id;
  final String username;
  final String displayName;
  final String role;

  bool get isManager => role == 'manager';

  factory AuthUser.fromMap(Map<String, Object?> row) => AuthUser(
        id: row['id'] as int,
        username: row['username'] as String,
        displayName: row['display_name'] as String,
        role: row['role'] as String,
      );
}


class CashierAccount {
  const CashierAccount({
    required this.user,
    required this.isActive,
    required this.createdAt,
    this.lastLoginAt,
  });

  final AuthUser user;
  final bool isActive;
  final DateTime createdAt;
  final DateTime? lastLoginAt;

  factory CashierAccount.fromMap(Map<String, Object?> row) => CashierAccount(
        user: AuthUser.fromMap(row),
        isActive: row['is_active'] == 1,
        createdAt: DateTime.parse(row['created_at'] as String),
        lastLoginAt: row['last_login_at'] == null
            ? null
            : DateTime.tryParse(row['last_login_at'] as String),
      );
}

/// إعداد صلاحية واحدة للكاشير. الحد الفارغ يعني عدم وضع سقف مالي.
class CashierPermissionSetting {
  const CashierPermissionSetting({
    required this.key,
    required this.label,
    required this.isAllowed,
    this.maxAmount,
  });

  final String key;
  final String label;
  final bool isAllowed;
  final int? maxAmount;
}

/// الصلاحيات التي يمكن للمدير ضبطها لكل حساب كاشير.
const Map<String, String> cashierPermissionLabels = {
  'credit_sales': 'البيع بالدين أو الدفع الجزئي',
  'discounts': 'تقديم خصم على الفاتورة',
  'returns': 'تسجيل مرتجعات البيع',
  'return_refunds': 'رد مبالغ المرتجعات',
  'customer_collections': 'تحصيل ديون الزبائن',
  'cash_expenses': 'تسجيل المصروفات النقدية',
  'supplier_purchases': 'تسجيل فواتير الشراء',
  'supplier_payments': 'سداد مستحقات الموردين',
  'view_customer_data': 'عرض بيانات ودفتر الزبائن',
  'view_supplier_data': 'عرض بيانات الموردين',
  'view_invoice_history': 'عرض سجل الفواتير',
  'view_reports': 'عرض التقارير',
  'stock_adjustments': 'تسوية المخزون وحركاته',
};

class AuthException implements Exception {
  const AuthException(this.message);
  final String message;

  @override
  String toString() => message;
}

class AuthRepository {
  AuthRepository(this._database);

  final Database _database;

  static const int _passwordIterations = 600000;
  static const int _saltLength = 16;

  Future<bool> hasAccounts() async {
    final rows = await _database.rawQuery('SELECT COUNT(*) AS total FROM users');
    return (rows.single['total'] as int) > 0;
  }

  /// إنشاء حساب المدير الأول فقط؛ لا توجد كلمة مرور أو بيانات دخول افتراضية.
  Future<AuthUser> createInitialManager({
    required String username,
    required String displayName,
    required String password,
  }) async {
    final cleanUsername = username.trim();
    final cleanName = displayName.trim();
    _validateCredentials(cleanUsername, cleanName, password);
    if (await hasAccounts()) {
      throw const AuthException('تم إنشاء حساب المدير مسبقًا. سجّل الدخول للمتابعة.');
    }

    final secureRandom = Random.secure();
    final salt = List<int>.generate(
      _saltLength,
      (_) => secureRandom.nextInt(256),
    );
    final passwordHash = await _hashPassword(password, salt);
    final now = DateTime.now().toUtc().toIso8601String();

    return _database.transaction((txn) async {
      final count = await txn.rawQuery('SELECT COUNT(*) AS total FROM users');
      if ((count.single['total'] as int) != 0) {
        throw const AuthException('تم إنشاء حساب المدير مسبقًا. سجّل الدخول للمتابعة.');
      }

      final id = await txn.insert('users', {
        'username': cleanUsername,
        'display_name': cleanName,
        'password_hash': passwordHash,
        'password_salt': base64Encode(salt),
        'password_iterations': _passwordIterations,
        'role': 'manager',
        'is_active': 1,
        'created_at': now,
      });
      await _writeAudit(
        txn,
        userId: id,
        username: cleanUsername,
        action: 'initial_manager_created',
        createdAt: now,
      );
      return AuthUser(
        id: id,
        username: cleanUsername,
        displayName: cleanName,
        role: 'manager',
      );
    });
  }

  /// التحقق من كلمة المرور مع قفل مؤقت بعد خمس محاولات فاشلة.
  Future<AuthUser> login({
    required String username,
    required String password,
  }) async {
    final cleanUsername = username.trim();
    final rows = await _database.query(
      'users',
      where: 'username = ? COLLATE NOCASE',
      whereArgs: [cleanUsername],
      limit: 1,
    );
    if (rows.isEmpty || rows.single['is_active'] != 1) {
      throw const AuthException('اسم المستخدم أو كلمة المرور غير صحيحة.');
    }

    final row = rows.single;
    final lockedUntil = row['locked_until'] as String?;
    if (lockedUntil != null) {
      final lockTime = DateTime.tryParse(lockedUntil);
      if (lockTime != null && lockTime.isAfter(DateTime.now().toUtc())) {
        final remaining = lockTime.difference(DateTime.now().toUtc()).inMinutes + 1;
        throw AuthException('الحساب مقفل مؤقتًا. حاول بعد $remaining دقيقة.');
      }
    }

    final salt = base64Decode(row['password_salt'] as String);
    final expectedHash = base64Decode(row['password_hash'] as String);
    final iterations = row['password_iterations'] as int;
    final actualHash = await _hashPassword(password, salt, iterations: iterations);

    if (!_constantTimeEquals(expectedHash, base64Decode(actualHash))) {
      final now = DateTime.now().toUtc();
      final attempts = (row['failed_attempts'] as int) + 1;
      final shouldLock = attempts >= 5;
      await _database.transaction((txn) async {
        await txn.update(
          'users',
          {
            'failed_attempts': shouldLock ? 0 : attempts,
            'locked_until': shouldLock
                ? now.add(const Duration(minutes: 5)).toIso8601String()
                : null,
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        await _writeAudit(
          txn,
          userId: row['id'] as int,
          username: cleanUsername,
          action: 'login_failed',
          createdAt: now.toIso8601String(),
        );
      });
      if (shouldLock) {
        throw const AuthException('تم قفل الحساب خمس دقائق بسبب تكرار كلمة المرور الخاطئة.');
      }
      throw const AuthException('اسم المستخدم أو كلمة المرور غير صحيحة.');
    }

    final now = DateTime.now().toUtc().toIso8601String();
    await _database.transaction((txn) async {
      await txn.update(
        'users',
        {
          'failed_attempts': 0,
          'locked_until': null,
          'last_login_at': now,
        },
        where: 'id = ?',
        whereArgs: [row['id']],
      );
      await _writeAudit(
        txn,
        userId: row['id'] as int,
        username: cleanUsername,
        action: 'login_success',
        createdAt: now,
      );
    });
    return AuthUser.fromMap(row);
  }


  /// يعيد الصلاحيات المضبوطة، ويعامل الصلاحية غير المسجلة على أنها ممنوعة.
  Future<List<CashierPermissionSetting>> getCashierPermissions({
    required AuthUser manager,
    required int cashierId,
  }) async {
    await _requireActiveManager(_database, manager.id);
    final cashierRows = await _database.query(
      'users',
      columns: ['id'],
      where: "id = ? AND role = 'cashier'",
      whereArgs: [cashierId],
      limit: 1,
    );
    if (cashierRows.isEmpty) {
      throw const AuthException('حساب الكاشير غير موجود.');
    }
    final rows = await _database.query(
      'cashier_permissions',
      where: 'user_id = ?',
      whereArgs: [cashierId],
    );
    final saved = {
      for (final row in rows) row['permission_key'] as String: row,
    };
    return cashierPermissionLabels.entries.map((entry) {
      final row = saved[entry.key];
      return CashierPermissionSetting(
        key: entry.key,
        label: entry.value,
        isAllowed: row?['is_allowed'] == 1,
        maxAmount: (row?['max_amount'] as num?)?.toInt(),
      );
    }).toList(growable: false);
  }

  /// يحفظ المدير إعدادات الكاشير ذريًا ويسجل كل تغيير في سجل التدقيق.
  Future<void> saveCashierPermissions({
    required AuthUser manager,
    required int cashierId,
    required List<CashierPermissionSetting> permissions,
  }) async {
    final keys = permissions.map((permission) => permission.key).toSet();
    if (keys.length != permissions.length ||
        permissions.any((permission) =>
            !cashierPermissionLabels.containsKey(permission.key) ||
            (permission.maxAmount != null && permission.maxAmount! < 0))) {
      throw const AuthException('إعدادات الصلاحيات أو الحدود المالية غير صالحة.');
    }

    await _database.transaction((txn) async {
      final managerUsername = await _requireActiveManager(txn, manager.id);
      final cashiers = await txn.query(
        'users',
        columns: ['id'],
        where: "id = ? AND role = 'cashier'",
        whereArgs: [cashierId],
        limit: 1,
      );
      if (cashiers.isEmpty) {
        throw const AuthException('حساب الكاشير غير موجود.');
      }

      final now = DateTime.now().toUtc().toIso8601String();
      for (final permission in permissions) {
        await txn.insert(
          'cashier_permissions',
          {
            'user_id': cashierId,
            'permission_key': permission.key,
            'is_allowed': permission.isAllowed ? 1 : 0,
            'max_amount': permission.maxAmount,
            'updated_by': manager.id,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await _writeAudit(
          txn,
          userId: manager.id,
          username: managerUsername,
          action: 'cashier_permission_updated:$cashierId:${permission.key}:${permission.isAllowed}:${permission.maxAmount ?? 'unlimited'}',
          createdAt: now,
        );
      }
    });
  }

  /// عرض حسابات الكاشير للمدير فقط، دون إرجاع بيانات كلمات المرور.
  Future<List<CashierAccount>> listCashiers({required AuthUser manager}) async {
    await _requireActiveManager(_database, manager.id);
    final rows = await _database.query(
      'users',
      columns: ['id', 'username', 'display_name', 'role', 'is_active', 'created_at', 'last_login_at'],
      where: "role = 'cashier'",
      orderBy: 'is_active DESC, display_name COLLATE NOCASE',
    );
    return rows.map(CashierAccount.fromMap).toList(growable: false);
  }

  /// إنشاء حساب كاشير جديد من حساب مدير نشط.
  Future<AuthUser> createCashier({
    required AuthUser manager,
    required String username,
    required String displayName,
    required String password,
  }) async {
    final cleanUsername = username.trim();
    final cleanName = displayName.trim();
    _validateCredentials(cleanUsername, cleanName, password);
    await _requireActiveManager(_database, manager.id);
    final salt = _generateSalt();
    final passwordHash = await _hashPassword(password, salt);
    final now = DateTime.now().toUtc().toIso8601String();

    return _database.transaction((txn) async {
      final managerUsername = await _requireActiveManager(txn, manager.id);
      final existing = await txn.query(
        'users',
        columns: ['id'],
        where: 'username = ? COLLATE NOCASE',
        whereArgs: [cleanUsername],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        throw const AuthException('اسم المستخدم مستخدم بالفعل. اختر اسمًا آخر.');
      }

      final id = await txn.insert('users', {
        'username': cleanUsername,
        'display_name': cleanName,
        'password_hash': passwordHash,
        'password_salt': base64Encode(salt),
        'password_iterations': _passwordIterations,
        'role': 'cashier',
        'is_active': 1,
        'created_at': now,
      });
      await _writeAudit(
        txn,
        userId: manager.id,
        username: managerUsername,
        action: 'cashier_created:$cleanUsername',
        createdAt: now,
      );
      return AuthUser(
        id: id,
        username: cleanUsername,
        displayName: cleanName,
        role: 'cashier',
      );
    });
  }

  /// تفعيل أو إيقاف حساب كاشير؛ لا تسمح هذه العملية بتعديل حساب مدير.
  Future<void> setCashierActive({
    required AuthUser manager,
    required int cashierId,
    required bool isActive,
  }) async {
    await _database.transaction((txn) async {
      final managerUsername = await _requireActiveManager(txn, manager.id);
      final rows = await txn.query(
        'users',
        columns: ['id', 'username', 'is_active'],
        where: "id = ? AND role = 'cashier'",
        whereArgs: [cashierId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw const AuthException('حساب الكاشير غير موجود.');
      }
      final cashier = rows.single;
      final currentState = cashier['is_active'] == 1;
      if (currentState == isActive) return;

      await txn.update(
        'users',
        {'is_active': isActive ? 1 : 0},
        where: 'id = ?',
        whereArgs: [cashierId],
      );
      await _writeAudit(
        txn,
        userId: manager.id,
        username: managerUsername,
        action: isActive
            ? 'cashier_activated:$cashierId'
            : 'cashier_deactivated:$cashierId',
        createdAt: DateTime.now().toUtc().toIso8601String(),
      );
    });
  }

  /// إعادة تعيين كلمة مرور كاشير مع إلغاء القفل والمحاولات الفاشلة.
  Future<void> resetCashierPassword({
    required AuthUser manager,
    required int cashierId,
    required String newPassword,
  }) async {
    if (newPassword.length < 10 || newPassword.length > 128) {
      throw const AuthException('كلمة المرور يجب أن تكون بين 10 و128 حرفًا.');
    }
    await _requireActiveManager(_database, manager.id);
    final salt = _generateSalt();
    final passwordHash = await _hashPassword(newPassword, salt);

    await _database.transaction((txn) async {
      final managerUsername = await _requireActiveManager(txn, manager.id);
      final rows = await txn.query(
        'users',
        columns: ['id'],
        where: "id = ? AND role = 'cashier'",
        whereArgs: [cashierId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw const AuthException('حساب الكاشير غير موجود.');
      }
      await txn.update(
        'users',
        {
          'password_hash': passwordHash,
          'password_salt': base64Encode(salt),
          'password_iterations': _passwordIterations,
          'failed_attempts': 0,
          'locked_until': null,
        },
        where: 'id = ?',
        whereArgs: [cashierId],
      );
      await _writeAudit(
        txn,
        userId: manager.id,
        username: managerUsername,
        action: 'cashier_password_reset:$cashierId',
        createdAt: DateTime.now().toUtc().toIso8601String(),
      );
    });
  }

  List<int> _generateSalt() {
    final secureRandom = Random.secure();
    return List<int>.generate(
      _saltLength,
      (_) => secureRandom.nextInt(256),
    );
  }

  Future<String> _requireActiveManager(
    DatabaseExecutor executor,
    int managerId,
  ) async {
    final rows = await executor.query(
      'users',
      columns: ['username'],
      where: "id = ? AND role = 'manager' AND is_active = 1",
      whereArgs: [managerId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const AuthException('هذه العملية متاحة لحساب مدير نشط فقط.');
    }
    return rows.single['username'] as String;
  }

  Future<void> logout(AuthUser user) async {
    await _writeAudit(
      _database,
      userId: user.id,
      username: user.username,
      action: 'logout',
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
  }

  void _validateCredentials(String username, String displayName, String password) {
    if (!RegExp(r'^[a-zA-Z0-9_.-]{3,32}$').hasMatch(username)) {
      throw const AuthException(
        'اسم المستخدم يجب أن يكون من 3 إلى 32 حرفًا إنجليزيًا أو رقمًا، ويمكن استخدام النقطة والشرطة.',
      );
    }
    if (displayName.isEmpty || displayName.length > 80) {
      throw const AuthException('أدخل اسمًا ظاهرًا صحيحًا لا يتجاوز 80 حرفًا.');
    }
    if (password.length < 10 || password.length > 128) {
      throw const AuthException('كلمة المرور يجب أن تكون بين 10 و128 حرفًا.');
    }
  }

  Future<String> _hashPassword(
    String password,
    List<int> salt, {
    int iterations = _passwordIterations,
  }) {
    // تُنفّذ عملية PBKDF2 في isolate حتى لا تتجمد واجهة المستخدم أثناء الاشتقاق.
    return compute<Map<String, Object?>, String>(_derivePbkdf2, {
      'password': password,
      'salt': base64Encode(salt),
      'iterations': iterations,
    });
  }

  static String _derivePbkdf2(Map<String, Object?> input) {
    final password = utf8.encode(input['password'] as String);
    final salt = base64Decode(input['salt'] as String);
    final iterations = input['iterations'] as int;
    final hmac = Hmac(sha256, password);
    final block = Uint8List(salt.length + 4)..setRange(0, salt.length, salt);
    block[block.length - 1] = 1;

    var current = hmac.convert(block).bytes;
    final result = Uint8List.fromList(current);
    for (var round = 1; round < iterations; round++) {
      current = hmac.convert(current).bytes;
      for (var index = 0; index < result.length; index++) {
        result[index] ^= current[index];
      }
    }
    return base64Encode(result);
  }

  static bool _constantTimeEquals(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }

  Future<void> _writeAudit(
    DatabaseExecutor executor, {
    required int userId,
    required String username,
    required String action,
    required String createdAt,
  }) async {
    await executor.insert('auth_audit_log', {
      'user_id': userId,
      'username_snapshot': username,
      'action': action,
      'created_at': createdAt,
    });
  }
}
