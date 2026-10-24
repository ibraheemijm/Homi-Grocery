// مستودع الموردين والمشتريات: حفظ ذري للفواتير وتحديث المخزون والمدفوعات.
import 'package:sqflite/sqflite.dart';

class SupplierBalance {
  const SupplierBalance({required this.id, required this.name, required this.purchaseCount, required this.totalDebt, required this.totalPaid});
  final int id;
  final String name;
  final int purchaseCount;
  final int totalDebt;
  final int totalPaid;
  int get balance => totalDebt - totalPaid;
  int get credit => (-balance).clamp(0, 1 << 62).toInt();
}

class PurchaseLine {
  const PurchaseLine({required this.productId, required this.productName, required this.unit, required this.quantity, required this.unitCost});
  final int productId;
  final String productName;
  final String unit;
  final double quantity;
  final int unitCost;
  int get lineTotal => (quantity * unitCost).round();
}

class PurchaseRecord {
  const PurchaseRecord({required this.id, required this.invoiceNumber, required this.supplierId, required this.subtotal, required this.discount, required this.total, required this.paidAmount, required this.createdAt});
  final int id;
  final String invoiceNumber;
  final int supplierId;
  final int subtotal;
  final int discount;
  final int total;
  final int paidAmount;
  final String createdAt;
  int get remainingAmount => (total - paidAmount).clamp(0, 1 << 62).toInt();
}

class PurchaseHistoryRecord {
  const PurchaseHistoryRecord({
    required this.id,
    required this.invoiceNumber,
    required this.supplierName,
    required this.subtotal,
    required this.discount,
    required this.total,
    required this.paidAmount,
    required this.paymentMethod,
    required this.createdAt,
    this.note,
  });

  final int id;
  final String invoiceNumber;
  final String supplierName;
  final int subtotal;
  final int discount;
  final int total;
  final int paidAmount;
  final String paymentMethod;
  final String createdAt;
  final String? note;

  int get remainingAmount => (total - paidAmount).clamp(0, 1 << 62).toInt();
}

class PurchaseItemRecord {
  const PurchaseItemRecord({
    required this.productName,
    required this.unit,
    required this.quantity,
    required this.unitCost,
    required this.lineTotal,
  });

  final String productName;
  final String unit;
  final double quantity;
  final int unitCost;
  final int lineTotal;
}

class SupplierRepository {
  SupplierRepository(this._database);
  final Database _database;

  Future<int> addSupplier({required String name, String? phone, String? notes}) async {
    final normalized = name.trim();
    if (normalized.isEmpty) throw ArgumentError('اسم المورد مطلوب.');
    final id = await _database.insert('suppliers', {
      'name': normalized,
      'phone': phone?.trim().isEmpty == true ? null : phone?.trim(),
      'notes': notes?.trim().isEmpty == true ? null : notes?.trim(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    if (id != 0) return id;
    final rows = await _database.query('suppliers', columns: ['id'], where: 'name = ? COLLATE NOCASE', whereArgs: [normalized], limit: 1);
    if (rows.isEmpty) throw StateError('تعذر حفظ المورد.');
    return rows.first['id'] as int;
  }

  Future<List<SupplierBalance>> balances({String query = ''}) async {
    final rows = await _database.rawQuery('''
      SELECT s.id, s.name,
        (SELECT COUNT(*) FROM purchases p WHERE p.supplier_id = s.id) AS purchase_count,
        COALESCE((SELECT SUM(p.total - p.paid_amount) FROM purchases p WHERE p.supplier_id = s.id), 0) AS total_debt,
        COALESCE((SELECT SUM(sp.amount) FROM supplier_payments sp WHERE sp.supplier_id = s.id), 0) + COALESCE((SELECT SUM(sr.amount) FROM supplier_returns sr JOIN purchases rp ON rp.id = sr.purchase_id WHERE rp.supplier_id = s.id), 0)
          - COALESCE((SELECT SUM(srr.amount) FROM supplier_return_refunds srr JOIN supplier_returns sr ON sr.id = srr.supplier_return_id JOIN purchases rp ON rp.id = sr.purchase_id WHERE rp.supplier_id = s.id), 0) AS total_paid
      FROM suppliers s WHERE s.name LIKE ?
      ORDER BY (COALESCE((SELECT SUM(p.total - p.paid_amount) FROM purchases p WHERE p.supplier_id = s.id), 0)
        - COALESCE((SELECT SUM(sp.amount) FROM supplier_payments sp WHERE sp.supplier_id = s.id), 0)
        - COALESCE((SELECT SUM(sr.amount) FROM supplier_returns sr JOIN purchases rp ON rp.id = sr.purchase_id WHERE rp.supplier_id = s.id), 0)
        + COALESCE((SELECT SUM(srr.amount) FROM supplier_return_refunds srr JOIN supplier_returns sr ON sr.id = srr.supplier_return_id JOIN purchases rp ON rp.id = sr.purchase_id WHERE rp.supplier_id = s.id), 0)) DESC,
        s.name COLLATE NOCASE ASC
    ''', ['%${query.trim()}%']);
    return rows.map((r) => SupplierBalance(
      id: r['id'] as int, name: r['name'] as String,
      purchaseCount: (r['purchase_count'] as num).toInt(),
      totalDebt: (r['total_debt'] as num).toInt(),
      totalPaid: (r['total_paid'] as num).toInt(),
    )).toList(growable: false);
  }

  Future<PurchaseRecord> createPurchase({
    required int supplierId,
    required List<PurchaseLine> lines,
    int discount = 0,
    required int paidAmount,
    String paymentMethod = 'آجل',
    String? note,
  }) async {
    if (lines.isEmpty) throw ArgumentError('أضف صنفًا واحدًا على الأقل.');
    if (discount < 0 || paidAmount < 0) throw ArgumentError('الخصم والمدفوع لا يمكن أن يكونا سالبين.');
    for (final line in lines) {
      if (line.productId <= 0 || !line.quantity.isFinite || line.quantity <= 0 || line.unitCost < 0) {
        throw ArgumentError('تحقق من كميات وأسعار أصناف الشراء.');
      }
    }
    return _database.transaction((txn) async {
      final supplier = await txn.query('suppliers', columns: ['id'], where: 'id = ?', whereArgs: [supplierId], limit: 1);
      if (supplier.isEmpty) throw StateError('المورد غير موجود.');
      final subtotal = lines.fold<int>(0, (sum, line) => sum + line.lineTotal);
      if (discount > subtotal) throw ArgumentError('الخصم يتجاوز إجمالي الشراء.');
      final total = subtotal - discount;
      if (paidAmount > total) throw ArgumentError('المدفوع يتجاوز إجمالي الفاتورة.');
      final now = DateTime.now().toUtc().toIso8601String();
      final invoiceNumber = 'PUR-${DateTime.now().toUtc().microsecondsSinceEpoch}';
      final purchaseId = await txn.insert('purchases', {
        'invoice_number': invoiceNumber, 'supplier_id': supplierId,
        'subtotal': subtotal, 'discount': discount, 'total': total,
        'paid_amount': paidAmount, 'payment_method': paymentMethod,
        'note': note?.trim().isEmpty == true ? null : note?.trim(), 'created_at': now,
      });
      if (paidAmount > 0) {
        await txn.insert('cash_transactions', {
          'direction': 'out',
          'category': 'شراء مدفوع',
          'amount': paidAmount,
          'payment_method': paymentMethod,
          'reference_type': 'purchase',
          'reference_id': purchaseId,
          'note': 'فاتورة شراء $invoiceNumber',
          'created_at': now,
        });
      }
      for (final line in lines) {
        final products = await txn.query('products', columns: ['id', 'stock_quantity'], where: 'id = ?', whereArgs: [line.productId], limit: 1);
        if (products.isEmpty) throw ArgumentError('أحد أصناف الشراء غير موجود.');
        final before = (products.single['stock_quantity'] as num).toDouble();
        final after = before + line.quantity;
        await txn.update('products', {'stock_quantity': after, 'purchase_price': line.unitCost}, where: 'id = ?', whereArgs: [line.productId]);
        await txn.insert('purchase_items', {
          'purchase_id': purchaseId, 'product_id': line.productId,
          'product_name': line.productName, 'unit': line.unit,
          'quantity': line.quantity, 'unit_cost': line.unitCost, 'line_total': line.lineTotal,
        });
        await txn.insert('stock_movements', {
          'product_id': line.productId, 'movement_type': 'شراء',
          'quantity_delta': line.quantity, 'stock_before': before, 'stock_after': after,
          'note': note?.trim().isEmpty == true ? 'فاتورة $invoiceNumber' : note?.trim(),
          'reference_type': 'purchase', 'reference_id': purchaseId, 'created_at': now,
        });
      }
      return PurchaseRecord(id: purchaseId, invoiceNumber: invoiceNumber, supplierId: supplierId,
        subtotal: subtotal, discount: discount, total: total, paidAmount: paidAmount, createdAt: now);
    });
  }

  /// يعرض سجل فواتير الشراء الأحدث أولًا، مع اسم المورد والمبالغ المحاسبية.
  Future<List<PurchaseHistoryRecord>> purchaseHistory({
    int? supplierId,
    int limit = 100,
  }) async {
    if (limit < 1 || limit > 1000) {
      throw ArgumentError('حد نتائج سجل المشتريات غير صالح.');
    }
    final rows = await _database.rawQuery('''
      SELECT p.id, p.invoice_number, p.supplier_id, s.name AS supplier_name,
        p.subtotal, p.discount, p.total, p.paid_amount, p.payment_method,
        p.note, p.created_at
      FROM purchases p
      JOIN suppliers s ON s.id = p.supplier_id
      WHERE (? IS NULL OR p.supplier_id = ?)
      ORDER BY p.created_at DESC, p.id DESC
      LIMIT ?
    ''', [supplierId, supplierId, limit]);
    return rows.map((row) => PurchaseHistoryRecord(
      id: row['id'] as int,
      invoiceNumber: row['invoice_number'] as String,
      supplierName: row['supplier_name'] as String,
      subtotal: (row['subtotal'] as num).toInt(),
      discount: (row['discount'] as num).toInt(),
      total: (row['total'] as num).toInt(),
      paidAmount: (row['paid_amount'] as num).toInt(),
      paymentMethod: row['payment_method'] as String,
      note: row['note'] as String?,
      createdAt: row['created_at'] as String,
    )).toList(growable: false);
  }

  /// يعرض البنود المحفوظة كما كانت وقت الشراء، لا حسب بيانات الصنف الحالية.
  Future<List<PurchaseItemRecord>> purchaseItems(int purchaseId) async {
    final rows = await _database.query(
      'purchase_items',
      columns: ['product_name', 'unit', 'quantity', 'unit_cost', 'line_total'],
      where: 'purchase_id = ?',
      whereArgs: [purchaseId],
      orderBy: 'id ASC',
    );
    return rows.map((row) => PurchaseItemRecord(
      productName: row['product_name'] as String,
      unit: row['unit'] as String,
      quantity: (row['quantity'] as num).toDouble(),
      unitCost: (row['unit_cost'] as num).toInt(),
      lineTotal: (row['line_total'] as num).toInt(),
    )).toList(growable: false);
  }

  /// يعيد أصنافًا من فاتورة شراء، ويحدّث المخزون والمستحق وسجل الحركة ذريًا.
  /// لتجنب رصيد دائن غير ممثل بعد، لا يسمح بإرجاع قيمة أكبر من المستحق الحالي للمورد.
  Future<int> createSupplierReturn({
    required int purchaseId,
    required Map<int, double> quantitiesByPurchaseItemId,
    String? note,
  }) async {
    if (quantitiesByPurchaseItemId.isEmpty ||
        quantitiesByPurchaseItemId.values.any((q) => !q.isFinite || q <= 0)) {
      throw ArgumentError('حدد كميات مرتجع صالحة.');
    }
    return _database.transaction((txn) async {
      final purchases = await txn.query(
        'purchases',
        columns: ['id', 'supplier_id', 'invoice_number', 'subtotal', 'total'],
        where: 'id = ?',
        whereArgs: [purchaseId],
        limit: 1,
      );
      if (purchases.isEmpty) throw StateError('فاتورة الشراء غير موجودة.');
      final purchase = purchases.single;
      final now = DateTime.now().toUtc().toIso8601String();
      final selectedLines = <Map<String, Object?>>[];
      var total = 0;
      for (final entry in quantitiesByPurchaseItemId.entries) {
        final rows = await txn.rawQuery('''
          SELECT pi.id, pi.product_id, pi.product_name, pi.quantity, pi.unit_cost, pi.line_total,
            p.subtotal AS purchase_subtotal, p.total AS purchase_total, pr.stock_quantity,
            COALESCE((SELECT SUM(sri.quantity) FROM supplier_return_items sri WHERE sri.purchase_item_id = pi.id), 0) AS returned_quantity,
            COALESCE((SELECT SUM(sri.line_total) FROM supplier_return_items sri WHERE sri.purchase_item_id = pi.id), 0) AS returned_amount
          FROM purchase_items pi
          JOIN purchases p ON p.id = pi.purchase_id
          JOIN products pr ON pr.id = pi.product_id
          WHERE pi.id = ? AND pi.purchase_id = ?
        ''', [entry.key, purchaseId]);
        if (rows.isEmpty) throw ArgumentError('أحد أصناف المرتجع لا يتبع فاتورة الشراء المحددة.');
        final row = rows.single;
        final original = (row['quantity'] as num).toDouble();
        final alreadyReturned = (row['returned_quantity'] as num).toDouble();
        final stock = (row['stock_quantity'] as num).toDouble();
        final quantity = entry.value;
        if (quantity > original - alreadyReturned + 0.0000001) {
          throw ArgumentError('كمية المرتجع تتجاوز الكمية المتبقية من فاتورة الشراء.');
        }
        if (quantity > stock + 0.0000001) {
          throw ArgumentError('المخزون الحالي لا يكفي لإرجاع هذه الكمية.');
        }
        final unitCost = (row['unit_cost'] as num).toInt();
        final originalLineTotal = (row['line_total'] as num).toInt();
        final purchaseSubtotal = (row['purchase_subtotal'] as num).toInt();
        final purchaseTotal = (row['purchase_total'] as num).toInt();
        final previousAmount = (row['returned_amount'] as num).toInt();
        // يوزّع خصم فاتورة الشراء نسبيًا على البنود، ويستخدم المجموع التراكمي
        // حتى لا تختلف القيمة إذا قُسّم إرجاع الكمية إلى عمليات متعددة.
        final cumulativeAmount = purchaseSubtotal == 0
            ? 0
            : (originalLineTotal * purchaseTotal * (alreadyReturned + quantity) /
                    (purchaseSubtotal * original))
                .round();
        final lineTotal = (cumulativeAmount - previousAmount)
            .clamp(0, originalLineTotal)
            .toInt();
        total += lineTotal;
        selectedLines.add({
          'purchase_item_id': entry.key,
          'product_id': row['product_id'] as int,
          'product_name': row['product_name'] as String,
          'quantity': quantity,
          'unit_cost': unitCost,
          'line_total': lineTotal,
          'stock_before': stock,
        });
      }
      if (total <= 0) throw ArgumentError('قيمة المرتجع يجب أن تكون أكبر من صفر.');
      final returnId = await txn.insert('supplier_returns', {
        'purchase_id': purchaseId,
        'amount': total,
        'note': note?.trim().isEmpty == true ? null : note?.trim(),
        'created_at': now,
      });
      for (final line in selectedLines) {
        final before = line['stock_before'] as double;
        final quantity = line['quantity'] as double;
        final after = before - quantity;
        await txn.update('products', {'stock_quantity': after}, where: 'id = ?', whereArgs: [line['product_id']]);
        await txn.insert('supplier_return_items', {
          'return_id': returnId,
          'purchase_item_id': line['purchase_item_id'],
          'product_id': line['product_id'],
          'product_name': line['product_name'],
          'quantity': quantity,
          'unit_cost': line['unit_cost'],
          'line_total': line['line_total'],
        });
        await txn.insert('stock_movements', {
          'product_id': line['product_id'],
          'movement_type': 'مرتجع شراء',
          'quantity_delta': -quantity,
          'stock_before': before,
          'stock_after': after,
          'note': note?.trim().isEmpty == true ? 'مرتجع فاتورة ${purchase['invoice_number']}' : note?.trim(),
          'reference_type': 'supplier_return',
          'reference_id': returnId,
          'created_at': now,
        });
      }
      return returnId;
    });
  }

  /// بنود فاتورة الشراء مع الكميات المتبقية القابلة للإرجاع.
  Future<List<Map<String, Object?>>> returnablePurchaseItems(int purchaseId) async {
    return _database.rawQuery('''
      SELECT pi.id, pi.product_id, pi.product_name, pi.unit, pi.quantity,
        pi.unit_cost, pi.line_total, pr.stock_quantity,
        MAX(0, pi.quantity - COALESCE((SELECT SUM(sri.quantity)
          FROM supplier_return_items sri WHERE sri.purchase_item_id = pi.id), 0)) AS returnable_quantity
      FROM purchase_items pi
      JOIN products pr ON pr.id = pi.product_id
      WHERE pi.purchase_id = ?
      ORDER BY pi.id ASC
    ''', [purchaseId]);
  }

  /// أقصى مبلغ لم يُسترد نقديًا بعد من مرتجع مورد.
  Future<int> maximumRefundableSupplierReturnAmount(int returnId) async {
    final rows = await _database.rawQuery('''
      SELECT MAX(0, sr.amount - COALESCE((
        SELECT SUM(srr.amount) FROM supplier_return_refunds srr
        WHERE srr.supplier_return_id = sr.id
      ), 0)) AS refundable
      FROM supplier_returns sr WHERE sr.id = ? LIMIT 1
    ''', [returnId]);
    if (rows.isEmpty) throw StateError('مرتجع المورد غير موجود.');
    return (rows.single['refundable'] as num).toInt();
  }

  /// تسجيل رد نقدي/بنكي وصل فعليًا من المورد؛ يظل الرصيد الدائن منفصلًا عن الخزينة.
  Future<int> recordSupplierReturnRefund({
    required int returnId,
    required int amount,
    String paymentMethod = 'نقدي',
    String? note,
  }) async {
    if (returnId <= 0 || amount <= 0) {
      throw ArgumentError('حدد مرتجعًا ومبلغ رد صالحين.');
    }
    if (paymentMethod.trim().isEmpty) {
      throw ArgumentError('حدد طريقة استلام المبلغ.');
    }
    return _database.transaction((txn) async {
      final rows = await txn.rawQuery('''
        SELECT sr.id, sr.amount FROM supplier_returns sr WHERE sr.id = ? LIMIT 1
      ''', [returnId]);
      if (rows.isEmpty) throw StateError('مرتجع المورد غير موجود.');
      final availableRows = await txn.rawQuery('''
        SELECT MAX(0, sr.amount - COALESCE((
          SELECT SUM(srr.amount) FROM supplier_return_refunds srr
          WHERE srr.supplier_return_id = sr.id
        ), 0)) AS refundable
        FROM supplier_returns sr WHERE sr.id = ? LIMIT 1
      ''', [returnId]);
      final available = (availableRows.single['refundable'] as num).toInt();
      if (amount > available) {
        throw ArgumentError('المبلغ أكبر من رصيد المرتجع المتاح للاسترداد ($available ج.س).');
      }
      final createdAt = DateTime.now().toUtc().toIso8601String();
      final refundId = await txn.insert('supplier_return_refunds', {
        'supplier_return_id': returnId,
        'amount': amount,
        'payment_method': paymentMethod.trim(),
        'note': note?.trim().isEmpty == true ? null : note?.trim(),
        'created_at': createdAt,
      });
      await txn.insert('cash_transactions', {
        'direction': 'in',
        'category': 'استرداد نقدي من مورد',
        'amount': amount,
        'payment_method': paymentMethod.trim(),
        'reference_type': 'supplier_return_refund',
        'reference_id': refundId,
        'note': note?.trim().isEmpty == true ? 'استرداد مرتجع المورد #$returnId' : note?.trim(),
        'created_at': createdAt,
      });
      return refundId;
    });
  }

  Future<void> recordPayment({required int supplierId, required int amount, String? note}) async {
    if (amount <= 0) throw ArgumentError('قيمة الدفع يجب أن تكون أكبر من صفر.');
    await _database.transaction((txn) async {
      final suppliers = await txn.query('suppliers', columns: ['id'], where: 'id = ?', whereArgs: [supplierId], limit: 1);
      if (suppliers.isEmpty) throw StateError('المورد غير موجود.');
      final result = await txn.rawQuery('''
        SELECT COALESCE((SELECT SUM(total - paid_amount) FROM purchases WHERE supplier_id = ?), 0) AS debt,
          COALESCE((SELECT SUM(amount) FROM supplier_payments WHERE supplier_id = ?), 0) +
          COALESCE((SELECT SUM(sr.amount) FROM supplier_returns sr JOIN purchases p ON p.id = sr.purchase_id WHERE p.supplier_id = ?), 0) -
          COALESCE((SELECT SUM(srr.amount) FROM supplier_return_refunds srr JOIN supplier_returns sr ON sr.id = srr.supplier_return_id JOIN purchases p ON p.id = sr.purchase_id WHERE p.supplier_id = ?), 0) AS paid
      ''', [supplierId, supplierId, supplierId, supplierId]);
      final outstanding = ((result.first['debt'] as num).toInt() - (result.first['paid'] as num).toInt()).clamp(0, 1 << 62).toInt();
      if (amount > outstanding) throw ArgumentError('الدفع يتجاوز المستحق للمورد ($outstanding ج.س).');
      final createdAt = DateTime.now().toUtc().toIso8601String();
      final paymentId = await txn.insert('supplier_payments', {
        'supplier_id': supplierId, 'amount': amount,
        'note': note?.trim().isEmpty == true ? null : note?.trim(),
        'created_at': createdAt,
      });
      await txn.insert('cash_transactions', {
        'direction': 'out',
        'category': 'سداد للمورد',
        'amount': amount,
        'payment_method': 'نقدي',
        'reference_type': 'supplier_payment',
        'reference_id': paymentId,
        'note': note?.trim().isEmpty == true ? null : note?.trim(),
        'created_at': createdAt,
      });
    });
  }
}
