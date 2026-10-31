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
    this.imagePath,
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
  final String? imagePath;
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
        'image_path': imagePath,
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
      imagePath: map['image_path'] as String?,
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

  /// إضافة صنف مع منع تكرار الاسم بعد تطبيع المسافات والحروف العربية.
  /// يشمل الفحص الأصناف المؤرشفة حتى لا يُعاد إنشاء الصنف نفسه باسم مختلف شكليًا.
  Future<int> addUnique(GroceryProduct product) async {
    _validate(product);
    return _database.transaction((txn) async {
      final rows = await txn.query('products', columns: ['name']);
      final normalizedName = normalizeProductName(product.name);
      final duplicate = rows.any(
        (row) => normalizeProductName(row['name'] as String) == normalizedName,
      );
      if (duplicate) {
        throw StateError('يوجد صنف بالاسم نفسه أو باسم مطابق بعد توحيد الكتابة.');
      }
      return txn.insert('products', {
        ...product.toMap(),
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }

  /// العثور على صنف بالاسم المطبع، بما في ذلك الأصناف المؤرشفة.
  Future<GroceryProduct?> findByNormalizedName(String name) async {
    final normalizedName = normalizeProductName(name);
    if (normalizedName.isEmpty) return null;
    final rows = await _database.query('products', orderBy: 'id ASC');
    for (final row in rows) {
      if (normalizeProductName(row['name'] as String) == normalizedName) {
        return GroceryProduct.fromMap(row);
      }
    }
    return null;
  }

  /// يؤرشف الصنف المنشأ أثناء فاتورة ملغاة إذا لم يُستخدم في أي عملية.
  /// لا يحذف السجل ولا يمس صنفًا دخل في بيع أو شراء أو حركة مخزون.
  Future<bool> archiveIfUnused(int productId) async {
    return _database.transaction((txn) async {
      final products = await txn.query(
        'products',
        columns: ['stock_quantity'],
        where: 'id = ?',
        whereArgs: [productId],
        limit: 1,
      );
      if (products.isEmpty ||
          (products.single['stock_quantity'] as num).abs() > 0.0000001) {
        return false;
      }
      for (final table in ['sale_items', 'purchase_items', 'stock_movements']) {
        final tableRows = await txn.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
          [table],
        );
        if (tableRows.isEmpty) continue;
        final rows = await txn.rawQuery(
          'SELECT COUNT(*) AS count FROM $table WHERE product_id = ?',
          [productId],
        );
        if ((rows.single['count'] as num).toInt() > 0) return false;
      }
      await txn.update(
        'products',
        {'is_active': 0},
        where: 'id = ?',
        whereArgs: [productId],
      );
      return true;
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

  /// تحديث سعر البيع فقط دون تغيير تكلفة الشراء أو كمية المخزون.
  Future<int> updateSellingPrice({required int productId, required int sellingPrice}) async {
    if (productId <= 0 || sellingPrice < 0) {
      throw ArgumentError('معرّف الصنف أو سعر البيع غير صالح.');
    }
    return _database.update(
      'products',
      {'selling_price': sellingPrice},
      where: 'id = ?',
      whereArgs: [productId],
    );
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


/// توحيد اختلافات الكتابة الشائعة في أسماء الأصناف العربية قبل المقارنة.
String normalizeProductName(String value) {
  return value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\u064B-\u065F\u0670\u0640]'), '')
      .replaceAll(RegExp(r'[أإآٱ]'), 'ا')
      .replaceAll('ى', 'ي')
      .replaceAll(RegExp(r'\s+'), ' ');
}
