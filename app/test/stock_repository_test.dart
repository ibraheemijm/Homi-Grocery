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
  late int managerId;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createStockMovementsSchema(database);
    await GroceryDatabase.createAuthSchema(database);
    managerId = await database.insert('users', {
      'username': 'manager_test',
      'display_name': 'مدير الاختبار',
      'password_hash': 'test-hash',
      'password_salt': 'test-salt',
      'password_iterations': 100000,
      'role': 'manager',
      'is_active': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
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
      userId: managerId,
      productId: id,
      movementType: 'إضافة',
      quantityDelta: 7,
      note: 'توريد افتتاحي',
    );
    expect(addition.stockBefore, 5);
    expect(addition.stockAfter, 12);
    expect((await products.getById(id))!.stockQuantity, 12);

    final adjustment = await stock.recordMovement(
      userId: managerId,
      productId: id,
      movementType: 'تسوية',
      quantityDelta: -2,
    );
    expect(adjustment.stockBefore, 12);
    expect(adjustment.stockAfter, 10);
    expect((await stock.history(id, userId: managerId)).length, 2);
  });

  test('يعرض سجل جميع الأصناف مع اسم كل صنف وبترتيب الأحدث', () async {
    final sugarId = await products.add(const GroceryProduct(
      name: 'سكر',
      stockQuantity: 5,
    ));
    final oilId = await products.add(const GroceryProduct(
      name: 'زيت',
      stockQuantity: 8,
    ));

    await stock.recordMovement(
      userId: managerId,
      productId: sugarId,
      movementType: 'إضافة',
      quantityDelta: 2,
    );
    await stock.recordMovement(
      userId: managerId,
      productId: oilId,
      movementType: 'تسوية',
      quantityDelta: -1,
    );

    final movements = await stock.history(null, userId: managerId);

    expect(movements, hasLength(2));
    expect(movements.first.productId, oilId);
    expect(movements.first.productName, 'زيت');
    expect(movements.last.productId, sugarId);
    expect(movements.last.productName, 'سكر');
  });

  test('يرفض الحركة الصفرية وغير المحدودة دون تغيير الرصيد', () async {
    final id = await products.add(const GroceryProduct(
      name: 'زيت',
      stockQuantity: 3,
    ));

    for (final quantity in <double>[0, double.infinity, double.nan]) {
      await expectLater(
        stock.recordMovement(
          userId: managerId,
          productId: id,
          movementType: 'تسوية',
          quantityDelta: quantity,
        ),
        throwsArgumentError,
      );
    }
    expect((await products.getById(id))!.stockQuantity, 3);
    expect(await stock.history(id, userId: managerId), isEmpty);
  });

  test('يسمح بالمخزون السالب ويسجل الحركة دون فقدان التاريخ', () async {
    final id = await products.add(const GroceryProduct(
      name: 'حليب',
      stockQuantity: 1,
    ));

    final movement = await stock.recordMovement(
      userId: managerId,
      productId: id,
      movementType: 'تسوية',
      quantityDelta: -4,
      note: 'تصحيح جرد',
    );

    expect(movement.stockAfter, -3);
    expect((await products.getById(id))!.stockQuantity, -3);
    expect((await stock.history(id, userId: managerId)).single.note, 'تصحيح جرد');
  });

  test('يمنع الكاشير من تعديل المخزون افتراضيًا ولا يسمح إلا بعد منح الصلاحية', () async {
    final productId = await products.add(const GroceryProduct(
      name: 'سكر',
      stockQuantity: 4,
    ));
    final cashierId = await database.insert('users', {
      'username': 'cashier_stock_test',
      'display_name': 'كاشير الاختبار',
      'password_hash': 'test-hash',
      'password_salt': 'test-salt',
      'password_iterations': 100000,
      'role': 'cashier',
      'is_active': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });

    await expectLater(
      stock.recordMovement(
        userId: cashierId,
        productId: productId,
        movementType: 'إضافة',
        quantityDelta: 3,
      ),
      throwsA(isA<StateError>()),
    );
    expect((await products.getById(productId))!.stockQuantity, 4);
    expect(await stock.history(productId, userId: managerId), isEmpty);
    await expectLater(
      stock.history(productId, userId: cashierId),
      throwsA(isA<StateError>()),
    );

    await database.insert('cashier_permissions', {
      'user_id': cashierId,
      'permission_key': 'stock_adjustments',
      'is_allowed': 1,
      'max_amount': null,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    final movement = await stock.recordMovement(
      userId: cashierId,
      productId: productId,
      movementType: 'إضافة',
      quantityDelta: 3,
    );

    expect(movement.stockAfter, 7);
    expect((await products.getById(productId))!.stockQuantity, 7);
    expect(await stock.history(productId, userId: cashierId), hasLength(1));
  });

}
