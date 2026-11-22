import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../widgets/dialog_lifecycle.dart';

import '../data/cashbox_repository.dart';
import '../data/grocery_database.dart';
import '../data/sale_repository.dart';

/// شاشة الخزينة والتقرير اليومي للمبالغ المسجلة فعليًا.
class CashboxScreen extends StatefulWidget {
  const CashboxScreen({required this.userId, this.isManager = false, this.shiftId, this.canViewCashbox = true, this.canRecordExpenses = false, this.canRecordManualMovements = true, super.key});

  final int userId;
  final bool isManager;
  final int? shiftId;
  final bool canViewCashbox;
  final bool canRecordExpenses;
  final bool canRecordManualMovements;

  @override
  State<CashboxScreen> createState() => _CashboxScreenState();
}

class _CashboxScreenState extends State<CashboxScreen> {
  late Future<_CashboxData> _data;
  String _paymentFilter = 'الكل';
  bool _canRefundOverpayments = false;

  @override
  void initState() {
    super.initState();
    if (widget.canViewCashbox) _reload();
    _loadOverpaymentPermission();
  }

  void _reload() {
    _data = _load();
  }

  Future<_CashboxData> _load() async {
    final db = await GroceryDatabase.open();
    final repo = CashboxRepository(db);
    return _CashboxData(
      await repo.summary(userId: widget.userId),
      await repo.recent(userId: widget.userId, paymentMethod: _paymentFilter == 'الكل' ? null : _paymentFilter),
    );
  }


  Future<void> _loadOverpaymentPermission() async {
    if (widget.isManager) {
      if (mounted) setState(() => _canRefundOverpayments = true);
      return;
    }
    try {
      final db = await GroceryDatabase.open();
      final rows = await db.query('cashier_permissions', columns: ['is_allowed'],
        where: "user_id = ? AND permission_key = 'customer_overpayments'",
        whereArgs: [widget.userId], limit: 1);
      if (mounted) setState(() => _canRefundOverpayments = rows.isNotEmpty && rows.single['is_allowed'] == 1);
    } catch (_) {
      if (mounted) setState(() => _canRefundOverpayments = false);
    }
  }

  Future<void> _showPendingOverpayments() async {
    if (!_canRefundOverpayments) return;
    final db = await GroceryDatabase.open();
    final repo = SaleRepository(db);
    Future<List<Map<String, Object?>>> load() => repo.pendingCustomerOverpayments(userId: widget.userId);
    var rows = await load();
    if (!mounted) return;
    await showDialogAndWaitForExit<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: const Text('مبالغ مستحقة للزبائن'),
          content: SizedBox(width: 520, child: rows.isEmpty
            ? const Text('لا توجد مبالغ زيادة معلقة.')
            : ConstrainedBox(constraints: const BoxConstraints(maxHeight: 420),
                child: ListView(shrinkWrap: true, children: [
                  for (final row in rows)
                    Card(child: ListTile(
                      title: Text('فاتورة ${row['invoice_number']}'),
                      subtitle: Text('المستلم الزائد: ${row['received_amount']} ج.س • سبق رده: ${row['refunded_amount']} ج.س'),
                      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Text('${row['outstanding_amount']} ج.س', style: const TextStyle(fontWeight: FontWeight.bold)),
                        const Text('متبقي', style: TextStyle(fontSize: 11)),
                      ]),
                      onTap: () async {
                        await _refundOverpayment(repo, row);
                        rows = await load();
                        if (mounted) refresh(() {});
                      },
                    )),
                ]))),
          actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إغلاق'))],
        ),
      ),
    );
    if (mounted && widget.canViewCashbox) setState(_reload);
  }

  Future<void> _refundOverpayment(SaleRepository repo, Map<String, Object?> row) async {
    final amountController = TextEditingController(text: '${row['outstanding_amount']}');
    String method = 'نقدي';
    final amount = await showDialogAndWaitForExit<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (context, refresh) => AlertDialog(
        title: Text('رد زيادة فاتورة ${row['invoice_number']}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('المبلغ المتبقي: ${row['outstanding_amount']} ج.س'),
          TextField(controller: amountController, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'مبلغ الرد')),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: method, decoration: const InputDecoration(labelText: 'وسيلة الرد'),
            items: const [
              DropdownMenuItem(value: 'نقدي', child: Text('نقدي')),
              DropdownMenuItem(value: 'تحويل بنكي', child: Text('تحويل بنكي')),
            ],
            onChanged: (value) { if (value != null) refresh(() => method = value); },
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
          FilledButton(onPressed: () {
            final value = int.tryParse(amountController.text.trim());
            final maximum = (row['outstanding_amount'] as num).toInt();
            if (value == null || value <= 0 || value > maximum) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('أدخل مبلغًا صحيحًا لا يتجاوز المستحق.')));
              return;
            }
            Navigator.pop(dialogContext, value);
          }, child: const Text('تأكيد الرد')),
        ],
      )),
    );
    amountController.dispose();
    if (amount == null || !mounted) return;
    try {
      await repo.refundCustomerOverpayment(saleId: (row['sale_id'] as num).toInt(),
        amount: amount, paymentMethod: method, userId: widget.userId, shiftId: widget.shiftId);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم تسجيل رد الزيادة.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر رد المبلغ: $error')));
    }
  }

  Future<void> _addMovement() async {
    if (!widget.canRecordManualMovements && !widget.canRecordExpenses) return;
    final direction = widget.canRecordManualMovements
        ? await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('نوع الحركة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              if (widget.canRecordManualMovements)
                ListTile(
                leading: const Icon(Icons.add_circle_outline, color: Colors.green),
                title: const Text('مقبوض يدوي'),
                subtitle: const Text('مثل دخل متنوع أو رصيد افتتاحي'),
                onTap: () => Navigator.pop(context, 'in'),
              ),
              if (widget.canRecordManualMovements || widget.canRecordExpenses)
                ListTile(
                leading: const Icon(Icons.remove_circle_outline, color: Colors.red),
                title: const Text('مصروف'),
                subtitle: const Text('مثل إيجار أو كهرباء أو نقل'),
                onTap: () => Navigator.pop(context, 'out'),
              ),
            ],
          ),
        ),
      ),
    )
        : 'out';
    if (direction == null || !mounted) return;
    final categoryController = TextEditingController();
    final amountController = TextEditingController();
    final noteController = TextEditingController();
    String paymentMethod = 'نقدي';
    final formKey = GlobalKey<FormState>();
    final saved = await showDialogAndWaitForExit<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(direction == 'in' ? 'تسجيل مقبوض' : 'تسجيل مصروف'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: categoryController,
                    decoration: const InputDecoration(labelText: 'البند', hintText: 'مثال: إيجار المحل'),
                    validator: (value) => value == null || value.trim().isEmpty ? 'أدخل اسم البند' : null,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: amountController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'المبلغ بالجنيه السوداني'),
                    validator: (value) {
                      final amount = int.tryParse(value?.trim() ?? '');
                      return amount == null || amount <= 0 ? 'أدخل مبلغًا صحيحًا أكبر من صفر' : null;
                    },
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: paymentMethod,
                    decoration: const InputDecoration(labelText: 'طريقة الدفع'),
                    items: const [
                      DropdownMenuItem(value: 'نقدي', child: Text('نقدي')),
                      DropdownMenuItem(value: 'تحويل بنكي', child: Text('تحويل بنكي')),
                    ],
                    onChanged: (value) {
                      if (value != null) setDialogState(() => paymentMethod = value);
                    },
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: noteController,
                    decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)'),
                    maxLines: 2,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                if (formKey.currentState!.validate()) Navigator.pop(dialogContext, true);
              },
              child: const Text('حفظ الحركة'),
            ),
          ],
        ),
      ),
    );
    if (saved == true && mounted) {
      try {
        final db = await GroceryDatabase.open();
        await CashboxRepository(db).recordManualMovement(
          direction: direction,
          category: categoryController.text,
          amount: int.parse(amountController.text.trim()),
          paymentMethod: paymentMethod,
          note: noteController.text,
          userId: widget.userId,
          shiftId: widget.shiftId,
        );
        if (mounted) {
          if (widget.canViewCashbox) setState(_reload);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم تسجيل الحركة')));
        }
      } catch (error) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر حفظ الحركة: $error')));
      }
    }
    categoryController.dispose();
    amountController.dispose();
    noteController.dispose();
  }

  String _money(int value) => '${value.toString()} ج.س';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!widget.canViewCashbox) {
      return Scaffold(
        appBar: AppBar(title: const Text('تسجيل مصروف')),
        body: Center(child: Padding(padding: const EdgeInsets.all(24), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.receipt_long_outlined, size: 48),
          const SizedBox(height: 12),
          Text('يمكنك تسجيل المصروفات المصرح بها فقط. لا تعرض هذه الشاشة أرصدة الخزينة أو حركاتها.', textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: widget.canRecordExpenses ? _addMovement : null, icon: const Icon(Icons.add_rounded), label: const Text('تسجيل مصروف')),
        ])))),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('الخزينة والتقرير اليومي'),
        actions: [
          if (_canRefundOverpayments)
            TextButton.icon(
              onPressed: _showPendingOverpayments,
              icon: const Icon(Icons.assignment_return_outlined),
              label: const Text('تسوية زيادات الزبائن'),
            ),
          IconButton(
            tooltip: 'تحديث',
            onPressed: () => setState(_reload),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      floatingActionButton: widget.canRecordManualMovements || widget.canRecordExpenses
          ? FloatingActionButton.extended(onPressed: _addMovement, icon: const Icon(Icons.add_rounded), label: Text(widget.canRecordManualMovements ? 'حركة يدوية' : 'تسجيل مصروف'))
          : null,
      body: FutureBuilder<_CashboxData>(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('تعذر تحميل بيانات الخزينة\n${snapshot.error}', textAlign: TextAlign.center),
            ));
          }
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final data = snapshot.data!;
          final summary = data.summary;
          return RefreshIndicator(
            onRefresh: () async => setState(_reload),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                defaultTargetPlatform == TargetPlatform.android ? 12 : 16,
                8,
                defaultTargetPlatform == TargetPlatform.android ? 12 : 16,
                96,
              ),
              children: [
                Text('ملخص اليوم', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                LayoutBuilder(builder: (context, constraints) {
                  final width = (constraints.maxWidth - 12) / (constraints.maxWidth > 560 ? 3 : 2);
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _SummaryCard(title: 'المقبوضات اليوم', amount: summary.todayIncome, icon: Icons.south_west_rounded, color: Colors.green, width: width, money: _money),
                      _SummaryCard(title: 'المدفوعات اليوم', amount: summary.todayExpense, icon: Icons.north_east_rounded, color: Colors.red, width: width, money: _money),
                      _SummaryCard(title: 'صافي اليوم', amount: summary.todayNet, icon: Icons.calculate_rounded, color: theme.colorScheme.primary, width: width, money: _money),
                    ],
                  );
                }),
                const SizedBox(height: 14),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const Icon(Icons.account_balance_wallet_outlined, size: 32),
                        const SizedBox(width: 12),
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('صافي الحركات المسجلة منذ البداية'),
                            const SizedBox(height: 4),
                            Text(_money(summary.currentBalance), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                          ],
                        )),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const SizedBox(height: 20),
                Text('تفصيل المقبوضات والمدفوعات حسب الطريقة', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                LayoutBuilder(builder: (context, constraints) {
                  final width = (constraints.maxWidth - 12) / 2;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _SummaryCard(title: 'المقبوض نقدًا', amount: summary.todayCashIncome, icon: Icons.payments_outlined, color: Colors.green, width: width, money: _money),
                      _SummaryCard(title: 'المدفوع نقدًا', amount: summary.todayCashExpense, icon: Icons.money_off_csred_outlined, color: Colors.red, width: width, money: _money),
                      _SummaryCard(title: 'المقبوض بتحويل بنكي', amount: summary.todayBankIncome, icon: Icons.account_balance_outlined, color: Colors.green, width: width, money: _money),
                      _SummaryCard(title: 'المدفوع بتحويل بنكي', amount: summary.todayBankExpense, icon: Icons.account_balance_outlined, color: Colors.red, width: width, money: _money),
                    ],
                  );
                }),
                const SizedBox(height: 24),
                LayoutBuilder(builder: (context, constraints) {
                  final compactAndroid =
                      defaultTargetPlatform == TargetPlatform.android &&
                      constraints.maxWidth < 600;
                  final filter = SizedBox(
                    width: compactAndroid ? double.infinity : 180,
                    child: DropdownButtonFormField<String>(
                      initialValue: _paymentFilter,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'فرز حسب الطريقة',
                        isDense: true,
                      ),
                      items: const [
                        DropdownMenuItem(value: 'الكل', child: Text('كل الطرق')),
                        DropdownMenuItem(value: 'نقدي', child: Text('نقدي')),
                        DropdownMenuItem(value: 'تحويل بنكي', child: Text('تحويل بنكي')),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() {
                            _paymentFilter = value;
                            _reload();
                          });
                        }
                      },
                    ),
                  );
                  final heading = Text(
                    'حركات اليوم',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  );
                  if (compactAndroid) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        heading,
                        const SizedBox(height: 8),
                        filter,
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: heading),
                      const SizedBox(width: 12),
                      filter,
                    ],
                  );
                }),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text('${data.movements.length} حركة معروضة', style: theme.textTheme.bodySmall),
                ),
                const SizedBox(height: 10),
                if (data.movements.isEmpty)
                  Card(child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(child: Text(_paymentFilter == 'الكل'
                        ? 'لا توجد حركات مسجلة اليوم. ستظهر هنا المقبوضات والمدفوعات الجديدة.'
                        : 'لا توجد حركات مسجلة اليوم بطريقة الدفع: $_paymentFilter.')),
                  ))
                else
                  ...data.movements.map((movement) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: movement.isIncome ? Colors.green.withValues(alpha: 0.12) : Colors.red.withValues(alpha: 0.12),
                        child: Icon(movement.isIncome ? Icons.south_west_rounded : Icons.north_east_rounded, color: movement.isIncome ? Colors.green : Colors.red),
                      ),
                      title: Text(movement.category),
                      subtitle: Text([
                        movement.paymentMethod,
                        if (movement.note?.isNotEmpty == true) movement.note!,
                        TimeOfDay.fromDateTime(DateTime.parse(movement.createdAt).toLocal()).format(context),
                      ].join(' • ')),
                      trailing: Text(
                        '${movement.isIncome ? '+' : '−'}${_money(movement.amount)}',
                        style: TextStyle(fontWeight: FontWeight.bold, color: movement.isIncome ? Colors.green : Colors.red),
                      ),
                    ),
                  )),
                const SizedBox(height: 12),
                Text('ملاحظة: يعرض الرصيد صافي الحركات المسجلة منذ إضافة ميزة الخزينة، ولا يشمل العمليات التاريخية السابقة لترحيلها.', style: theme.textTheme.bodySmall),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CashboxData {
  const _CashboxData(this.summary, this.movements);
  final CashboxSummary summary;
  final List<CashTransaction> movements;
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.title,
    required this.amount,
    required this.icon,
    required this.color,
    required this.width,
    required this.money,
  });

  final String title;
  final int amount;
  final IconData icon;
  final Color color;
  final double width;
  final String Function(int) money;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            Text(money(amount), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    ),
  );
}
