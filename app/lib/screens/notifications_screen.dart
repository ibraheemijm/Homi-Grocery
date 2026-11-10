import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../data/grocery_database.dart';
import '../data/notification_repository.dart';

/// عرض سجل الإشعارات وطلبات الموافقة؛ قرارات النشر محصورة بالمدير.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({
    required this.userId,
    required this.isManager,
    this.database,
    super.key,
  });

  final int userId;
  final bool isManager;
  // يسمح بحقن قاعدة بيانات الاختبار نفسها دون تغيير سلوك التطبيق الفعلي.
  final Database? database;

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  late Future<_NotificationData> _data;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _data = _load();
  }

  Future<Database> _openDatabase() async =>
      widget.database ?? await GroceryDatabase.open();

  Future<_NotificationData> _load() async {
    final db = await _openDatabase();
    final notifications = NotificationRepository(db);
    final approvals = DeliveryApprovalRepository(db);
    return _NotificationData(
      notifications: await notifications.list(),
      unreadCount: await notifications.unreadCount(),
      approvals: await approvals.list(),
    );
  }

  Future<void> _markAllRead() async {
    final db = await _openDatabase();
    await NotificationRepository(db).markAllRead();
    if (mounted) setState(_reload);
  }

  Future<void> _markRead(int id) async {
    final db = await _openDatabase();
    await NotificationRepository(db).markRead(id);
    if (mounted) setState(_reload);
  }

  Future<bool> _confirmDecision({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _decide(DeliveryApproval approval, {required bool approved}) async {
    if (!widget.isManager || _busy || approval.status != 'pending') return;
    final accepted = await _confirmDecision(
      title: approved ? 'اعتماد طلب النشر' : 'رفض طلب النشر',
      message: approved
          ? 'هل تعتمد هذا الطلب؟ لن يبدأ أي نشر خارجي في هذا الإصدار.'
          : 'هل تؤكد رفض هذا الطلب؟',
      confirmLabel: approved ? 'اعتماد' : 'رفض',
    );
    if (!accepted || !mounted) return;

    setState(() => _busy = true);
    try {
      final db = await _openDatabase();
      await DeliveryApprovalRepository(db).decide(
        managerUserId: widget.userId,
        id: approval.id,
        approved: approved,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(approved ? 'تم اعتماد الطلب.' : 'تم رفض الطلب.')),
      );
      setState(_reload);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر حفظ القرار: $error')),
        );
        setState(_reload);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revokeInitialApproval() async {
    if (!widget.isManager || _busy) return;
    final accepted = await _confirmDecision(
      title: 'سحب الموافقة الأولية',
      message: 'سيتم سحب الموافقة الأولية ورفض طلبات التغيير المعلقة. هل تريد المتابعة؟',
      confirmLabel: 'سحب الموافقة',
    );
    if (!accepted || !mounted) return;

    setState(() => _busy = true);
    try {
      final db = await _openDatabase();
      await DeliveryApprovalRepository(db).revokeInitialApproval(
        managerUserId: widget.userId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم سحب الموافقة الأولية.')),
      );
      setState(_reload);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر سحب الموافقة: $error')),
        );
        setState(_reload);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  String _requestType(String type) => switch (type) {
        'initial_enable' => 'طلب التفعيل الأولي',
        'important_change' => 'طلب تغيير مهم',
        _ => type,
      };

  String _formatDate(String value) {
    final date = DateTime.tryParse(value)?.toLocal();
    if (date == null) return value;
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // اختصار العنوان بصريًا عند ضيق عرض الهاتف مع إبقاء النص الكامل متاحًا دلاليًا.
        title: const Text(
          'الإشعارات وسجل الموافقات',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: _busy ? null : () => setState(_reload),
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
          final hasActiveInitialApproval = data.approvals.any(
            (item) => item.requestType == 'initial_enable' && item.status == 'approved',
          );
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
                        '${_typeLabel(item.type)} • ${item.body.isEmpty ? _formatDate(item.createdAt) : item.body}',
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
                    'هذه السجلات توثّق قرارات النشر محليًا فقط. لا يوجد نشر خارجي مفعّل في هذا الإصدار.',
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
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // يسمح بنقل شارة الحالة إلى سطر مستقل على الهواتف الضيقة.
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              const Icon(Icons.verified_user_outlined),
                              Text(
                                _requestType(approval.requestType),
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                              Chip(label: Text(_approvalStatus(approval.status))),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            approval.summary,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text('نطاق البيانات: ${approval.dataScope}'),
                          if (approval.changeKey != null)
                            Text('معرّف التغيير: ${approval.changeKey}'),
                          Text('تاريخ الطلب: ${_formatDate(approval.createdAt)}'),
                          if (approval.decidedAt != null)
                            Text('تاريخ القرار: ${_formatDate(approval.decidedAt!)}'),
                          if (approval.decidedByUserId != null)
                            Text('اتخذ القرار حساب المدير رقم: ${approval.decidedByUserId}'),
                          if (approval.decisionNote?.isNotEmpty == true)
                            Text('ملاحظة القرار: ${approval.decisionNote}'),
                          if (widget.isManager && approval.status == 'pending') ...[
                            const Divider(height: 20),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FilledButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : () => _decide(approval, approved: true),
                                  icon: const Icon(Icons.check_rounded),
                                  label: const Text('موافقة'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : () => _decide(approval, approved: false),
                                  icon: const Icon(Icons.close_rounded),
                                  label: const Text('رفض'),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
              if (widget.isManager && hasActiveInitialApproval)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.warning_amber_rounded),
                    title: const Text('سحب الموافقة الأولية'),
                    subtitle: const Text(
                      'يسحب الموافقة ويوقف اعتماد التغييرات المعلقة.',
                    ),
                    trailing: TextButton(
                      onPressed: _busy ? null : _revokeInitialApproval,
                      child: const Text('سحب'),
                    ),
                  ),
                ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(child: CircularProgressIndicator()),
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
