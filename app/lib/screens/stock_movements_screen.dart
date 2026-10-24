// شاشة متابعة حركات المخزون وتسجيل الإضافات والتسويات والمرتجعات.
import 'package:flutter/material.dart';

import '../data/grocery_database.dart';
import '../data/product_repository.dart';
import '../data/stock_repository.dart';

class StockMovementsScreen extends StatefulWidget {
  const StockMovementsScreen({super.key});

  @override
  State<StockMovementsScreen> createState() => _StockMovementsScreenState();
}

class _StockMovementsScreenState extends State<StockMovementsScreen> {
  ProductRepository? _productsRepository;
  StockRepository? _stockRepository;
  List<GroceryProduct> _products = [];
  List<StockMovement> _movements = [];
  int? _selectedProductId;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final db = await GroceryDatabase.open();
      _productsRepository = ProductRepository(db);
      _stockRepository = StockRepository(db);
      _products = await _productsRepository!.search('');
      if (_products.isNotEmpty) {
        _selectedProductId = _products.first.id;
        await _loadHistory();
      }
      if (mounted) {
        setState(() => _loading = false);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'تعذر تحميل حركات المخزون: $error';
        });
      }
    }
  }

  Future<void> _loadHistory() async {
    final id = _selectedProductId;
    if (id == null || _stockRepository == null) {
      if (mounted) setState(() => _movements = []);
      return;
    }
    final rows = await _stockRepository!.history(id);
    if (mounted) setState(() => _movements = rows);
  }

  Future<void> _addMovement() async {
    if (_products.isEmpty || _stockRepository == null) return;
    final formKey = GlobalKey<FormState>();
    var productId = _selectedProductId ?? _products.first.id!;
    var type = 'إضافة';
    final quantity = TextEditingController();
    final note = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('تسجيل حركة مخزون'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  DropdownButtonFormField<int>(
                    initialValue: productId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'الصنف'),
                    items: _products.map((product) => DropdownMenuItem(
                      value: product.id,
                      child: Text(product.name, overflow: TextOverflow.ellipsis),
                    )).toList(),
                    onChanged: (value) {
                      if (value != null) setDialogState(() => productId = value);
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: type,
                    decoration: const InputDecoration(labelText: 'نوع الحركة'),
                    items: const [
                      DropdownMenuItem(value: 'إضافة', child: Text('إضافة مخزون')),
                      DropdownMenuItem(value: 'تسوية', child: Text('تسوية / تصحيح')),
                      DropdownMenuItem(value: 'مرتجع بيع', child: Text('مرتجع بيع')),
                      DropdownMenuItem(value: 'مرتجع شراء', child: Text('مرتجع شراء')),
                    ],
                    onChanged: (value) {
                      if (value != null) setDialogState(() => type = value);
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: quantity,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: const InputDecoration(
                      labelText: 'كمية الحركة',
                      helperText: 'استخدم موجبًا للإضافة وسالبًا للخصم أو التصحيح',
                    ),
                    validator: (value) {
                      final number = double.tryParse((value ?? '').trim());
                      if (number == null || !number.isFinite || number == 0) {
                        return 'أدخل كمية صالحة غير صفرية';
                      }
                      if (type != 'تسوية' && number < 0) {
                        return 'استخدم كمية موجبة لهذا النوع من الحركة';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: note,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: 'ملاحظة أو سبب الحركة (اختياري)'),
                  ),
                ]),
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

    if (result == true && mounted) {
      try {
        await _stockRepository!.recordMovement(
          productId: productId,
          movementType: type,
          quantityDelta: double.parse(quantity.text.trim()),
          note: note.text,
        );
        _selectedProductId = productId;
        _products = await _productsRepository!.search('');
        await _loadHistory();
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم تسجيل حركة المخزون وتحديث الرصيد.')));
        }
      } catch (error) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر حفظ الحركة: $error')));
      }
    }
    quantity.dispose();
    note.dispose();
  }

  String _number(double value) =>
      value == value.truncateToDouble() ? value.toInt().toString() : value.toString();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    GroceryProduct? selected;
    for (final product in _products) {
      if (product.id == _selectedProductId) {
        selected = product;
        break;
      }
    }
    return Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('حركات المخزون', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 5),
                Text('سجل موثق للإضافات والتسويات والمرتجعات والمبيعات', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ])),
              FilledButton.icon(
                onPressed: _loading || _products.isEmpty ? null : _addMovement,
                icon: const Icon(Icons.add_rounded),
                label: const Text('حركة جديدة'),
              ),
            ]),
            const SizedBox(height: 18),
            if (_products.isNotEmpty)
              DropdownButtonFormField<int>(
                initialValue: _selectedProductId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'اختر الصنف لعرض سجل حركاته',
                  prefixIcon: Icon(Icons.inventory_2_outlined),
                  border: OutlineInputBorder(),
                ),
                items: _products.map((product) => DropdownMenuItem(
                  value: product.id,
                  child: Text('${product.name} — الرصيد: ${_number(product.stockQuantity)} ${product.unit}', overflow: TextOverflow.ellipsis),
                )).toList(),
                onChanged: (value) async {
                  setState(() { _selectedProductId = value; _loading = true; });
                  try {
                    await _loadHistory();
                    if (mounted) setState(() => _loading = false);
                  } catch (error) {
                    if (mounted) setState(() { _loading = false; _error = error.toString(); });
                  }
                },
              ),
            if (selected != null) ...[
              const SizedBox(height: 12),
              Card(child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  const CircleAvatar(child: Icon(Icons.inventory_2_rounded)),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(selected.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                    Text('الرصيد الحالي: ${_number(selected.stockQuantity)} ${selected.unit}'),
                  ])),
                  if (selected.stockQuantity <= selected.minimumQuantity)
                    const Chip(avatar: Icon(Icons.warning_amber_rounded, size: 18), label: Text('مخزون منخفض')),
                ]),
              )),
            ],
            const SizedBox(height: 12),
            if (_error != null)
              Expanded(child: Center(child: Text(_error!, textAlign: TextAlign.center)))
            else if (_loading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (_products.isEmpty)
              const Expanded(child: Center(child: Text('أضف صنفًا أولًا حتى تتمكن من تسجيل حركات المخزون.', textAlign: TextAlign.center)))
            else if (_movements.isEmpty)
              const Expanded(child: Center(child: Text('لا توجد حركات مسجلة لهذا الصنف بعد.')))
            else
              Expanded(child: ListView.separated(
                itemCount: _movements.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final movement = _movements[index];
                  final positive = movement.quantityDelta > 0;
                  final date = DateTime.tryParse(movement.createdAt)?.toLocal();
                  final dateText = date == null ? movement.createdAt : '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}  ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
                  return Card(child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: positive ? const Color(0xFFDCE9DF) : const Color(0xFFF3DEDA),
                      child: Icon(positive ? Icons.south_west_rounded : Icons.north_east_rounded, color: positive ? const Color(0xFF173D32) : const Color(0xFF9B342C)),
                    ),
                    title: Text(movement.movementType, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('$dateText${movement.note == null ? '' : '\n${movement.note}'}\nقبل: ${_number(movement.stockBefore)}  •  بعد: ${_number(movement.stockAfter)}'),
                    isThreeLine: true,
                    trailing: Text('${positive ? '+' : ''}${_number(movement.quantityDelta)}', style: TextStyle(fontWeight: FontWeight.w800, color: positive ? const Color(0xFF24734A) : const Color(0xFFB43B32))),
                  ));
                },
              )),
          ]),
        ),
      ),
    );
  }
}
