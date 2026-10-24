// عمليات الأصناف الأساسية. لا تضع منطق الواجهة أو تنسيق الأرقام في هذا الملف.
import 'package:sqflite/sqflite.dart';

/// نموذج صنف بسيط؛ الأسعار مخزنة كأعداد صحيحة لتجنب أخطاء الكسور العشرية.
class GroceryProduct {
  const GroceryProduct({
    this.id,
    this.barcode,
    required this.name,
    this.unit = 'حبة',
    this.purchasePrice = 0,
    this.sellingPrice = 0,
    this.stockQuantity = 0,
    this.minimumQuantity = 0,
    this.isActive = true,
  });

  final int? id;
  final String? barcode;
  final String name;
  final String unit;
  final int purchasePrice;
  final int sellingPrice;
  final double stockQuantity;
  final double minimumQuantity;
  final bool isActive;

  /// تحويل النموذج إلى صيغة تخزين SQLite.
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'barcode': barcode?.trim().isEmpty == true ? null : barcode?.trim(),
        'name': name.trim(),
        'unit': unit.trim(),
        'purchase_price': purchasePrice,
        'selling_price': sellingPrice,
        'stock_quantity': stockQuantity,
        'minimum_quantity': minimumQuantity,
        'is_active': isActive ? 1 : 0,
      };

  /// بناء نموذج من صف قاعدة البيانات.
  factory GroceryProduct.fromMap(Map<String, Object?> map) {
    return GroceryProduct(
      id: map['id'] as int,
      barcode: map['barcode'] as String?,
      name: map['name'] as String,
      unit: map['unit'] as String,
      purchasePrice: map['purchase_price'] as int,
      sellingPrice: map['selling_price'] as int,
      stockQuantity: (map['stock_quantity'] as num).toDouble(),
      minimumQuantity: (map['minimum_quantity'] as num).toDouble(),
      isActive: (map['is_active'] as int) == 1,
    );
  }
}

/// مستودع الأصناف: يوفر عمليات آمنة قابلة للاختبار دون ارتباط مباشر بالواجهة.
class ProductRepository {
  ProductRepository(this._database);

  final Database _database;

  /// حفظ صنف جديد بعد التحقق من الحقول الأساسية.
  Future<int> add(GroceryProduct product) async {
    _validate(product);
    return _database.insert('products', {
      ...product.toMap(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// تحديث بيانات صنف موجود، مع التأكد من وجود معرّف له.
  Future<int> update(GroceryProduct product) async {
    _validate(product);
    final id = product.id;
    if (id == null) {
      throw ArgumentError('لا يمكن تحديث صنف دون معرّف.');
    }
    return _database.update(
      'products',
      product.toMap()..remove('id'),
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// البحث بالاسم أو الباركود مع إظهار الأصناف النشطة فقط افتراضيًا.
  Future<List<GroceryProduct>> search(
    String query, {
    bool includeInactive = false,
  }) async {
    final term = query.trim();
    final rows = await _database.query(
      'products',
      where: includeInactive
          ? '(name LIKE ? OR barcode LIKE ?)'
          : 'is_active = 1 AND (name LIKE ? OR barcode LIKE ?)',
      whereArgs: ['%$term%', '%$term%'],
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return rows.map(GroceryProduct.fromMap).toList(growable: false);
  }

  /// جلب صنف واحد حسب معرّفه؛ ترجع null إذا لم يوجد.
  Future<GroceryProduct?> getById(int id) async {
    final rows = await _database.query(
      'products',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : GroceryProduct.fromMap(rows.first);
  }

  /// تعطيل الصنف بدل حذفه نهائيًا للحفاظ على سلامة سجل العمليات المستقبلية.
  Future<int> archive(int id) {
    return _database.update(
      'products',
      {'is_active': 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  void _validate(GroceryProduct product) {
    if (product.name.trim().isEmpty) {
      throw ArgumentError('اسم الصنف مطلوب.');
    }
    if (product.unit.trim().isEmpty) {
      throw ArgumentError('وحدة الصنف مطلوبة.');
    }
    if (product.purchasePrice < 0 || product.sellingPrice < 0) {
      throw ArgumentError('لا يُسمح بأن تكون الأسعار سالبة.');
    }
    // المخزون السالب مسموح وفق متطلبات المشروع، لكن يجب أن تكون الكمية رقمًا صالحًا.
    if (!product.stockQuantity.isFinite ||
        !product.minimumQuantity.isFinite ||
        product.minimumQuantity < 0) {
      throw ArgumentError('كمية المخزون أو حد التنبيه غير صالح.');
    }
  }
}
