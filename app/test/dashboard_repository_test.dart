// اختبارات إحصاءات اللوحة الرئيسية اعتمادًا على البيانات المحلية.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/customer_repository.dart';
import 'package:homi_grocery/data/cash_shift_repository.dart';
import 'package:homi_grocery/data/dashboard_repository.dart';
import 'package:homi_grocery/data/grocery_database.dart';
import 'package:homi_grocery/data/product_repository.dart';
import 'package:homi_grocery/data/sale_repository.dart';

void main() {
  late Database database;
  late int managerId;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createAuthSchema(database);
    managerId = await database.insert('users', {
      'username': 'dashboard_manager', 'display_name': 'مدير اللوحة',
      'password_hash': 'test-hash', 'password_salt': 'test-salt',
      'password_iterations': 100000, 'role': 'manager', 'is_active': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await GroceryDatabase.createSalesSchema(database);
    await GroceryDatabase.createCostOfGoodsSchema(database);
    await GroceryDatabase.createCustomersSchema(database);
    await GroceryDatabase.createOpeningBalancesSchema(database);
    await GroceryDatabase.createStockMovementsSchema(database);
    await GroceryDatabase.createSalesReturnsSchema(database);
    await GroceryDatabase.createSaleReturnRefundsSchema(database);
    await GroceryDatabase.createCashTransactionsSchema(database);
    await GroceryDatabase.createCashShiftsSchema(database);
  });

  Future<int> ensureManagerShift() async {
    final shifts = CashShiftRepository(database);
    final current = await shifts.getOpenShift(userId: managerId);
    if (current != null) {
      if (current.userId != managerId) {
        throw StateError('وردية الاختبار المفتوحة لا تخص المدير.');
      }
      return current.id;
    }
    return (await shifts.openShift(userId: managerId, openingCash: 0)).id;
  }

  tearDown(() async => database.close());

  test('يحمي ملخص اللوحة وسجل الفواتير بصلاحيات القراءة المخصصة', () async {
    final cashierId = await database.insert('users', {
      'username': 'dashboard_reader', 'display_name': 'قارئ اللوحة',
      'password_hash': 'test-hash', 'password_salt': 'test-salt',
      'password_iterations': 100000, 'role': 'cashier', 'is_active': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    final dashboard = DashboardRepository(database);
    await expectLater(dashboard.load(userId: cashierId), throwsA(isA<StateError>()));
    await expectLater(dashboard.loadRecentInvoices(userId: cashierId), throwsA(isA<StateError>()));

    for (final key in ['view_reports', 'view_invoice_history']) {
      await database.insert('cashier_permissions', {
        'user_id': cashierId,
        'permission_key': key,
        'is_allowed': 1,
        'max_amount': null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    }
    expect(await dashboard.load(userId: cashierId), isA<DashboardStats>());
    expect(await dashboard.loadRecentInvoices(userId: cashierId), isEmpty);
  });

  test('تحسب المبيعات والمدفوعات والديون والأصناف المنخفضة من قاعدة البيانات', () async {
    final products = ProductRepository(database, userId: managerId);
    final sales = SaleRepository(database);
    final customers = CustomerRepository(database);

    final soldId = await products.add(const GroceryProduct(
      name: 'سكر', sellingPrice: 500, stockQuantity: 5,
    ));
    final soldProduct = (await products.getById(soldId))!;
    await sales.createSale(
      lines: [SaleLine(product: soldProduct, quantity: 1)],
      discount: 0,
      paidAmount: 200,
      paymentMethod: 'جزئي',
      customerName: 'زبون اللوحة',
    
      userId: managerId, shiftId: await ensureManagerShift());
    final customer = (await customers.balances(userId: managerId)).single;
    await customers.recordPayment(customerId: customer.id, amount: 100, userId: managerId, shiftId: await ensureManagerShift());

    await products.add(const GroceryProduct(
      name: 'حليب منخفض', sellingPrice: 100, stockQuantity: 1, minimumQuantity: 2,
    ));

    final stats = await DashboardRepository(database).load(userId: managerId, now: DateTime.now());
    expect(stats.todaySales, 500);
    expect(stats.todayPaid, 200);
    expect(stats.customerDebt, 200);
    expect(stats.lowStockCount, 1);
  });

  test('تضيف أرصدة الزبائن الافتتاحية إلى إجمالي الديون في لوحة التحكم', () async {
    final customers = CustomerRepository(database);
    await customers.addCustomer(name: 'زبون برصيد قديم', userId: managerId, openingBalance: 750);

    final stats = await DashboardRepository(database).load(userId: managerId, now: DateTime.now());
    expect(stats.customerDebt, 750);
  });

  test('تخصم مرتجعات اليوم وردود النقد الفعلية من صافي لوحة التحكم', () async {
    final products = ProductRepository(database, userId: managerId);
    final sales = SaleRepository(database);
    final productId = await products.add(const GroceryProduct(
      name: 'صابون', sellingPrice: 250, stockQuantity: 4,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 0,
      paidAmount: 500,
      paymentMethod: 'نقدي',
      userId: managerId,
      shiftId: await ensureManagerShift());
    final itemId = (await database.query(
      'sale_items', columns: ['id'], where: 'sale_id = ?', whereArgs: [sale.id],
    )).single['id'] as int;

    await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 1},
    
      userId: managerId);
    await sales.recordReturnRefund(
      saleId: sale.id,
      amount: 250,
      userId: managerId,
      shiftId: await ensureManagerShift(),
    );

    final stats = await DashboardRepository(database).load(userId: managerId, now: DateTime.now());
    expect(stats.todaySales, 250);
    expect(stats.todayPaid, 250);
  });

  test('تعيد آخر الفواتير من الأحدث إلى الأقدم بدل الحالة الفارغة الثابتة', () async {
    await database.insert('sales', {
      'invoice_number': 'INV-OLD',
      'customer_name': 'زبون قديم',
      'subtotal': 100,
      'discount': 0,
      'total': 100,
      'paid_amount': 100,
      'payment_method': 'نقدي',
      'created_at': '2026-01-01T10:00:00.000',
    });
    await database.insert('sales', {
      'invoice_number': 'INV-NEW',
      'customer_name': 'زبون جديد',
      'subtotal': 250,
      'discount': 0,
      'total': 250,
      'paid_amount': 100,
      'payment_method': 'جزئي',
      'created_at': '2026-01-02T10:00:00.000',
    });

    final invoices = await DashboardRepository(database).loadRecentInvoices(userId: managerId);
    expect(invoices.map((invoice) => invoice.invoiceNumber).toList(),
        ['INV-NEW', 'INV-OLD']);
    expect(invoices.first.customerName, 'زبون جديد');
    expect(invoices.first.remaining, 150);
  });

  test('تتعامل مع قاعدة فواتير فارغة دون خطأ', () async {
    final invoices = await DashboardRepository(database).loadRecentInvoices(userId: managerId);
    expect(invoices, isEmpty);
  });

  test('يعرض اسم الزبون النقدي عند غياب اسم الزبون', () async {
    await database.insert('sales', {
      'invoice_number': 'INV-CASH',
      'customer_name': null,
      'subtotal': 75,
      'discount': 0,
      'total': 75,
      'paid_amount': 75,
      'payment_method': 'نقدي',
      'created_at': '2026-01-03T10:00:00.000',
    });

    final invoices = await DashboardRepository(database).loadRecentInvoices(userId: managerId);

    expect(invoices.single.customerName, 'زبون نقدي');
  });

  test('يكسر تعادل وقت الإنشاء بمعرّف الفاتورة ويحترم حد القائمة', () async {
    for (var id = 1; id <= 3; id++) {
      await database.insert('sales', {
        'id': id,
        'invoice_number': 'INV-$id',
        'customer_name': 'زبون $id',
        'subtotal': 100,
        'discount': 0,
        'total': 100,
        'paid_amount': 100,
        'payment_method': 'نقدي',
        'created_at': '2026-01-04T10:00:00.000',
      });
    }

    final invoices = await DashboardRepository(database).loadRecentInvoices(userId: managerId, limit: 2);

    expect(invoices.map((invoice) => invoice.invoiceNumber).toList(),
        ['INV-3', 'INV-2']);
  });

}
