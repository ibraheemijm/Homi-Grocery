// بوابة الدخول: تمنع فتح بيانات المتجر قبل إنشاء المدير أو تسجيل الدخول.
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../data/auth_repository.dart';
import '../data/android_biometric_login.dart';
import '../data/cash_shift_repository.dart';
import '../data/grocery_database.dart';

typedef GroceryDatabaseProvider = Future<Database> Function();
typedef AuthRepositoryProvider = AuthRepository Function(Database database);

typedef AuthenticatedBuilder = Widget Function(
  AuthUser user,
  int shiftId,
  VoidCallback onLogout,
);

class AuthenticationGate extends StatefulWidget {
  const AuthenticationGate({
    required this.authenticatedBuilder,
    this.databaseProvider,
    this.authRepositoryProvider,
    this.useBiometrics = true,
    super.key,
  });

  final AuthenticatedBuilder authenticatedBuilder;
  final GroceryDatabaseProvider? databaseProvider;
  final AuthRepositoryProvider? authRepositoryProvider;
  // يتيح تعطيل تكامل الجهاز في الاختبارات التي لا تختبر الدخول الحيوي.
  final bool useBiometrics;

  Future<Database> _openDatabase() =>
      databaseProvider?.call() ?? GroceryDatabase.open();

  @override
  State<AuthenticationGate> createState() => _AuthenticationGateState();
}

class _AuthenticationGateState extends State<AuthenticationGate> {
  AuthRepository? _repository;
  AuthUser? _user;
  CashShift? _shift;
  bool _needsSetup = false;
  bool _loading = true;
  bool _biometricReady = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final database = await widget._openDatabase();
      final repository =
          widget.authRepositoryProvider?.call(database) ?? AuthRepository(database);
      final needsSetup = !(await repository.hasAccounts());
      final biometric = AndroidBiometricLogin.instance;
      final biometricReady =
          widget.useBiometrics &&
          defaultTargetPlatform == TargetPlatform.android &&
          await biometric.isAvailable &&
          await biometric.hasSavedCredentials;
      if (!mounted) return;
      setState(() {
        _repository = repository;
        _needsSetup = needsSetup;
        _biometricReady = biometricReady;
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
    final database = await widget._openDatabase();
    final shifts = CashShiftRepository(database);
    final openShift = await shifts.getOpenShift(userId: user.id);
    if (openShift != null) {
      if (mounted) {
        setState(() {
          _shift = openShift;
          _user = user;
        });
      }
      return;
    }
    if (await shifts.hasOpenShiftForAnotherUser(userId: user.id)) {
      throw const CashShiftException(
        'توجد وردية مفتوحة لحساب آخر. يجب على صاحب الوردية تسجيل الدخول وإغلاقها أولًا.',
      );
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
    var amountText = '0';
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
                TextFormField(
                  initialValue: '0',
                  onChanged: (value) => amountText = value,
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
                final amount = int.tryParse(amountText.trim());
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
    return result;
  }

  // تسجيل الدخول بكلمة المرور، مع عرض تفعيل البصمة اختياريًا على Android.
  Future<void> _loginWithPassword(String username, String password) async {
    final user = await _repository!.login(username: username, password: password);
    if (widget.useBiometrics &&
        defaultTargetPlatform == TargetPlatform.android) {
      final biometric = AndroidBiometricLogin.instance;
      if (await biometric.hasSavedCredentials) {
        // تحديث بيانات الدخول المشفرة إذا غيّر المستخدم كلمة مروره.
        await biometric.saveCredentials(username: username, password: password);
      } else if (await biometric.isAvailable && mounted) {
        final enable = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('تفعيل الدخول بالبصمة؟'),
            content: const Text(
              'يمكنك فتح Homi Grocery لاحقًا ببصمة الإصبع بدل كتابة اسم المستخدم وكلمة المرور. '
              'ستُحفظ بيانات الدخول مشفرة على هذا الجهاز فقط.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('ليس الآن'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('تفعيل البصمة'),
              ),
            ],
          ),
        );
        if (enable == true && mounted) {
          final enabled = await biometric.enableWithBiometrics(
            username: username,
            password: password,
          );
          if (enabled && mounted) setState(() => _biometricReady = true);
        }
      }
    }
    await _activateUser(user);
  }

  // لا يُستعاد الحساب إلا بعد نجاح التحقق الحيوي ثم إعادة التحقق من كلمة المرور محليًا.
  Future<void> _loginWithBiometrics() async {
    final biometric = AndroidBiometricLogin.instance;
    final credentials = await biometric.authenticate();
    if (credentials == null) {
      throw const AuthException('لم يكتمل التحقق بالبصمة. استخدم كلمة المرور للدخول.');
    }
    late AuthUser user;
    try {
      user = await _repository!.login(
        username: credentials.username,
        password: credentials.password,
      );
    } catch (error) {
      // لا تمسح بيانات الدخول عند قفل الحساب مؤقتًا أو تعذر قاعدة البيانات.
      // تُمسح فقط إذا رفض مستودع المصادقة بيانات الاعتماد نفسها أو كان الحساب غير نشط.
      if (error is AuthException &&
          error.message == 'اسم المستخدم أو كلمة المرور غير صحيحة.') {
        await biometric.clearCredentials();
        if (mounted) setState(() => _biometricReady = false);
      }
      rethrow;
    }
    await _activateUser(user);
  }

  Future<void> _logout() async {
    final current = _user;
    final shift = _shift;
    if (current == null || shift == null) return;
    var shiftClosed = false;
    try {
      final closingCash = await _askCashAmount(
        title: 'إغلاق الوردية وتسليم العهدة',
        message: 'عدّ النقدية الفعلية الموجودة في الدرج وأدخل المبلغ قبل تسجيل الخروج.',
        actionLabel: 'إغلاق الوردية والخروج',
      );
      if (closingCash == null || !mounted) return;

      final database = await widget._openDatabase();
      final closed = await CashShiftRepository(database).closeShift(
        shiftId: shift.id,
        userId: current.id,
        closingCash: closingCash,
      );
      shiftClosed = true;
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

      // لا نُبقي جلسة المستخدم نشطة بعد إغلاق ورديته، حتى إن تعذر حفظ سجل الخروج.
      try {
        await _repository?.logout(current);
      } finally {
        if (mounted) {
          setState(() {
            _user = null;
            _shift = null;
          });
        }
      }
    } catch (error) {
      if (mounted) {
        if (shiftClosed) {
          setState(() {
            _user = null;
            _shift = null;
          });
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              shiftClosed
                  ? 'أُغلقت الوردية، لكن تعذر إكمال تسجيل الخروج: $error'
                  : 'تعذر إغلاق الوردية: $error',
            ),
          ),
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
      return defaultTargetPlatform == TargetPlatform.android
          ? const AndroidStartupScreen()
          : const Scaffold(
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
      onLogin: _loginWithPassword,
      onBiometricLogin: _biometricReady ? _loginWithBiometrics : null,
    );
  }
}

// شاشة بدء خفيفة تحمل هوية التطبيق أثناء تهيئة قاعدة البيانات على Android.
class AndroidStartupScreen extends StatelessWidget {
  const AndroidStartupScreen({super.key});

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [Color(0xFF173D32), Color(0xFF102B24)],
              ),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 92,
                    height: 92,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: const Color(0xFFC7A35A),
                        width: 1.5,
                      ),
                    ),
                    child: const Icon(
                      Icons.storefront_rounded,
                      size: 48,
                      color: Color(0xFFF7F4EA),
                    ),
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    'Homi Grocery',
                    style: TextStyle(
                      color: Color(0xFFF7F4EA),
                      fontSize: 27,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'إدارة متجرك بسهولة',
                    style: TextStyle(
                      color: Color(0xFFDCE9DF),
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 34),
                  const SizedBox(
                    width: 25,
                    height: 25,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Color(0xFFC7A35A),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'جارٍ تجهيز بيانات المتجر...',
                    style: TextStyle(
                      color: Color(0xFFE5E9E4),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
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
  const _LoginScreen({required this.onLogin, this.onBiometricLogin});

  final Future<void> Function(String username, String password) onLogin;
  final Future<void> Function()? onBiometricLogin;

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
            if (widget.onBiometricLogin != null) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _working
                    ? null
                    : () async {
                        setState(() {
                          _working = true;
                          _error = null;
                        });
                        try {
                          await widget.onBiometricLogin!();
                        } catch (error) {
                          if (mounted) setState(() => _error = error.toString());
                        } finally {
                          if (mounted) setState(() => _working = false);
                        }
                      },
                icon: const Icon(Icons.fingerprint_rounded),
                label: const Text('الدخول بالبصمة'),
              ),
            ],
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
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final theme = Theme.of(context);
      final dark = theme.brightness == Brightness.dark;
      return Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: const Color(0xFF173D32),
          body: Stack(
            children: [
              Positioned(
                top: -95,
                left: -75,
                child: Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFC7A35A).withValues(alpha: 0.10),
                  ),
                ),
              ),
              Positioned(
                bottom: -120,
                right: -90,
                child: Container(
                  width: 280,
                  height: 280,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
              ),
              SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(22, 28, 22, 24),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            width: 76,
                            height: 76,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(25),
                              border: Border.all(
                                color: const Color(0xFFC7A35A),
                                width: 1.4,
                              ),
                            ),
                            child: const Icon(
                              Icons.storefront_rounded,
                              color: Color(0xFFF7F4EA),
                              size: 40,
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Homi Grocery',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Color(0xFFF7F4EA),
                              fontSize: 27,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 7),
                          const Text(
                            'إدارة متجرك بسهولة',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Color(0xFFDCE9DF),
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 28),
                          Card(
                            color: dark
                                ? const Color(0xFF1B2B25).withValues(alpha: 0.97)
                                : const Color(0xFFF7F4EA).withValues(alpha: 0.98),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28),
                              side: BorderSide(
                                color: const Color(0xFFC7A35A).withValues(alpha: 0.42),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(22),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    title,
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.headlineSmall?.copyWith(
                                      fontWeight: FontWeight.w900,
                                      color: dark ? Colors.white : const Color(0xFF173D32),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    subtitle,
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                  const SizedBox(height: 24),
                                  child,
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),
                          const Text(
                            'يعمل دون إنترنت • بياناتك محفوظة محليًا',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Color(0xFFDCE9DF),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Directionality(
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
}
