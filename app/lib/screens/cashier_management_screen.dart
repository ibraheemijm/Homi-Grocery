// إدارة حسابات الكاشير متاحة للمدير فقط.
import 'package:flutter/material.dart';

import '../data/auth_repository.dart';
import '../data/grocery_database.dart';
import 'sales_screen.dart';
import 'invoices_screen.dart';
import 'customers_screen.dart';
import 'suppliers_screen.dart';
import 'cashbox_screen.dart';
import 'reports_screen.dart';
import 'stock_movements_screen.dart';

class CashierManagementScreen extends StatefulWidget {
  const CashierManagementScreen({
    required this.manager,
    super.key,
  });

  final AuthUser manager;

  @override
  State<CashierManagementScreen> createState() =>
      _CashierManagementScreenState();
}

class _CashierManagementScreenState extends State<CashierManagementScreen> {
  AuthRepository? _repository;
  List<CashierAccount> _cashiers = const [];
  bool _loading = true;
  bool _working = false;
  String? _error;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final database = await GroceryDatabase.open();
      final repository = AuthRepository(database);
      final cashiers = await repository.listCashiers(manager: widget.manager);
      if (!mounted) return;
      setState(() {
        _repository = repository;
        _cashiers = cashiers;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _createCashier() async {
    final name = TextEditingController();
    final username = TextEditingController();
    final password = TextEditingController();
    final confirmation = TextEditingController();
    String? dialogError;

    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('إضافة كاشير'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'اسم الكاشير'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: username,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'اسم المستخدم',
                    helperText: '3–32 حرفًا إنجليزيًا أو رقمًا أو . _ -',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'كلمة المرور',
                    helperText: '10 أحرف على الأقل',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: confirmation,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'تأكيد كلمة المرور',
                  ),
                ),
                if (dialogError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    dialogError!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                if (password.text != confirmation.text) {
                  setDialogState(() => dialogError = 'كلمتا المرور غير متطابقتين.');
                  return;
                }
                Navigator.pop(dialogContext, {
                  'name': name.text,
                  'username': username.text,
                  'password': password.text,
                });
              },
              child: const Text('إنشاء الحساب'),
            ),
          ],
        ),
      ),
    );

    name.dispose();
    username.dispose();
    password.dispose();
    confirmation.dispose();
    if (values == null || !mounted) return;

    setState(() => _working = true);
    try {
      await _repository!.createCashier(
        manager: widget.manager,
        username: values['username']!,
        displayName: values['name']!,
        password: values['password']!,
      );
      await _load();
      if (mounted) _showMessage('تم إنشاء حساب الكاشير.');
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _resetPassword(CashierAccount account) async {
    final password = TextEditingController();
    final confirmation = TextEditingController();
    String? dialogError;

    final newPassword = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('تغيير كلمة مرور ${account.user.displayName}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'كلمة المرور الجديدة',
                  helperText: '10 أحرف على الأقل',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: confirmation,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'تأكيد كلمة المرور'),
              ),
              if (dialogError != null) ...[
                const SizedBox(height: 10),
                Text(
                  dialogError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                if (password.text != confirmation.text) {
                  setDialogState(() => dialogError = 'كلمتا المرور غير متطابقتين.');
                  return;
                }
                if (password.text.length < 10 || password.text.length > 128) {
                  setDialogState(() => dialogError = 'كلمة المرور يجب أن تكون بين 10 و128 حرفًا.');
                  return;
                }
                Navigator.pop(dialogContext, password.text);
              },
              child: const Text('حفظ كلمة المرور'),
            ),
          ],
        ),
      ),
    );

    password.dispose();
    confirmation.dispose();
    if (newPassword == null || !mounted) return;

    setState(() => _working = true);
    try {
      await _repository!.resetCashierPassword(
        manager: widget.manager,
        cashierId: account.user.id,
        newPassword: newPassword,
      );
      if (mounted) _showMessage('تم تغيير كلمة المرور وإلغاء أي قفل للحساب.');
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _editPermissions(CashierAccount account) async {
    setState(() => _working = true);
    List<CashierPermissionSetting> settings;
    try {
      settings = await _repository!.getCashierPermissions(
        manager: widget.manager,
        cashierId: account.user.id,
      );
    } catch (error) {
      if (mounted) _showMessage(error.toString());
      if (mounted) setState(() => _working = false);
      return;
    }
    if (!mounted) return;
    setState(() => _working = false);

    final enabled = {
      for (final setting in settings) setting.key: setting.isAllowed,
    };
    final limits = {
      for (final setting in settings)
        setting.key: TextEditingController(
          text: setting.maxAmount?.toString() ?? '',
        ),
    };
    String? dialogError;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('صلاحيات ${account.user.displayName}'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'عدم تفعيل الصلاحية يعني منعها. اترك الحد المالي فارغًا إذا لم ترد وضع سقف للعملية.',
                  ),
                  const SizedBox(height: 12),
                  ...settings.map((setting) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(setting.label),
                        value: enabled[setting.key] ?? false,
                        onChanged: (value) => setDialogState(
                          () => enabled[setting.key] = value,
                        ),
                      ),
                      if (const {
                        'credit_sales',
                        'discounts',
                        'returns',
                        'return_refunds',
                        'customer_collections',
                        'cash_expenses',
                        'supplier_purchases',
                        'supplier_payments',
        'supplier_returns',
        'supplier_return_refunds',
                      }.contains(setting.key))
                        TextField(
                          controller: limits[setting.key],
                          enabled: enabled[setting.key] ?? false,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'الحد الأقصى للعملية (ج.س) — اختياري',
                            isDense: true,
                          ),
                        ),
                      const Divider(height: 20),
                    ],
                  )),
                  if (dialogError != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        dialogError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                for (final setting in settings) {
                  if (!const {
                    'credit_sales',
                    'discounts',
                    'returns',
                    'return_refunds',
                    'customer_collections',
                    'cash_expenses',
                    'supplier_purchases',
                    'supplier_payments',
        'supplier_returns',
        'supplier_return_refunds',
                  }.contains(setting.key)) {
                    continue;
                  }
                  final raw = limits[setting.key]!.text.trim();
                  if (raw.isNotEmpty &&
                      (int.tryParse(raw) == null || int.parse(raw) < 0)) {
                    setDialogState(
                      () => dialogError = 'أدخل حدًا ماليًا صحيحًا أو اترك الحقل فارغًا.',
                    );
                    return;
                  }
                }
                Navigator.pop(dialogContext, true);
              },
              child: const Text('حفظ الصلاحيات'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) {
      for (final controller in limits.values) {
        controller.dispose();
      }
      return;
    }
    final updated = settings.map((setting) {
      final hasAmountLimit = const {
        'credit_sales',
        'discounts',
        'returns',
        'return_refunds',
        'customer_collections',
        'cash_expenses',
        'supplier_purchases',
        'supplier_payments',
        'supplier_returns',
        'supplier_return_refunds',
      }.contains(setting.key);
      final raw = hasAmountLimit ? limits[setting.key]!.text.trim() : '';
      return CashierPermissionSetting(
        key: setting.key,
        label: setting.label,
        isAllowed: enabled[setting.key] ?? false,
        maxAmount: raw.isEmpty ? null : int.parse(raw),
      );
    }).toList(growable: false);
    for (final controller in limits.values) {
      controller.dispose();
    }

    setState(() => _working = true);
    try {
      await _repository!.saveCashierPermissions(
        manager: widget.manager,
        cashierId: account.user.id,
        permissions: updated,
      );
      if (mounted) _showMessage('تم حفظ إعدادات الصلاحيات وتسجيلها في سجل التدقيق.');
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _changeStatus(CashierAccount account, bool isActive) async {
    final action = isActive ? 'تفعيل' : 'إيقاف';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('$action حساب الكاشير؟'),
        content: Text(
          isActive
              ? 'سيتمكن ${account.user.displayName} من تسجيل الدخول مجددًا.'
              : 'لن يتمكن ${account.user.displayName} من تسجيل الدخول بعد الإيقاف.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(action),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _working = true);
    try {
      await _repository!.setCashierActive(
        manager: widget.manager,
        cashierId: account.user.id,
        isActive: isActive,
      );
      await _load();
      if (mounted) _showMessage('تم $action الحساب.');
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _lastLoginLabel(DateTime? value) {
    if (value == null) return 'لم يسجل الدخول بعد';
    final date = value.toLocal();
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return 'آخر دخول: $day/$month $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('إدارة الكاشيرين'),
          actions: [
            IconButton(
              tooltip: 'تحديث القائمة',
              onPressed: _working ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.lock_outline_rounded, size: 42),
                          const SizedBox(height: 12),
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _load,
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('إعادة المحاولة'),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              const CircleAvatar(
                                child: Icon(Icons.groups_2_rounded),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'حسابات الكاشير',
                                      style: TextStyle(fontWeight: FontWeight.w800),
                                    ),
                                    Text('عدد الحسابات: ${_cashiers.length}'),
                                  ],
                                ),
                              ),
                              FilledButton.icon(
                                onPressed: _working ? null : _createCashier,
                                icon: const Icon(Icons.person_add_alt_1_rounded),
                                label: const Text('إضافة كاشير'),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.info_outline_rounded),
                              SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'يمكن ضبط الصلاحيات والحدود المالية لكل كاشير. يجري استكمال فرض هذه الإعدادات على جميع العمليات في طبقة البيانات.',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_cashiers.isEmpty)
                        const Card(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Column(
                              children: [
                                Icon(Icons.person_add_alt_1_rounded, size: 42),
                                SizedBox(height: 10),
                                Text('لا توجد حسابات كاشير حتى الآن'),
                                SizedBox(height: 4),
                                Text(
                                  'أضف حسابًا لكل عامل حتى ترتبط عملياته ووردياته بهوية مستقلة.',
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        ..._cashiers.map(
                          (account) => Card(
                            child: ListTile(
                              leading: CircleAvatar(
                                child: Icon(
                                  account.isActive
                                      ? Icons.point_of_sale_rounded
                                      : Icons.person_off_rounded,
                                ),
                              ),
                              title: Text(
                                account.user.displayName,
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                              subtitle: Text(
                                '@${account.user.username}\n${_lastLoginLabel(account.lastLoginAt)}',
                              ),
                              isThreeLine: true,
                              trailing: PopupMenuButton<String>(
                                enabled: !_working,
                                onSelected: (value) {
                                  if (value == 'password') {
                                    _resetPassword(account);
                                  } else if (value == 'permissions') {
                                    _editPermissions(account);
                                  } else if (value == 'status') {
                                    _changeStatus(account, !account.isActive);
                                  }
                                },
                                itemBuilder: (context) => [
                                  const PopupMenuItem(
                                    value: 'permissions',
                                    child: Text('إعداد الصلاحيات'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'password',
                                    child: Text('تغيير كلمة المرور'),
                                  ),
                                  PopupMenuItem(
                                    value: 'status',
                                    child: Text(
                                      account.isActive ? 'إيقاف الحساب' : 'تفعيل الحساب',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      if (_working)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                    ],
                  ),
      ),
    );
  }
}


// مساحة عمل الكاشير: تعرض الأقسام التي منحها المدير لهذا الحساب فقط.
class CashierWorkspaceScreen extends StatefulWidget {
  const CashierWorkspaceScreen({
    required this.cashier,
    required this.shiftId,
    required this.onLogout,
    super.key,
  });

  final AuthUser cashier;
  final int shiftId;
  final VoidCallback onLogout;

  @override
  State<CashierWorkspaceScreen> createState() => _CashierWorkspaceScreenState();
}

class _CashierWorkspaceScreenState extends State<CashierWorkspaceScreen> {
  Set<String> _permissions = const {};
  bool _loading = true;
  String? _error;
  int _selectedIndex = 0;

  Future<void> _loadPermissions() async {
    try {
      final database = await GroceryDatabase.open();
      final permissions = await AuthRepository(database)
          .getActiveCashierPermissionKeys(cashierId: widget.cashier.id);
      if (!mounted) return;
      setState(() {
        _permissions = permissions;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _loadPermissions();
  }

  List<_CashierWorkspaceItem> get _items => [
        const _CashierWorkspaceItem('المبيعات', Icons.point_of_sale_rounded, 'sales'),
        if (_permissions.contains('view_invoice_history'))
          const _CashierWorkspaceItem('الفواتير', Icons.receipt_long_rounded, 'invoices'),
        if (_permissions.contains('view_customer_data'))
          const _CashierWorkspaceItem('الزبائن والديون', Icons.people_alt_rounded, 'customers'),
        if (_permissions.contains('view_supplier_data'))
          const _CashierWorkspaceItem('الموردون والمشتريات', Icons.local_shipping_rounded, 'suppliers'),
        if (_permissions.contains('view_cashbox'))
          const _CashierWorkspaceItem('الخزينة', Icons.account_balance_wallet_rounded, 'cashbox'),
        if (_permissions.contains('view_reports'))
          const _CashierWorkspaceItem('التقارير', Icons.analytics_rounded, 'reports'),
        if (_permissions.contains('stock_adjustments'))
          const _CashierWorkspaceItem('حركات المخزون', Icons.history_rounded, 'stock'),
      ];

  Widget _selectedScreen() {
    final item = _items[_selectedIndex];
    switch (item.key) {
      case 'sales':
        return SalesScreen(
          userId: widget.cashier.id,
          shiftId: widget.shiftId,
          cashierMode: true,
          cashierPermissions: _permissions,
        );
      case 'invoices':
        return InvoicesScreen(userId: widget.cashier.id);
      case 'customers':
        return CustomersScreen(userId: widget.cashier.id, shiftId: widget.shiftId);
      case 'suppliers':
        return SuppliersScreen(userId: widget.cashier.id, shiftId: widget.shiftId);
      case 'cashbox':
        return CashboxScreen(userId: widget.cashier.id, shiftId: widget.shiftId);
      case 'reports':
        return ReportsScreen(userId: widget.cashier.id);
      case 'stock':
        return StockMovementsScreen(userId: widget.cashier.id);
      default:
        return const Center(child: Text('القسم غير متاح لهذا الحساب.'));
    }
  }

  Widget _navigationList({required bool closeDrawer}) => ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 18),
            child: Text('أقسام الكاشير', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
          for (var index = 0; index < _items.length; index++)
            ListTile(
              selected: index == _selectedIndex,
              leading: Icon(_items[index].icon),
              title: Text(_items[index].label),
              onTap: () {
                setState(() => _selectedIndex = index);
                if (closeDrawer && Navigator.canPop(context)) {
                  Navigator.pop(context);
                }
              },
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('مساحة الكاشير')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () {
                    setState(() => _loading = true);
                    _loadPermissions();
                  },
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('إعادة تحميل الصلاحيات'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 900;
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            appBar: AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Homi Grocery'),
                  Text(
                    '${_items[_selectedIndex].label} • ${widget.cashier.displayName}',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ),
              actions: [
                if (!desktop)
                  Builder(
                    builder: (context) => IconButton(
                      tooltip: 'الأقسام المسموح بها',
                      onPressed: () => Scaffold.of(context).openDrawer(),
                      icon: const Icon(Icons.menu_rounded),
                    ),
                  ),
                IconButton(
                  tooltip: 'تسجيل الخروج وتسليم الوردية',
                  onPressed: widget.onLogout,
                  icon: const Icon(Icons.logout_rounded),
                ),
                const SizedBox(width: 8),
              ],
            ),
            drawer: desktop ? null : Drawer(child: _navigationList(closeDrawer: true)),
            body: Row(
              children: [
                if (desktop)
                  SizedBox(
                    width: 250,
                    child: Material(
                      color: Theme.of(context).colorScheme.surface,
                      child: _navigationList(closeDrawer: false),
                    ),
                  ),
                Expanded(child: _selectedScreen()),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CashierWorkspaceItem {
  const _CashierWorkspaceItem(this.label, this.icon, this.key);
  final String label;
  final IconData icon;
  final String key;
}
