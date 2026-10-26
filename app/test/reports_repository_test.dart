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
    await GroceryDatabase.createCostOfGoodsSchema(database);
    await GroceryDatabase.createPurchasesSchema(database);
    await GroceryDatabase.createSupplierReturnsSchema(database);
    await GroceryDatabase.createSupplierReturnRefundsSchema(database);
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
    final purchaseId = await database.insert('purchases', {
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
    final supplierReturnId = await database.insert('supplier_returns', {
      'purchase_id': purchaseId, 'amount': 25, 'created_at': createdAt,
    });
    await database.insert('supplier_return_refunds', {
      'supplier_return_id': supplierReturnId, 'amount': 10,
      'payment_method': 'نقدي', 'created_at': createdAt,
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
    await database.insert('cash_transactions', {
      'direction': 'in', 'category': 'تحويل وارد', 'amount': 250,
      'payment_method': 'تحويل بنكي', 'created_at': createdAt,
    });
    await database.insert('cash_transactions', {
      'direction': 'out', 'category': 'تحويل صادر', 'amount': 80,
      'payment_method': 'تحويل بنكي', 'created_at': createdAt,
    });
    final productId = await database.insert('products', {
      'name': 'صنف منخفض',
      'unit': 'حبة',
      'purchase_price': 60,
      'selling_price': 100,
      'stock_quantity': 0,
      'minimum_quantity': 1,
      'is_active': 1,
      'created_at': createdAt,
    });
    final saleItemId = await database.insert('sale_items', {
      'sale_id': saleId,
      'product_id': productId,
      'product_name': 'صنف منخفض',
      'unit': 'حبة',
      'quantity': 5,
      'unit_price': 100,
      'cost_price': 60,
      'line_total': 500,
    });
    final returnId = await database.insert('sale_returns', {
      'sale_id': saleId, 'amount': 100, 'created_at': createdAt,
    });
    await database.insert('sale_return_items', {
      'return_id': returnId, 'sale_item_id': saleItemId, 'quantity': 1, 'amount': 100,
    });

    final report = await ReportsRepository(database).load(day: now);
    expect(report.salesTotal, 500);
    expect(report.salesCount, 1);
    expect(report.saleReturns, 100);
    expect(report.grossProfit, 160);
    expect(report.purchaseTotal, 250);
    expect(report.purchaseCount, 1);
    expect(report.customerCollections, 100);
    expect(report.supplierPayments, 50);
    expect(report.supplierRefunds, 10);
    expect(report.returnRefunds, 20);
    expect(report.cashIncome, 650);
    expect(report.cashExpense, 280);
    expect(report.cashNet, 370);
    expect(report.cashOnlyIncome, 400);
    expect(report.cashOnlyExpense, 200);
    expect(report.bankTransferIncome, 250);
    expect(report.bankTransferExpense, 80);
    expect(report.lowStockCount, 1);
  });

  test('يجمع التقرير الشهري وصافي كميات الأصناف بعد مرتجعات الفترة', () async {
    final start = DateTime(2026, 5, 1);
    final end = DateTime(2026, 6, 1);
    final mayAt = DateTime(2026, 5, 10, 12).toUtc().toIso8601String();
    final aprilAt = DateTime(2026, 4, 10, 12).toUtc().toIso8601String();
    final juneAt = DateTime(2026, 6, 2, 12).toUtc().toIso8601String();

    Future<int> addProduct(String name) => database.insert('products', {
      'name': name,
      'unit': 'حبة',
      'purchase_price': 10,
      'selling_price': 20,
      'stock_quantity': 10,
      'minimum_quantity': 0,
      'is_active': 1,
      'created_at': mayAt,
    });

    Future<int> addSale(String invoice, String date, int total) => database.insert('sales', {
      'invoice_number': invoice,
      'subtotal': total,
      'discount': 0,
      'total': total,
      'paid_amount': total,
      'payment_method': 'نقدي',
      'created_at': date,
    });

    Future<int> addItem(int saleId, int productId, String name, double quantity, int total) =>
        database.insert('sale_items', {
          'sale_id': saleId,
          'product_id': productId,
          'product_name': name,
          'unit': 'حبة',
          'quantity': quantity,
          'unit_price': 20,
          'cost_price': 10,
          'line_total': total,
        });

    final sugar = await addProduct('سكر');
    final oil = await addProduct('زيت');
    final flour = await addProduct('دقيق');

    final maySaleA = await addSale('PERIOD-A', mayAt, 200);
    final maySaleB = await addSale('PERIOD-B', mayAt, 120);
    final aprilSale = await addSale('PERIOD-APRIL', aprilAt, 400);
    await addSale('PERIOD-JUNE', juneAt, 900);

    final sugarItem = await addItem(maySaleA, sugar, 'سكر', 10, 200);
    await addItem(maySaleB, oil, 'زيت', 6, 120);
    final flourItem = await addItem(aprilSale, flour, 'دقيق', 20, 400);

    final sugarReturn = await database.insert('sale_returns', {
      'sale_id': maySaleA,
      'amount': 60,
      'created_at': mayAt,
    });
    await database.insert('sale_return_items', {
      'return_id': sugarReturn,
      'sale_item_id': sugarItem,
      'quantity': 3,
      'amount': 60,
    });

    final flourReturn = await database.insert('sale_returns', {
      'sale_id': aprilSale,
      'amount': 300,
      'created_at': mayAt,
    });
    await database.insert('sale_return_items', {
      'return_id': flourReturn,
      'sale_item_id': flourItem,
      'quantity': 15,
      'amount': 300,
    });

    final report = await ReportsRepository(database).loadPeriod(
      start: start,
      end: end,
    );

    expect(report.salesTotal, 320);
    expect(report.salesCount, 2);
    expect(report.returnsTotal, 360);
    expect(report.netSalesTotal, -40);
    // مجمل الربح = صافي المبيعات - تكلفة مبيعات الفترة + تكلفة المرتجعات المسجلة فيها.
    expect(report.grossProfit, -20);
    expect(report.products.map((product) => product.name), ['سكر', 'زيت', 'دقيق']);
    expect(report.products.map((product) => product.netQuantity), [7, 6, -15]);

  });
  test('لا يعرض ربحًا عندما تكون تكلفة صنف في فاتورة قديمة غير محفوظة', () async {
    final now = DateTime.now();
    final createdAt = DateTime(now.year, now.month, now.day, 12)
        .toUtc()
        .toIso8601String();
    final productId = await database.insert('products', {
      'name': 'صنف تاريخي',
      'unit': 'حبة',
      'purchase_price': 40,
      'selling_price': 100,
      'stock_quantity': 0,
      'minimum_quantity': 0,
      'is_active': 1,
      'created_at': createdAt,
    });
    final saleId = await database.insert('sales', {
      'invoice_number': 'REPORT-MISSING-COST',
      'subtotal': 100,
      'discount': 0,
      'total': 100,
      'paid_amount': 100,
      'payment_method': 'نقدي',
      'created_at': createdAt,
    });
    await database.insert('sale_items', {
      'sale_id': saleId,
      'product_id': productId,
      'product_name': 'صنف تاريخي',
      'unit': 'حبة',
      'quantity': 1,
      'unit_price': 100,
      'line_total': 100,
      // cost_price متروك null عمدًا لمحاكاة فاتورة سابقة لترحيل التكلفة.
    });

    final report = await ReportsRepository(database).load(day: now);

    expect(report.salesTotal, 100);
    expect(report.grossProfit, isNull);

    final periodStart = DateTime(now.year, now.month, now.day);
    final periodReport = await ReportsRepository(database).loadPeriod(
      start: periodStart,
      end: periodStart.add(const Duration(days: 1)),
    );
    expect(periodReport.grossProfit, isNull);
  });

}
