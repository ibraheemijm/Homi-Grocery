// مستودع الموردين والمشتريات: حفظ ذري للفواتير وتحديث المخزون والمدفوعات.
import 'package:sqflite/sqflite.dart';

class SupplierBalance {
  const SupplierBalance({required this.id, required this.name, required this.purchaseCount, required this.totalDebt, required this.totalPaid});
  final int id;
  final String name;
  final int purchaseCount;
  final int totalDebt;
  final int totalPaid;
  int get balance => (totalDebt - totalPaid).clamp(0, 1 << 62).toInt();
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
        COALESCE((SELECT SUM(sp.amount) FROM supplier_payments sp WHERE sp.supplier_id = s.id), 0) AS total_paid
      FROM suppliers s WHERE s.name LIKE ?
      ORDER BY (COALESCE((SELECT SUM(p.total - p.paid_amount) FROM purchases p WHERE p.supplier_id = s.id), 0)
        - COALESCE((SELECT SUM(sp.amount) FROM supplier_payments sp WHERE sp.supplier_id = s.id), 0)) DESC,
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

  Future<void> recordPayment({required int supplierId, required int amount, String? note}) async {
    if (amount <= 0) throw ArgumentError('قيمة الدفع يجب أن تكون أكبر من صفر.');
    await _database.transaction((txn) async {
      final suppliers = await txn.query('suppliers', columns: ['id'], where: 'id = ?', whereArgs: [supplierId], limit: 1);
      if (suppliers.isEmpty) throw StateError('المورد غير موجود.');
      final result = await txn.rawQuery('''
        SELECT COALESCE((SELECT SUM(total - paid_amount) FROM purchases WHERE supplier_id = ?), 0) AS debt,
          COALESCE((SELECT SUM(amount) FROM supplier_payments WHERE supplier_id = ?), 0) AS paid
      ''', [supplierId, supplierId]);
      final outstanding = ((result.first['debt'] as num).toInt() - (result.first['paid'] as num).toInt()).clamp(0, 1 << 62).toInt();
      if (amount > outstanding) throw ArgumentError('الدفع يتجاوز المستحق للمورد ($outstanding ج.س).');
      await txn.insert('supplier_payments', {
        'supplier_id': supplierId, 'amount': amount,
        'note': note?.trim().isEmpty == true ? null : note?.trim(),
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }
}
