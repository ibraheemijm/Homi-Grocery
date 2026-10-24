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
          columns: ['id', 'name', 'unit', 'selling_price', 'is_active'],
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
        await txn.rawUpdate(
          'UPDATE products SET stock_quantity = stock_quantity - ? WHERE id = ?',
          [line.quantity, productId],
        );
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
