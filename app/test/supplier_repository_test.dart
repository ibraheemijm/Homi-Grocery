// اختبارات الموردين والمشتريات وتحديث المخزون والمدفوعات.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/grocery_database.dart';
import 'package:homi_grocery/data/product_repository.dart';
import 'package:homi_grocery/data/supplier_repository.dart';

void main() {
  late Database database;
  late ProductRepository products;
  late SupplierRepository suppliers;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createSalesSchema(database);
    await GroceryDatabase.createCustomersSchema(database);
    await GroceryDatabase.createStockMovementsSchema(database);
    await GroceryDatabase.createSalesReturnsSchema(database);
    await GroceryDatabase.createPurchasesSchema(database);
    await GroceryDatabase.createCashTransactionsSchema(database);
    await GroceryDatabase.createSupplierReturnsSchema(database);
    await GroceryDatabase.createSupplierReturnRefundsSchema(database);
    products = ProductRepository(database);
    suppliers = SupplierRepository(database);
  });

  tearDown(() async => database.close());

  test('يحفظ فاتورة الشراء ويزيد المخزون ويسجل حركة الشراء', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'سكر', purchasePrice: 100, sellingPrice: 150, stockQuantity: 4,
    ));
    final supplierId = await suppliers.addSupplier(name: 'مورد السكر');
    final purchase = await suppliers.createPurchase(
      supplierId: supplierId,
      lines: [PurchaseLine(productId: productId, productName: 'سكر', unit: 'كيلوجرام', quantity: 3, unitCost: 120)],
      discount: 20,
      paidAmount: 100,
      paymentMethod: 'جزئي',
    );

    expect(purchase.subtotal, 360);
    expect(purchase.total, 340);
    expect(purchase.remainingAmount, 240);
    expect((await products.getById(productId))!.stockQuantity, 7);
    expect((await products.getById(productId))!.purchasePrice, 120);
    expect(await database.query('purchase_items'), hasLength(1));
    final movements = await database.query('stock_movements', where: "reference_type = 'purchase'");
    expect(movements, hasLength(1));
    expect(movements.single['quantity_delta'], 3);
    expect((await suppliers.balances()).single.balance, 240);
    final cashEntries = await database.query('cash_transactions', where: "reference_type = 'purchase'");
    expect(cashEntries, hasLength(1));
    expect(cashEntries.single['direction'], 'out');
    expect(cashEntries.single['amount'], 100);
  });

  test('يدعم عدة أصناف في فاتورة واحدة ويحدّث المخزون لكل صنف', () async {
    final riceId = await products.add(const GroceryProduct(
      name: 'أرز', purchasePrice: 100, sellingPrice: 150, stockQuantity: 2,
    ));
    final oilId = await products.add(const GroceryProduct(
      name: 'زيت', purchasePrice: 200, sellingPrice: 280, stockQuantity: 5,
    ));
    final supplierId = await suppliers.addSupplier(name: 'مورد متعدد الأصناف');

    final purchase = await suppliers.createPurchase(
      supplierId: supplierId,
      lines: [
        PurchaseLine(productId: riceId, productName: 'أرز', unit: 'كيلوجرام', quantity: 3, unitCost: 110),
        PurchaseLine(productId: oilId, productName: 'زيت', unit: 'عبوة', quantity: 2, unitCost: 210),
      ],
      discount: 20,
      paidAmount: 100,
    );

    expect(purchase.subtotal, 750);
    expect(purchase.total, 730);
    expect((await products.getById(riceId))!.stockQuantity, 5);
    expect((await products.getById(oilId))!.stockQuantity, 7);
    expect(await database.query('purchase_items'), hasLength(2));
    expect(await database.query('stock_movements', where: "reference_type = 'purchase'"), hasLength(2));
  });

  test('أي صنف غير موجود يلغي فاتورة الشراء وكل تغييرات المخزون', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'طحين', purchasePrice: 100, sellingPrice: 150, stockQuantity: 3,
    ));
    final supplierId = await suppliers.addSupplier(name: 'مورد الطحين');

    await expectLater(
      suppliers.createPurchase(
        supplierId: supplierId,
        lines: [
          PurchaseLine(productId: productId, productName: 'طحين', unit: 'كيلوجرام', quantity: 2, unitCost: 100),
          const PurchaseLine(productId: 999999, productName: 'غير موجود', unit: 'حبة', quantity: 1, unitCost: 50),
        ],
        paidAmount: 0,
      ),
      throwsArgumentError,
    );

    expect((await products.getById(productId))!.stockQuantity, 3);
    expect(await database.query('purchases'), isEmpty);
    expect(await database.query('purchase_items'), isEmpty);
    expect(await database.query('stock_movements', where: "reference_type = 'purchase'"), isEmpty);
  });

  test('يرفض الخصم أو المدفوع الزائد دون تعديل المخزون', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'أرز', purchasePrice: 100, sellingPrice: 150, stockQuantity: 2,
    ));
    final supplierId = await suppliers.addSupplier(name: 'مورد الأرز');
    final line = PurchaseLine(productId: productId, productName: 'أرز', unit: 'كيلوجرام', quantity: 2, unitCost: 100);

    await expectLater(
      suppliers.createPurchase(supplierId: supplierId, lines: [line], discount: 201, paidAmount: 0),
      throwsArgumentError,
    );
    await expectLater(
      suppliers.createPurchase(supplierId: supplierId, lines: [line], paidAmount: 201),
      throwsArgumentError,
    );
    expect((await products.getById(productId))!.stockQuantity, 2);
    expect(await database.query('purchases'), isEmpty);
    expect(await database.query('stock_movements', where: "reference_type = 'purchase'"), isEmpty);
  });

  test('يسجل دفعة المورد ويمنع تجاوز المستحق', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'زيت', purchasePrice: 50, sellingPrice: 80, stockQuantity: 1,
    ));
    final supplierId = await suppliers.addSupplier(name: 'مورد الزيت');
    await suppliers.createPurchase(
      supplierId: supplierId,
      lines: [PurchaseLine(productId: productId, productName: 'زيت', unit: 'عبوة', quantity: 2, unitCost: 50)],
      paidAmount: 20,
    );

    expect((await suppliers.balances()).single.balance, 80);
    await suppliers.recordPayment(supplierId: supplierId, amount: 30, note: 'دفعة نقدية');
    expect((await suppliers.balances()).single.balance, 50);
    await expectLater(
      suppliers.recordPayment(supplierId: supplierId, amount: 51),
      throwsArgumentError,
    );
    expect(await database.query('supplier_payments'), hasLength(1));
  });

  test('يعرض سجل فواتير الشراء وبنودها كما حُفظت', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'سكر', purchasePrice: 100, sellingPrice: 150, stockQuantity: 0,
    ));
    final supplierId = await suppliers.addSupplier(name: 'مورد السكر');
    final purchase = await suppliers.createPurchase(
      supplierId: supplierId,
      lines: [
        PurchaseLine(productId: productId, productName: 'سكر وقت الشراء', unit: 'كيلوجرام', quantity: 2, unitCost: 125),
      ],
      discount: 10,
      paidAmount: 100,
      note: 'اختبار السجل',
    );

    final history = await suppliers.purchaseHistory();
    expect(history, hasLength(1));
    expect(history.single.id, purchase.id);
    expect(history.single.invoiceNumber, purchase.invoiceNumber);
    expect(history.single.supplierName, 'مورد السكر');
    expect(history.single.subtotal, 250);
    expect(history.single.discount, 10);
    expect(history.single.total, 240);
    expect(history.single.paidAmount, 100);
    expect(history.single.remainingAmount, 140);
    expect(history.single.note, 'اختبار السجل');

    final items = await suppliers.purchaseItems(purchase.id);
    expect(items, hasLength(1));
    expect(items.single.productName, 'سكر وقت الشراء');
    expect(items.single.unitCost, 125);
    expect(items.single.lineTotal, 250);
    expect(await suppliers.purchaseHistory(supplierId: supplierId), hasLength(1));
    expect(await suppliers.purchaseHistory(supplierId: supplierId + 1), isEmpty);
  });

  test('يرفض حد سجل مشتريات غير صالح', () async {
    await expectLater(suppliers.purchaseHistory(limit: 0), throwsArgumentError);
    await expectLater(suppliers.purchaseHistory(limit: 1001), throwsArgumentError);
  });

  test('مرتجع المورد يخفض المخزون والمستحق ويسجل حركة عكسية ذريًا', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'أرز', purchasePrice: 100, sellingPrice: 150, stockQuantity: 0,
    ));
    final supplierId = await suppliers.addSupplier(name: 'مورد الأرز');
    final purchase = await suppliers.createPurchase(
      supplierId: supplierId,
      lines: [PurchaseLine(productId: productId, productName: 'أرز', unit: 'كيلوجرام', quantity: 4, unitCost: 100)],
      paidAmount: 0,
    );
    final items = await suppliers.returnablePurchaseItems(purchase.id);
    final itemId = items.single['id'] as int;

    final returnId = await suppliers.createSupplierReturn(
      purchaseId: purchase.id,
      quantitiesByPurchaseItemId: {itemId: 1},
      note: 'صنف تالف',
    );

    expect((await products.getById(productId))!.stockQuantity, 3);
    expect((await suppliers.balances()).single.balance, 300);
    final returns = await database.query('supplier_returns', where: 'id = ?', whereArgs: [returnId]);
    expect(returns.single['amount'], 100);
    final lines = await database.query('supplier_return_items', where: 'return_id = ?', whereArgs: [returnId]);
    expect(lines.single['quantity'], 1);
    final movements = await database.query('stock_movements', where: "reference_type = 'supplier_return'");
    expect(movements, hasLength(1));
    expect(movements.single['quantity_delta'], -1);
    expect(movements.single['stock_before'], 4);
    expect(movements.single['stock_after'], 3);
    expect(await database.query('cash_transactions', where: "reference_type = 'supplier_return'"), isEmpty);
  });

  test('يرفض تجاوز كمية الفاتورة أو المستحق دون تعديل البيانات', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'زيت', purchasePrice: 50, sellingPrice: 80, stockQuantity: 0,
    ));
    final supplierId = await suppliers.addSupplier(name: 'مورد الزيت');
    final purchase = await suppliers.createPurchase(
      supplierId: supplierId,
      lines: [PurchaseLine(productId: productId, productName: 'زيت', unit: 'عبوة', quantity: 2, unitCost: 50)],
      paidAmount: 0,
    );
    final itemId = (await suppliers.returnablePurchaseItems(purchase.id)).single['id'] as int;

    await suppliers.createSupplierReturn(
      purchaseId: purchase.id,
      quantitiesByPurchaseItemId: {itemId: 1},
    );
    await expectLater(
      suppliers.createSupplierReturn(
        purchaseId: purchase.id,
        quantitiesByPurchaseItemId: {itemId: 2},
      ),
      throwsArgumentError,
    );
    expect((await products.getById(productId))!.stockQuantity, 1);
    expect(await database.query('supplier_returns'), hasLength(1));
    expect(await database.query('supplier_return_items'), hasLength(1));
  });

  test('يسمح برصيد دائن بعد مرتجع فاتورة مدفوعة ويسجل الاسترداد النقدي منفصلًا', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'حليب', purchasePrice: 100, sellingPrice: 150, stockQuantity: 0,
    ));
    final supplierId = await suppliers.addSupplier(name: 'مورد الحليب');
    final purchase = await suppliers.createPurchase(
      supplierId: supplierId,
      lines: [PurchaseLine(productId: productId, productName: 'حليب', unit: 'عبوة', quantity: 1, unitCost: 100)],
      paidAmount: 100,
      paymentMethod: 'نقدي',
    );
    final itemId = (await suppliers.returnablePurchaseItems(purchase.id)).single['id'] as int;
    final returnId = await suppliers.createSupplierReturn(
      purchaseId: purchase.id,
      quantitiesByPurchaseItemId: {itemId: 1},
    );

    var balance = (await suppliers.balances()).single;
    expect(balance.balance, -100);
    expect(balance.credit, 100);
    expect(await suppliers.maximumRefundableSupplierReturnAmount(returnId), 100);
    expect(await database.query('cash_transactions', where: "reference_type = 'supplier_return_refund'"), isEmpty);

    await expectLater(
      suppliers.recordSupplierReturnRefund(returnId: returnId, amount: 101),
      throwsArgumentError,
    );
    await suppliers.recordSupplierReturnRefund(
      returnId: returnId,
      amount: 40,
      paymentMethod: 'تحويل بنكي',
    );
    balance = (await suppliers.balances()).single;
    expect(balance.balance, -60);
    expect(balance.credit, 60);
    expect(await suppliers.maximumRefundableSupplierReturnAmount(returnId), 60);
    final cashEntries = await database.query(
      'cash_transactions',
      where: "reference_type = 'supplier_return_refund'",
    );
    expect(cashEntries, hasLength(1));
    expect(cashEntries.single['direction'], 'in');
    expect(cashEntries.single['amount'], 40);
    expect(cashEntries.single['payment_method'], 'تحويل بنكي');
  });

  test('يرفض اسم المورد الفارغ', () async {
    await expectLater(suppliers.addSupplier(name: '  '), throwsArgumentError);
  });
}
