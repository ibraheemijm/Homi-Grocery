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
      customerName: 'زبون اختبار',
    );

    expect(sale.total, 1800);
    expect(sale.paidAmount, 1000);
    expect(sale.remainingAmount, 800);
    expect(sale.customerName, 'زبون اختبار');
    expect((await products.getById(productId))!.stockQuantity, 8);
    expect((await sales.recentSales()).length, 1);
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
}
