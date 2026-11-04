// شاشة البيع السريع: اختيار الأصناف، حساب الفاتورة وحفظها مع تحديث المخزون.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../data/grocery_database.dart';
import '../data/customer_repository.dart';
import '../data/product_repository.dart';
import '../data/sale_repository.dart';
import '../widgets/manager_approval_dialog.dart';
import 'barcode_scanner_screen.dart';

class SalesScreen extends StatefulWidget {
  const SalesScreen({this.onDataChanged, required this.userId, this.shiftId, this.cashierMode = false, this.cashierPermissions = const {}, super.key});

  final VoidCallback? onDataChanged;
  final int userId;
  final int? shiftId;
  final bool cashierMode;
  final Set<String> cashierPermissions;

  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  bool get _canCreditSales => !widget.cashierMode || widget.cashierPermissions.contains('credit_sales');
  bool get _canDiscount => !widget.cashierMode || widget.cashierPermissions.contains('discounts');
  bool get _canViewInvoices => !widget.cashierMode || widget.cashierPermissions.contains('view_invoice_history') || widget.cashierPermissions.contains('returns') || widget.cashierPermissions.contains('return_refunds');
  bool get _canReturn => !widget.cashierMode || widget.cashierPermissions.contains('returns');
  bool get _canRefund => !widget.cashierMode || widget.cashierPermissions.contains('return_refunds');
  bool get _canRefundOverpayment => !widget.cashierMode || widget.cashierPermissions.contains('customer_overpayments');
  final _search = TextEditingController();
  final _customer = TextEditingController();
  final _customerNickname = TextEditingController();
  int? _selectedCustomerId;
  final _discountController = TextEditingController(text: '0');
  ProductRepository? _productsRepository;
  CustomerRepository? _customersRepository;
  SaleRepository? _salesRepository;
  List<CustomerBalance> _customerMatches = [];
  bool _showCustomerSuggestions = false;
  Timer? _customerSearchTimer;
  int _customerSearchRequest = 0;
  List<GroceryProduct> _matches = [];
  List<SaleLine> _cart = [];
  List<SaleRecord> _recent = [];
  bool _loading = true;
  bool _saving = false;
  String _salesViewMode = 'grid';
  String? _error;
  final ScrollController _androidSalesScrollController = ScrollController();
  final GlobalKey _androidCartSectionKey = GlobalKey();

  @override
  void initState() { super.initState(); _initialize(); }

  // يؤخر البحث قليلًا حتى لا يُنفّذ استعلامًا مع كل ضغطة مفتاح.
  void _searchCustomers(String value) {
    _selectedCustomerId = null;
    _customerSearchTimer?.cancel();
    final query = value.trim();
    if (query.isNotEmpty) {
      setState(() {
        _customerMatches = [];
        _showCustomerSuggestions = false;
      });
    }
    final request = ++_customerSearchRequest;
    if (query.isEmpty || _customersRepository == null) {
      setState(() {
        _customerMatches = [];
        _showCustomerSuggestions = false;
      });
      return;
    }
    _customerSearchTimer = Timer(const Duration(milliseconds: 280), () async {
      try {
        final matches = await _customersRepository!.balances(userId: widget.userId, query: query);
        if (!mounted ||
            request != _customerSearchRequest ||
            _customer.text.trim() != query) {
          return;
        }
        setState(() {
          _customerMatches = matches.take(8).toList(growable: false);
          _showCustomerSuggestions = _customerMatches.isNotEmpty;
        });
      } catch (_) {
        if (!mounted || request != _customerSearchRequest) return;
        setState(() {
          _customerMatches = [];
          _showCustomerSuggestions = false;
        });
      }
    });
  }

  // عند حفظ الدين فقط نتحقق من الأسماء المشابهة، ولا نقاطع الكتابة بالتنبيهات.
  Future<String?> _resolveNewDebtCustomerName(String name) async {
    final matches = await _customersRepository!.balances(userId: widget.userId, query: name);
    if (!mounted) return null;
    if (matches.isEmpty) return name;

    _customerNickname.clear();
    final resolved = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('اسم مشابه في دفتر الحسابات'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('وجدنا أسماء مشابهة: ${matches.take(4).map((item) => item.name).join('، ')}.'),
              const SizedBox(height: 10),
              const Text('إذا كان هذا زبونًا جديدًا، أضف لقبًا لتمييز حسابه. أو ألغِ للعودة واختيار الحساب الصحيح من الاقتراحات.'),
              const SizedBox(height: 12),
              TextField(
                controller: _customerNickname,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'لقب للزبون الجديد',
                  hintText: 'مثال: السوق أو الحي',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('العودة للاختيار'),
          ),
          FilledButton(
            onPressed: () {
              final nickname = _customerNickname.text.trim();
              if (nickname.isEmpty) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text('أدخل لقبًا لتمييز الزبون الجديد.')),
                );
                return;
              }
              Navigator.pop(dialogContext, '$name - $nickname');
            },
            child: const Text('تأكيد الاسم الجديد'),
          ),
        ],
      ),
    );
    return resolved;
  }

  void _selectCustomer(CustomerBalance customer) {
    _customerSearchTimer?.cancel();
    _customerSearchRequest++;
    _selectedCustomerId = customer.id;
    _customerNickname.clear();
    _customer.value = TextEditingValue(
      text: customer.name,
      selection: TextSelection.collapsed(offset: customer.name.length),
    );
    setState(() {
      _customerMatches = [];
      _showCustomerSuggestions = false;
    });
    FocusScope.of(context).unfocus();
  }

  // فتح التخزين المحلي وتحميل أحدث الفواتير والأصناف.
  Future<void> _initialize() async {
    try {
      final database = await GroceryDatabase.open();
      final viewRows = await database.query('app_metadata', columns: ['value'], where: 'key = ?', whereArgs: ['sales_view_mode'], limit: 1);
      final viewMode = viewRows.isEmpty ? 'grid' : viewRows.single['value'] as String;
      _productsRepository = ProductRepository(database);
      _salesRepository = SaleRepository(database);
      if (!widget.cashierMode || widget.cashierPermissions.contains('view_customer_data')) {
        _customersRepository = CustomerRepository(database);
      }
      if (_canViewInvoices) {
        _recent = await _salesRepository!.recentSales(userId: widget.userId, limit: 50);
      }
      _matches = await _productsRepository!.search('');
      if (!mounted) return;
      setState(() { _salesViewMode = const {'grid', 'rows', 'rowsWithIcons'}.contains(viewMode) ? viewMode : 'grid'; _loading = false; _error = null; });
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

  // مسح الباركود بالكاميرا متاح في واجهة Android فقط.
  Future<void> _scanBarcode() async {
    final barcode = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const BarcodeScannerScreen()),
    );
    if (!mounted || barcode == null || barcode.trim().isEmpty) return;

    final value = barcode.trim();
    _search.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    await _searchProducts(value);
    if (!mounted) return;

    final exactIndex = _matches.indexWhere(
      (product) => product.barcode?.trim() == value,
    );
    if (exactIndex < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا يوجد صنف مرتبط بهذا الباركود.')),
      );
      return;
    }

    _addProduct(_matches[exactIndex]);
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('أُضيف الصنف إلى الفاتورة.')),
    );
  }

  int get _subtotal => _cart.fold<int>(0, (sum, line) => sum + line.lineTotal);
  int get _discount => int.tryParse(_discountController.text.trim()) ?? 0;
  int get _total => (_subtotal - _discount).clamp(0, 1 << 62).toInt();

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

  // يتيح إدخال وزن دقيق بدل الاقتصار على أزرار الزيادة والنقصان.
  Future<void> _editQuantity(int index) async {
    final controller = TextEditingController(
      text: _quantity(_cart[index].quantity),
    );
    final value = await showDialog<double>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('كمية ${_cart[index].product.name}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'الكمية بـ ${_cart[index].product.unit}',
            hintText: 'مثال: 1 أو 0.5 أو 0.25',
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () {
              final parsed = double.tryParse(controller.text.trim());
              if (parsed == null || !parsed.isFinite || parsed <= 0) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text('أدخل كمية أكبر من صفر.')),
                );
                return;
              }
              Navigator.pop(dialogContext, parsed);
            },
            child: const Text('تأكيد الكمية'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null && mounted) _changeQuantity(index, value);
  }

  // وحدات الوزن والحجم تسمح بالزيادة بربع وحدة؛ القطع تبقى بوحدة كاملة.
  double _quantityStep(GroceryProduct product) {
    final unit = product.unit.toLowerCase().replaceAll(' ', '');
    const fractionalUnits = [
      'كجم', 'كيلوجرام', 'كيلوغرام', 'كيلو', 'كغ',
      'جم', 'جرام', 'غرام', 'لتر', 'مل',
    ];
    return fractionalUnits.any(unit.contains) ? 0.25 : 1;
  }

  @override
  void dispose() {
    _customerSearchTimer?.cancel();
    _androidSalesScrollController.dispose();
    _search.dispose(); _customer.dispose(); _customerNickname.dispose(); _discountController.dispose(); super.dispose();
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
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _initialize,
                            child: const Text('إعادة المحاولة'),
                          ),
                        ],
                      ),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final androidPhone =
                          defaultTargetPlatform == TargetPlatform.android &&
                              constraints.maxWidth < 600;
                      if (androidPhone) {
                        return _buildAndroidPhoneLayout(theme);
                      }

                      final narrow = constraints.maxWidth < 850;
                      if (narrow) {
                        return SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildSalesHeading(theme),
                              const SizedBox(height: 14),
                              _buildCatalog(theme, compact: true),
                              const SizedBox(height: 12),
                              _buildCart(theme, compact: true),
                              const SizedBox(height: 12),
                              if (_canViewInvoices) _buildRecent(theme, compact: true),
                            ],
                          ),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildSalesHeading(theme),
                            const SizedBox(height: 16),
                            Expanded(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    flex: 6,
                                    child: _buildCatalog(theme, compact: false),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    flex: 5,
                                    child: Column(
                                      children: [
                                        Expanded(
                                          flex: widget.cashierMode ? 5 : 3,
                                          child: _buildCart(theme, compact: false),
                                        ),
                                        if (_canViewInvoices) ...[
                                          const SizedBox(height: 12),
                                          Expanded(
                                            flex: 2,
                                            child: _buildRecent(theme, compact: false),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
    );
  }

  // تخطيط هاتف Android: قائمة الأصناف قابلة للتمرير، وملخص الفاتورة ثابت أسفل الشاشة.
  Widget _buildAndroidPhoneLayout(ThemeData theme) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: _buildSalesHeading(theme),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: _androidSalesScrollController,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildCatalog(theme, compact: true),
                  const SizedBox(height: 12),
                  KeyedSubtree(
                    key: _androidCartSectionKey,
                    child: _buildCart(theme, compact: true),
                  ),
                  const SizedBox(height: 12),
                  if (_canViewInvoices) _buildRecent(theme, compact: true),
                ],
              ),
            ),
          ),
          _buildAndroidCartBar(theme),
        ],
      );

  // يظل الإجمالي وعدد الأصناف ظاهرين أثناء تصفح قائمة المنتجات.
  Widget _buildAndroidCartBar(ThemeData theme) => Material(
        color: theme.colorScheme.surface,
        elevation: 8,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_cart.length} صنف في الفاتورة',
                        style: theme.textTheme.bodySmall,
                      ),
                      Text(
                        '$_total ج.س',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: () {
                    final target = _androidCartSectionKey.currentContext;
                    if (target != null) {
                      Scrollable.ensureVisible(
                        target,
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOutCubic,
                        alignment: 0.04,
                      );
                    }
                  },
                  icon: const Icon(Icons.receipt_long_rounded),
                  label: const Text('عرض الفاتورة'),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _buildSalesHeading(ThemeData theme) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.cashierMode ? 'نقطة البيع' : 'المبيعات',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            widget.cashierMode && !_canCreditSales
                ? 'أضف الأصناف إلى الفاتورة واستلم المبلغ نقدًا أو بتحويل بنكي أو بالطريقتين.'
                : 'أنشئ فاتورة جديدة وسيُحدّث المخزون تلقائيًا بعد الحفظ.',
            style: theme.textTheme.bodyMedium,
          ),
        ],
      );

  // قائمة الأصناف داخل مساحة مستقلة قابلة للتمرير.
  Widget _buildCatalog(ThemeData theme, {required bool compact}) => Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'اختيار الأصناف',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _search,
                      onChanged: _searchProducts,
                      decoration: InputDecoration(
                        hintText: 'اسم الصنف أو الباركود',
                        prefixIcon: const Icon(Icons.search_rounded),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  if (defaultTargetPlatform == TargetPlatform.android) ...[
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'مسح الباركود بالكاميرا',
                      onPressed: _scanBarcode,
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                      style: IconButton.styleFrom(
                        minimumSize: const Size(50, 50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              if (compact)
                SizedBox(
                  height: 380,
                  child: _matches.isEmpty
                      ? const Center(
                          child: Text(
                            'لا توجد أصناف. أضف الأصناف من قسم المخزون أولًا.',
                            textAlign: TextAlign.center,
                          ),
                        )
                      : _buildProductList(theme),
                )
              else
                Expanded(
                  child: _matches.isEmpty
                      ? const Center(
                          child: Text(
                            'لا توجد أصناف. أضف الأصناف من قسم المخزون أولًا.',
                            textAlign: TextAlign.center,
                          ),
                        )
                      : _buildProductList(theme),
                ),
            ],
          ),
        ),
      );

  Widget _buildProductList(ThemeData theme) {
    if (_salesViewMode == 'grid') {
      return GridView.builder(
        padding: const EdgeInsets.only(bottom: 4),
        itemCount: _matches.length,
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 190,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 0.92,
        ),
        itemBuilder: (context, index) {
          final product = _matches[index];
          final hasImage = product.imagePath != null &&
              File(product.imagePath!).existsSync();
          return Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _addProduct(product),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: hasImage
                            ? Image.file(
                                File(product.imagePath!),
                                fit: BoxFit.contain,
                              )
                            : Icon(
                                Icons.inventory_2_rounded,
                                size: 36,
                                color: theme.colorScheme.primary,
                              ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      product.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${product.sellingPrice} ج.س',
                      style: theme.textTheme.bodySmall,
                    ),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: IconButton.filledTonal(
                        tooltip: 'إضافة إلى الفاتورة',
                        onPressed: () => _addProduct(product),
                        icon: const Icon(Icons.add_rounded),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 4),
      itemCount: _matches.length,
      itemBuilder: (context, index) {
        final product = _matches[index];
        final hasImage = product.imagePath != null &&
            File(product.imagePath!).existsSync();
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: _salesViewMode == 'rowsWithIcons'
              ? CircleAvatar(
                  backgroundImage:
                      hasImage ? FileImage(File(product.imagePath!)) : null,
                  child: hasImage
                      ? null
                      : Icon(
                          Icons.inventory_2_rounded,
                          color: theme.colorScheme.primary,
                        ),
                )
              : null,
          title: Text(
            product.name,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            'السعر: ${product.sellingPrice} ج.س • المتاح: ${_quantity(product.stockQuantity)} ${product.unit}',
          ),
          trailing: IconButton.filledTonal(
            tooltip: 'إضافة إلى الفاتورة',
            onPressed: () => _addProduct(product),
            icon: const Icon(Icons.add_rounded),
          ),
        );
      },
    );
  }

  // بطاقة الفاتورة ثابتة؛ التمرير محصور في بنود السلة فقط.
  Widget _buildCart(ThemeData theme, {required bool compact}) => Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'الفاتورة الحالية',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text('${_cart.length} صنف'),
                ],
              ),
              const SizedBox(height: 8),
              if (compact)
                SizedBox(
                  height: (_cart.length * 76).clamp(90, 260).toDouble(),
                  child: _buildCartLines(theme),
                )
              else
                Expanded(child: _buildCartLines(theme)),
              const Divider(height: 20),
              if (_canCreditSales) ...[
                TextField(
                  controller: _customer,
                  onChanged: _customersRepository == null ? null : _searchCustomers,
                  decoration: const InputDecoration(
                    labelText: 'اسم الزبون (مطلوب عند البيع بالدين)', 
                    hintText: 'اختر حسابًا من الاقتراحات أو أدخل اسم زبون جديد',
                    prefixIcon: Icon(Icons.person_search_rounded),
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_showCustomerSuggestions && _customerMatches.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    constraints: const BoxConstraints(maxHeight: 150),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      border: Border.all(color: theme.colorScheme.outlineVariant),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: _customerMatches.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final customer = _customerMatches[index];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.person_outline_rounded),
                          title: Text(customer.name),
                          subtitle: Text('الرصيد الحالي: ${customer.balance} ج.س'),
                          onTap: () => _selectCustomer(customer),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 10),
              ],
              if (_canDiscount) ...[
                TextField(
                  controller: _discountController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: false),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'الخصم بالجنيه',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              _totalRow('الإجمالي قبل الخصم', _subtotal),
              if (_canDiscount)
                _totalRow('الخصم', _discount.clamp(0, _subtotal).toInt()),
              const Divider(),
              _totalRow('المطلوب دفعه', _total, strong: true),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _cart.isEmpty ||
                        _saving ||
                        _discount < 0 ||
                        _discount > _subtotal
                    ? null
                    : _checkout,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.receipt_long_rounded),
                label: Text(
                  _saving ? 'جارٍ حفظ الفاتورة...' : 'إتمام البيع',
                ),
              ),
              if (_discount > _subtotal || _discount < 0)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'تحقق من قيمة الخصم.',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
            ],
          ),
        ),
      );

  Widget _buildCartLines(ThemeData theme) {
    if (_cart.isEmpty) {
      return const Center(
        child: Text(
          'اختر الأصناف من القائمة لإضافتها إلى الفاتورة.',
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: _cart.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final line = _cart[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      line.product.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${line.lineTotal} ج.س',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'تقليل الكمية',
                onPressed: () => _changeQuantity(
                  index,
                  line.quantity - _quantityStep(line.product),
                ),
                icon: const Icon(Icons.remove_circle_outline),
              ),
              SizedBox(
                width: 48,
                child: TextButton(
                  onPressed: () => _editQuantity(index),
                  child: Text(_quantity(line.quantity), textAlign: TextAlign.center),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'زيادة الكمية',
                onPressed: () => _changeQuantity(
                  index,
                  line.quantity + _quantityStep(line.product),
                ),
                icon: const Icon(Icons.add_circle_outline),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _cart.removeAt(index)),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _totalRow(String label, int value, {bool strong = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(children: [
      Expanded(child: Text(label, style: TextStyle(fontWeight: strong ? FontWeight.w800 : FontWeight.normal))),
      Text('$value ج.س', style: TextStyle(fontWeight: strong ? FontWeight.w900 : FontWeight.w600, fontSize: strong ? 18 : 14)),
    ]),
  );

  // اختيار طريقة السداد وتوزيع المقبوض بين النقد والتحويل لكلا الدورين.
  // صلاحية البيع الآجل والجزئي تبقى مستقلة عن وسيلة استلام المبلغ.
  Future<void> _checkout() async {
    Map<String, Object?>? result;
    {
      final cashController = TextEditingController(text: '$_total');
      final bankController = TextEditingController(text: '0');
      String method = 'نقدي';
      String paymentChannel = 'نقدي';

      // يضبط قيمة واحدة أو يوزعها على الحقلين حسب وسيلة الاستلام.
      void setReceivedAmount(int amount) {
        final safeAmount = amount.clamp(0, 1 << 62).toInt();
        if (paymentChannel == 'نقدي') {
          cashController.text = '$safeAmount';
          bankController.text = '0';
        } else if (paymentChannel == 'تحويل بنكي') {
          cashController.text = '0';
          bankController.text = '$safeAmount';
        } else {
          final cash = safeAmount ~/ 2;
          cashController.text = '$cash';
          bankController.text = '${safeAmount - cash}';
        }
      }

      result = await showDialog<Map<String, Object?>>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, refreshDialog) {
            final cash = int.tryParse(cashController.text.trim()) ?? 0;
            final bank = int.tryParse(bankController.text.trim()) ?? 0;
            final received = cash + bank;
            return AlertDialog(
              title: const Text('تأكيد الدفع'),
              content: SizedBox(
                width: 380,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _totalRow('إجمالي الفاتورة', _total),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: method,
                        decoration: const InputDecoration(
                          labelText: 'طريقة السداد',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem(value: 'نقدي', child: Text('كامل')),
                          if (_canCreditSales) ...[
                            const DropdownMenuItem(value: 'جزئي', child: Text('دفع جزئي')),
                            const DropdownMenuItem(value: 'آجل', child: Text('آجل / دون دفع')),
                          ],
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          refreshDialog(() {
                            method = value;
                            if (method == 'آجل') paymentChannel = 'نقدي';
                            final amount = method == 'آجل'
                                ? 0
                                : method == 'جزئي'
                                    ? (_total > 1 ? _total ~/ 2 : 0)
                                    : _total;
                            setReceivedAmount(amount);
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: paymentChannel,
                        decoration: const InputDecoration(
                          labelText: 'طريقة استلام المبلغ',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'نقدي', child: Text('نقدي')),
                          DropdownMenuItem(value: 'تحويل بنكي', child: Text('تحويل بنكي')),
                          DropdownMenuItem(value: 'مختلط', child: Text('مختلط (نقدي + تحويل بنكي)')),
                        ],
                        onChanged: method == 'آجل' ? null : (value) {
                          if (value == null) return;
                          refreshDialog(() {
                            paymentChannel = value;
                            final amount = method == 'آجل'
                                ? 0
                                : method == 'جزئي'
                                    ? (_total > 1 ? _total ~/ 2 : 0)
                                    : _total;
                            setReceivedAmount(amount);
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      if (paymentChannel == 'نقدي')
                        TextField(
                          controller: cashController,
                          autofocus: true,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'المبلغ النقدي المستلم',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (_) => refreshDialog(() {}),
                        )
                      else if (paymentChannel == 'تحويل بنكي')
                        TextField(
                          controller: bankController,
                          autofocus: true,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'المبلغ المحول بنكيًا',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (_) => refreshDialog(() {}),
                        )
                      else ...[
                        TextField(
                          controller: cashController,
                          autofocus: true,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'المبلغ النقدي المستلم',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (_) => refreshDialog(() {}),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: bankController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'المبلغ المحول بنكيًا',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (_) => refreshDialog(() {}),
                        ),
                      ],
                      const SizedBox(height: 10),
                      _totalRow('إجمالي المبلغ المستلم', received, strong: true),
                      const SizedBox(height: 8),
                      const Text(
                        'إذا زاد المبلغ المستلم عن الإجمالي، تُسجل الزيادة كمبلغ مستحق للزبون ولا تُضاف إلى إيراد البيع.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('رجوع'),
                ),
                FilledButton(
                  onPressed: () {
                    final enteredCash = int.tryParse(cashController.text.trim());
                    final enteredBank = int.tryParse(bankController.text.trim());
                    if (enteredCash == null || enteredBank == null ||
                        enteredCash < 0 || enteredBank < 0) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        const SnackBar(content: Text('أدخل مبالغ صحيحة غير سالبة.')),
                      );
                      return;
                    }
                    final totalReceived = enteredCash + enteredBank;
                    final channelMatches = method == 'آجل'
                        ? enteredCash == 0 && enteredBank == 0
                        : paymentChannel == 'نقدي'
                            ? enteredCash > 0 && enteredBank == 0
                            : paymentChannel == 'تحويل بنكي'
                                ? enteredBank > 0 && enteredCash == 0
                                : enteredCash > 0 && enteredBank > 0;
                    if (!channelMatches ||
                        (method == 'نقدي' && totalReceived < _total) ||
                        (method == 'آجل' && totalReceived != 0) ||
                        (method == 'جزئي' &&
                            (totalReceived == 0 || totalReceived >= _total))) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        const SnackBar(
                          content: Text('تحقق من المبالغ وطريقة السداد المختارة.'),
                        ),
                      );
                      return;
                    }
                    Navigator.pop(dialogContext, {
                      'paid': totalReceived,
                      'method': method,
                      'channel': paymentChannel,
                      'cash': enteredCash,
                      'bank': enteredBank,
                    });
                  },
                  child: const Text('حفظ الفاتورة'),
                ),
              ],
            );
          },
        ),
      );
      cashController.dispose();
      bankController.dispose();
    }
    if (result == null || !mounted) return;

    setState(() => _saving = true);
    try {
      final hasDebt = (result['paid']! as int) < _total;
      final typedName = _customer.text.trim();
      String? customerNameForDebt;
      if (hasDebt && typedName.isNotEmpty) {
        if (_customersRepository == null) {
          customerNameForDebt = typedName;
        } else if (_selectedCustomerId != null) {
          customerNameForDebt = typedName;
        } else {
          customerNameForDebt = await _resolveNewDebtCustomerName(typedName);
          if (customerNameForDebt == null) {
            if (mounted) setState(() => _saving = false);
            return;
          }
        }
      }
      String? managerApprovalToken;
      final needsManagerApproval = widget.cashierMode &&
          _discount > 0 &&
          await _salesRepository!.requiresCashierApproval(
            userId: widget.userId,
            amount: _discount,
          );
      if (!mounted) return;
      if (needsManagerApproval) {
        final activeShiftId = widget.shiftId;
        if (activeShiftId == null) {
          throw StateError('لا توجد وردية نشطة لهذا الكاشير.');
        }
        if (!context.mounted) return;
        final credentials = await showDialog<ManagerApprovalCredentials>(
          context: context,
          barrierDismissible: false,
          builder: (_) => ManagerApprovalDialog(discountAmount: _discount),
        );
        if (!mounted) return;
        if (credentials == null) {
          setState(() => _saving = false);
          return;
        }
        managerApprovalToken =
            await _salesRepository!.requestCashierDiscountApproval(
          managerUsername: credentials.username,
          managerPassword: credentials.password,
          cashierUserId: widget.userId,
          shiftId: activeShiftId,
          discountAmount: _discount,
        );
      }
      final sale = await _salesRepository!.createSale(
        lines: List<SaleLine>.from(_cart),
        discount: _discount,
        paidAmount: result['paid']! as int,
        paymentMethod: result['method']! as String,
        paymentChannel: result['channel']! as String,
        cashPaidAmount: result['cash'] as int?,
        bankPaidAmount: result['bank'] as int?,
        customerName: customerNameForDebt,
        customerId: hasDebt ? _selectedCustomerId : null,
        userId: widget.userId,
        shiftId: widget.shiftId,
        managerApprovalToken: managerApprovalToken,
      );
      _cart = [];
      _customer.clear();
      _customerNickname.clear();
      _selectedCustomerId = null;
      _customerMatches = [];
      _showCustomerSuggestions = false;
      _customerSearchTimer?.cancel();
      _customerSearchRequest++;
      _discountController.text = '0';
      if (_canViewInvoices) {
        _recent = await _salesRepository!.recentSales(userId: widget.userId, limit: 50);
      }
      widget.onDataChanged?.call();
      await _searchProducts(_search.text);
      if (!mounted) return;
      setState(() => _saving = false);

      // إذا ظهرت زيادة، نتيح تسويتها فورًا بدل تركها مستحقة دون إجراء واضح.
      var refundedNow = 0;
      var overpaymentOutstanding = sale.overpaymentAmount;
      if (sale.overpaymentAmount > 0 && _canRefundOverpayment) {
        final refund = await _showOverpaymentRefundDialog(sale);
        if (refund != null) {
          try {
            overpaymentOutstanding = await _salesRepository!.refundCustomerOverpayment(
              saleId: sale.id,
              amount: refund['amount']! as int,
              paymentMethod: refund['method']! as String,
              userId: widget.userId,
              shiftId: widget.shiftId,
            );
            refundedNow = refund['amount']! as int;
          } catch (error) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('لم يُسجل رد الزيادة: $error. بقي المبلغ مستحقًا للزبون.')),
              );
            }
          }
        }
      }

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('تم حفظ الفاتورة'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('رقم الفاتورة: ${sale.invoiceNumber}'),
            const SizedBox(height: 8),
            _totalRow('الإجمالي', sale.total),
            _totalRow('إجمالي المبلغ المستلم', sale.paidAmount + sale.overpaymentAmount),
            _totalRow('المتبقي من قيمة الفاتورة', sale.remainingAmount),
            if (refundedNow > 0) _totalRow('المبلغ المسترد', refundedNow),
            if (refundedNow > 0)
              _totalRow('صافي المبلغ المدفوع', sale.paidAmount + sale.overpaymentAmount - refundedNow),
            if (overpaymentOutstanding > 0)
              _totalRow('زيادة مستحقة للزبون', overpaymentOutstanding),
            if (sale.overpaymentAmount > 0 && !_canRefundOverpayment)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('تحتاج تسوية هذه الزيادة إلى منح صلاحية رد مبالغ الزيادة للكاشير أو تنفيذها من حساب المدير.'),
              ),
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

  // يتيح رد الزيادة كاملة أو جزئيًا فور حفظ الفاتورة، أو إبقاءها مستحقة.
  Future<Map<String, Object?>?> _showOverpaymentRefundDialog(SaleRecord sale) async {
    final amountController = TextEditingController(text: '${sale.overpaymentAmount}');
    var paymentMethod = widget.shiftId == null ? 'تحويل بنكي' : 'نقدي';
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refreshDialog) => AlertDialog(
          title: const Text('تسوية الزيادة المستلمة'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _totalRow('الزيادة المستلمة', sale.overpaymentAmount, strong: true),
                const SizedBox(height: 8),
                const Text('أدخل المبلغ الذي سترده الآن. يمكنك رد الزيادة كاملة أو جزء منها، أو تركها مستحقة للزبون.'),
                const SizedBox(height: 12),
                TextField(
                  controller: amountController,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'مبلغ الرد الآن',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: paymentMethod,
                  decoration: const InputDecoration(
                    labelText: 'طريقة رد المبلغ',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'نقدي', child: Text('نقدًا من الخزينة')),
                    DropdownMenuItem(value: 'تحويل بنكي', child: Text('تحويل بنكي')),
                  ],
                  onChanged: (value) {
                    if (value != null) refreshDialog(() => paymentMethod = value);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إبقاؤها مستحقة'),
            ),
            FilledButton(
              onPressed: () {
                final amount = int.tryParse(amountController.text.trim());
                if (amount == null || amount <= 0 || amount > sale.overpaymentAmount) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(content: Text('أدخل مبلغًا صحيحًا لا يتجاوز الزيادة المستلمة.')),
                  );
                  return;
                }
                Navigator.pop(dialogContext, {'amount': amount, 'method': paymentMethod});
              },
              child: const Text('تأكيد الرد'),
            ),
          ],
        ),
      ),
    );
    amountController.dispose();
    return result;
  }

  // فتح نموذج مرتجع مرتبط ببنود الفاتورة الأصلية.
  Future<void> _returnSale(SaleRecord sale) async {
    try {
      final database = await GroceryDatabase.open();
      final items = await database.query(
        'sale_items',
        columns: ['id', 'product_name', 'unit', 'quantity'],
        where: 'sale_id = ?',
        whereArgs: [sale.id],
        orderBy: 'id ASC',
      );
      final remaining = <int, double>{};
      for (final item in items) {
        final id = item['id'] as int;
        final sold = (item['quantity'] as num).toDouble();
        final returned = await _salesRepository!.returnedQuantity(id, userId: widget.userId);
        remaining[id] = (sold - returned).clamp(0, sold).toDouble();
      }
      final controllers = <int, TextEditingController>{
        for (final item in items)
          item['id'] as int: TextEditingController(text: '0'),
      };
      final noteController = TextEditingController();
      if (!mounted) return;
      final quantities = await showDialog<Map<int, double>>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, refreshDialog) => AlertDialog(
            title: Text('مرتجع الفاتورة ${sale.invoiceNumber}'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('أدخل الكمية المرتجعة لكل صنف. لا يمكن تجاوز الكمية المتبقية.'),
                    const SizedBox(height: 12),
                    for (final item in items)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(item['product_name'] as String,
                                      style: const TextStyle(fontWeight: FontWeight.w700)),
                                  Text('المتاح للإرجاع: ${_quantity(remaining[item['id'] as int]!)} ${item['unit']}'),
                                ],
                              ),
                            ),
                            SizedBox(
                              width: 92,
                              child: TextField(
                                controller: controllers[item['id'] as int],
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: const InputDecoration(labelText: 'الكمية', border: OutlineInputBorder(), isDense: true),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: noteController,
                      decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)', border: OutlineInputBorder()),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () {
                  final selected = <int, double>{};
                  for (final entry in controllers.entries) {
                    final value = double.tryParse(entry.value.text.trim()) ?? 0;
                    if (!value.isFinite || value < 0 || value > (remaining[entry.key] ?? 0)) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('تحقق من الكميات؛ لا يمكن إرجاع كمية أكبر من المتبقي.')),
                      );
                      return;
                    }
                    if (value > 0) selected[entry.key] = value;
                  }
                  if (selected.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('أدخل كمية واحدة على الأقل لإرجاعها.')),
                    );
                    return;
                  }
                  Navigator.pop(dialogContext, selected);
                },
                child: const Text('تأكيد المرتجع'),
              ),
            ],
          ),
        ),
      );
      final note = noteController.text;
      for (final controller in controllers.values) {
        controller.dispose();
      }
      noteController.dispose();
      if (quantities == null || !mounted) return;

      SaleReturnRecord returned;
      try {
        returned = await _salesRepository!.returnItems(
          saleId: sale.id,
          quantitiesBySaleItemId: quantities,
          note: note,
          userId: widget.userId,
          shiftId: widget.shiftId,
        );
      } on ManagerApprovalRequiredException catch (approvalRequest) {
        if (!widget.cashierMode || widget.shiftId == null) rethrow;
        if (!mounted) return;
        final credentials = await showDialog<ManagerApprovalCredentials>(
          context: context,
          barrierDismissible: false,
          builder: (_) => ManagerApprovalDialog(
            discountAmount: approvalRequest.amount,
            operationName: 'المرتجع',
            cancelLabel: 'إلغاء المرتجع',
          ),
        );
        if (!mounted) return;
        if (credentials == null) return;
        final token = await _salesRepository!.requestCashierReturnApproval(
          managerUsername: credentials.username,
          managerPassword: credentials.password,
          cashierUserId: widget.userId,
          shiftId: widget.shiftId!,
          saleId: sale.id,
          returnAmount: approvalRequest.amount,
        );
        returned = await _salesRepository!.returnItems(
          saleId: sale.id,
          quantitiesBySaleItemId: quantities,
          note: note,
          userId: widget.userId,
          shiftId: widget.shiftId,
          managerApprovalToken: token,
        );
      }
      if (_canViewInvoices) {
        _recent = await _salesRepository!.recentSales(userId: widget.userId, limit: 50);
      }
      widget.onDataChanged?.call();
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم تسجيل المرتجع بقيمة ${returned.amount} ج.س وإعادة الكمية إلى المخزون.')),
      );
      // إذا تجاوز المرتجع الدين الأصلي، اسأل عن الرد النقدي الفعلي
      // بدل خصم مبلغ من الخزينة لم يُسلَّم للزبون.
      final refundable = await _salesRepository!.maximumRefundableAmount(sale.id, userId: widget.userId);
      if (refundable > 0 && mounted && _canRefund) await _refundSale(sale);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تسجيل المرتجع: $error')),
      );
    }
  }

  // تسجيل رد نقدي فعلي للزبون بعد احتساب الجزء الذي يغطي دين الفاتورة.
  Future<void> _refundSale(SaleRecord sale) async {
    try {
      final available = await _salesRepository!.maximumRefundableAmount(sale.id, userId: widget.userId);
      if (!mounted) return;
      if (available <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا يوجد فائض متاح للرد النقدي؛ المرتجعات تغطي الدين الأصلي للفاتورة أولًا.')),
        );
        return;
      }

      final amountController = TextEditingController(text: available.toString());
      String paymentMethod = 'نقدي';
      final amount = await showDialog<int>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, refreshDialog) => AlertDialog(
            title: Text('رد نقدي للفاتورة ${sale.invoiceNumber}'),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('الحد الأقصى المتاح للرد: $available ج.س'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: amountController,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'المبلغ الذي رُدّ فعليًا', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: paymentMethod,
                    decoration: const InputDecoration(labelText: 'طريقة الرد', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'نقدي', child: Text('نقدي')),
                      DropdownMenuItem(value: 'تحويل بنكي', child: Text('تحويل بنكي')),
                      DropdownMenuItem(value: 'محفظة إلكترونية', child: Text('محفظة إلكترونية')),
                    ],
                    onChanged: (value) {
                      if (value != null) refreshDialog(() => paymentMethod = value);
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
              FilledButton(
                onPressed: () {
                  final value = int.tryParse(amountController.text.trim());
                  if (value == null || value <= 0 || value > available) {
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      SnackBar(content: Text('أدخل مبلغًا بين 1 و$available ج.س.')),
                    );
                    return;
                  }
                  Navigator.pop(dialogContext, value);
                },
                child: const Text('تسجيل الرد الفعلي'),
              ),
            ],
          ),
        ),
      );
      amountController.dispose();
      if (amount == null || !mounted) return;

      await _salesRepository!.recordReturnRefund(
        saleId: sale.id,
        amount: amount,
        paymentMethod: paymentMethod,
        userId: widget.userId,
        shiftId: widget.shiftId,
      );
      widget.onDataChanged?.call();
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم تسجيل رد نقدي فعلي بقيمة $amount ج.س.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تسجيل رد المبلغ: $error')),
      );
    }
  }

  // أحدث الفواتير في بطاقة مستقلة وتمرير مستقل عن بقية الشاشة.
  Widget _buildRecent(ThemeData theme, {required bool compact}) => Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'أحدث الفواتير',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              if (compact)
                SizedBox(
                  height: (_recent.length * 88).clamp(70, 240).toDouble(),
                  child: _buildRecentList(),
                )
              else
                Expanded(child: _buildRecentList()),
            ],
          ),
        ),
      );

  Widget _buildRecentList() {
    if (_recent.isEmpty) {
      return const Center(child: Text('لا توجد فواتير محفوظة حتى الآن.'));
    }
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: _recent.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final sale = _recent[index];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const CircleAvatar(
            child: Icon(Icons.receipt_long_rounded),
          ),
          title: Text(sale.invoiceNumber),
          subtitle: Text(
            '${sale.paymentMethod} • متبقي ${sale.remainingAmount} ج.س',
          ),
          trailing: PopupMenuButton<String>(
            tooltip: 'إجراءات الفاتورة',
            onSelected: (value) {
              if (value == 'return') _returnSale(sale);
              if (value == 'refund') _refundSale(sale);
            },
            itemBuilder: (_) => [
              if (_canReturn)
                const PopupMenuItem(value: 'return', child: Text('تسجيل مرتجع')),
              if (_canRefund)
                const PopupMenuItem(value: 'refund', child: Text('تسجيل رد نقدي')),
            ],
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${sale.total} ج.س',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const Icon(Icons.more_horiz_rounded),
              ],
            ),
          ),
        );
      },
    );
  }

  String _quantity(double value) => value == value.truncateToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(2);
}
