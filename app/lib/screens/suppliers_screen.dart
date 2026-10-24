// واجهة الموردين والمشتريات والمدفوعات.
import 'package:flutter/material.dart';

import '../data/grocery_database.dart';
import '../data/product_repository.dart';
import '../data/supplier_repository.dart';

class SuppliersScreen extends StatefulWidget {
  const SuppliersScreen({super.key});

  @override
  State<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends State<SuppliersScreen> {
  SupplierRepository? _repository;
  ProductRepository? _productsRepository;
  List<SupplierBalance> _suppliers = [];
  List<GroceryProduct> _products = [];
  bool _loading = true;
  String? _error;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final db = await GroceryDatabase.open();
      _repository = SupplierRepository(db);
      _productsRepository = ProductRepository(db);
      _products = await _productsRepository!.search('');
      await _load();
      if (mounted) setState(() { _loading = false; _error = null; });
    } catch (error) {
      if (mounted) setState(() { _loading = false; _error = 'تعذر تحميل الموردين: $error'; });
    }
  }

  Future<void> _load() async {
    if (_repository == null) return;
    final rows = await _repository!.balances(query: _search.text);
    if (mounted) setState(() => _suppliers = rows);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
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
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            Text('الموردون والمشتريات', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                            Wrap(spacing: 8, children: [
                              OutlinedButton.icon(onPressed: _addSupplier, icon: const Icon(Icons.person_add_alt_1_rounded), label: const Text('إضافة مورد')),
                              FilledButton.icon(onPressed: _createPurchase, icon: const Icon(Icons.add_shopping_cart_rounded), label: const Text('فاتورة شراء')),
                            ]),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text('متابعة فواتير الشراء، زيادة المخزون، والمبالغ المستحقة للموردين.', style: theme.textTheme.bodyMedium),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _search,
                          onChanged: (_) => _load(),
                          decoration: const InputDecoration(hintText: 'ابحث باسم المورد', prefixIcon: Icon(Icons.search_rounded), border: OutlineInputBorder()),
                        ),
                        const SizedBox(height: 14),
                        if (_suppliers.isEmpty)
                          const Card(child: Padding(
                            padding: EdgeInsets.all(28),
                            child: Column(children: [
                              Icon(Icons.local_shipping_outlined, size: 44),
                              SizedBox(height: 10),
                              Text('لا توجد سجلات موردين بعد.', style: TextStyle(fontWeight: FontWeight.w700)),
                              SizedBox(height: 5),
                              Text('أضف موردًا ثم سجّل فاتورة شراء لبدء متابعة المخزون والمستحقات.', textAlign: TextAlign.center),
                            ]),
                          ))
                        else
                          ..._suppliers.map((supplier) => Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Row(children: [
                                const CircleAvatar(child: Icon(Icons.local_shipping_outlined)),
                                const SizedBox(width: 12),
                                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(supplier.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                                  const SizedBox(height: 4),
                                  Text('فواتير الشراء: ${supplier.purchaseCount} • قبل الدفعات العامة: ${supplier.totalDebt} ج.س'),
                                ])),
                                const SizedBox(width: 8),
                                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                                  Text('${supplier.balance} ج.س', style: TextStyle(fontWeight: FontWeight.w900, color: supplier.balance > 0 ? Colors.red.shade700 : theme.colorScheme.primary)),
                                  Text(supplier.balance > 0 ? 'مستحق للمورد' : 'لا توجد مستحقات', style: theme.textTheme.labelSmall),
                                ]),
                                IconButton(tooltip: 'تسجيل دفعة', onPressed: supplier.balance > 0 ? () => _recordPayment(supplier) : null, icon: const Icon(Icons.payments_outlined)),
                              ]),
                            ),
                          )),
                      ]),
                    ),
                  ),
                ),
    );
  }

  Future<void> _addSupplier() async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final note = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة مورد'),
        content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'اسم المورد', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الهاتف (اختياري)', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextField(controller: note, decoration: const InputDecoration(labelText: 'ملاحظات (اختياري)', border: OutlineInputBorder())),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حفظ المورد')),
        ],
      ),
    );
    if (result == true && mounted) {
      try {
        await _repository!.addSupplier(name: name.text, phone: phone.text, notes: note.text);
        await _load();
        _message('تم حفظ المورد.');
      } catch (error) { _message('تعذر حفظ المورد: $error'); }
    }
    name.dispose(); phone.dispose(); note.dispose();
  }

  Future<void> _createPurchase() async {
    if (_suppliers.isEmpty) {
      _message('أضف موردًا أولًا قبل تسجيل فاتورة شراء.');
      return;
    }
    if (_products.isEmpty) {
      _message('أضف صنفًا إلى المخزون أولًا.');
      return;
    }

    int supplierId = _suppliers.first.id;
    final drafts = <_PurchaseDraftLine>[
      _PurchaseDraftLine(productId: _products.first.id!, cost: _products.first.purchasePrice.toString()),
    ];
    final discount = TextEditingController(text: '0');
    final paid = TextEditingController(text: '0');
    final note = TextEditingController();
    int estimatedSubtotal() => drafts.fold<int>(0, (sum, line) {
      final quantity = double.tryParse(line.quantity.text.trim()) ?? 0;
      final cost = int.tryParse(line.cost.text.trim()) ?? 0;
      return sum + (quantity * cost).round();
    });

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, refresh) => AlertDialog(
        title: const Text('فاتورة شراء جديدة'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<int>(
              initialValue: supplierId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'المورد', border: OutlineInputBorder()),
              items: [for (final s in _suppliers) DropdownMenuItem(value: s.id, child: Text(s.name, overflow: TextOverflow.ellipsis))],
              onChanged: (v) { if (v != null) refresh(() => supplierId = v); },
            ),
            const SizedBox(height: 14),
            Row(children: [
              const Expanded(child: Text('أصناف الفاتورة', style: TextStyle(fontWeight: FontWeight.w800))),
              TextButton.icon(
                onPressed: () => refresh(() => drafts.add(_PurchaseDraftLine(productId: _products.first.id!, cost: _products.first.purchasePrice.toString()))),
                icon: const Icon(Icons.add_rounded),
                label: const Text('إضافة صنف'),
              ),
            ]),
            ...List.generate(drafts.length, (index) {
              final draft = drafts[index];
              return Card(
                key: ValueKey(draft),
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(children: [
                    Row(children: [
                      Expanded(child: Text('الصنف ${index + 1}', style: const TextStyle(fontWeight: FontWeight.w700))),
                      if (drafts.length > 1)
                        IconButton(
                          tooltip: 'حذف الصنف',
                          onPressed: () => refresh(() => drafts.removeAt(index).dispose()),
                          icon: const Icon(Icons.delete_outline_rounded),
                        ),
                    ]),
                    DropdownButtonFormField<int>(
                      initialValue: draft.productId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'الصنف', border: OutlineInputBorder()),
                      items: [for (final p in _products) DropdownMenuItem(value: p.id, child: Text('${p.name} • المخزون ${p.stockQuantity}', overflow: TextOverflow.ellipsis))],
                      onChanged: (v) {
                        if (v != null) refresh(() {
                          draft.productId = v;
                          draft.cost.text = _products.firstWhere((p) => p.id == v).purchasePrice.toString();
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: TextField(
                        controller: draft.quantity,
                        onChanged: (_) => refresh(() {}),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'الكمية', border: OutlineInputBorder()),
                      )),
                      const SizedBox(width: 8),
                      Expanded(child: TextField(
                        controller: draft.cost,
                        onChanged: (_) => refresh(() {}),
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'سعر الوحدة (ج.س)', border: OutlineInputBorder()),
                      )),
                    ]),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: Text('الإجمالي: ${((double.tryParse(draft.quantity.text.trim()) ?? 0) * (int.tryParse(draft.cost.text.trim()) ?? 0)).round()} ج.س'),
                    ),
                  ]),
                ),
              );
            }),
            const SizedBox(height: 8),
            TextField(controller: discount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'الخصم (ج.س)', border: OutlineInputBorder())),
            const SizedBox(height: 10),
            TextField(controller: paid, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المدفوع الآن (ج.س)', border: OutlineInputBorder())),
            const SizedBox(height: 10),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)', border: OutlineInputBorder())),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Theme.of(ctx).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
              child: Text('إجمالي الأصناف: ${estimatedSubtotal()} ج.س\nالإجمالي بعد الخصم: ${(estimatedSubtotal() - (int.tryParse(discount.text.trim()) ?? 0)).clamp(0, 1 << 62)} ج.س',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 8),
            const Text('تُحفظ جميع الأصناف وتُحدّث الكميات وسجل المخزون ضمن معاملة واحدة.', style: TextStyle(fontSize: 12)),
          ])),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () {
            final subtotal = estimatedSubtotal();
            final d = int.tryParse(discount.text.trim());
            final p = int.tryParse(paid.text.trim());
            final validLines = drafts.every((line) {
              final q = double.tryParse(line.quantity.text.trim());
              final cost = int.tryParse(line.cost.text.trim());
              return q != null && q.isFinite && q > 0 && cost != null && cost >= 0;
            });
            if (!validLines || d == null || d < 0 || d > subtotal || p == null || p < 0 || p > subtotal - d) {
              ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('تحقق من الكميات والأسعار والخصم والمدفوع.')));
              return;
            }
            Navigator.pop(ctx, true);
          }, child: const Text('حفظ الفاتورة')),
        ],
      )),
    );

    if (saved == true && mounted) {
      try {
        final lines = drafts.map((draft) {
          final product = _products.firstWhere((p) => p.id == draft.productId);
          return PurchaseLine(
            productId: product.id!,
            productName: product.name,
            unit: product.unit,
            quantity: double.parse(draft.quantity.text.trim()),
            unitCost: int.parse(draft.cost.text.trim()),
          );
        }).toList(growable: false);
        await _repository!.createPurchase(
          supplierId: supplierId,
          lines: lines,
          discount: int.parse(discount.text.trim()),
          paidAmount: int.parse(paid.text.trim()),
          paymentMethod: int.parse(paid.text.trim()) == 0 ? 'آجل' : 'جزئي',
          note: note.text,
        );
        await _load();
        _products = await _productsRepository!.search('');
        _message('تم حفظ فاتورة الشراء بجميع أصنافها وتحديث المخزون.');
      } catch (error) {
        _message('لم تُحفظ الفاتورة: $error');
      }
    }
    for (final draft in drafts) { draft.dispose(); }
    discount.dispose();
    paid.dispose();
    note.dispose();
  }

  Future<void> _recordPayment(SupplierBalance supplier) async {
    final amount = TextEditingController();
    final note = TextEditingController();
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('دفعة إلى ${supplier.name}'),
        content: SizedBox(width: 360, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('المستحق الحالي: ${supplier.balance} ج.س'),
          const SizedBox(height: 10),
          TextField(controller: amount, autofocus: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ المدفوع', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextField(controller: note, decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)', border: OutlineInputBorder())),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(onPressed: () { final value = int.tryParse(amount.text.trim()); if (value != null && value > 0) Navigator.pop(ctx, value); }, child: const Text('تسجيل الدفعة')),
        ],
      ),
    );
    if (result != null && mounted) {
      try {
        await _repository!.recordPayment(supplierId: supplier.id, amount: result, note: note.text);
        await _load();
        _message('تم تسجيل دفعة المورد.');
      } catch (error) { _message('لم تُسجل الدفعة: $error'); }
    }
    amount.dispose(); note.dispose();
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _PurchaseDraftLine {
  _PurchaseDraftLine({required this.productId, String quantity = '1', String cost = '0'})
      : quantity = TextEditingController(text: quantity),
        cost = TextEditingController(text: cost);

  int productId;
  final TextEditingController quantity;
  final TextEditingController cost;

  void dispose() {
    quantity.dispose();
    cost.dispose();
  }
}
