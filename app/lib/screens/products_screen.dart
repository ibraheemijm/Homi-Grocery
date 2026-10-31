// شاشة إدارة الأصناف والمخزون، متصلة بقاعدة SQLite المحلية.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../data/grocery_database.dart';
import '../data/product_repository.dart';

class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});
  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  final _search = TextEditingController();
  ProductRepository? _repository;
  List<GroceryProduct> _products = [];
  bool _showArchived = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  // فتح قاعدة البيانات قبل عرض بيانات الأصناف.
  Future<void> _initialize() async {
    try {
      _repository = ProductRepository(await GroceryDatabase.open());
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'تعذر فتح قاعدة البيانات: $error'; });
    }
  }

  // تحميل القائمة من SQLite وتطبيق البحث الحالي.
  Future<void> _load() async {
    if (_repository == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final rows = await _repository!.search(_search.text, includeInactive: true);
      if (!mounted) return;
      setState(() {
        _products = rows.where((item) => item.isActive != _showArchived).toList(growable: false);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'تعذر تحميل الأصناف: $error'; });
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('الأصناف والمخزون', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 5),
                Text('إدارة الأصناف والأسعار والكميات المحفوظة محليًا', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ])),
              FilledButton.icon(onPressed: _repository == null ? null : () => _edit(), icon: const Icon(Icons.add_rounded), label: const Text('إضافة صنف')),
            ]),
            const SizedBox(height: 14),
            Wrap(spacing: 8, children: [
              ChoiceChip(
                label: const Text('الأصناف النشطة'),
                selected: !_showArchived,
                onSelected: (_) {
                  setState(() => _showArchived = false);
                  _load();
                },
              ),
              ChoiceChip(
                label: const Text('الأصناف المؤرشفة'),
                selected: _showArchived,
                onSelected: (_) {
                  setState(() => _showArchived = true);
                  _load();
                },
              ),
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: _search,
              onChanged: (_) => _load(),
              decoration: InputDecoration(
                hintText: 'ابحث باسم الصنف أو الباركود',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: IconButton(onPressed: () { _search.clear(); _load(); }, icon: const Icon(Icons.close_rounded)),
                filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 14),
            if (_error != null)
              Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.error_outline_rounded, size: 40),
                Text(_error!, textAlign: TextAlign.center),
                OutlinedButton(onPressed: _initialize, child: const Text('إعادة المحاولة')),
              ])))
            else if (_loading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (_products.isEmpty)
              Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.inventory_2_outlined, size: 62, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(height: 12),
                Text(_search.text.isEmpty ? 'لا توجد أصناف مسجلة بعد' : 'لا توجد نتائج مطابقة', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text('أضف الأصناف لتبدأ في تنظيم الأسعار والكميات.', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(onPressed: () => _edit(), icon: const Icon(Icons.add_rounded), label: const Text('إضافة أول صنف')),
              ])))
            else
              Expanded(child: ListView.separated(
                itemCount: _products.length,
                separatorBuilder: (context, index) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final item = _products[index];
                  final low = item.stockQuantity <= item.minimumQuantity;
                  final barcodeText = item.barcode == null ? '' : ' • باركود: ${item.barcode}';
                  return Card(child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: low ? const Color(0xFFF3DEDA) : const Color(0xFFDCE9DF),
                      backgroundImage: item.imagePath != null && File(item.imagePath!).existsSync()
                          ? FileImage(File(item.imagePath!))
                          : null,
                      child: item.imagePath != null && File(item.imagePath!).existsSync()
                          ? null
                          : Icon(low ? Icons.warning_amber_rounded : Icons.inventory_2_rounded, color: const Color(0xFF173D32)),
                    ),
                    title: Text(item.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('شراء: ${item.purchasePrice} ج.س • بيع: ${item.sellingPrice} ج.س\nالمخزون: ${_quantity(item.stockQuantity)} ${item.unit}$barcodeText'),
                    isThreeLine: true,
                    trailing: PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == 'edit') _edit(item);
                        if (value == 'archive') _archive(item);
                        if (value == 'restore') _restore(item);
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'edit', child: Text('تعديل الصنف')),
                        if (item.isActive)
                          const PopupMenuItem(value: 'archive', child: Text('أرشفة الصنف'))
                        else
                          const PopupMenuItem(value: 'restore', child: Text('إعادة تفعيل الصنف')),
                      ],
                    ),
                  ));
                },
              )),
            if (!_loading && _error == null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _showArchived ? 'عدد الأصناف المؤرشفة: ${_products.length}' : 'عدد الأصناف النشطة: ${_products.length}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ]),
        ),
      ),
    );
  }

  // نافذة واحدة لإضافة صنف أو تعديل صنف قائم.
  Future<void> _edit([GroceryProduct? old]) async {
    final key = GlobalKey<FormState>();
    final name = TextEditingController(text: old?.name ?? '');
    final barcode = TextEditingController(text: old?.barcode ?? '');
    final unit = TextEditingController(text: old?.unit ?? 'حبة');
    final buy = TextEditingController(text: '${old?.purchasePrice ?? 0}');
    final sell = TextEditingController(text: '${old?.sellingPrice ?? 0}');
    final stock = TextEditingController(text: '${old?.stockQuantity ?? 0}');
    final minimum = TextEditingController(text: '${old?.minimumQuantity ?? 0}');
    String? imagePath = old?.imagePath;

    final result = await showDialog<GroceryProduct>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, refreshDialog) => AlertDialog(
        title: Text(old == null ? 'إضافة صنف جديد' : 'تعديل بيانات الصنف'),
        content: SizedBox(width: 440, child: SingleChildScrollView(child: Form(
          key: key,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _field(name, 'اسم الصنف', required: true),
            _field(barcode, 'الباركود (اختياري)'),
            Row(children: [Expanded(child: _field(buy, 'سعر الشراء', numeric: true)), const SizedBox(width: 8), Expanded(child: _field(sell, 'سعر البيع', numeric: true))]),
            Row(children: [Expanded(child: _field(stock, 'الكمية الحالية', decimal: true)), const SizedBox(width: 8), Expanded(child: _field(minimum, 'حد التنبيه', decimal: true, nonNegative: true))]),
            _field(unit, 'وحدة القياس', required: true),
            const SizedBox(height: 8),
            if (imagePath != null && File(imagePath!).existsSync())
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(File(imagePath!), height: 120, width: 160, fit: BoxFit.contain),
              )
            else
              const Icon(Icons.image_outlined, size: 54),
            OutlinedButton.icon(
              onPressed: () async {
                try {
                  final picked = await _pickProductImage();
                  if (picked != null) refreshDialog(() => imagePath = picked);
                } catch (error) {
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر اختيار صورة الصنف: $error')));
                }
              },
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(imagePath == null ? 'اختيار صورة للصنف' : 'تغيير صورة الصنف'),
            ),
            const Text('يمكن تسجيل مخزون سالب عند الحاجة.', style: TextStyle(fontSize: 12)),
          ]),
        ))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
          FilledButton(onPressed: () {
            if (!key.currentState!.validate()) return;
            final buyValue = int.tryParse(buy.text.trim());
            final sellValue = int.tryParse(sell.text.trim());
            final stockValue = double.tryParse(stock.text.trim());
            final minValue = double.tryParse(minimum.text.trim());
            if (buyValue == null || sellValue == null || stockValue == null || minValue == null || !stockValue.isFinite || !minValue.isFinite || minValue < 0) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تحقق من الأسعار والكميات المدخلة.')));
              return;
            }
            Navigator.pop(dialogContext, GroceryProduct(
              id: old?.id, name: name.text.trim(),
              barcode: barcode.text.trim().isEmpty ? null : barcode.text.trim(),
              unit: unit.text.trim(), purchasePrice: buyValue, sellingPrice: sellValue,
              stockQuantity: stockValue, minimumQuantity: minValue,
              imagePath: imagePath,
            ));
          }, child: const Text('حفظ')),
        ],
      )),
    );
    name.dispose(); barcode.dispose(); unit.dispose(); buy.dispose(); sell.dispose(); stock.dispose(); minimum.dispose();
    if (result == null || !mounted) return;
    try {
      if (old == null) { await _repository!.add(result); } else { await _repository!.update(result); }
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(old == null ? 'تم حفظ الصنف.' : 'تم تحديث الصنف.')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر الحفظ؛ تحقق من عدم تكرار الباركود. $error')));
    }
  }

  Future<String?> _pickProductImage() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    final sourcePath = result?.files.single.path;
    if (sourcePath == null) return null;
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'product-images'));
    await directory.create(recursive: true);
    final extension = p.extension(sourcePath);
    final target = p.join(
      directory.path,
      'product-${DateTime.now().microsecondsSinceEpoch}${extension.isEmpty ? '.img' : extension}',
    );
    await File(sourcePath).copy(target);
    return target;
  }

  // الأرشفة تحافظ على سجل الصنف بدل حذفه نهائيًا.
  Future<void> _archive(GroceryProduct item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('أرشفة الصنف؟'),
        content: Text('سيختفي "${item.name}" من قائمة الأصناف النشطة دون حذف سجله.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('أرشفة')),
        ],
      ),
    );
    if (ok != true) return;
    try { await _repository!.archive(item.id!); await _load(); }
    catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذرت الأرشفة: $error')));
    }
  }

  // إعادة الصنف المؤرشف إلى قائمة الأصناف المتاحة للبيع والشراء.
  Future<void> _restore(GroceryProduct item) async {
    try {
      await _repository!.restore(item.id!);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تمت إعادة تفعيل ${item.name}.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذرت إعادة تفعيل الصنف: $error')),
      );
    }
  }

  // إنشاء حقل إدخال مع تحقق مناسب للأرقام والنصوص.
  Widget _field(TextEditingController controller, String label, {bool required = false, bool numeric = false, bool decimal = false, bool nonNegative = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        controller: controller,
        keyboardType: numeric || decimal ? const TextInputType.numberWithOptions(decimal: true, signed: true) : TextInputType.text,
        decoration: InputDecoration(labelText: label, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
        validator: (value) {
          final text = value?.trim() ?? '';
          if (required && text.isEmpty) return 'هذا الحقل مطلوب';
          if ((numeric || decimal) && text.isNotEmpty) {
            final parsed = numeric ? int.tryParse(text)?.toDouble() : double.tryParse(text);
            if (parsed == null || !parsed.isFinite) return 'أدخل رقمًا صالحًا';
            if (numeric && parsed < 0) return 'لا يُسمح بالسالب هنا';
            if (nonNegative && parsed < 0) return 'لا يُسمح بالسالب';
          }
          return null;
        },
      ),
    );
  }

  // عرض الكمية دون أصفار عشرية غير ضرورية.
  String _quantity(double value) => value == value.truncateToDouble() ? value.toInt().toString() : value.toString();
}
