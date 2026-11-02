// عمليات البيع والفواتير داخل معاملات SQLite لضمان حفظ الفاتورة والمخزون معًا.
import 'package:sqflite/sqflite.dart';

import 'auth_repository.dart';
import 'manager_approval_repository.dart';
import 'product_repository.dart';
import 'cash_shift_repository.dart';

class SaleLine {
  const SaleLine({required this.product, required this.quantity});

  final GroceryProduct product;
  final double quantity;

  int get lineTotal => (product.sellingPrice * quantity).round();
}

class SaleRecord {
  const SaleRecord({
    required this.id,
    required this.invoiceNumber,
    required this.total,
    required this.paidAmount,
    required this.paymentMethod,
    required this.createdAt,
    this.customerName,
    this.overpaymentAmount = 0,
  });

  final int id;
  final String invoiceNumber;
  final int total;
  final int paidAmount;
  final String paymentMethod;
  final String createdAt;
  final String? customerName;
  final int overpaymentAmount;

  int get remainingAmount => total - paidAmount;

  factory SaleRecord.fromMap(Map<String, Object?> map) => SaleRecord(
        id: map['id'] as int,
        invoiceNumber: map['invoice_number'] as String,
        total: map['total'] as int,
        paidAmount: map['paid_amount'] as int,
        paymentMethod: map['payment_method'] as String,
        createdAt: map['created_at'] as String,
        customerName: map['customer_name'] as String?,
        overpaymentAmount: (map['overpayment_amount'] as num?)?.toInt() ?? 0,
      );
}

class SaleReturnRecord {
  const SaleReturnRecord({
    required this.id,
    required this.saleId,
    required this.amount,
    required this.createdAt,
  });

  final int id;
  final int saleId;
  final int amount;
  final String createdAt;
}

class ManagerApprovalRequiredException implements Exception {
  const ManagerApprovalRequiredException(this.amount);
  final int amount;

  @override
  String toString() => 'يتطلب المرتجع البالغ $amount ج.س موافقة المدير.';
}

class SaleRepository {
  SaleRepository(this._database, {DateTime Function()? clock})
      : _managerApprovals = ManagerApprovalRepository(
          _database,
          AuthRepository(_database),
          clock: clock,
        );

  final Database _database;
  final ManagerApprovalRepository _managerApprovals;

  /// يحدد من إعدادات الكاشير ما إذا كان الخصم يحتاج موافقة مدير.
  /// يعاد فحص القرار داخل معاملة البيع لمنع الاعتماد على قراءة قديمة.
  Future<bool> requiresCashierApproval({
    required int userId,
    required int amount,
  }) async {
    if (amount < 0) throw ArgumentError('قيمة الخصم غير صالحة.');
    final rows = await _database.query(
      'cashier_permissions',
      columns: ['is_allowed', 'max_amount'],
      where: "user_id = ? AND permission_key = 'discounts'",
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty || rows.single['is_allowed'] != 1) return true;
    final limit = (rows.single['max_amount'] as num?)?.toInt();
    return limit != null && amount > limit;
  }

  /// يصدر موافقة مؤقتة على خصم فاتورة الكاشير بعد التحقق من بيانات المدير.
  Future<String> requestCashierDiscountApproval({
    required String managerUsername,
    required String managerPassword,
    required int cashierUserId,
    required int shiftId,
    required int discountAmount,
  }) async {
    if (managerUsername.trim().isEmpty || managerPassword.isEmpty) {
      throw const ManagerApprovalException('أدخل اسم مستخدم المدير وكلمة المرور.');
    }
    final managers = await _database.query(
      'users',
      where: "username = ? COLLATE NOCASE AND role = 'manager' AND is_active = 1",
      whereArgs: [managerUsername.trim()],
      limit: 1,
    );
    if (managers.isEmpty) {
      throw const ManagerApprovalException('بيانات المدير غير صحيحة أو أن الحساب غير نشط.');
    }
    final grant = await _managerApprovals.issueApproval(
      manager: AuthUser.fromMap(managers.single),
      managerPassword: managerPassword,
      scope: ManagerApprovalScope(
        cashierUserId: cashierUserId,
        shiftId: shiftId,
        permissionKey: 'discounts',
        operationType: 'sale.create',
        amount: discountAmount,
      ),
    );
    return grant.token;
  }

  /// يصدر موافقة مدير لمرتجع محدد بعد التأكد من صلاحية المرتجعات للكاشير.
  Future<String> requestCashierReturnApproval({
    required String managerUsername,
    required String managerPassword,
    required int cashierUserId,
    required int shiftId,
    required int saleId,
    required int returnAmount,
  }) async {
    if (managerUsername.trim().isEmpty || managerPassword.isEmpty) {
      throw const ManagerApprovalException('أدخل اسم مستخدم المدير وكلمة المرور.');
    }
    if (saleId <= 0 || returnAmount <= 0) {
      throw const ManagerApprovalException('بيانات المرتجع غير صالحة للموافقة.');
    }
    final permissions = await _database.query(
      'cashier_permissions',
      columns: ['is_allowed', 'max_amount'],
      where: "user_id = ? AND permission_key = 'returns'",
      whereArgs: [cashierUserId],
      limit: 1,
    );
    if (permissions.isEmpty || permissions.single['is_allowed'] != 1) {
      throw const ManagerApprovalException('لا يملك الكاشير صلاحية تسجيل المرتجعات.');
    }
    final limit = (permissions.single['max_amount'] as num?)?.toInt();
    if (limit == null || returnAmount <= limit) {
      throw const ManagerApprovalException('لا يحتاج هذا المرتجع إلى موافقة استثنائية.');
    }
    final managers = await _database.query(
      'users',
      where: "username = ? COLLATE NOCASE AND role = 'manager' AND is_active = 1",
      whereArgs: [managerUsername.trim()],
      limit: 1,
    );
    if (managers.isEmpty) {
      throw const ManagerApprovalException('بيانات المدير غير صحيحة أو أن الحساب غير نشط.');
    }
    final grant = await _managerApprovals.issueApproval(
      manager: AuthUser.fromMap(managers.single),
      managerPassword: managerPassword,
      scope: ManagerApprovalScope(
        cashierUserId: cashierUserId,
        shiftId: shiftId,
        permissionKey: 'returns',
        operationType: 'sale.return',
        amount: returnAmount,
        referenceType: 'sale',
        referenceId: saleId,
      ),
    );
    return grant.token;
  }

  /// يتحقق من صلاحية الكاشير ويعيد سقف العملية المالي إن وُجد.
  /// الصلاحية غير المسجلة أو غير المفعلة مرفوضة افتراضيًا.
  static Future<int?> _requireCashierPermission(
    Transaction txn, {
    required int userId,
    required String permissionKey,
    required String permissionLabel,
  }) async {
    final rows = await txn.query(
      'cashier_permissions',
      columns: ['is_allowed', 'max_amount'],
      where: 'user_id = ? AND permission_key = ?',
      whereArgs: [userId, permissionKey],
      limit: 1,
    );
    if (rows.isEmpty || rows.single['is_allowed'] != 1) {
      throw StateError('لا يملك الكاشير صلاحية $permissionLabel.');
    }
    return (rows.single['max_amount'] as num?)?.toInt();
  }


  // يمنع قراءة سجل الفواتير إلا للمدير أو الكاشير الممنوح صلاحية العرض.
  Future<void> requireInvoiceHistoryAccess(int userId) async {
    final accounts = await _database.query(
      'users', columns: ['role', 'is_active'],
      where: 'id = ?', whereArgs: [userId], limit: 1,
    );
    if (accounts.isEmpty || accounts.single['is_active'] != 1) {
      throw StateError('الحساب غير نشط أو غير موجود.');
    }
    final role = accounts.single['role'];
    if (role == 'manager') return;
    if (role != 'cashier') throw StateError('لا يملك المستخدم صلاحية عرض سجل الفواتير.');
    final permissions = await _database.query(
      'cashier_permissions', columns: ['is_allowed'],
      where: "user_id = ? AND permission_key IN ('view_invoice_history', 'returns', 'return_refunds') AND is_allowed = 1",
      whereArgs: [userId], limit: 1,
    );
    if (permissions.isEmpty || permissions.single['is_allowed'] != 1) {
      throw StateError('لا يملك الكاشير صلاحية عرض سجل الفواتير.');
    }
  }

  Future<List<Map<String, Object?>>> invoiceHistory({
    required int userId,
    String query = '',
    int limit = 200,
  }) async {
    await requireInvoiceHistoryAccess(userId);
    if (limit < 1 || limit > 500) throw ArgumentError('حد نتائج سجل الفواتير غير صالح.');
    final normalized = query.trim();
    return _database.rawQuery('''
      SELECT s.id, s.invoice_number, s.customer_name, s.total,
        s.paid_amount, s.payment_method, s.created_at,
        (SELECT COUNT(*) FROM sale_items si WHERE si.sale_id = s.id) AS item_count
      FROM sales s
      WHERE (? = '' OR s.invoice_number LIKE ? OR COALESCE(s.customer_name, '') LIKE ?)
      ORDER BY s.id DESC
      LIMIT ?
    ''', [normalized, '%$normalized%', '%$normalized%', limit]);
  }

  Future<void> _requireReturnReadAccess(int userId) async {
    final accounts = await _database.query(
      'users', columns: ['role', 'is_active'],
      where: 'id = ?', whereArgs: [userId], limit: 1,
    );
    if (accounts.isEmpty || accounts.single['is_active'] != 1) {
      throw StateError('الحساب غير نشط أو غير موجود.');
    }
    final role = accounts.single['role'];
    if (role == 'manager') return;
    if (role != 'cashier') throw StateError('نوع الحساب غير مصرح له بقراءة بيانات المرتجعات.');
    final permissions = await _database.query(
      'cashier_permissions', columns: ['is_allowed'],
      where: "user_id = ? AND permission_key IN ('returns', 'return_refunds') AND is_allowed = 1",
      whereArgs: [userId], limit: 1,
    );
    if (permissions.isEmpty || permissions.single['is_allowed'] != 1) {
      throw StateError('لا يملك الكاشير صلاحية قراءة بيانات المرتجعات.');
    }
  }


  /// يسجل ردًا كليًا أو جزئيًا لزيادة دفع مرتبطة بفاتورة، دون إنشاء دين زبون.
  Future<int> refundCustomerOverpayment({
    required int saleId, required int amount, required String paymentMethod,
    required int userId, int? shiftId,
  }) async {
    if (amount <= 0 || !const {'نقدي', 'تحويل بنكي'}.contains(paymentMethod)) {
      throw ArgumentError('مبلغ الرد أو وسيلة الدفع غير صالحة.');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    return _database.transaction((txn) async {
      final users = await txn.query('users', columns: ['role', 'is_active'], where: 'id = ?', whereArgs: [userId], limit: 1);
      if (users.isEmpty || users.single['is_active'] != 1) throw StateError('الحساب غير نشط أو غير موجود.');
      if (users.single['role'] == 'cashier') {
        await _requireCashierPermission(txn, userId: userId, permissionKey: 'customer_overpayments', permissionLabel: 'رد مبالغ الزيادة المستحقة للزبائن');
      } else if (users.single['role'] != 'manager') {
        throw StateError('نوع الحساب غير مصرح له برد المبالغ.');
      }
      if (paymentMethod == 'نقدي') await CashShiftRepository.validateActiveShift(txn, shiftId: shiftId, userId: userId);
      final rows = await txn.query('customer_overpayments', where: 'sale_id = ?', whereArgs: [saleId], limit: 1);
      if (rows.isEmpty) throw StateError('لا توجد زيادة دفع مستحقة لهذه الفاتورة.');
      final row = rows.single;
      final outstanding = (row['received_amount'] as int) - (row['refunded_amount'] as int);
      if (amount > outstanding) throw StateError('مبلغ الرد يتجاوز الزيادة المستحقة ($outstanding ج.س).');
      await txn.update('customer_overpayments', {'refunded_amount': (row['refunded_amount'] as int) + amount}, where: 'id = ?', whereArgs: [row['id']]);
      await txn.insert('cash_transactions', {
        'direction': 'out', 'category': 'رد زيادة دفع للزبون', 'amount': amount,
        'payment_method': paymentMethod, 'reference_type': 'customer_overpayment',
        'reference_id': saleId, 'user_id': userId,
        'shift_id': paymentMethod == 'نقدي' ? shiftId : null,
        'note': 'رد زيادة دفع عن الفاتورة رقم $saleId', 'created_at': now,
      });
      return outstanding - amount;
    });
  }

  /// يعيد سجل الزيادات التي لم تُرد بالكامل، مرتبطًا برقم الفاتورة فقط.
  Future<List<Map<String, Object?>>> pendingCustomerOverpayments() async => _database.rawQuery('''
    SELECT o.sale_id, s.invoice_number, o.received_amount, o.refunded_amount,
      (o.received_amount - o.refunded_amount) AS outstanding_amount, o.created_at
    FROM customer_overpayments o JOIN sales s ON s.id = o.sale_id
    WHERE o.received_amount > o.refunded_amount ORDER BY o.id DESC
  ''');

  // حفظ الفاتورة وبنودها وتحديث المخزون في معاملة واحدة.
  Future<SaleRecord> createSale({
    required List<SaleLine> lines,
    required int discount,
    required int paidAmount,
    required String paymentMethod,
    String paymentChannel = 'نقدي',
    int? cashPaidAmount,
    int? bankPaidAmount,
    String? customerName,
    int? customerId,
    required int userId,
    int? shiftId,
    String? managerApprovalToken,
  }) async {
    if (lines.isEmpty) throw ArgumentError('أضف صنفًا واحدًا على الأقل.');
    if (discount < 0 || paidAmount < 0) {
      throw ArgumentError('الخصم والمبلغ المدفوع لا يمكن أن يكونا سالبين.');
    }
    for (final line in lines) {
      if (!line.quantity.isFinite || line.quantity <= 0) {
        throw ArgumentError('كمية البيع يجب أن تكون أكبر من صفر.');
      }
      if (line.product.id == null) {
        throw ArgumentError('يوجد صنف غير محفوظ في قاعدة البيانات.');
      }
    }

    final subtotal = lines.fold<int>(0, (sum, line) => sum + line.lineTotal);
    if (discount > subtotal) throw ArgumentError('الخصم أكبر من إجمالي الفاتورة.');
    final total = subtotal - discount;
    // المبلغ المستلم قد يتجاوز الإجمالي؛ الزيادة التزام مستقل وليست إيرادًا.
    final receivedAmount = paidAmount;
    final cashReceived = cashPaidAmount ?? (paymentChannel == 'تحويل بنكي' ? 0 : receivedAmount);
    final bankReceived = bankPaidAmount ?? (paymentChannel == 'تحويل بنكي' ? receivedAmount : 0);
    if (cashReceived < 0 || bankReceived < 0 || cashReceived + bankReceived != receivedAmount) {
      throw ArgumentError('مجموع النقد والتحويل يجب أن يساوي إجمالي المبلغ المستلم.');
    }
    final effectiveChannel = cashReceived > 0 && bankReceived > 0 ? 'مختلط' : bankReceived > 0 ? 'تحويل بنكي' : 'نقدي';
    if (paymentChannel != effectiveChannel && cashPaidAmount != null && bankPaidAmount != null) {
      throw ArgumentError('طريقة الدفع لا تتوافق مع توزيع المبلغ.');
    }
    final overpaymentAmount = (receivedAmount - total).clamp(0, 1 << 62).toInt();
    paidAmount = receivedAmount > total ? total : receivedAmount;
    if (!const ['نقدي', 'جزئي', 'آجل'].contains(paymentMethod)) {
      throw ArgumentError('طريقة السداد غير معروفة.');
    }
    if (!const {'نقدي', 'تحويل بنكي', 'مختلط'}.contains(effectiveChannel)) {
      throw ArgumentError('طريقة استلام المبلغ غير مدعومة.');
    }
    if (paymentMethod == 'نقدي' && paidAmount != total) {
      throw ArgumentError('الفاتورة النقدية يجب أن تُدفع بالكامل.');
    }
    if (paymentMethod == 'آجل' && paidAmount != 0) {
      throw ArgumentError('الفاتورة الآجلة لا تسجل مبلغًا مدفوعًا عند البيع.');
    }
    if (paymentMethod == 'جزئي' && (paidAmount <= 0 || paidAmount >= total)) {
      throw ArgumentError('الدفع الجزئي يجب أن يكون أكبر من صفر وأقل من الإجمالي.');
    }
    final hasDebt = paidAmount < total;
    if (hasDebt && customerId == null && customerName?.trim().isNotEmpty != true) {
      throw ArgumentError('اسم الزبون مطلوب لتسجيل الرصيد المتبقي في دفتر الديون.');
    }
    if (!hasDebt) {
      // البيع النقدي لا ينشئ سجل زبون ولا يربط الفاتورة بدفتر الديون.
      customerId = null;
      customerName = null;
    }

    final now = DateTime.now().toUtc();
    final invoice = 'HG-${now.microsecondsSinceEpoch}';
    final createdAt = now.toIso8601String();

    ManagerApprovalConsumeResult? approvalFailure;
    final sale = await _database.transaction<SaleRecord?>((txn) async {
      final accounts = await txn.query(
        'users',
        columns: ['role', 'is_active'],
        where: 'id = ?',
        whereArgs: [userId],
        limit: 1,
      );
      if (accounts.isEmpty || accounts.single['is_active'] != 1) {
        throw StateError('الحساب غير نشط أو غير موجود ولا يمكنه تسجيل مبيعات.');
      }
      final role = accounts.single['role'];
      if (role != 'manager' && role != 'cashier') {
        throw StateError('نوع الحساب غير مصرح له بتسجيل المبيعات.');
      }
      if (role == 'cashier') {
          if (total <= 0 || bankReceived > 0) {
            throw StateError(
              'الكاشير لا يسجل بيعًا صفريًا أو يستلم عبر التحويل البنكي.',
            );
          }
          if (discount > 0) {
            final permissionRows = await txn.query(
              'cashier_permissions',
              columns: ['is_allowed', 'max_amount'],
              where: "user_id = ? AND permission_key = 'discounts'",
              whereArgs: [userId],
              limit: 1,
            );
            final permission = permissionRows.isEmpty
                ? null
                : permissionRows.single;
            final isAllowed = permission?['is_allowed'] == 1;
            final limit = (permission?['max_amount'] as num?)?.toInt();
            final needsApproval = !isAllowed || (limit != null && discount > limit);
            if (needsApproval) {
              if (managerApprovalToken == null || shiftId == null) {
                approvalFailure = ManagerApprovalConsumeResult.notFound;
                return null;
              }
              approvalFailure = await _managerApprovals.consumeWithinTransaction(
                txn,
                token: managerApprovalToken,
                executingUserId: userId,
                scope: ManagerApprovalScope(
                  cashierUserId: userId,
                  shiftId: shiftId,
                  permissionKey: 'discounts',
                  operationType: 'sale.create',
                  amount: discount,
                ),
              );
              if (approvalFailure != ManagerApprovalConsumeResult.consumed) {
                return null;
              }
            } else if (managerApprovalToken != null) {
              approvalFailure = ManagerApprovalConsumeResult.scopeMismatch;
              return null;
            }
          }
          if (hasDebt) {
            final limit = await _requireCashierPermission(
              txn,
              userId: userId,
              permissionKey: 'credit_sales',
              permissionLabel: 'البيع بالدين أو الدفع الجزئي',
            );
            final debtAmount = total - paidAmount;
            if (limit != null && debtAmount > limit) {
              throw StateError('الرصيد الآجل يتجاوز الحد المسموح ($limit ج.س).');
            }
          }
      }
      if (cashReceived > 0) {
        await CashShiftRepository.validateActiveShift(
          txn,
          shiftId: shiftId,
          userId: userId,
        );
      }
      final normalizedCustomer = hasDebt ? customerName?.trim() : null;
      var linkedCustomerId = hasDebt ? customerId : null;
      if (hasDebt && linkedCustomerId != null) {
        final existing = await txn.query(
          'customers',
          columns: ['id', 'name'],
          where: 'id = ?',
          whereArgs: [linkedCustomerId],
          limit: 1,
        );
        if (existing.isEmpty) throw StateError('الزبون المحدد لم يعد موجودًا في دفتر الحسابات.');
        // الاسم المعتمد للحساب هو الاسم المحفوظ، ولا يُستخدم نص الحقل لتغيير الربط.
      } else if (hasDebt && normalizedCustomer != null && normalizedCustomer.isNotEmpty) {
        final existing = await txn.query(
          'customers',
          columns: ['id'],
          where: 'name = ? COLLATE NOCASE',
          whereArgs: [normalizedCustomer],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          throw StateError('هذا الاسم موجود في دفتر الحسابات. اختر الزبون من الاقتراحات أو عدّل الاسم/أضف لقبًا.');
        }
        linkedCustomerId = await txn.insert('customers', {
          'name': normalizedCustomer,
          'created_at': createdAt,
        });
      }
      final saleId = await txn.insert('sales', {
        'invoice_number': invoice,
        'customer_id': linkedCustomerId,
        'customer_name': linkedCustomerId == null ? null : normalizedCustomer,
        'subtotal': subtotal,
        'discount': discount,
        'total': total,
        'paid_amount': paidAmount,
        'payment_method': paymentMethod,
        'created_at': createdAt,
      });
      // تفصل حركة كل وسيلة دفع حتى لا يختلط رصيد الخزينة برصيد البنك.
      for (final receipt in [
        if (cashReceived > 0) ('نقدي', cashReceived),
        if (bankReceived > 0) ('تحويل بنكي', bankReceived),
      ]) {
        await txn.insert('cash_transactions', {
          'direction': 'in', 'category': 'مبيعات', 'amount': receipt.$2,
          'payment_method': receipt.$1, 'reference_type': 'sale', 'reference_id': saleId,
          'user_id': userId, 'shift_id': receipt.$1 == 'نقدي' ? shiftId : null,
          'note': 'فاتورة $invoice', 'created_at': createdAt,
        });
      }

      if (overpaymentAmount > 0) {
        await txn.insert('customer_overpayments', {
          'sale_id': saleId,
          'received_amount': overpaymentAmount,
          'refunded_amount': 0,
          'created_at': createdAt,
        });
      }

      for (final line in lines) {
        final productId = line.product.id!;
        final rows = await txn.query(
          'products',
          columns: ['id', 'name', 'unit', 'selling_price', 'purchase_price', 'stock_quantity', 'is_active'],
          where: 'id = ?',
          whereArgs: [productId],
          limit: 1,
        );
        if (rows.isEmpty || rows.first['is_active'] != 1) {
          throw StateError('أحد الأصناف لم يعد متاحًا للبيع.');
        }
        final current = rows.first;
        if (current['selling_price'] != line.product.sellingPrice) {
          throw StateError('تغير سعر أحد الأصناف بعد إضافته إلى الفاتورة. أعد المحاولة بالسعر الحالي.');
        }
        await txn.insert('sale_items', {
          'sale_id': saleId,
          'product_id': productId,
          'product_name': current['name'],
          'unit': current['unit'],
          'quantity': line.quantity,
          'unit_price': current['selling_price'],
          'cost_price': current['purchase_price'],
          'line_total': line.lineTotal,
        });
        // المخزون السالب مسموح حسب سياسة المشروع؛ كل حركة بيع تسجل هنا.
        final stockBefore = (current['stock_quantity'] as num).toDouble();
        final stockAfter = stockBefore - line.quantity;
        await txn.rawUpdate(
          'UPDATE products SET stock_quantity = ? WHERE id = ?',
          [stockAfter, productId],
        );
        await txn.insert('stock_movements', {
          'product_id': productId,
          'movement_type': 'بيع',
          'quantity_delta': -line.quantity,
          'stock_before': stockBefore,
          'stock_after': stockAfter,
          'reference_type': 'sale',
          'reference_id': saleId,
          'created_at': createdAt,
        });
      }

      return SaleRecord(
        id: saleId,
        invoiceNumber: invoice,
        total: total,
        paidAmount: paidAmount,
        paymentMethod: paymentMethod,
        createdAt: createdAt,
        customerName: linkedCustomerId == null ? null : normalizedCustomer,
        overpaymentAmount: overpaymentAmount,
      );
    });

    if (sale == null) {
      final message = switch (approvalFailure) {
        ManagerApprovalConsumeResult.expired => 'انتهت موافقة المدير. اطلب موافقة جديدة.',
        ManagerApprovalConsumeResult.scopeMismatch => 'الموافقة لا تطابق مبلغ الخصم أو المستخدم أو الوردية.',
        ManagerApprovalConsumeResult.alreadyUsed => 'استُخدمت موافقة المدير مسبقًا.',
        ManagerApprovalConsumeResult.inactiveAccount => 'حساب المدير أو الكاشير لم يعد نشطًا.',
        ManagerApprovalConsumeResult.invalidShift => 'الوردية غير نشطة أو لا تخص الكاشير.',
        _ => 'يتطلب هذا الخصم موافقة مدير صالحة قبل حفظ الفاتورة.',
      };
      throw StateError(message);
    }
    return sale;
  }


  /// إرجاع كميات من فاتورة سابقة مع تحديث المخزون والسجل المالي ذريًا.
  /// مفاتيح الخريطة هي معرّفات بنود الفاتورة الأصلية.
  Future<SaleReturnRecord> returnItems({
    required int saleId,
    required Map<int, double> quantitiesBySaleItemId,
    String? note,
    required int userId,
    int? shiftId,
    String? managerApprovalToken,
  }) async {
    if (quantitiesBySaleItemId.isEmpty) {
      throw ArgumentError('حدد كمية واحدة على الأقل لإرجاعها.');
    }
    for (final entry in quantitiesBySaleItemId.entries) {
      if (entry.key <= 0 || !entry.value.isFinite || entry.value <= 0) {
        throw ArgumentError('كميات المرتجع يجب أن تكون أرقامًا موجبة وصالحة.');
      }
    }

    ManagerApprovalConsumeResult? approvalFailure;
    final returned = await _database.transaction<SaleReturnRecord?>((txn) async {
      final accounts = await txn.query(
        'users',
        columns: ['role', 'is_active'],
        where: 'id = ?',
        whereArgs: [userId],
        limit: 1,
      );
      if (accounts.isEmpty || accounts.single['is_active'] != 1) {
        throw StateError('الحساب غير نشط أو غير موجود.');
      }
      final role = accounts.single['role'];
      if (role != 'manager' && role != 'cashier') {
        throw StateError('نوع الحساب غير مصرح له بتسجيل المرتجعات.');
      }
      final sales = await txn.query(
        'sales',
        columns: ['id', 'subtotal', 'total'],
        where: 'id = ?',
        whereArgs: [saleId],
        limit: 1,
      );
      if (sales.isEmpty) throw StateError('الفاتورة غير موجودة.');
      final subtotal = (sales.single['subtotal'] as num).toInt();
      final saleTotal = (sales.single['total'] as num).toInt();

      final returnLines = <Map<String, Object?>>[];
      var totalAmount = 0;
      for (final entry in quantitiesBySaleItemId.entries) {
        final rows = await txn.rawQuery('''
          SELECT si.id, si.sale_id, si.product_id, si.product_name,
            si.quantity, si.line_total,
            COALESCE((SELECT SUM(sri.quantity)
              FROM sale_return_items sri
              JOIN sale_returns sr ON sr.id = sri.return_id
              WHERE sri.sale_item_id = si.id), 0) AS returned_quantity,
            COALESCE((SELECT SUM(sri.amount)
              FROM sale_return_items sri
              JOIN sale_returns sr ON sr.id = sri.return_id
              WHERE sri.sale_item_id = si.id), 0) AS returned_amount,
            p.stock_quantity
          FROM sale_items si
          JOIN products p ON p.id = si.product_id
          WHERE si.id = ? AND si.sale_id = ?
          LIMIT 1
        ''', [entry.key, saleId]);
        if (rows.isEmpty) {
          throw ArgumentError('أحد البنود لا يتبع الفاتورة المحددة.');
        }
        final row = rows.single;
        final sold = (row['quantity'] as num).toDouble();
        final returned = (row['returned_quantity'] as num).toDouble();
        final requested = entry.value;
        if (requested > sold - returned + 1e-9) {
          throw ArgumentError(
            'الكمية المطلوبة تتجاوز الكمية المتبقية للإرجاع للصنف ${row['product_name']}.',
          );
        }

        // خصم الفاتورة يُوزّع نسبيًا على البنود. استخدام المجموع التراكمي
        // يمنع اختلاف المبلغ عند تقسيم إرجاع الكمية نفسها إلى عمليات متعددة.
        final lineTotal = (row['line_total'] as num).toInt();
        final previouslyReturnedAmount = (row['returned_amount'] as num).toInt();
        final cumulativeQuantity = returned + requested;
        final cumulativeAmount = subtotal == 0
            ? 0
            : (lineTotal * saleTotal * cumulativeQuantity / (subtotal * sold))
                .round();
        final amount = (cumulativeAmount - previouslyReturnedAmount)
            .clamp(0, lineTotal)
            .toInt();
        totalAmount += amount;
        returnLines.add({
          'sale_item_id': row['id'] as int,
          'product_id': row['product_id'] as int,
          'quantity': requested,
          'amount': amount,
          'stock_before': (row['stock_quantity'] as num).toDouble(),
        });
      }

      int? returnLimit;
      if (role == 'cashier') {
        // لا يمكن للموافقة تجاوز غياب صلاحية المرتجعات نفسها.
        returnLimit = await _requireCashierPermission(
          txn,
          userId: userId,
          permissionKey: 'returns',
          permissionLabel: 'تسجيل مرتجعات البيع',
        );
        if (shiftId == null) {
          throw StateError('يلزم وجود وردية نشطة لتسجيل مرتجع الكاشير.');
        }
        await CashShiftRepository.validateActiveShift(
          txn,
          shiftId: shiftId,
          userId: userId,
        );
        if (returnLimit != null && totalAmount > returnLimit) {
          if (managerApprovalToken == null || managerApprovalToken.isEmpty) {
            throw ManagerApprovalRequiredException(totalAmount);
          }
          approvalFailure = await _managerApprovals.consumeWithinTransaction(
            txn,
            token: managerApprovalToken,
            executingUserId: userId,
            scope: ManagerApprovalScope(
              cashierUserId: userId,
              shiftId: shiftId,
              permissionKey: 'returns',
              operationType: 'sale.return',
              amount: totalAmount,
              referenceType: 'sale',
              referenceId: saleId,
            ),
          );
          if (approvalFailure != ManagerApprovalConsumeResult.consumed) {
            return null;
          }
        } else if (managerApprovalToken != null) {
          approvalFailure = ManagerApprovalConsumeResult.scopeMismatch;
          return null;
        }
      }

      final now = DateTime.now().toUtc().toIso8601String();
      final returnId = await txn.insert('sale_returns', {
        'sale_id': saleId,
        'amount': totalAmount,
        'note': note?.trim().isEmpty == true ? null : note?.trim(),
        'created_at': now,
      });

      for (final line in returnLines) {
        final before = line['stock_before'] as double;
        final quantity = line['quantity'] as double;
        final after = before + quantity;
        await txn.update(
          'products',
          {'stock_quantity': after},
          where: 'id = ?',
          whereArgs: [line['product_id']],
        );
        await txn.insert('sale_return_items', {
          'return_id': returnId,
          'sale_item_id': line['sale_item_id'],
          'quantity': quantity,
          'amount': line['amount'],
        });
        await txn.insert('stock_movements', {
          'product_id': line['product_id'],
          'movement_type': 'مرتجع بيع',
          'quantity_delta': quantity,
          'stock_before': before,
          'stock_after': after,
          'note': note?.trim().isEmpty == true ? null : note?.trim(),
          'reference_type': 'sale_return',
          'reference_id': returnId,
          'created_at': now,
        });
      }

      return SaleReturnRecord(
        id: returnId,
        saleId: saleId,
        amount: totalAmount,
        createdAt: now,
      );
    });

    if (returned == null) {
      final message = switch (approvalFailure) {
        ManagerApprovalConsumeResult.expired => 'انتهت موافقة المدير. اطلب موافقة جديدة.',
        ManagerApprovalConsumeResult.scopeMismatch => 'الموافقة لا تطابق الكاشير أو الوردية أو الفاتورة أو مبلغ المرتجع.',
        ManagerApprovalConsumeResult.alreadyUsed => 'استُخدمت موافقة المدير مسبقًا.',
        ManagerApprovalConsumeResult.inactiveAccount => 'حساب المدير أو الكاشير لم يعد نشطًا.',
        ManagerApprovalConsumeResult.invalidShift => 'الوردية غير نشطة أو لا تخص الكاشير.',
        _ => 'يتطلب هذا المرتجع موافقة مدير صالحة قبل حفظه.',
      };
      throw StateError(message);
    }
    return returned;
  }

  /// الحد المتبقي من النقد الذي يمكن رده فعليًا بعد أن غطت المرتجعات دين الفاتورة الأصلي.
  Future<int> maximumRefundableAmount(int saleId, {required int userId}) async {
    await _requireReturnReadAccess(userId);
    final rows = await _database.rawQuery('''
      SELECT MAX(0,
        COALESCE((SELECT SUM(sr.amount) FROM sale_returns sr WHERE sr.sale_id = s.id), 0)
        - MAX(0, s.total - s.paid_amount)
        - COALESCE((
          SELECT SUM(srr.amount)
          FROM sale_return_refunds srr
          WHERE srr.sale_id = s.id
        ), 0)
      ) AS refundable
      FROM sales s WHERE s.id = ? LIMIT 1
    ''', [saleId]);
    if (rows.isEmpty) throw StateError('الفاتورة غير موجودة.');
    return (rows.single['refundable'] as num).toInt();
  }

  /// تسجيل مبلغ نقدي أُعيد بالفعل للزبون؛ لا يسمح بتجاوز فائض المرتجعات عن دين الفاتورة.
  Future<int> recordReturnRefund({
    required int saleId,
    required int amount,
    String paymentMethod = 'نقدي',
    String? note,
    required int userId,
    int? shiftId,
  }) async {
    if (saleId <= 0) throw ArgumentError('معرّف الفاتورة غير صالح.');
    if (amount <= 0) throw ArgumentError('مبلغ الرد يجب أن يكون أكبر من صفر.');
    if (paymentMethod.trim().isEmpty) {
      throw ArgumentError('حدد طريقة رد المبلغ.');
    }
    return _database.transaction((txn) async {
      final accounts = await txn.query(
        'users',
        columns: ['role', 'is_active'],
        where: 'id = ?',
        whereArgs: [userId],
        limit: 1,
      );
      if (accounts.isEmpty || accounts.single['is_active'] != 1) {
        throw StateError('الحساب غير نشط أو غير موجود.');
      }
      final role = accounts.single['role'];
      if (role != 'manager' && role != 'cashier') {
        throw StateError('نوع الحساب غير مصرح له برد مبالغ المرتجعات.');
      }
      if (role == 'cashier') {
          final limit = await _requireCashierPermission(
            txn,
            userId: userId,
            permissionKey: 'return_refunds',
            permissionLabel: 'رد مبالغ المرتجعات',
          );
          if (limit != null && amount > limit) {
            throw StateError('مبلغ الرد يتجاوز الحد المسموح ($limit ج.س).');
          }
      }
      if (paymentMethod.trim() == 'نقدي') {
        await CashShiftRepository.validateActiveShift(
          txn,
          shiftId: shiftId,
          userId: userId,
        );
      }
      final sales = await txn.query(
        'sales',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [saleId],
        limit: 1,
      );
      if (sales.isEmpty) throw StateError('الفاتورة غير موجودة.');
      final rows = await txn.rawQuery('''
        SELECT MAX(0,
          COALESCE((SELECT SUM(sr.amount) FROM sale_returns sr WHERE sr.sale_id = s.id), 0)
          - MAX(0, s.total - s.paid_amount)
          - COALESCE((
            SELECT SUM(srr.amount)
            FROM sale_return_refunds srr
            WHERE srr.sale_id = s.id
          ), 0)
        ) AS refundable
        FROM sales s WHERE s.id = ? LIMIT 1
      ''', [saleId]);
      final available = (rows.single['refundable'] as num).toInt();
      if (amount > available) {
        throw ArgumentError('مبلغ الرد يتجاوز المبلغ المتاح للرد النقدي ($available ج.س).');
      }
      final createdAt = DateTime.now().toUtc().toIso8601String();
      final refundId = await txn.insert('sale_return_refunds', {
        'sale_id': saleId,
        'amount': amount,
        'payment_method': paymentMethod.trim(),
        'note': note?.trim().isEmpty == true ? null : note?.trim(),
        'created_at': createdAt,
      });
      await txn.insert('cash_transactions', {
        'direction': 'out',
        'category': 'رد نقدي لمرتجع بيع',
        'amount': amount,
        'payment_method': paymentMethod.trim(),
        'reference_type': 'sale_return_refund',
        'reference_id': refundId,
        'user_id': userId,
        'shift_id': paymentMethod.trim() == 'نقدي' ? shiftId : null,
        'note': note?.trim().isEmpty == true ? 'فاتورة البيع #$saleId' : note?.trim(),
        'created_at': createdAt,
      });
      return refundId;
    });
  }

  /// مجموع الكميات المرتجعة لبند فاتورة.
  Future<double> returnedQuantity(int saleItemId, {required int userId}) async {
    await _requireReturnReadAccess(userId);
    final rows = await _database.rawQuery('''
      SELECT COALESCE(SUM(quantity), 0) AS quantity
      FROM sale_return_items WHERE sale_item_id = ?
    ''', [saleItemId]);
    return (rows.single['quantity'] as num).toDouble();
  }

  // عرض أحدث الفواتير أولًا.
  Future<List<SaleRecord>> recentSales({required int userId, int limit = 50}) async {
    await requireInvoiceHistoryAccess(userId);
    if (limit < 1 || limit > 500) throw ArgumentError('حد نتائج سجل الفواتير غير صالح.');
    final rows = await _database.query(
      'sales',
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map(SaleRecord.fromMap).toList(growable: false);
  }
}
