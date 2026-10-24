// شاشة الزبائن والديون: عرض الأرصدة وتسجيل التحصيلات من قاعدة البيانات.
import 'package:flutter/material.dart';

import '../data/customer_repository.dart';
import '../data/grocery_database.dart';

class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  CustomerRepository? _repository;
  List<CustomerBalance> _customers = [];
  final _search = TextEditingController();
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final database = await GroceryDatabase.open();
      _repository = CustomerRepository(database);
      await _load();
      if (mounted) setState(() { _loading = false; _error = null; });
    } catch (error) {
      if (mounted) setState(() { _loading = false; _error = 'تعذر تحميل حسابات الزبائن: $error'; });
    }
  }

  Future<void> _load() async {
    if (_repository == null) return;
    final rows = await _repository!.balances(query: _search.text);
    if (mounted) setState(() => _customers = rows);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _initialize, child: const Text('إعادة المحاولة')),
                    ]),
                  ))
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(18),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1100),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Row(children: [
                            Expanded(child: Text('الزبائن والديون', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800))),
                            FilledButton.icon(onPressed: _addCustomer, icon: const Icon(Icons.person_add_alt_1_rounded), label: const Text('إضافة زبون')),
                          ]),
                          const SizedBox(height: 6),
                          Text('الأرصدة محسوبة من الفواتير والتحصيلات المسجلة، وليست أرقامًا ثابتة.', style: theme.textTheme.bodyMedium),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _search,
                            onChanged: (_) => _load(),
                            decoration: const InputDecoration(
                              hintText: 'ابحث باسم الزبون',
                              prefixIcon: Icon(Icons.search_rounded),
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 14),
                          if (_customers.isEmpty)
                            const Card(child: Padding(
                              padding: EdgeInsets.all(28),
                              child: Column(children: [
                                Icon(Icons.people_outline_rounded, size: 44),
                                SizedBox(height: 10),
                                Text('لا يوجد زبائن مطابقون للبحث.'),
                                SizedBox(height: 5),
                                Text('يمكن إضافة زبون هنا أو تسجيل اسمه عند إنشاء فاتورة.', textAlign: TextAlign.center),
                              ]),
                            ))
                          else
                            ..._customers.map((customer) => Card(
                              margin: const EdgeInsets.only(bottom: 10),
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Row(children: [
                                  CircleAvatar(child: Text(customer.name.isEmpty ? '?' : customer.name.characters.first)),
                                  const SizedBox(width: 12),
                                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(customer.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                                    const SizedBox(height: 4),
                                    Text('الفواتير: ${customer.salesCount} • إجمالي المتبقي قبل التحصيلات: ${customer.totalDebt} ج.س'),
                                  ])),
                                  const SizedBox(width: 8),
                                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                                    Text('${customer.balance} ج.س', style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      color: customer.balance > 0 ? Colors.red.shade700 : theme.colorScheme.primary,
                                    )),
                                    Text(customer.balance > 0 ? 'الرصيد المستحق' : 'لا توجد ديون مستحقة',
                                      style: theme.textTheme.labelSmall),
                                  ]),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    tooltip: 'كشف الحساب',
                                    onPressed: () => _showLedger(customer),
                                    icon: const Icon(Icons.receipt_long_outlined),
                                  ),
                                  IconButton(
                                    tooltip: 'تسجيل تحصيل',
                                    onPressed: customer.balance > 0 ? () => _collect(customer) : null,
                                    icon: const Icon(Icons.payments_outlined),
                                  ),
                                ]),
                              ),
                            )),
                        ]),
                      ),
                    ),
                  ),
      ),
    );
  }

  Future<void> _showLedger(CustomerBalance customer) async {
    try {
      final entries = await _repository!.ledger(customer.id);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('كشف حساب ${customer.name}'),
          content: SizedBox(
            width: 560,
            child: entries.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(18),
                    child: Text('لا توجد حركات مالية مسجلة لهذا الزبون.'),
                  )
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final entry in entries)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              entry.isCredit
                                  ? Icons.south_west_rounded
                                  : Icons.north_east_rounded,
                              color: entry.isCredit
                                  ? Colors.green.shade700
                                  : Colors.red.shade700,
                            ),
                            title: Text(entry.title),
                            subtitle: Text(
                              [
                                _formatDate(entry.createdAt),
                                if (entry.note?.trim().isNotEmpty == true) entry.note!.trim(),
                              ].join(' • '),
                            ),
                            trailing: Text(
                              '${entry.isCredit ? '−' : '+'}${entry.amount} ج.س',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: entry.isCredit
                                    ? Colors.green.shade700
                                    : Colors.red.shade700,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      );
    } catch (error) {
      _message('تعذر تحميل كشف الحساب: $error');
    }
  }

  String _formatDate(String value) {
    final date = DateTime.tryParse(value)?.toLocal();
    if (date == null) return value;
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${date.year}-${twoDigits(date.month)}-${twoDigits(date.day)} '
        '${twoDigits(date.hour)}:${twoDigits(date.minute)}';
  }

  Future<void> _addCustomer() async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إضافة زبون'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'اسم الزبون')),
          const SizedBox(height: 10),
          TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الهاتف (اختياري)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حفظ')),
        ],
      ),
    );
    if (result == true && mounted) {
      try {
        await _repository!.addCustomer(name: name.text, phone: phone.text);
        await _load();
      } catch (error) {
        _message('تعذر إضافة الزبون: $error');
      }
    }
    name.dispose();
    phone.dispose();
  }

  Future<void> _collect(CustomerBalance customer) async {
    final amountController = TextEditingController();
    final noteController = TextEditingController();
    final amount = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('تحصيل من ${customer.name}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('الرصيد المستحق: ${customer.balance} ج.س'),
          const SizedBox(height: 12),
          TextField(controller: amountController, autofocus: true, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'المبلغ المستلم', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextField(controller: noteController, decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)', border: OutlineInputBorder())),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
          FilledButton(onPressed: () {
            final value = int.tryParse(amountController.text.trim());
            if (value == null || value <= 0) return;
            Navigator.pop(context, value);
          }, child: const Text('تسجيل التحصيل')),
        ],
      ),
    );
    if (amount != null && mounted) {
      try {
        await _repository!.recordPayment(customerId: customer.id, amount: amount, note: noteController.text);
        await _load();
        _message('تم تسجيل التحصيل بنجاح.');
      } catch (error) {
        _message('لم يتم تسجيل التحصيل: $error');
      }
    }
    amountController.dispose();
    noteController.dispose();
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}
