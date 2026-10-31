import 'package:flutter/material.dart';

import '../data/grocery_database.dart';
import '../data/notification_repository.dart';

/// عرض سجل الإشعارات وطلبات الموافقة المحفوظة محليًا فقط.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  late Future<_NotificationData> _data;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _data = _load();
  }

  Future<_NotificationData> _load() async {
    final db = await GroceryDatabase.open();
    final notifications = NotificationRepository(db);
    final approvals = DeliveryApprovalRepository(db);
    return _NotificationData(
      notifications: await notifications.list(),
      unreadCount: await notifications.unreadCount(),
      approvals: await approvals.list(),
    );
  }

  Future<void> _markAllRead() async {
    final db = await GroceryDatabase.open();
    await NotificationRepository(db).markAllRead();
    if (mounted) setState(_reload);
  }

  Future<void> _markRead(int id) async {
    final db = await GroceryDatabase.open();
    await NotificationRepository(db).markRead(id);
    if (mounted) setState(_reload);
  }

  String _typeLabel(String type) => switch (type) {
        'low_stock' => 'المخزون',
        'backup' => 'النسخ الاحتياطي',
        'sync' => 'المزامنة',
        'delivery_approval' => 'موافقة الدليفري',
        _ => 'عام',
      };

  String _approvalStatus(String status) => switch (status) {
        'pending' => 'بانتظار الموافقة',
        'approved' => 'موافق عليه',
        'rejected' => 'مرفوض',
        'revoked' => 'مسحوب',
        _ => status,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('الإشعارات وسجل الموافقات'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: () => setState(_reload),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: FutureBuilder<_NotificationData>(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('تعذر تحميل السجل: ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.notifications_active_rounded),
                  title: const Text('الإشعارات المحلية'),
                  subtitle: Text('غير المقروء: ${data.unreadCount}'),
                  trailing: data.unreadCount == 0
                      ? null
                      : TextButton(
                          onPressed: _markAllRead,
                          child: const Text('قراءة الكل'),
                        ),
                ),
              ),
              if (data.notifications.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(18),
                    child: Text('لا توجد إشعارات مسجلة حتى الآن.'),
                  ),
                )
              else
                for (final item in data.notifications)
                  Card(
                    child: ListTile(
                      leading: Icon(item.isRead
                          ? Icons.notifications_none_rounded
                          : Icons.notifications_active_rounded),
                      title: Text(item.title),
                      subtitle: Text(
                        '${_typeLabel(item.type)} • ${item.body.isEmpty ? item.createdAt : item.body}',
                      ),
                      trailing: item.isRead
                          ? const Icon(Icons.check_rounded)
                          : TextButton(
                              onPressed: () => _markRead(item.id),
                              child: const Text('قراءة'),
                            ),
                    ),
                  ),
              const Padding(
                padding: EdgeInsets.only(top: 20, bottom: 8),
                child: Text(
                  'سجل موافقات الدليفري',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'هذه السجلات توثّق طلبات الموافقة فقط. لا يوجد نشر خارجي مفعّل في هذا الإصدار.',
                  ),
                ),
              ),
              if (data.approvals.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(18),
                    child: Text('لا توجد طلبات موافقة مسجلة.'),
                  ),
                )
              else
                for (final approval in data.approvals)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.verified_user_outlined),
                      title: Text(approval.summary),
                      subtitle: Text(
                        '${approval.dataScope} • ${_approvalStatus(approval.status)}',
                      ),
                      isThreeLine: true,
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

class _NotificationData {
  const _NotificationData({
    required this.notifications,
    required this.unreadCount,
    required this.approvals,
  });

  final List<LocalNotification> notifications;
  final int unreadCount;
  final List<DeliveryApproval> approvals;
}
