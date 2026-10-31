// إدارة الحسابات المحلية وتسجيل الدخول دون إرسال بيانات الاعتماد إلى أي خادم.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

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

    final salt = List<int>.generate(
      _saltLength,
      (_) => Random.secure().nextInt(256),
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
    if (password.length < 10) {
      throw const AuthException('كلمة المرور يجب ألا تقل عن 10 أحرف.');
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
