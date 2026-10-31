// بوابة الدخول: تمنع فتح بيانات المتجر قبل إنشاء المدير أو تسجيل الدخول.
import 'package:flutter/material.dart';

import '../data/auth_repository.dart';
import '../data/cash_shift_repository.dart';
import '../data/grocery_database.dart';

typedef AuthenticatedBuilder = Widget Function(
  AuthUser user,
  int shiftId,
  VoidCallback onLogout,
);

class AuthenticationGate extends StatefulWidget {
  const AuthenticationGate({
    required this.authenticatedBuilder,
    super.key,
  });

  final AuthenticatedBuilder authenticatedBuilder;

  @override
  State<AuthenticationGate> createState() => _AuthenticationGateState();
}

class _AuthenticationGateState extends State<AuthenticationGate> {
  AuthRepository? _repository;
  AuthUser? _user;
  CashShift? _shift;
  bool _needsSetup = false;
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
      final repository = AuthRepository(database);
      final needsSetup = !(await repository.hasAccounts());
      if (!mounted) return;
      setState(() {
        _repository = repository;
        _needsSetup = needsSetup;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'تعذر تهيئة قاعدة البيانات المحلية: $error';
      });
    }
  }

  Future<void> _activateUser(AuthUser user) async {
    final database = await GroceryDatabase.open();
    final shifts = CashShiftRepository(database);
    final openShift = await shifts.getOpenShift();
    if (openShift != null) {
      if (openShift.userId != user.id) {
        throw const CashShiftException(
          'توجد وردية مفتوحة لمستخدم آخر. سجّل الدخول بالحساب صاحب الوردية وأغلقها أولًا.',
        );
      }
      if (mounted) {
        setState(() {
          _shift = openShift;
          _user = user;
        });
      }
      return;
    }

    final openingCash = await _askCashAmount(
      title: 'فتح وردية جديدة',
      message: 'أدخل النقدية الفعلية الموجودة في درجك الآن. ستُسجل كرصد افتتاحي.',
      actionLabel: 'فتح الوردية',
    );
    if (openingCash == null) {
      throw const CashShiftException('تم إلغاء الدخول؛ يجب إدخال رصيد بداية الدرج لفتح الوردية.');
    }
    final shift = await shifts.openShift(
      userId: user.id,
      openingCash: openingCash,
    );
    if (mounted) {
      setState(() {
        _shift = shift;
        _user = user;
      });
    }
  }

  Future<int?> _askCashAmount({
    required String title,
    required String message,
    required String actionLabel,
  }) async {
    final controller = TextEditingController(text: '0');
    String? error;
    final result = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, refresh) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(message),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'المبلغ بالجنيه السوداني',
                    prefixIcon: Icon(Icons.payments_outlined),
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: TextStyle(color: Theme.of(dialogContext).colorScheme.error)),
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
                final amount = int.tryParse(controller.text.trim());
                if (amount == null || amount < 0) {
                  refresh(() => error = 'أدخل مبلغًا صحيحًا لا يقل عن صفر.');
                  return;
                }
                Navigator.pop(dialogContext, amount);
              },
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _logout() async {
    final current = _user;
    final shift = _shift;
    if (current == null || shift == null) return;
    try {
      final closingCash = await _askCashAmount(
        title: 'إغلاق الوردية وتسليم العهدة',
        message: 'عدّ النقدية الفعلية الموجودة في الدرج وأدخل المبلغ قبل تسجيل الخروج.',
        actionLabel: 'إغلاق الوردية والخروج',
      );
      if (closingCash == null || !mounted) return;

      final database = await GroceryDatabase.open();
      final closed = await CashShiftRepository(database).closeShift(
        shiftId: shift.id,
        userId: current.id,
        closingCash: closingCash,
      );
      if (current.isManager && mounted) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('ملخص تسوية الوردية'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('النقد المتوقع: ${closed.expectedCash} ج.س'),
                Text('النقد الفعلي: ${closed.closingCash} ج.س'),
                Text(
                  'الفرق: ${closed.difference} ج.س',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: (closed.difference ?? 0) < 0
                        ? Theme.of(dialogContext).colorScheme.error
                        : Theme.of(dialogContext).colorScheme.primary,
                  ),
                ),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('متابعة'),
              ),
            ],
          ),
        );
      }
      await _repository?.logout(current);
      if (mounted) {
        setState(() {
          _user = null;
          _shift = null;
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر إغلاق الوردية: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_user case final user?) {
      final shift = _shift;
      if (shift != null) {
        return widget.authenticatedBuilder(user, shift.id, _logout);
      }
    }
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return _GateError(message: _error!, onRetry: _initialize);
    }
    final repository = _repository!;
    if (_needsSetup) {
      return _CreateManagerScreen(
        onCreate: (username, displayName, password) async {
          final user = await repository.createInitialManager(
            username: username,
            displayName: displayName,
            password: password,
          );
          if (mounted) setState(() => _needsSetup = false);
          await _activateUser(user);
          return user;
        },
      );
    }
    return _LoginScreen(
      onLogin: (username, password) async {
        final user = await repository.login(
          username: username,
          password: password,
        );
        await _activateUser(user);
        return user;
      },
    );
  }
}

class _GateError extends StatelessWidget {
  const _GateError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.storage_rounded, size: 48),
                  const SizedBox(height: 16),
                  const Text('تعذر فتح Homi Grocery'),
                  const SizedBox(height: 8),
                  Text(message, textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('إعادة المحاولة'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

class _CreateManagerScreen extends StatefulWidget {
  const _CreateManagerScreen({required this.onCreate});

  final Future<AuthUser> Function(
    String username,
    String displayName,
    String password,
  ) onCreate;

  @override
  State<_CreateManagerScreen> createState() => _CreateManagerScreenState();
}

class _CreateManagerScreenState extends State<_CreateManagerScreen> {
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _obscure = true;
  bool _working = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _displayName.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_password.text != _confirmation.text) {
      setState(() => _error = 'كلمتا المرور غير متطابقتين.');
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.onCreate(
        _username.text,
        _displayName.text,
        _password.text,
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: 'إعداد المتجر لأول مرة',
        subtitle: 'أنشئ حساب المدير. لن تُستخدم كلمة مرور افتراضية.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _displayName,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'اسم المدير الظاهر',
                prefixIcon: Icon(Icons.badge_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _username,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'اسم المستخدم',
                helperText: '3–32 حرفًا إنجليزيًا أو رقمًا أو . _ -',
                prefixIcon: Icon(Icons.person_outline_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: _obscure,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'كلمة المرور',
                helperText: '10 أحرف على الأقل',
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirmation,
              obscureText: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _working ? null : _submit(),
              decoration: const InputDecoration(
                labelText: 'تأكيد كلمة المرور',
                prefixIcon: Icon(Icons.lock_reset_rounded),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _working ? null : _submit,
              child: _working
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('إنشاء حساب المدير'),
            ),
          ],
        ),
      );
}

class _LoginScreen extends StatefulWidget {
  const _LoginScreen({required this.onLogin});

  final Future<AuthUser> Function(String username, String password) onLogin;

  @override
  State<_LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<_LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _working = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.onLogin(_username.text, _password.text);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: 'تسجيل الدخول',
        subtitle: 'أدخل بيانات حسابك للوصول إلى بيانات المتجر.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _username,
              autofocus: true,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'اسم المستخدم',
                prefixIcon: Icon(Icons.person_outline_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: _obscure,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _working ? null : _submit(),
              decoration: InputDecoration(
                labelText: 'كلمة المرور',
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _working ? null : _submit,
              child: _working
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('دخول'),
            ),
          ],
        ),
      );
}

class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const CircleAvatar(
                            radius: 30,
                            child: Icon(Icons.storefront_rounded, size: 30),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            'Homi Grocery',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            subtitle,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 24),
                          child,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}
