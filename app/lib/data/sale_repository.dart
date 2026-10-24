// عمليات البيع والفواتير داخل معاملات SQLite لضمان حفظ الفاتورة والمخزون معًا.
import 'package:sqflite/sqflite.dart';

import 'product_repository.dart';

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
  });

  final int id;
  final String invoiceNumber;
  final int total;
  final int paidAmount;
  final String paymentMethod;
  final String createdAt;
  final String? customerName;

  int get remainingAmount => total - paidAmount;

  factory SaleRecord.fromMap(Map<String, Object?> map) => SaleRecord(
        id: map['id'] as int,
        invoiceNumber: map['invoice_number'] as String,
        total: map['total'] as int,
        paidAmount: map['paid_amount'] as int,
        paymentMethod: map['payment_method'] as String,
        createdAt: map['created_at'] as String,
        customerName: map['customer_name'] as String?,
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

class SaleRepository {
  SaleRepository(this._database);

  final Database _database;

  // حفظ الفاتورة وبنودها وتحديث المخزون في معاملة واحدة.
  Future<SaleRecord> createSale({
    required List<SaleLine> lines,
    required int discount,
    required int paidAmount,
    required String paymentMethod,
    String? customerName,
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
    if (paidAmount > total) {
      throw ArgumentError('المبلغ المدفوع أكبر من إجمالي الفاتورة.');
    }
    if (!const ['نقدي', 'جزئي', 'آجل'].contains(paymentMethod)) {
      throw ArgumentError('طريقة السداد غير معروفة.');
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
    if (paidAmount < total && customerName?.trim().isNotEmpty != true) {
      throw ArgumentError('اسم الزبون مطلوب لتسجيل الرصيد المتبقي في دفتر الديون.');
    }

    final now = DateTime.now().toUtc();
    final invoice = 'HG-${now.microsecondsSinceEpoch}';
    final createdAt = now.toIso8601String();

    return _database.transaction((txn) async {
      final normalizedCustomer = customerName?.trim();
      int? customerId;
      if (normalizedCustomer != null && normalizedCustomer.isNotEmpty) {
        final existing = await txn.query(
          'customers',
          columns: ['id'],
          where: 'name = ? COLLATE NOCASE',
          whereArgs: [normalizedCustomer],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          customerId = existing.first['id'] as int;
        } else {
          customerId = await txn.insert('customers', {
            'name': normalizedCustomer,
            'created_at': createdAt,
          });
        }
      }
      final saleId = await txn.insert('sales', {
        'invoice_number': invoice,
        'customer_id': customerId,
        'customer_name': normalizedCustomer?.isEmpty == true ? null : normalizedCustomer,
        'subtotal': subtotal,
        'discount': discount,
        'total': total,
        'paid_amount': paidAmount,
        'payment_method': paymentMethod,
        'created_at': createdAt,
      });

      for (final line in lines) {
        final productId = line.product.id!;
        final rows = await txn.query(
          'products',
          columns: ['id', 'name', 'unit', 'selling_price', 'stock_quantity', 'is_active'],
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
        customerName: normalizedCustomer?.isEmpty == true ? null : normalizedCustomer,
      );
    });
  }


  /// إرجاع كميات من فاتورة سابقة مع تحديث المخزون والسجل المالي ذريًا.
  /// مفاتيح الخريطة هي معرّفات بنود الفاتورة الأصلية.
  Future<SaleReturnRecord> returnItems({
    required int saleId,
    required Map<int, double> quantitiesBySaleItemId,
    String? note,
  }) async {
    if (quantitiesBySaleItemId.isEmpty) {
      throw ArgumentError('حدد كمية واحدة على الأقل لإرجاعها.');
    }
    for (final entry in quantitiesBySaleItemId.entries) {
      if (entry.key <= 0 || !entry.value.isFinite || entry.value <= 0) {
        throw ArgumentError('كميات المرتجع يجب أن تكون أرقامًا موجبة وصالحة.');
      }
    }

    return _database.transaction((txn) async {
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
  }

  /// الحد المتبقي من النقد الذي يمكن رده فعليًا بعد أن غطت المرتجعات دين الفاتورة الأصلي.
  Future<int> maximumRefundableAmount(int saleId) async {
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
  }) async {
    if (saleId <= 0) throw ArgumentError('معرّف الفاتورة غير صالح.');
    if (amount <= 0) throw ArgumentError('مبلغ الرد يجب أن يكون أكبر من صفر.');
    if (paymentMethod.trim().isEmpty) {
      throw ArgumentError('حدد طريقة رد المبلغ.');
    }
    return _database.transaction((txn) async {
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
      return txn.insert('sale_return_refunds', {
        'sale_id': saleId,
        'amount': amount,
        'payment_method': paymentMethod.trim(),
        'note': note?.trim().isEmpty == true ? null : note?.trim(),
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }

  /// مجموع الكميات المرتجعة لبند فاتورة.
  Future<double> returnedQuantity(int saleItemId) async {
    final rows = await _database.rawQuery('''
      SELECT COALESCE(SUM(quantity), 0) AS quantity
      FROM sale_return_items WHERE sale_item_id = ?
    ''', [saleItemId]);
    return (rows.single['quantity'] as num).toDouble();
  }

  // عرض أحدث الفواتير أولًا.
  Future<List<SaleRecord>> recentSales({int limit = 50}) async {
    final rows = await _database.query(
      'sales',
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map(SaleRecord.fromMap).toList(growable: false);
  }
}
