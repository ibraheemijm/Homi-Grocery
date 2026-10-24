import 'package:flutter/material.dart';

import '../data/grocery_database.dart';
import '../data/reports_repository.dart';

/// تقارير حسب اليوم؛ لا يعرض ربحًا تقديريًا قبل حفظ تكلفة الصنف وقت البيع.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  DateTime _day = DateTime.now();
  late Future<DailyReport> _report;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _report = _load();
  }

  Future<DailyReport> _load() async {
    final db = await GroceryDatabase.open();
    return ReportsRepository(db).load(day: _day);
  }

  String _money(int amount) => '${amount.toString()} ج.س';

  String _dateLabel(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  Future<void> _chooseDay() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      helpText: 'اختر يوم التقرير',
    );
    if (selected != null && mounted) {
      setState(() {
        _day = selected;
        _reload();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('التقارير اليومية'),
        actions: [
          IconButton(tooltip: 'اختيار التاريخ', onPressed: _chooseDay, icon: const Icon(Icons.calendar_month_rounded)),
          IconButton(tooltip: 'تحديث', onPressed: () => setState(_reload), icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: FutureBuilder<DailyReport>(
        future: _report,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('تعذر تحميل التقرير\n${snapshot.error}', textAlign: TextAlign.center),
            ));
          }
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final report = snapshot.data!;
          return RefreshIndicator(
            onRefresh: () async => setState(_reload),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.event_note_rounded),
                    title: const Text('تاريخ التقرير'),
                    subtitle: Text(_dateLabel(report.day)),
                    trailing: const Icon(Icons.edit_calendar_rounded),
                    onTap: _chooseDay,
                  ),
                ),
                const SizedBox(height: 16),
                Text('حركة البيع والشراء', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                _ReportTile(title: 'إجمالي المبيعات', amount: report.salesTotal, note: '${report.salesCount} فاتورة', icon: Icons.point_of_sale_rounded, money: _money),
                _ReportTile(title: 'مرتجعات المبيعات', amount: report.saleReturns, note: 'قيمة البضاعة المرتجعة في هذا اليوم', icon: Icons.assignment_return_outlined, money: _money),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.trending_up_rounded),
                    title: const Text('مجمل الربح التقديري'),
                    subtitle: Text(report.grossProfit == null
                        ? 'غير متاح: توجد فواتير قديمة لا تحتوي على تكلفة محفوظة وقت البيع.'
                        : 'المبيعات ناقص المرتجعات وتكلفة البضاعة المباعة بعد المرتجعات'),
                    trailing: Text(
                      report.grossProfit == null ? '—' : _money(report.grossProfit!),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: report.grossProfit != null && report.grossProfit! < 0 ? Colors.red : Colors.green,
                      ),
                    ),
                  ),
                ),
                _ReportTile(title: 'إجمالي المشتريات', amount: report.purchaseTotal, note: '${report.purchaseCount} فاتورة شراء', icon: Icons.local_shipping_rounded, money: _money),
                const SizedBox(height: 18),
                Text('التحصيلات والمرتجعات', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                _ReportTile(title: 'تحصيلات الزبائن', amount: report.customerCollections, note: 'المبالغ المسجلة في دفتر التحصيل', icon: Icons.call_received_rounded, money: _money),
                _ReportTile(title: 'مدفوعات الموردين', amount: report.supplierPayments, note: 'المبالغ المسجلة للموردين', icon: Icons.call_made_rounded, money: _money),
                _ReportTile(title: 'مبالغ مستردة من الموردين', amount: report.supplierRefunds, note: 'النقد المستلم فعليًا من الموردين', icon: Icons.call_received_rounded, money: _money),
                _ReportTile(title: 'ردود نقدية للمرتجعات', amount: report.returnRefunds, note: 'رد النقد الفعلي للزبائن', icon: Icons.assignment_return_rounded, money: _money),
                const SizedBox(height: 18),
                Text('حركة الخزينة', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                _ReportTile(title: 'إجمالي المقبوضات', amount: report.cashIncome, note: 'من حركات الخزينة المسجلة', icon: Icons.south_west_rounded, money: _money),
                _ReportTile(title: 'إجمالي المدفوعات', amount: report.cashExpense, note: 'من حركات الخزينة المسجلة', icon: Icons.north_east_rounded, money: _money),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.account_balance_wallet_rounded),
                    title: const Text('صافي حركة الخزينة'),
                    trailing: Text(_money(report.cashNet), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: report.cashNet < 0 ? Colors.red : Colors.green)),
                  ),
                ),
                const SizedBox(height: 18),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.inventory_2_rounded),
                    title: const Text('أصناف وصلت حد إعادة الطلب'),
                    subtitle: const Text('العدد الحالي، وليس عدد الأصناف التي انخفضت في هذا اليوم'),
                    trailing: Text(report.lowStockCount.toString(), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'مجمل الربح يعتمد على تكلفة الصنف المحفوظة عند البيع، ويستبعد الفواتير القديمة التي لا يمكن معرفة تكلفتها بدقة. هذا ليس صافي الربح بعد المصروفات التشغيلية.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ReportTile extends StatelessWidget {
  const _ReportTile({
    required this.title,
    required this.amount,
    required this.note,
    required this.icon,
    required this.money,
  });

  final String title;
  final int amount;
  final String note;
  final IconData icon;
  final String Function(int) money;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: ListTile(
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(title),
      subtitle: Text(note),
      trailing: Text(money(amount), style: const TextStyle(fontWeight: FontWeight.bold)),
    ),
  );
}
