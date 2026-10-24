import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/grocery_database.dart';
import 'package:homi_grocery/data/reports_repository.dart';

void main() {
  late Database database;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createSalesSchema(database);
    await GroceryDatabase.createCustomersSchema(database);
    await GroceryDatabase.createStockMovementsSchema(database);
    await GroceryDatabase.createSalesReturnsSchema(database);
    await GroceryDatabase.createPurchasesSchema(database);
    await GroceryDatabase.createSaleReturnRefundsSchema(database);
    await GroceryDatabase.createCashTransactionsSchema(database);
  });

  tearDown(() async => database.close());

  test('يجمع تقرير اليوم من الفواتير والتحصيلات والخزينة', () async {
    final now = DateTime.now();
    final createdAt = DateTime(now.year, now.month, now.day, 12).toUtc().toIso8601String();
    final customerId = await database.insert('customers', {
      'name': 'زبون التقرير',
      'created_at': createdAt,
    });
    final supplierId = await database.insert('suppliers', {
      'name': 'مورد التقرير',
      'created_at': createdAt,
    });
    final saleId = await database.insert('sales', {
      'invoice_number': 'REPORT-SALE-1',
      'customer_id': customerId,
      'customer_name': 'زبون التقرير',
      'subtotal': 500,
      'discount': 0,
      'total': 500,
      'paid_amount': 300,
      'payment_method': 'جزئي',
      'created_at': createdAt,
    });
    await database.insert('purchases', {
      'invoice_number': 'REPORT-PURCHASE-1',
      'supplier_id': supplierId,
      'subtotal': 250,
      'discount': 0,
      'total': 250,
      'paid_amount': 50,
      'payment_method': 'جزئي',
      'created_at': createdAt,
    });
    await database.insert('customer_payments', {
      'customer_id': customerId, 'amount': 100, 'created_at': createdAt,
    });
    await database.insert('supplier_payments', {
      'supplier_id': supplierId, 'amount': 50, 'created_at': createdAt,
    });
    await database.insert('sale_return_refunds', {
      'sale_id': saleId, 'amount': 20, 'payment_method': 'نقدي', 'created_at': createdAt,
    });
    await database.insert('cash_transactions', {
      'direction': 'in', 'category': 'مبيعات', 'amount': 400,
      'payment_method': 'نقدي', 'created_at': createdAt,
    });
    await database.insert('cash_transactions', {
      'direction': 'out', 'category': 'مصروف', 'amount': 200,
      'payment_method': 'نقدي', 'created_at': createdAt,
    });
    await database.insert('products', {
      'name': 'صنف منخفض',
      'unit': 'حبة',
      'purchase_price': 10,
      'selling_price': 20,
      'stock_quantity': 0,
      'minimum_quantity': 1,
      'is_active': 1,
      'created_at': createdAt,
    });

    final report = await ReportsRepository(database).load(day: now);
    expect(report.salesTotal, 500);
    expect(report.salesCount, 1);
    expect(report.purchaseTotal, 250);
    expect(report.purchaseCount, 1);
    expect(report.customerCollections, 100);
    expect(report.supplierPayments, 50);
    expect(report.returnRefunds, 20);
    expect(report.cashIncome, 400);
    expect(report.cashExpense, 200);
    expect(report.cashNet, 200);
    expect(report.lowStockCount, 1);
  });
}
