// إدارة حسابات الكاشير متاحة للمدير فقط.
import 'package:flutter/material.dart';

import '../data/auth_repository.dart';
import '../data/grocery_database.dart';
import 'sales_screen.dart';

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

    final updated = settings.map((setting) {
      final raw = limits[setting.key]!.text.trim();
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
    if (confirmed != true || !mounted) return;

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


// مساحة عمل الكاشير: نقطة بيع نقدية فقط دون مؤشرات أو أدوات الإدارة.
class CashierWorkspaceScreen extends StatelessWidget {
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
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Homi Grocery'),
                Text(
                  'نقطة البيع • ${cashier.displayName}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'تسجيل الخروج وتسليم الوردية',
                onPressed: onLogout,
                icon: const Icon(Icons.logout_rounded),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: SalesScreen(
            userId: cashier.id,
            shiftId: shiftId,
            cashierMode: true,
          ),
        ),
      );
}
