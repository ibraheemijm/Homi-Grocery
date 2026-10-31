import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../data/grocery_database.dart';
import '../data/report_print_service.dart';
import '../data/reports_repository.dart';
import '../data/pdf_file_exporter.dart';
import '../data/pdf_file_name.dart';

/// تقارير حسب اليوم؛ لا يعرض ربحًا تقديريًا قبل حفظ تكلفة الصنف وقت البيع.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  DateTime _day = DateTime.now();
  DateTime _periodDate = DateTime.now();
  String _periodMode = 'month';
  late Future<DailyReport> _report;
  late Future<PeriodReport> _periodReport;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _report = _load();
    _periodReport = _loadPeriod();
  }

  Future<PeriodReport> _loadPeriod() async {
    final db = await GroceryDatabase.open();
    final start = _periodMode == 'month'
        ? DateTime(_periodDate.year, _periodDate.month)
        : DateTime(_periodDate.year);
    final end = _periodMode == 'month'
        ? DateTime(_periodDate.year, _periodDate.month + 1)
        : DateTime(_periodDate.year + 1);
    return ReportsRepository(db).loadPeriod(start: start, end: end);
  }

  Future<DailyReport> _load() async {
    final db = await GroceryDatabase.open();
    return ReportsRepository(db).load(day: _day);
  }

  String _money(int amount) => '${amount.toString()} ج.س';

  String _dateLabel(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  String _compactDateLabel(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';

  Future<void> _choosePeriodDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _periodDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      helpText: _periodMode == 'month' ? 'اختر شهر التقرير' : 'اختر سنة التقرير',
    );
    if (selected != null && mounted) {
      setState(() {
        _periodDate = selected;
        _reload();
      });
    }
  }

  Future<void> _printDailyReport(DailyReport report, {bool saveToFile = false}) async {
    try {
      final database = await GroceryDatabase.open();
      final rows = await database.query(
        'app_metadata',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: ['store_name'],
        limit: 1,
      );
      final storeName = rows.isEmpty ? 'Homi Grocery' : (rows.single['value'] as String).trim();
      final languageRows = await database.query(
        'app_metadata',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: ['pdf_filename_language'],
        limit: 1,
      );
      final filenameLanguage = languageRows.isEmpty
          ? 'both'
          : languageRows.single['value'] as String;
      final bytes = await ReportPrintService().buildDailyPdf(
        report: report,
        storeName: storeName.isEmpty ? 'Homi Grocery' : storeName,
      );
      if (!mounted) return;
      final fileName = buildPdfFileName(
        language: filenameLanguage,
        arabicLabel: 'تقرير-يومي',
        englishLabel: 'Daily-Report',
        sharedSuffix: _compactDateLabel(report.day),
        includeExportDate: false,
      );
      if (saveToFile) {
        final path = await savePdfBytes(
          bytes: bytes,
          fileName: fileName,
          dialogTitle: 'حفظ التقرير اليومي PDF',
        );
        if (path != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('تم حفظ التقرير: $path')),
          );
        }
      } else {
        await Printing.layoutPdf(
          name: fileName,
          onLayout: (_) async => bytes,
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر إنشاء التقرير اليومي PDF: $error')),
      );
    }
  }

  Future<void> _printPeriodReport(PeriodReport report, {bool saveToFile = false}) async {
    try {
      final database = await GroceryDatabase.open();
      final rows = await database.query(
        'app_metadata',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: ['store_name'],
        limit: 1,
      );
      final storeName = rows.isEmpty ? 'Homi Grocery' : (rows.single['value'] as String).trim();
      final languageRows = await database.query(
        'app_metadata',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: ['pdf_filename_language'],
        limit: 1,
      );
      final filenameLanguage = languageRows.isEmpty
          ? 'both'
          : languageRows.single['value'] as String;
      final bytes = await ReportPrintService().buildPeriodPdf(
        report: report,
        storeName: storeName.isEmpty ? 'Homi Grocery' : storeName,
        periodLabel: _periodLabel(report),
      );
      if (!mounted) return;
      final modeLabel = _periodMode == 'year' ? 'سنوي' : 'شهري';
      final englishModeLabel = _periodMode == 'year' ? 'Annual' : 'Monthly';
      final periodLabel = _periodMode == 'year'
          ? report.start.year.toString()
          : '${report.start.year}-${report.start.month.toString().padLeft(2, '0')}';
      final fileName = buildPdfFileName(
        language: filenameLanguage,
        arabicLabel: 'تقرير-$modeLabel',
        englishLabel: '$englishModeLabel-Report',
        sharedSuffix: periodLabel,
      );
      if (saveToFile) {
        final path = await savePdfBytes(
          bytes: bytes,
          fileName: fileName,
          dialogTitle: 'حفظ تقرير الفترة PDF',
        );
        if (path != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('تم حفظ التقرير: $path')),
          );
        }
      } else {
        await Printing.layoutPdf(
          name: fileName,
          onLayout: (_) async => bytes,
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر إنشاء التقرير PDF: $error')),
      );
    }
  }

  String _quantity(double value) =>
      value == value.truncateToDouble() ? value.toInt().toString() : value.toStringAsFixed(2);

  String _periodLabel(PeriodReport report) {
    if (_periodMode == 'year') return report.start.year.toString();
    return '${report.start.year}-${report.start.month.toString().padLeft(2, '0')}';
  }

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
        title: const Text('التقارير'),
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
                Text('ملخص المبيعات والأصناف الأكثر مبيعًا', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _periodMode,
                        decoration: const InputDecoration(
                          labelText: 'نوع الفترة',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'month', child: Text('شهري')),
                          DropdownMenuItem(value: 'year', child: Text('سنوي')),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            _periodMode = value;
                            _reload();
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _choosePeriodDate,
                        icon: const Icon(Icons.calendar_month_rounded),
                        label: Text(_periodMode == 'month'
                            ? '${_periodDate.year}-${_periodDate.month.toString().padLeft(2, '0')}'
                            : _periodDate.year.toString()),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                FutureBuilder<PeriodReport>(
                  future: _periodReport,
                  builder: (context, periodSnapshot) {
                    if (periodSnapshot.hasError) {
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text('تعذر تحميل ملخص الفترة: ${periodSnapshot.error}'),
                        ),
                      );
                    }
                    if (!periodSnapshot.hasData) {
                      return const Card(
                        child: Padding(
                          padding: EdgeInsets.all(20),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      );
                    }
                    final period = periodSnapshot.data!;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () => _printPeriodReport(period),
                              icon: const Icon(Icons.print_rounded),
                              label: const Text('طباعة تقرير الفترة'),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: () => _printPeriodReport(period, saveToFile: true),
                              icon: const Icon(Icons.save_alt_rounded),
                              label: const Text('حفظ PDF باسم التقرير'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Card(
                          child: Column(
                            children: [
                              ListTile(
                                leading: const Icon(Icons.point_of_sale_rounded),
                                title: const Text('إجمالي المبيعات'),
                                subtitle: Text('${period.salesCount} فاتورة • ${_periodLabel(period)}'),
                                trailing: Text(_money(period.salesTotal), style: const TextStyle(fontWeight: FontWeight.bold)),
                              ),
                              const Divider(height: 1),
                              ListTile(
                                leading: const Icon(Icons.assignment_return_outlined),
                                title: const Text('مرتجعات المبيعات'),
                                trailing: Text(_money(period.returnsTotal), style: const TextStyle(fontWeight: FontWeight.bold)),
                              ),
                              const Divider(height: 1),
                              ListTile(
                                leading: const Icon(Icons.account_balance_wallet_outlined),
                                title: const Text('صافي المبيعات بعد المرتجعات'),
                                trailing: Text(
                                  _money(period.netSalesTotal),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: period.netSalesTotal < 0 ? Colors.red : Colors.green,
                                  ),
                                ),
                              ),
                              const Divider(height: 1),
                              ListTile(
                                leading: const Icon(Icons.trending_up_rounded),
                                title: const Text('مجمل الربح للفترة'),
                                subtitle: Text(period.grossProfit == null
                                    ? 'غير متاح: توجد فواتير أو مرتجعات بتكلفة تاريخية غير محفوظة.'
                                    : 'بعد خصم تكلفة البضاعة المباعة وإضافة تكلفة البضاعة المرتجعة'),
                                trailing: Text(
                                  period.grossProfit == null ? '—' : _money(period.grossProfit!),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: period.grossProfit != null && period.grossProfit! < 0
                                        ? Colors.red
                                        : Colors.green,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text('الأكثر مبيعًا حسب صافي الكمية', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        const Text('صافي الكمية = كميات المبيعات في الفترة ناقص كميات المرتجعات المسجلة في الفترة.'),
                        const SizedBox(height: 8),
                        if (period.products.isEmpty)
                          const Card(child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('لا توجد مبيعات أو مرتجعات مسجلة لهذه الفترة.'),
                          ))
                        else
                          ...period.products.map((product) => Card(
                            child: ListTile(
                              leading: CircleAvatar(
                                child: Text((period.products.indexOf(product) + 1).toString()),
                              ),
                              title: Text(product.name),
                              subtitle: Text('مباع: ${_quantity(product.soldQuantity)} • مرتجع: ${_quantity(product.returnedQuantity)} ${product.unit}'),
                              trailing: Text(
                                '${_quantity(product.netQuantity)} ${product.unit}',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: product.netQuantity < 0 ? Colors.red : theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          )),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 18),
                Text('التقرير اليومي', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.event_note_rounded),
                    title: const Text('تاريخ التقرير'),
                    subtitle: Text(_dateLabel(report.day)),
                    trailing: const Icon(Icons.edit_calendar_rounded),
                    onTap: _chooseDay,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _printDailyReport(report),
                      icon: const Icon(Icons.print_rounded),
                      label: const Text('طباعة التقرير اليومي'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => _printDailyReport(report, saveToFile: true),
                      icon: const Icon(Icons.save_alt_rounded),
                      label: const Text('حفظ PDF باسم التقرير'),
                    ),
                  ],
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
                const SizedBox(height: 4),
                const Text('التحصيلات = مبالغ قبضها من الزبائن وسُجلت في دفتر التحصيل. مرتجعات المبيعات = قيمة البضاعة التي أُعيدت. أما «ردود نقدية للمرتجعات» فلا تزيد إلا عند تسجيل مبلغ دُفع فعليًا للزبون؛ لذلك قد تكون صفرًا رغم وجود مرتجع إذا خُصم من الدين بدل رد النقد.'),
                const SizedBox(height: 10),
                _ReportTile(title: 'تحصيلات الزبائن', amount: report.customerCollections, note: 'المبالغ المسجلة في دفتر التحصيل', icon: Icons.call_received_rounded, money: _money),
                _ReportTile(title: 'مدفوعات الموردين', amount: report.supplierPayments, note: 'المبالغ المسجلة للموردين', icon: Icons.call_made_rounded, money: _money),
                _ReportTile(title: 'مبالغ مستردة من الموردين', amount: report.supplierRefunds, note: 'النقد المستلم فعليًا من الموردين', icon: Icons.call_received_rounded, money: _money),
                _ReportTile(title: 'ردود نقدية للمرتجعات', amount: report.returnRefunds, note: 'رد النقد الفعلي للزبائن', icon: Icons.assignment_return_rounded, money: _money),
                const SizedBox(height: 18),
                Text('حركة الخزينة', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                _ReportTile(title: 'إجمالي المقبوضات', amount: report.cashIncome, note: 'من حركات الخزينة المسجلة', icon: Icons.south_west_rounded, money: _money),
                _ReportTile(title: 'إجمالي المدفوعات', amount: report.cashExpense, note: 'من حركات الخزينة المسجلة بجميع الطرق', icon: Icons.north_east_rounded, money: _money),
                const SizedBox(height: 8),
                Text('تفصيل الخزينة حسب طريقة الدفع', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                _ReportTile(title: 'المقبوضات النقدية', amount: report.cashOnlyIncome, note: 'المبالغ المستلمة نقدًا', icon: Icons.payments_outlined, money: _money),
                _ReportTile(title: 'المدفوعات النقدية', amount: report.cashOnlyExpense, note: 'المبالغ المدفوعة نقدًا', icon: Icons.money_off_csred_outlined, money: _money),
                _ReportTile(title: 'مقبوضات التحويل البنكي', amount: report.bankTransferIncome, note: 'المبالغ المستلمة بتحويل بنكي', icon: Icons.account_balance_outlined, money: _money),
                _ReportTile(title: 'مدفوعات التحويل البنكي', amount: report.bankTransferExpense, note: 'المبالغ المدفوعة بتحويل بنكي', icon: Icons.account_balance_outlined, money: _money),
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
