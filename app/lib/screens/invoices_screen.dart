// شاشة استعراض الفواتير المحفوظة وإعادة طباعتها.
import 'package:flutter/material.dart';

import '../data/grocery_database.dart';
import '../data/invoice_print_service.dart';

class InvoicesScreen extends StatefulWidget {
  const InvoicesScreen({super.key});

  @override
  State<InvoicesScreen> createState() => _InvoicesScreenState();
}

class _InvoicesScreenState extends State<InvoicesScreen> {
  final _search = TextEditingController();
  List<Map<String, Object?>> _invoices = [];
  bool _loading = true;
  bool _printing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadInvoices();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadInvoices() async {
    try {
      final db = await GroceryDatabase.open();
      final query = _search.text.trim();
      final rows = await db.rawQuery('''
        SELECT s.id, s.invoice_number, s.customer_name, s.total,
          s.paid_amount, s.payment_method, s.created_at,
          (SELECT COUNT(*) FROM sale_items si WHERE si.sale_id = s.id) AS item_count
        FROM sales s
        WHERE (? = '' OR s.invoice_number LIKE ? OR COALESCE(s.customer_name, '') LIKE ?)
        ORDER BY s.id DESC
        LIMIT 200
      ''', [query, '%$query%', '%$query%']);
      if (!mounted) return;
      setState(() {
        _invoices = rows;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'تعذر تحميل الفواتير: $error';
      });
    }
  }

  Future<void> _print(Map<String, Object?> invoice, {required bool thermal}) async {
    if (_printing) return;
    setState(() => _printing = true);
    try {
      final db = await GroceryDatabase.open();
      await InvoicePrintService(db).printInvoice(invoice['id'] as int, thermal: thermal);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذرت طباعة الفاتورة: $error')),
      );
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  String _date(String value) {
    final parsed = DateTime.tryParse(value)?.toLocal();
    if (parsed == null) return value;
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')} ${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('الفواتير'),
          actions: [
            IconButton(
              tooltip: 'تحديث القائمة',
              onPressed: _loadInvoices,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: TextField(
                controller: _search,
                onChanged: (_) => _loadInvoices(),
                decoration: InputDecoration(
                  hintText: 'ابحث برقم الفاتورة أو اسم الزبون',
                  prefixIcon: const Icon(Icons.search_rounded),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Text(_error!, textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            FilledButton(onPressed: _loadInvoices, child: const Text('إعادة المحاولة')),
                          ]),
                        ))
                      : _invoices.isEmpty
                          ? const Center(child: Text('لا توجد فواتير مطابقة للبحث.'))
                          : RefreshIndicator(
                              onRefresh: _loadInvoices,
                              child: ListView.separated(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                                itemCount: _invoices.length,
                                separatorBuilder: (_, __) => const SizedBox(height: 8),
                                itemBuilder: (context, index) {
                                  final invoice = _invoices[index];
                                  final total = invoice['total'] as int;
                                  final paid = invoice['paid_amount'] as int;
                                  return Card(
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.stretch,
                                        children: [
                                          Row(
                                            children: [
                                              const Icon(Icons.receipt_long_rounded, color: Color(0xFF173D32)),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  invoice['invoice_number'] as String,
                                                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                                                ),
                                              ),
                                              Text('$total ج.س', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          Text('الزبون: ${(invoice['customer_name'] as String?)?.trim().isNotEmpty == true ? invoice['customer_name'] : 'زبون نقدي'}'),
                                          Text('التاريخ: ${_date(invoice['created_at'] as String)}'),
                                          Text('عدد البنود: ${invoice['item_count']} • المستلم: $paid ج.س • المتبقي: ${total - paid} ج.س'),
                                          const SizedBox(height: 8),
                                          Wrap(
                                            alignment: WrapAlignment.start,
                                            spacing: 8,
                                            runSpacing: 4,
                                            children: [
                                              OutlinedButton.icon(
                                                onPressed: _printing ? null : () => _print(invoice, thermal: false),
                                                icon: const Icon(Icons.picture_as_pdf_rounded),
                                                label: const Text('فاتورة A4 / PDF'),
                                              ),
                                              FilledButton.tonalIcon(
                                                onPressed: _printing ? null : () => _print(invoice, thermal: true),
                                                icon: const Icon(Icons.receipt_rounded),
                                                label: const Text('إيصال حراري'),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
            ),
          ],
        ),
      ),
    );
  }
}
