import 'package:flutter/material.dart';

import '../data/cashbox_repository.dart';
import '../data/grocery_database.dart';

/// شاشة الخزينة والتقرير اليومي للمبالغ المسجلة فعليًا.
class CashboxScreen extends StatefulWidget {
  const CashboxScreen({this.userId, this.shiftId, super.key});

  final int? userId;
  final int? shiftId;

  @override
  State<CashboxScreen> createState() => _CashboxScreenState();
}

class _CashboxScreenState extends State<CashboxScreen> {
  late Future<_CashboxData> _data;
  String _paymentFilter = 'الكل';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _data = _load();
  }

  Future<_CashboxData> _load() async {
    final db = await GroceryDatabase.open();
    final repo = CashboxRepository(db);
    return _CashboxData(
      await repo.summary(),
      await repo.recent(paymentMethod: _paymentFilter == 'الكل' ? null : _paymentFilter),
    );
  }

  Future<void> _addMovement() async {
    final direction = await showModalBottomSheet<String>(
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
              ListTile(
                leading: const Icon(Icons.add_circle_outline, color: Colors.green),
                title: const Text('مقبوض يدوي'),
                subtitle: const Text('مثل دخل متنوع أو رصيد افتتاحي'),
                onTap: () => Navigator.pop(context, 'in'),
              ),
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
    );
    if (direction == null || !mounted) return;
    final categoryController = TextEditingController();
    final amountController = TextEditingController();
    final noteController = TextEditingController();
    String paymentMethod = 'نقدي';
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
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
                      DropdownMenuItem(value: 'محفظة إلكترونية', child: Text('محفظة إلكترونية')),
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
          setState(_reload);
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('الخزينة والتقرير اليومي'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: () => setState(_reload),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addMovement,
        icon: const Icon(Icons.add_rounded),
        label: const Text('حركة يدوية'),
      ),
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
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
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
                Row(children: [
                  Expanded(child: Text('حركات اليوم', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold))),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 160,
                    child: DropdownButtonFormField<String>(
                      initialValue: _paymentFilter,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'فرز حسب الطريقة', isDense: true),
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
                  ),
                ]),
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
