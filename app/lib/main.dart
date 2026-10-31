// المكتبة الأساسية لبناء واجهات Flutter وعناصر Material Design.
import 'dart:async';

import 'package:flutter/material.dart';

import 'data/dashboard_repository.dart';
import 'data/grocery_database.dart';
import 'data/font_preferences.dart';
import 'data/auth_repository.dart';
import 'screens/authentication_gate.dart';

import 'screens/invoices_screen.dart';
import 'screens/cashbox_screen.dart';
import 'screens/customers_screen.dart';
import 'screens/products_screen.dart';
import 'screens/reports_screen.dart';
import 'screens/sales_screen.dart';
import 'screens/stock_movements_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/suppliers_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/backup_screen.dart';

// نقطة تشغيل التطبيق: تُنشئ واجهة Homi Grocery وتعرضها للمستخدم.


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await FontPreferences.load();
  } catch (_) {
    // تبقى الواجهة على الخط الافتراضي إذا تعذر تحميل التفضيلات.
  }
  runApp(const HomiGroceryApp());
}

// ألوان الهوية البصرية موحّدة هنا لتسهيل تعديل التصميم مستقبلًا.
const Color brandGreen = Color(0xFF173D32);
const Color brandCream = Color(0xFFF7F4EA);
const Color brandGold = Color(0xFFC7A35A);
const Color brandMint = Color(0xFFDCE9DF);

// الجذر الرئيسي للتطبيق؛ يحتفظ بحالة المظهر الفاتح أو الداكن.
class HomiGroceryApp extends StatefulWidget {
  const HomiGroceryApp({super.key});

  @override
  State<HomiGroceryApp> createState() => _HomiGroceryAppState();
}

class _HomiGroceryAppState extends State<HomiGroceryApp> {
  ThemeMode _themeMode = ThemeMode.light;

  // تبديل المظهر مع إعادة بناء الواجهة لتطبيق الألوان الجديدة.
  void _toggleTheme() {
    setState(() {
      _themeMode =
          _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: FontPreferences.uiFontNotifier,
      builder: (context, _) => MaterialApp(
        title: 'Homi Grocery',
        debugShowCheckedModeBanner: false,
        themeMode: _themeMode,
        theme: _buildTheme(Brightness.light),
        darkTheme: _buildTheme(Brightness.dark),
        home: AuthenticationGate(
          authenticatedBuilder: (user, onLogout) => DashboardScreen(
            isDark: _themeMode == ThemeMode.dark,
            onToggleTheme: _toggleTheme,
            user: user,
            onLogout: onLogout,
          ),
        ),
      ),
    );
  }

  // إنشاء إعدادات الثيم من مجموعة ألوان موحدة بدل تكرارها في كل شاشة.
  ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: brandGreen,
      brightness: brightness,
      primary: isDark ? const Color(0xFF9BC7B2) : brandGreen,
      secondary: brandGold,
      surface: isDark ? const Color(0xFF17231F) : Colors.white,
    );
    return ThemeData(
      useMaterial3: true,
      fontFamily: FontPreferences.uiFont == FontPreferences.importedFontFamily
          ? FontPreferences.registeredImportedFontFamily
          : FontPreferences.uiFont,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          isDark ? const Color(0xFF101915) : brandCream,
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? const Color(0xFF101915) : brandCream,
        foregroundColor: isDark ? Colors.white : brandGreen,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: isDark ? const Color(0xFF1B2B25) : Colors.white.withValues(alpha: 0.88),
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : brandGreen.withValues(alpha: 0.08),
          ),
        ),
      ),
      dividerColor: isDark
          ? Colors.white.withValues(alpha: 0.10)
          : brandGreen.withValues(alpha: 0.10),
    );
  }
}

// الشاشة الرئيسية التي تتكيف مع عرض الكمبيوتر أو الهاتف.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    required this.isDark,
    required this.onToggleTheme,
    required this.user,
    required this.onLogout,
    super.key,
  });

  final bool isDark;
  final VoidCallback onToggleTheme;
  final AuthUser user;
  final VoidCallback onLogout;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedIndex = 0;
  DashboardStats? _stats;
  String? _statsError;
  List<RecentInvoice> _recentInvoices = const [];
  bool _recentInvoicesLoading = true;
  DateTime _clockNow = DateTime.now();
  Timer? _clockTimer;
  String _storeName = 'اسم البقالة';
  bool _use24HourClock = true;
  String _occasionText = '';
  String _occasionStart = '';
  String _occasionEnd = '';
  bool _occasionEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadDashboardStats();
    _loadRecentInvoices();
    _loadHomePreferences();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _clockNow = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }
  // طلب تأكيد قبل إنهاء جلسة المستخدم الحالي.
  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تسجيل الخروج'),
        content: const Text('هل تريد إنهاء الجلسة الحالية؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('تسجيل الخروج'),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.onLogout();
  }


  Future<void> _loadHomePreferences() async {
    try {
      final database = await GroceryDatabase.open();
      final rows = await database.query('app_metadata', columns: ['key', 'value'],
        where: 'key IN (?, ?, ?, ?, ?, ?)', whereArgs: ['store_name', 'clock_24h', 'occasion_enabled', 'occasion_text', 'occasion_start', 'occasion_end']);
      final values = {for (final row in rows) row['key'] as String: row['value'] as String};
      if (!mounted) return;
      setState(() {
        final name = values['store_name']?.trim();
        if (name != null && name.isNotEmpty) _storeName = name;
        _use24HourClock = values['clock_24h'] != 'false';
        _occasionEnabled = values['occasion_enabled'] == 'true';
        _occasionText = values['occasion_text'] ?? '';
        _occasionStart = values['occasion_start'] ?? '';
        _occasionEnd = values['occasion_end'] ?? '';
      });
    } catch (_) {
      // تبقى القيم الافتراضية إذا كانت قاعدة البيانات غير متاحة.
    }
  }

  Future<void> _loadRecentInvoices() async {
    try {
      final database = await GroceryDatabase.open();
      final rows = await DashboardRepository(database).loadRecentInvoices();
      if (!mounted) return;
      setState(() {
        _recentInvoices = rows;
        _recentInvoicesLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _recentInvoicesLoading = false);
    }
  }

  String get _timeGreeting {
    if (_occasionEnabled && _occasionText.trim().isNotEmpty) {
      final today = '${_clockNow.year.toString().padLeft(4, '0')}-${_clockNow.month.toString().padLeft(2, '0')}-${_clockNow.day.toString().padLeft(2, '0')}';
      if (_occasionStart.isNotEmpty && _occasionEnd.isNotEmpty &&
          today.compareTo(_occasionStart) >= 0 && today.compareTo(_occasionEnd) <= 0) {
        return _occasionText;
      }
    }
    final hour = _clockNow.hour;
    if (hour >= 5 && hour < 11) return 'صباح الخير';
    if (hour >= 11 && hour < 17) return 'نهارك سعيد';
    return 'مساء الخير';
  }

  String get _digitalClock {
    final hour = _use24HourClock ? _clockNow.hour : ((_clockNow.hour % 12 == 0) ? 12 : _clockNow.hour % 12);
    final time = '${hour.toString().padLeft(2, '0')}:${_clockNow.minute.toString().padLeft(2, '0')}:${_clockNow.second.toString().padLeft(2, '0')}';
    return _use24HourClock ? time : '$time ${_clockNow.hour < 12 ? 'ص' : 'م'}';
  }

  // تحميل إحصاءات فعلية من قاعدة البيانات المحلية.
  Future<void> _loadDashboardStats() async {
    try {
      final database = await GroceryDatabase.open();
      final stats = await DashboardRepository(database).load();
      if (mounted) setState(() { _stats = stats; _statsError = null; });
    } catch (error) {
      if (mounted) setState(() => _statsError = error.toString());
    }
  }

  // تعريف عناصر التنقل في مكان واحد لتوحيد أسماء الأقسام وأيقوناتها.
  static const List<_NavigationItem> _navigationItems = [
    _NavigationItem('الرئيسية', Icons.dashboard_rounded),
    _NavigationItem('المبيعات', Icons.point_of_sale_rounded),
    _NavigationItem('الفواتير', Icons.receipt_long_rounded),
    _NavigationItem('الزبائن والديون', Icons.people_alt_rounded),
    _NavigationItem('الأصناف والمخزون', Icons.inventory_2_rounded),
    _NavigationItem('الموردون والمشتريات', Icons.local_shipping_rounded),
    _NavigationItem('الخزينة', Icons.account_balance_wallet_rounded),
    _NavigationItem('التقارير', Icons.analytics_rounded),
    _NavigationItem('الإعدادات', Icons.settings_rounded),
    _NavigationItem('حركات المخزون', Icons.history_rounded),
    _NavigationItem('الإشعارات وسجل الموافقات', Icons.notifications_active_rounded),
    _NavigationItem('النسخ الاحتياطي والاستعادة', Icons.backup_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    // فرض اتجاه RTL على الشاشة لدعم الواجهة العربية.
    return Directionality(
      textDirection: TextDirection.rtl,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // عند عرض 900 بكسل أو أكثر نستخدم قائمة جانبية للكمبيوتر.
          final isDesktop = constraints.maxWidth >= 900;
          return Scaffold(
            body: SafeArea(
              child: Row(
                children: [
                  if (isDesktop) _buildSidebar(context),
                  Expanded(
                    child: _selectedIndex == 0
                        ? _buildDashboard(context, isDesktop)
                        : _selectedIndex == 1
                            ? SalesScreen(onDataChanged: () {
                                _loadDashboardStats();
                                _loadRecentInvoices();
                              })
                            : _selectedIndex == 2
                                ? const InvoicesScreen()
                            : _selectedIndex == 3
                                ? const CustomersScreen()
                                : _selectedIndex == 4
                                    ? const ProductsScreen()
                                    : _selectedIndex == 5
                                        ? const SuppliersScreen()
                                        : _selectedIndex == 6
                                            ? const CashboxScreen()
                                            : _selectedIndex == 7
                                                ? const ReportsScreen()
                                                : _selectedIndex == 8
                                                    ? const SettingsScreen()
                                                    : _selectedIndex == 9
                                        ? const StockMovementsScreen()
                                        : _selectedIndex == 10
                                            ? const NotificationsScreen()
                                            : _selectedIndex == 11
                                                ? const BackupScreen()
                                : _buildPlaceholder(context, _navigationItems[_selectedIndex]),
                  ),
                ],
              ),
            ),
            bottomNavigationBar: isDesktop
                ? null
                : NavigationBar(
                    selectedIndex: _selectedIndex == 0
                        ? 0
                        : _selectedIndex == 1
                            ? 1
                            : _selectedIndex == 3
                                ? 2
                                : 3,
                    onDestinationSelected: (index) {
                      if (index == 3) {
                        _showMoreMenu(context);
                      } else {
                        setState(() => _selectedIndex = index == 2 ? 3 : index);
                        if (index == 0) { _loadDashboardStats(); _loadRecentInvoices(); _loadHomePreferences(); }
                      }
                    },
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.dashboard_rounded),
                        label: 'الرئيسية',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.point_of_sale_rounded),
                        label: 'البيع',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.people_alt_rounded),
                        label: 'الزبائن',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.grid_view_rounded),
                        label: 'المزيد',
                      ),
                    ],
                  ),
          );
        },
      ),
    );
  }

  // قائمة أقسام إضافية للهواتف حتى تبقى جميع الشاشات قابلة للوصول.
  Future<void> _showMoreMenu(BuildContext context) async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('الأقسام الأخرى', style: TextStyle(fontWeight: FontWeight.w800))),
            for (var index = 2; index < _navigationItems.length; index++)
              ListTile(
                leading: Icon(_navigationItems[index].icon),
                title: Text(_navigationItems[index].label),
                onTap: () => Navigator.pop(sheetContext, index),
              ),
          ],
        ),
      ),
    );
    if (selected != null && mounted) setState(() => _selectedIndex = selected);
  }

  // قائمة التنقل الجانبية الخاصة بالشاشات الواسعة.
  Widget _buildSidebar(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 244,
      margin: const EdgeInsets.all(14),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: brandGreen,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(Icons.storefront_rounded, color: Colors.white),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Homi Grocery',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                    ),
                    SizedBox(height: 2),
                    Text('إدارة البقالة', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'القائمة الرئيسية',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: _navigationItems.length,
              itemBuilder: (context, index) {
                final item = _navigationItems[index];
                final selected = _selectedIndex == index;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Material(
                    color: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      selected: selected,
                      selectedTileColor: widget.isDark
                          ? const Color(0xFF315047)
                          : brandMint,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      leading: Icon(
                        item.icon,
                        color: selected
                            ? (widget.isDark ? Colors.white : brandGreen)
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      title: Text(
                        item.label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                          color: selected
                              ? (widget.isDark ? Colors.white : brandGreen)
                              : null,
                        ),
                      ),
                      onTap: () {
                        setState(() => _selectedIndex = index);
                        if (index == 0) { _loadDashboardStats(); _loadRecentInvoices(); _loadHomePreferences(); }
                      },
                    ),
                  ),
                );
              },
            ),
          ),
          Divider(color: theme.dividerColor),
          const ListTile(
            leading: Icon(Icons.sync_rounded, color: brandGreen),
            title: Text('جاهزية العمل دون إنترنت', style: TextStyle(fontSize: 12)),
            subtitle: Text('سيُفعّل الحفظ المحلي مع قاعدة البيانات', style: TextStyle(fontSize: 11)),
            contentPadding: EdgeInsets.symmetric(horizontal: 8),
          ),
        ],
      ),
    );
  }

  // بناء لوحة الملخص؛ تتغير الأعمدة والمسافات بحسب مساحة الشاشة.
  Widget _buildDashboard(BuildContext context, bool isDesktop) {
    final theme = Theme.of(context);
    final horizontalPadding = isDesktop ? 28.0 : 16.0;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(horizontalPadding, 18, horizontalPadding, 28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1400),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _storeName,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '$_timeGreeting  •  $_digitalClock',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: widget.isDark ? 'المظهر الفاتح' : 'المظهر الداكن',
                    onPressed: widget.onToggleTheme,
                    icon: Icon(
                      widget.isDark
                          ? Icons.light_mode_rounded
                          : Icons.dark_mode_rounded,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.user.displayName,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        widget.user.isManager ? 'مدير' : 'كاشير',
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: 'تسجيل الخروج',
                    onPressed: _confirmLogout,
                    icon: const Icon(Icons.logout_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              _buildStatusBanner(context),
              const SizedBox(height: 18),
              LayoutBuilder(
                builder: (context, box) {
                  final columns = box.maxWidth >= 1050
                      ? 4
                      : box.maxWidth >= 620
                          ? 2
                          : 1;
                  return GridView.count(
                    crossAxisCount: columns,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: columns == 1 ? 2.8 : 1.7,
                    children: [
                      _MetricCard(
                        title: 'مبيعات اليوم',
                        value: _stats == null ? '—' : '${_stats!.todaySales} ج.س',
                        note: 'إجمالي الفواتير اليوم',
                        icon: Icons.trending_up_rounded,
                        tint: const Color(0xFFDCE9DF),
                        onTap: () => setState(() => _selectedIndex = 7),
                      ),
                      _MetricCard(
                        title: 'المقبوض اليوم',
                        value: _stats == null ? '—' : '${_stats!.todayPaid} ج.س',
                        note: 'المبالغ المسجلة في فواتير اليوم',
                        icon: Icons.payments_rounded,
                        tint: const Color(0xFFF1E6CC),
                        onTap: () => setState(() => _selectedIndex = 6),
                      ),
                      _MetricCard(
                        title: 'ديون الزبائن',
                        value: _stats == null ? '—' : '${_stats!.customerDebt} ج.س',
                        note: 'الرصيد المستحق بعد التحصيلات',
                        icon: Icons.account_balance_wallet_rounded,
                        tint: const Color(0xFFF3DEDA),
                        onTap: () => setState(() => _selectedIndex = 3),
                      ),
                      _MetricCard(
                        title: 'أصناف منخفضة',
                        value: _stats == null ? '—' : '${_stats!.lowStockCount}',
                        note: 'وصلت إلى حد التنبيه أو أقل',
                        icon: Icons.inventory_2_rounded,
                        tint: const Color(0xFFDDE7F2),
                        onTap: () => setState(() => _selectedIndex = 4),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 22),
              LayoutBuilder(
                builder: (context, box) {
                  final stacked = box.maxWidth < 760;
                  final recentSales = _buildRecentSales(context);
                  final shortcuts = _buildQuickActions(context);
                  if (stacked) {
                    return Column(
                      children: [
                        recentSales,
                        const SizedBox(height: 16),
                        shortcuts,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 3, child: recentSales),
                      const SizedBox(width: 16),
                      Expanded(flex: 2, child: shortcuts),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // شريط يوضح حالة المشروع. لا ندّعي تفعيل التخزين قبل بناء قاعدة البيانات.
  Widget _buildStatusBanner(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            brandGreen,
            brandGreen.withValues(alpha: 0.88),
          ],
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, color: Colors.white, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _statsError == null ? 'ملخص قاعدة البيانات المحلية' : 'تعذر تحميل الإحصاءات',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _statsError == null ? 'الأرقام تُقرأ من قاعدة البيانات على هذا الجهاز.' : 'افتح التطبيق مجددًا أو تحقق من قاعدة البيانات المحلية.',
                  style: const TextStyle(color: Color(0xFFE1EDE6), fontSize: 12),
                ),
              ],
            ),
          ),
          Icon(Icons.verified_user_outlined, color: theme.colorScheme.secondary),
        ],
      ),
    );
  }

  // عرض أحدث الفواتير الحقيقية، مع إعادة المحاولة وحالة فارغة واضحة.
  Widget _buildRecentSales(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('آخر الفواتير', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                ),
                IconButton(
                  tooltip: 'تحديث آخر الفواتير',
                  onPressed: () {
                    setState(() => _recentInvoicesLoading = true);
                    _loadRecentInvoices();
                  },
                  icon: const Icon(Icons.refresh_rounded),
                ),
                TextButton(
                  onPressed: () => setState(() => _selectedIndex = 2),
                  child: const Text('عرض الكل'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_recentInvoicesLoading)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_recentInvoices.isEmpty)
              Column(
                children: [
                  Icon(Icons.receipt_long_outlined, size: 42,
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.45)),
                  const SizedBox(height: 10),
                  const Text('لا توجد فواتير حتى الآن',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 5),
                  Text('ستظهر هنا أحدث عمليات البيع بعد تسجيل فاتورة.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12)),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: () => setState(() => _selectedIndex = 1),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('بدء عملية بيع'),
                  ),
                ],
              )
            else
              ..._recentInvoices.map((invoice) {
                final parsed = DateTime.tryParse(invoice.createdAt)?.toLocal();
                final date = parsed == null ? invoice.createdAt :
                  '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')} ${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.receipt_long_rounded, color: brandGreen),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(invoice.invoiceNumber,
                                style: const TextStyle(fontWeight: FontWeight.w800)),
                              const SizedBox(height: 3),
                              Text('${invoice.customerName} • $date',
                                style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text('${invoice.total} ج.س',
                              style: const TextStyle(fontWeight: FontWeight.w800)),
                            Text(invoice.remaining == 0 ? 'مدفوعة' : 'متبقي ${invoice.remaining} ج.س',
                              style: TextStyle(fontSize: 11,
                                color: invoice.remaining == 0 ? Colors.green : theme.colorScheme.error)),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  // اختصارات تنقل المستخدم مباشرة إلى الأقسام الأكثر استخدامًا.
  Widget _buildQuickActions(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'اختصارات سريعة',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            _QuickAction(
              icon: Icons.point_of_sale_rounded,
              label: 'بدء عملية بيع',
              onTap: () => setState(() => _selectedIndex = 1),
            ),
            _QuickAction(
              icon: Icons.person_add_alt_1_rounded,
              label: 'إضافة زبون',
              onTap: () => setState(() => _selectedIndex = 3),
            ),
            _QuickAction(
              icon: Icons.add_box_rounded,
              label: 'إضافة صنف للمخزون',
              onTap: () => setState(() => _selectedIndex = 4),
            ),
            _QuickAction(
              icon: Icons.account_balance_wallet_rounded,
              label: 'تسجيل مصروف',
              onTap: () => setState(() => _selectedIndex = 6),
            ),
          ],
        ),
      ),
    );
  }

  // شاشة مؤقتة للأقسام التي لم تُنفّذ وظائفها بعد.
  Widget _buildPlaceholder(BuildContext context, _NavigationItem item) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(item.icon, size: 54, color: brandGreen),
                  const SizedBox(height: 16),
                  Text(
                    item.label,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'هذه الشاشة ضمن خطة التنفيذ. سنضيف الوظائف الفعلية والبيانات المحلية بعد اعتماد أساس التطبيق.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: () => setState(() => _selectedIndex = 0),
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: const Text('العودة للرئيسية'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// بطاقة ملخص قابلة لإعادة الاستخدام للأرقام مثل المبيعات والديون.
class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.title,
    required this.value,
    required this.note,
    required this.icon,
    required this.tint,
    required this.onTap,
  });

  final String title;
  final String value;
  final String note;
  final IconData icon;
  final Color tint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ),
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: tint,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(icon, color: brandGreen, size: 20),
                ),
              ],
            ),
            Text(
              value,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: theme.colorScheme.onSurface,
              ),
            ),
            Text(
              note,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 11),
            ),
            ],
          ),
        ),
      ),
    );
  }
}

// عنصر اختصار موحد؛ يستقبل الأيقونة والنص والإجراء عند الضغط.
class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        tileColor: Theme.of(context).scaffoldBackgroundColor,
        leading: Icon(icon, color: brandGreen),
        title: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        trailing: const Icon(Icons.chevron_left_rounded),
        onTap: onTap,
      ),
    );
  }
}

// نموذج بسيط يجمع اسم القسم وأيقونته لتجنب تكرار القيم.
class _NavigationItem {
  const _NavigationItem(this.label, this.icon);

  final String label;
  final IconData icon;
}
