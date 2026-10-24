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

  test('يرفض اسم المورد الفارغ', () async {
    await expectLater(suppliers.addSupplier(name: '  '), throwsArgumentError);
  });
}
