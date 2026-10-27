// سجل إشعارات وموافقات محلي قابل للتدقيق. لا توجد اتصالات شبكية في هذه الطبقة.
import 'package:sqflite/sqflite.dart';

class LocalNotification {
  const LocalNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.isRead,
    this.eventKey,
    this.relatedId,
  });

  final int id;
  final String type;
  final String title;
  final String body;
  final String createdAt;
  final bool isRead;
  final String? eventKey;
  final String? relatedId;

  static LocalNotification fromRow(Map<String, Object?> row) => LocalNotification(
        id: row['id'] as int,
        type: row['type'] as String,
        title: row['title'] as String,
        body: row['body'] as String,
        createdAt: row['created_at'] as String,
        isRead: row['read_at'] != null,
        eventKey: row['event_key'] as String?,
        relatedId: row['related_id'] as String?,
      );
}

class DeliveryApproval {
  const DeliveryApproval({
    required this.id,
    required this.requestType,
    required this.summary,
    required this.dataScope,
    required this.status,
    required this.createdAt,
    this.changeKey,
    this.decidedAt,
    this.decisionNote,
  });

  final int id;
  final String requestType;
  final String summary;
  final String dataScope;
  final String status;
  final String createdAt;
  final String? changeKey;
  final String? decidedAt;
  final String? decisionNote;

  static DeliveryApproval fromRow(Map<String, Object?> row) => DeliveryApproval(
        id: row['id'] as int,
        requestType: row['request_type'] as String,
        summary: row['summary'] as String,
        dataScope: row['data_scope'] as String,
        status: row['status'] as String,
        createdAt: row['created_at'] as String,
        changeKey: row['change_key'] as String?,
        decidedAt: row['decided_at'] as String?,
        decisionNote: row['decision_note'] as String?,
      );
}

class NotificationRepository {
  NotificationRepository(this._database);
  final Database _database;

  Future<int> add({
    required String type,
    required String title,
    String body = '',
    String? eventKey,
    String? relatedId,
    DateTime? now,
  }) async {
    if (title.trim().isEmpty) throw ArgumentError('عنوان الإشعار مطلوب.');
    return _database.insert(
      'local_notifications',
      {
        'type': type,
        'title': title.trim(),
        'body': body.trim(),
        'event_key': eventKey,
        'related_id': relatedId,
        'created_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<LocalNotification>> list({bool unreadOnly = false, int limit = 100}) async {
    final rows = await _database.query(
      'local_notifications',
      where: unreadOnly ? 'read_at IS NULL' : null,
      orderBy: 'created_at DESC, id DESC',
      limit: limit.clamp(1, 500),
    );
    return rows.map(LocalNotification.fromRow).toList(growable: false);
  }

  Future<int> unreadCount() async {
    final rows = await _database.rawQuery(
      'SELECT COUNT(*) AS count FROM local_notifications WHERE read_at IS NULL',
    );
    return (rows.single['count'] as num).toInt();
  }

  Future<void> markRead(int id, {DateTime? now}) async {
    await _database.update(
      'local_notifications',
      {'read_at': (now ?? DateTime.now()).toUtc().toIso8601String()},
      where: 'id = ? AND read_at IS NULL',
      whereArgs: [id],
    );
  }

  Future<void> markAllRead({DateTime? now}) async {
    await _database.update(
      'local_notifications',
      {'read_at': (now ?? DateTime.now()).toUtc().toIso8601String()},
      where: 'read_at IS NULL',
    );
  }
}

class DeliveryApprovalRepository {
  DeliveryApprovalRepository(this._database);
  final Database _database;

  Future<int> requestInitialEnable({
    required String summary,
    required String dataScope,
    DateTime? now,
  }) async {
    return _request(
      requestType: 'initial_enable',
      summary: summary,
      dataScope: dataScope,
      now: now,
    );
  }

  Future<int> requestImportantChange({
    required String changeKey,
    required String summary,
    required String dataScope,
    DateTime? now,
  }) async {
    final approved = await _database.query(
      'delivery_publication_approvals',
      columns: ['id'],
      where: "request_type = 'initial_enable' AND status = 'approved'",
      limit: 1,
    );
    if (approved.isEmpty) {
      throw StateError('يلزم الحصول على الموافقة الأولية الفعالة قبل طلب نشر تغيير.');
    }
    if (changeKey.trim().isEmpty) throw ArgumentError('معرّف التغيير مطلوب.');
    return _request(
      requestType: 'important_change',
      changeKey: changeKey.trim(),
      summary: summary,
      dataScope: dataScope,
      now: now,
    );
  }

  Future<int> _request({
    required String requestType,
    required String summary,
    required String dataScope,
    String? changeKey,
    DateTime? now,
  }) async {
    if (summary.trim().isEmpty || dataScope.trim().isEmpty) {
      throw ArgumentError('يجب تحديد ملخص التغيير ونطاق البيانات.');
    }
    return _database.insert('delivery_publication_approvals', {
      'request_type': requestType,
      'change_key': changeKey,
      'summary': summary.trim(),
      'data_scope': dataScope.trim(),
      'status': 'pending',
      'created_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
    });
  }

  Future<void> decide({
    required int id,
    required bool approved,
    String? note,
    DateTime? now,
  }) async {
    await _database.transaction((txn) async {
      final rows = await txn.query(
        'delivery_publication_approvals',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('طلب الموافقة غير موجود.');
      final request = rows.single;
      if (request['status'] != 'pending') {
        throw StateError('يمكن اتخاذ القرار على الطلب المعلّق فقط.');
      }
      if (approved && request['request_type'] == 'important_change') {
        final initialApprovals = await txn.query(
          'delivery_publication_approvals',
          columns: ['id'],
          where: "request_type = 'initial_enable' AND status = 'approved'",
          limit: 1,
        );
        if (initialApprovals.isEmpty) {
          throw StateError('لا يمكن اعتماد تغيير مهم بعد سحب الموافقة الأولية.');
        }
      }
      final changed = await txn.update(
        'delivery_publication_approvals',
        {
          'status': approved ? 'approved' : 'rejected',
          'decided_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
          'decision_note': note?.trim(),
        },
        where: 'id = ? AND status = ?',
        whereArgs: [id, 'pending'],
      );
      if (changed != 1) {
        throw StateError('تغيّرت حالة الطلب؛ أعد تحميل السجل قبل اتخاذ القرار.');
      }
    });
  }

  Future<void> revokeInitialApproval({String? note, DateTime? now}) async {
    final timestamp = (now ?? DateTime.now()).toUtc().toIso8601String();
    await _database.transaction((txn) async {
      await txn.update(
        'delivery_publication_approvals',
        {
          'status': 'revoked',
          'decided_at': timestamp,
          'decision_note': note?.trim() ?? 'سُحبت الموافقة الأولية.',
        },
        where: "request_type = 'initial_enable' AND status = 'approved'",
      );
      await txn.update(
        'delivery_publication_approvals',
        {
          'status': 'rejected',
          'decided_at': timestamp,
          'decision_note': 'أُلغي الطلب لأن الموافقة الأولية سُحبت.',
        },
        where: "request_type = 'important_change' AND status = 'pending'",
      );
    });
  }

  Future<List<DeliveryApproval>> list({String? status, int limit = 100}) async {
    final rows = await _database.query(
      'delivery_publication_approvals',
      where: status == null ? null : 'status = ?',
      whereArgs: status == null ? null : [status],
      orderBy: 'created_at DESC, id DESC',
      limit: limit.clamp(1, 500),
    );
    return rows.map(DeliveryApproval.fromRow).toList(growable: false);
  }
}
