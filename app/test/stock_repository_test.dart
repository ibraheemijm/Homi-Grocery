// اختبارات سجل المخزون لضمان تطابق الحركة مع الرصيد المحفوظ.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/grocery_database.dart';
import 'package:homi_grocery/data/product_repository.dart';
import 'package:homi_grocery/data/stock_repository.dart';

void main() {
  late Database database;
  late ProductRepository products;
  late StockRepository stock;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createStockMovementsSchema(database);
    products = ProductRepository(database);
    stock = StockRepository(database);
  });

  tearDown(() async => database.close());

  test('يسجل الإضافة والتسوية مع الرصيد قبل الحركة وبعدها', () async {
    final id = await products.add(const GroceryProduct(
      name: 'سكر',
      stockQuantity: 5,
    ));

    final addition = await stock.recordMovement(
      productId: id,
      movementType: 'إضافة',
      quantityDelta: 7,
      note: 'توريد افتتاحي',
    );
    expect(addition.stockBefore, 5);
    expect(addition.stockAfter, 12);
    expect((await products.getById(id))!.stockQuantity, 12);

    final adjustment = await stock.recordMovement(
      productId: id,
      movementType: 'تسوية',
      quantityDelta: -2,
    );
    expect(adjustment.stockBefore, 12);
    expect(adjustment.stockAfter, 10);
    expect((await stock.history(id)).length, 2);
  });

  test('يرفض الحركة الصفرية وغير المحدودة دون تغيير الرصيد', () async {
    final id = await products.add(const GroceryProduct(
      name: 'زيت',
      stockQuantity: 3,
    ));

    for (final quantity in <double>[0, double.infinity, double.nan]) {
      await expectLater(
        stock.recordMovement(
          productId: id,
          movementType: 'تسوية',
          quantityDelta: quantity,
        ),
        throwsArgumentError,
      );
    }
    expect((await products.getById(id))!.stockQuantity, 3);
    expect(await stock.history(id), isEmpty);
  });

  test('يسمح بالمخزون السالب ويسجل الحركة دون فقدان التاريخ', () async {
    final id = await products.add(const GroceryProduct(
      name: 'حليب',
      stockQuantity: 1,
    ));

    final movement = await stock.recordMovement(
      productId: id,
      movementType: 'تسوية',
      quantityDelta: -4,
      note: 'تصحيح جرد',
    );

    expect(movement.stockAfter, -3);
    expect((await products.getById(id))!.stockQuantity, -3);
    expect((await stock.history(id)).single.note, 'تصحيح جرد');
  });
}
