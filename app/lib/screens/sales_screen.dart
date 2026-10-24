// شاشة البيع السريع: اختيار الأصناف، حساب الفاتورة وحفظها مع تحديث المخزون.
import 'package:flutter/material.dart';
import '../data/grocery_database.dart';
import '../data/product_repository.dart';
import '../data/sale_repository.dart';

class SalesScreen extends StatefulWidget {
  const SalesScreen({super.key});
  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  final _search = TextEditingController();
  final _customer = TextEditingController();
  final _discountController = TextEditingController(text: '0');
  ProductRepository? _productsRepository;
  SaleRepository? _salesRepository;
  List<GroceryProduct> _matches = [];
  List<SaleLine> _cart = [];
  List<SaleRecord> _recent = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() { super.initState(); _initialize(); }

  // فتح التخزين المحلي وتحميل أحدث الفواتير والأصناف.
  Future<void> _initialize() async {
    try {
      final database = await GroceryDatabase.open();
      _productsRepository = ProductRepository(database);
      _salesRepository = SaleRepository(database);
      _recent = await _salesRepository!.recentSales(limit: 8);
      _matches = await _productsRepository!.search('');
      if (!mounted) return;
      setState(() { _loading = false; _error = null; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'تعذر فتح بيانات البيع: $error'; });
    }
  }

  Future<void> _searchProducts(String query) async {
    if (_productsRepository == null) return;
    try {
      final rows = await _productsRepository!.search(query);
      if (!mounted) return;
      setState(() => _matches = rows);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'تعذر البحث عن الأصناف: $error');
    }
  }

  int get _subtotal => _cart.fold<int>(0, (sum, line) => sum + line.lineTotal);
  int get _discount => int.tryParse(_discountController.text.trim()) ?? 0;
  int get _total => (_subtotal - _discount).clamp(0, 1 << 62);

  // إضافة الصنف إلى السلة أو زيادة كميته إذا كان موجودًا.
  void _addProduct(GroceryProduct product) {
    setState(() {
      final index = _cart.indexWhere((line) => line.product.id == product.id);
      if (index >= 0) {
        final old = _cart[index];
        _cart[index] = SaleLine(product: old.product, quantity: old.quantity + 1);
      } else {
        _cart = [..._cart, SaleLine(product: product, quantity: 1)];
      }
    });
  }

  void _changeQuantity(int index, double quantity) {
    if (!quantity.isFinite || quantity <= 0) return;
    setState(() { _cart[index] = SaleLine(product: _cart[index].product, quantity: quantity); });
  }

  @override
  void dispose() {
    _search.dispose(); _customer.dispose(); _discountController.dispose(); super.dispose();
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
                : LayoutBuilder(builder: (context, constraints) {
                    final narrow = constraints.maxWidth < 850;
                    final catalog = _buildCatalog(theme);
                    final cart = _buildCart(theme);
                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(18),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Text('المبيعات', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 5),
                        Text('أنشئ فاتورة جديدة وسيُحدّث المخزون تلقائيًا بعد الحفظ.', style: theme.textTheme.bodyMedium),
                        const SizedBox(height: 18),
                        if (narrow) ...[catalog, const SizedBox(height: 16), cart]
                        else Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Expanded(flex: 6, child: catalog),
                          const SizedBox(width: 16),
                          Expanded(flex: 5, child: cart),
                        ]),
                        const SizedBox(height: 24),
                        _buildRecent(theme),
                      ]),
                    );
                  }),
      ),
    );
  }

  // قائمة البحث واختيار الأصناف المتاحة.
  Widget _buildCatalog(ThemeData theme) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('اختيار الأصناف', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        TextField(
          controller: _search,
          onChanged: _searchProducts,
          decoration: InputDecoration(
            hintText: 'اسم الصنف أو الباركود',
            prefixIcon: const Icon(Icons.search_rounded),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        const SizedBox(height: 8),
        if (_matches.isEmpty)
          const Padding(padding: EdgeInsets.all(18), child: Text('لا توجد أصناف. أضف الأصناف من قسم المخزون أولًا.', textAlign: TextAlign.center))
        else
          ..._matches.take(30).map((product) => ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(product.name, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('السعر: ${product.sellingPrice} ج.س • المتاح: ${_quantity(product.stockQuantity)} ${product.unit}'),
            trailing: IconButton.filledTonal(
              tooltip: 'إضافة إلى الفاتورة',
              onPressed: () => _addProduct(product),
              icon: const Icon(Icons.add_rounded),
            ),
          )),
      ]),
    ),
  );

  // السلة والخصم والإجمالي وبدء الدفع.
  Widget _buildCart(ThemeData theme) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('الفاتورة الحالية', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
          Text('${_cart.length} صنف'),
        ]),
        const SizedBox(height: 8),
        if (_cart.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 28), child: Text('اختر الأصناف من القائمة لإضافتها إلى الفاتورة.', textAlign: TextAlign.center))
        else
          ..._cart.asMap().entries.map((entry) {
            final index = entry.key;
            final line = entry.value;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(line.product.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text('${line.lineTotal} ج.س', style: theme.textTheme.bodySmall),
                ])),
                IconButton(onPressed: () => _changeQuantity(index, line.quantity - 1), icon: const Icon(Icons.remove_circle_outline)),
                SizedBox(width: 34, child: Text(_quantity(line.quantity), textAlign: TextAlign.center)),
                IconButton(onPressed: () => _changeQuantity(index, line.quantity + 1), icon: const Icon(Icons.add_circle_outline)),
                IconButton(onPressed: () => setState(() => _cart.removeAt(index)), icon: const Icon(Icons.delete_outline_rounded)),
              ]),
            );
          }),
        const Divider(height: 24),
        TextField(controller: _customer, decoration: const InputDecoration(labelText: 'اسم الزبون (اختياري)', border: OutlineInputBorder())),
        const SizedBox(height: 10),
        TextField(
          controller: _discountController,
          keyboardType: const TextInputType.numberWithOptions(decimal: false),
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'الخصم بالجنيه', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 14),
        _totalRow('الإجمالي قبل الخصم', _subtotal),
        _totalRow('الخصم', _discount.clamp(0, _subtotal)),
        const Divider(),
        _totalRow('المطلوب دفعه', _total, strong: true),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: _cart.isEmpty || _saving || _discount < 0 || _discount > _subtotal ? null : _checkout,
          icon: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.receipt_long_rounded),
          label: Text(_saving ? 'جارٍ حفظ الفاتورة...' : 'إتمام البيع'),
        ),
        if (_discount > _subtotal || _discount < 0)
          const Padding(padding: EdgeInsets.only(top: 8), child: Text('تحقق من قيمة الخصم.', style: TextStyle(color: Colors.red))),
      ]),
    ),
  );

  Widget _totalRow(String label, int value, {bool strong = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(children: [
      Expanded(child: Text(label, style: TextStyle(fontWeight: strong ? FontWeight.w800 : FontWeight.normal))),
      Text('$1 ج.س', style: TextStyle(fontWeight: strong ? FontWeight.w900 : FontWeight.w600, fontSize: strong ? 18 : 14)),
    ]),
  );

  // اختيار طريقة الدفع والمبلغ المستلم، مع السماح بالبيع الآجل والجزئي.
  Future<void> _checkout() async {
    final paidController = TextEditingController(text: '$1');
    String method = 'نقدي';
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (context, refreshDialog) => AlertDialog(
        title: const Text('تأكيد الدفع'),
        content: SizedBox(width: 380, child: Column(mainAxisSize: MainAxisSize.min, children: [
          _totalRow('إجمالي الفاتورة', _total),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: method,
            decoration: const InputDecoration(labelText: 'طريقة السداد', border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'نقدي', child: Text('نقدي')),
              DropdownMenuItem(value: 'جزئي', child: Text('دفع جزئي')),
              DropdownMenuItem(value: 'آجل', child: Text('آجل / دون دفع')),
            ],
            onChanged: (value) {
              if (value == null) return;
              refreshDialog(() {
                method = value;
                if (method == 'نقدي') paidController.text = '$1';
                if (method == 'آجل') paidController.text = '0';
              });
            },
          ),
          const SizedBox(height: 12),
          TextField(controller: paidController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ المستلم', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          const Text('المتبقي سيظهر في الفاتورة. متابعة ديون الزبائن ستضاف ضمن وحدة الحسابات.', style: TextStyle(fontSize: 12)),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('رجوع')),
          FilledButton(onPressed: () {
            final paid = int.tryParse(paidController.text.trim());
            if (paid == null || paid < 0 || paid > _total ||
                (method == 'نقدي' && paid != _total) ||
                (method == 'آجل' && paid != 0) ||
                (method == 'جزئي' && (paid == 0 || paid == _total))) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('المبلغ لا يتوافق مع طريقة السداد المختارة.')));
              return;
            }
            Navigator.pop(dialogContext, {'paid': paid, 'method': method});
          }, child: const Text('حفظ الفاتورة')),
        ],
      )),
    );
    paidController.dispose();
    if (result == null || !mounted) return;

    setState(() => _saving = true);
    try {
      final sale = await _salesRepository!.createSale(
        lines: List<SaleLine>.from(_cart),
        discount: _discount,
        paidAmount: result['paid']! as int,
        paymentMethod: result['method']! as String,
        customerName: _customer.text,
      );
      _cart = [];
      _customer.clear();
      _discountController.text = '0';
      _recent = await _salesRepository!.recentSales(limit: 8);
      await _searchProducts(_search.text);
      if (!mounted) return;
      setState(() => _saving = false);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('تم حفظ الفاتورة'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('رقم الفاتورة: ${sale.invoiceNumber}'),
            const SizedBox(height: 8),
            _totalRow('الإجمالي', sale.total),
            _totalRow('المستلم', sale.paidAmount),
            _totalRow('المتبقي', sale.remainingAmount),
          ]),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('حسنًا'))],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('لم تُحفظ الفاتورة، ولم تُعتمد حركة البيع: $error')));
    }
  }

  // عرض أحدث الفواتير المحفوظة محليًا.
  Widget _buildRecent(ThemeData theme) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('أحدث الفواتير', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        if (_recent.isEmpty)
          const Text('لا توجد فواتير محفوظة حتى الآن.')
        else
          ..._recent.map((sale) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const CircleAvatar(child: Icon(Icons.receipt_long_rounded)),
            title: Text(sale.invoiceNumber),
            subtitle: Text('${sale.customerName?.isNotEmpty == true ? sale.customerName : 'زبون نقدي'} • ${sale.paymentMethod} • متبقي ${sale.remainingAmount} ج.س'),
            trailing: Text('${sale.total} ج.س', style: const TextStyle(fontWeight: FontWeight.w800)),
          )),
      ]),
    ),
  );

  String _quantity(double value) => value == value.truncateToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(2);
}
