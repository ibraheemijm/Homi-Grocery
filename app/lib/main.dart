// المكتبة الأساسية لبناء واجهات Flutter وعناصر Material Design.
import 'package:flutter/material.dart';

import 'screens/products_screen.dart';
import 'screens/sales_screen.dart';

// نقطة تشغيل التطبيق: تُنشئ واجهة Homi Grocery وتعرضها للمستخدم.


void main() {
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
    return MaterialApp(
      title: 'Homi Grocery',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: DashboardScreen(
        isDark: _themeMode == ThemeMode.dark,
        onToggleTheme: _toggleTheme,
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
    super.key,
  });

  final bool isDark;
  final VoidCallback onToggleTheme;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedIndex = 0;

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
                            ? const SalesScreen()
                            : _selectedIndex == 4
                                ? const ProductsScreen()
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
                  child: ListTile(
                    selected: selected,
                    selectedTileColor: brandMint,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    leading: Icon(
                      item.icon,
                      color: selected ? brandGreen : theme.colorScheme.onSurfaceVariant,
                    ),
                    title: Text(
                      item.label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected ? brandGreen : null,
                      ),
                    ),
                    onTap: () => setState(() => _selectedIndex = index),
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
                          'الرئيسية',
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          'ملخص نشاط البقالة اليوم',
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
                  const CircleAvatar(
                    backgroundColor: brandMint,
                    foregroundColor: brandGreen,
                    child: Icon(Icons.person_rounded),
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
                    children: const [
                      _MetricCard(
                        title: 'مبيعات اليوم',
                        value: '0 ج.س',
                        note: 'إجمالي الفواتير اليوم',
                        icon: Icons.trending_up_rounded,
                        tint: Color(0xFFDCE9DF),
                      ),
                      _MetricCard(
                        title: 'المقبوض نقدًا',
                        value: '0 ج.س',
                        note: 'المبالغ المستلمة اليوم',
                        icon: Icons.payments_rounded,
                        tint: Color(0xFFF1E6CC),
                      ),
                      _MetricCard(
                        title: 'ديون الزبائن',
                        value: '0 ج.س',
                        note: 'إجمالي الرصيد المستحق',
                        icon: Icons.account_balance_wallet_rounded,
                        tint: Color(0xFFF3DEDA),
                      ),
                      _MetricCard(
                        title: 'أصناف منخفضة',
                        value: '0',
                        note: 'تحتاج إلى مراجعة المخزون',
                        icon: Icons.inventory_2_rounded,
                        tint: Color(0xFFDDE7F2),
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
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'واجهة أولية قيد التطوير',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'سيُضاف التخزين المحلي قبل استخدام بيانات المتجر الحقيقية.',
                  style: TextStyle(color: Color(0xFFE1EDE6), fontSize: 12),
                ),
              ],
            ),
          ),
          Icon(Icons.verified_user_outlined, color: theme.colorScheme.secondary),
        ],
      ),
    );
  }

  // مساحة عرض آخر الفواتير؛ ستُربط لاحقًا ببيانات قاعدة البيانات.
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
                  child: Text(
                    'آخر الفواتير',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _selectedIndex = 2),
                  child: const Text('عرض الكل'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Icon(Icons.receipt_long_outlined,
                size: 42, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.45)),
            const SizedBox(height: 10),
            const Text(
              'لا توجد فواتير حتى الآن',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 5),
            Text(
              'ستظهر هنا أحدث عمليات البيع بعد تسجيل أول فاتورة.',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () => setState(() => _selectedIndex = 1),
              icon: const Icon(Icons.add_rounded),
              label: const Text('بدء عملية بيع'),
            ),
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
  });

  final String title;
  final String value;
  final String note;
  final IconData icon;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
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
