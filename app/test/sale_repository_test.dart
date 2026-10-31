// اختبارات إنشاء الفواتير وتحديث المخزون كوحدة عمل واحدة.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/grocery_database.dart';
import 'package:homi_grocery/data/product_repository.dart';
import 'package:homi_grocery/data/sale_repository.dart';

void main() {
  late Database database;
  late ProductRepository products;
  late SaleRepository sales;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createSalesSchema(database);
    await GroceryDatabase.createCustomersSchema(database);
    await GroceryDatabase.createStockMovementsSchema(database);
    await GroceryDatabase.createSalesReturnsSchema(database);
    await GroceryDatabase.createCashTransactionsSchema(database);
    await GroceryDatabase.createSaleReturnRefundsSchema(database);
    await GroceryDatabase.createCostOfGoodsSchema(database);
    products = ProductRepository(database);
    sales = SaleRepository(database);
  });

  tearDown(() async {
    await database.close();
  });

  test('يحفظ الفاتورة ويخصم الكمية من المخزون', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'سكر',
      unit: 'كيلوجرام',
      sellingPrice: 1000,
      stockQuantity: 10,
    ));
    final product = (await products.getById(productId))!;

    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 200,
      paidAmount: 1000,
      paymentMethod: 'جزئي',
      paymentChannel: 'تحويل بنكي',
      customerName: 'زبون اختبار',
    );

    expect(sale.total, 1800);
    expect(sale.paidAmount, 1000);
    expect(sale.remainingAmount, 800);
    expect(sale.customerName, 'زبون اختبار');
    expect((await products.getById(productId))!.stockQuantity, 8);
    expect((await sales.recentSales()).length, 1);
    final cashEntries = await database.query('cash_transactions', where: "reference_type = 'sale'");
    expect(cashEntries, hasLength(1));
    expect(cashEntries.single['direction'], 'in');
    expect(cashEntries.single['amount'], 1000);
    expect(cashEntries.single['payment_method'], 'تحويل بنكي');
  });


  test('يحسب بيع نصف وربع الكيلوجرام ويخصم الوزن الكسري من المخزون', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'سكر',
      unit: 'كيلوجرام',
      sellingPrice: 2000,
      stockQuantity: 2,
    ));
    final product = (await products.getById(productId))!;
    final halfKilo = SaleLine(product: product, quantity: 0.5);
    final quarterKilo = SaleLine(product: product, quantity: 0.25);

    expect(halfKilo.lineTotal, 1000);
    expect(quarterKilo.lineTotal, 500);

    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 0.75)],
      discount: 0,
      paidAmount: 1500,
      paymentMethod: 'نقدي',
    );

    expect(sale.total, 1500);
    expect((await products.getById(productId))!.stockQuantity, 1.25);
    final item = (await database.query(
      'sale_items', where: 'sale_id = ?', whereArgs: [sale.id],
    )).single;
    expect(item['quantity'], 0.75);
    expect(item['unit'], 'كيلوجرام');
  });

  test('البيع النقدي لا يحفظ اسم الزبون ولا ينشئ حسابًا حتى مع تطابق الاسم', () async {
    await database.insert('customers', {
      'name': 'محمد أحمد',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    final productId = await products.add(const GroceryProduct(
      name: 'ماء', sellingPrice: 100, stockQuantity: 5,
    ));
    final product = (await products.getById(productId))!;

    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 0,
      paidAmount: 100,
      paymentMethod: 'نقدي',
      customerName: 'محمد أحمد',
    );

    expect(sale.customerName, isNull);
    final savedSale = (await database.query(
      'sales', where: 'id = ?', whereArgs: [sale.id],
    )).single;
    expect(savedSale['customer_id'], isNull);
    expect(savedSale['customer_name'], isNull);
    expect(await database.query('customers'), hasLength(1));
  });

  test('الدين لا يرتبط بحساب موجود إلا عند تمرير معرّف الحساب المختار', () async {
    final customerId = await database.insert('customers', {
      'name': 'محمد أحمد',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    final productId = await products.add(const GroceryProduct(
      name: 'خبز', sellingPrice: 200, stockQuantity: 5,
    ));
    final product = (await products.getById(productId))!;

    await expectLater(
      sales.createSale(
        lines: [SaleLine(product: product, quantity: 1)],
        discount: 0,
        paidAmount: 0,
        paymentMethod: 'آجل',
        customerName: 'محمد أحمد',
      ),
      throwsStateError,
    );
    expect(await sales.recentSales(), isEmpty);

    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 0,
      paidAmount: 0,
      paymentMethod: 'آجل',
      customerName: 'محمد أحمد',
      customerId: customerId,
    );
    final savedSale = (await database.query(
      'sales', where: 'id = ?', whereArgs: [sale.id],
    )).single;
    expect(savedSale['customer_id'], customerId);
    expect(savedSale['customer_name'], 'محمد أحمد');
    expect(await database.query('customers'), hasLength(1));
  });

  test('يحفظ تكلفة الصنف وقت البيع لا سعر الشراء الذي قد يتغير لاحقًا', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'قهوة', purchasePrice: 40, sellingPrice: 100, stockQuantity: 5,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 0,
      paidAmount: 200,
      paymentMethod: 'نقدي',
    );
    final item = (await database.query(
      'sale_items', where: 'sale_id = ?', whereArgs: [sale.id],
    )).single;
    expect(item['cost_price'], 40);
    await database.update('products', {'purchase_price': 75}, where: 'id = ?', whereArgs: [productId]);
    final saved = (await database.query(
      'sale_items', where: 'sale_id = ?', whereArgs: [sale.id],
    )).single;
    expect(saved['cost_price'], 40);
  });

  test('يرفض الخصم الزائد دون حفظ فاتورة أو تعديل المخزون', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'زيت',
      sellingPrice: 500,
      stockQuantity: 4,
    ));
    final product = (await products.getById(productId))!;

    await expectLater(
      sales.createSale(
        lines: [SaleLine(product: product, quantity: 1)],
        discount: 600,
        paidAmount: 0,
        paymentMethod: 'آجل',
      ),
      throwsArgumentError,
    );

    expect(await sales.recentSales(), isEmpty);
    expect((await products.getById(productId))!.stockQuantity, 4);
  });

  test('يعيد الكمية إلى المخزون ويسجل المرتجع مرة واحدة', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'حليب', sellingPrice: 250, stockQuantity: 5,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 3)],
      discount: 0,
      paidAmount: 750,
      paymentMethod: 'نقدي',
    );
    final item = (await database.query(
      'sale_items',
      columns: ['id'],
      where: 'sale_id = ?',
      whereArgs: [sale.id],
    )).single;
    final itemId = item['id'] as int;

    final returned = await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 1},
      note: 'عبوة تالفة',
    );

    expect(returned.amount, 250);
    expect((await products.getById(productId))!.stockQuantity, 3);
    expect(await sales.returnedQuantity(itemId), 1);
    final movements = await database.query(
      'stock_movements',
      where: "reference_type = 'sale_return'",
    );
    expect(movements, hasLength(1));
    expect(movements.single['quantity_delta'], 1);
  });

  test('يرفض تكرار إرجاع كمية تتجاوز المتبقي دون تغيير المخزون', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'زيت', sellingPrice: 100, stockQuantity: 2,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 0,
      paidAmount: 200,
      paymentMethod: 'نقدي',
    );
    final itemId = (await database.query(
      'sale_items',
      columns: ['id'],
      where: 'sale_id = ?',
      whereArgs: [sale.id],
    )).single['id'] as int;

    await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 1},
    );
    await expectLater(
      sales.returnItems(
        saleId: sale.id,
        quantitiesBySaleItemId: {itemId: 1.1},
      ),
      throwsArgumentError,
    );

    expect((await products.getById(productId))!.stockQuantity, 1);
    expect(await sales.returnedQuantity(itemId), 1);
    expect(await database.query('sale_returns'), hasLength(1));
  });

  test('لا يسمح برد نقد يتجاوز فائض المرتجع عن الدين الأصلي للفاتورة', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'منظف', sellingPrice: 100, stockQuantity: 4,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 0,
      paidAmount: 100,
      paymentMethod: 'جزئي',
      customerName: 'زبون مرتجع',
    );
    final itemId = (await database.query(
      'sale_items', columns: ['id'], where: 'sale_id = ?', whereArgs: [sale.id],
    )).single['id'] as int;

    final returned = await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 2},
    );
    expect(returned.amount, 200);
    expect(await sales.maximumRefundableAmount(sale.id), 100);

    await expectLater(
      sales.recordReturnRefund(saleId: sale.id, amount: 101),
      throwsArgumentError,
    );
    await sales.recordReturnRefund(
      saleId: sale.id, amount: 80, paymentMethod: 'نقدي', note: 'رد فعلي',
    );
    expect(await sales.maximumRefundableAmount(sale.id), 20);
    await sales.recordReturnRefund(saleId: sale.id, amount: 20);
    expect(await sales.maximumRefundableAmount(sale.id), 0);
    expect(await database.query('sale_return_refunds'), hasLength(2));
    final cashEntries = await database.query(
      'cash_transactions',
      where: "reference_type = 'sale_return_refund'",
    );
    expect(cashEntries, hasLength(2));
    expect(cashEntries.fold<int>(0, (sum, row) => sum + (row['amount'] as int)), 100);
    expect(cashEntries.every((row) => row['direction'] == 'out'), isTrue);
  });

  test('المرتجع لفاتورة مدفوعة بالكامل يسمح برد قيمة المرتجع فقط', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'صابون', sellingPrice: 75, stockQuantity: 3,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 0,
      paidAmount: 150,
      paymentMethod: 'نقدي',
    );
    final itemId = (await database.query(
      'sale_items', columns: ['id'], where: 'sale_id = ?', whereArgs: [sale.id],
    )).single['id'] as int;
    await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 1},
    );

    expect(await sales.maximumRefundableAmount(sale.id), 75);
    await sales.recordReturnRefund(saleId: sale.id, amount: 75);
    expect(await sales.maximumRefundableAmount(sale.id), 0);
    await expectLater(
      sales.recordReturnRefund(saleId: sale.id, amount: 1),
      throwsArgumentError,
    );
  });

  test('يوزع خصم الفاتورة على المرتجعات الجزئية دون تجاوز القيمة المدفوعة', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'أرز', sellingPrice: 100, stockQuantity: 4,
    ));
    final product = (await products.getById(productId))!;
    final sale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 40,
      paidAmount: 160,
      paymentMethod: 'نقدي',
    );
    final itemId = (await database.query(
      'sale_items',
      columns: ['id'],
      where: 'sale_id = ?',
      whereArgs: [sale.id],
    )).single['id'] as int;

    final first = await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 1},
    );
    final second = await sales.returnItems(
      saleId: sale.id,
      quantitiesBySaleItemId: {itemId: 1},
    );

    expect(first.amount, 80);
    expect(second.amount, 80);
    final returns = await database.query('sale_returns');
    expect(
      returns.fold<int>(0, (sum, row) => sum + (row['amount'] as int)),
      160,
    );
    expect((await products.getById(productId))!.stockQuantity, 4);
  });

  test('يسمح بالمخزون السالب وفق سياسة المشروع', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'حليب',
      sellingPrice: 300,
      stockQuantity: 1,
    ));
    final product = (await products.getById(productId))!;

    await sales.createSale(
      lines: [SaleLine(product: product, quantity: 2)],
      discount: 0,
      paidAmount: 600,
      paymentMethod: 'نقدي',
    );

    expect((await products.getById(productId))!.stockQuantity, -1);
  });

  test('يربط البيع النقدي بمستخدم الوردية ولا يربط التحويل البنكي بدرج النقدية', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'ماء', sellingPrice: 100, stockQuantity: 4,
    ));
    final product = (await products.getById(productId))!;

    final cashSale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 0,
      paidAmount: 100,
      paymentMethod: 'نقدي',
      userId: 7,
      shiftId: 12,
    );
    final cashEntry = (await database.query(
      'cash_transactions',
      where: "reference_type = 'sale' AND reference_id = ?",
      whereArgs: [cashSale.id],
    )).single;
    expect(cashEntry['user_id'], 7);
    expect(cashEntry['shift_id'], 12);

    final bankSale = await sales.createSale(
      lines: [SaleLine(product: product, quantity: 1)],
      discount: 0,
      paidAmount: 100,
      paymentMethod: 'نقدي',
      paymentChannel: 'تحويل بنكي',
      userId: 7,
      shiftId: 12,
    );
    final bankEntry = (await database.query(
      'cash_transactions',
      where: "reference_type = 'sale' AND reference_id = ?",
      whereArgs: [bankSale.id],
    )).single;
    expect(bankEntry['user_id'], 7);
    expect(bankEntry['shift_id'], isNull);
    expect(bankEntry['payment_method'], 'تحويل بنكي');
  });

}
