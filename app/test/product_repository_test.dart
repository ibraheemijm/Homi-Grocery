// اختبارات قاعدة البيانات ومستودع الأصناف باستخدام SQLite داخل الذاكرة.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/grocery_database.dart';
import 'package:homi_grocery/data/product_repository.dart';

void main() {
  late Database database;
  late ProductRepository repository;

  setUp(() async {
    // قاعدة مؤقتة لكل اختبار حتى لا تتداخل النتائج بين الاختبارات.
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await GroceryDatabase.createSchema(database);
    repository = ProductRepository(database);
  });

  tearDown(() async {
    await database.close();
  });

  test('يحفظ الصنف ويعيد بياناته بدقة', () async {
    final id = await repository.add(const GroceryProduct(
      barcode: '123456',
      name: 'سكر',
      unit: 'كيلوجرام',
      purchasePrice: 1500,
      sellingPrice: 2000,
      stockQuantity: 12.5,
      minimumQuantity: 2,
    ));

    final saved = await repository.getById(id);

    expect(saved, isNotNull);
    expect(saved!.name, 'سكر');
    expect(saved.purchasePrice, 1500);
    expect(saved.sellingPrice, 2000);
    expect(saved.stockQuantity, 12.5);
    expect(saved.isActive, isTrue);
  });

  test('يحدّث سعر البيع دون تغيير تكلفة الشراء أو المخزون ويحفظ مسار الصورة', () async {
    final id = await repository.add(const GroceryProduct(
      name: 'حليب',
      purchasePrice: 80,
      sellingPrice: 100,
      stockQuantity: 9,
      imagePath: '/tmp/homi-product-image.png',
    ));

    await repository.updateSellingPrice(productId: id, sellingPrice: 125);
    final saved = await repository.getById(id);

    expect(saved, isNotNull);
    expect(saved!.purchasePrice, 80);
    expect(saved.sellingPrice, 125);
    expect(saved.stockQuantity, 9);
    expect(saved.imagePath, '/tmp/homi-product-image.png');
  });

  test('يبحث باسم الصنف أو الباركود', () async {
    await repository.add(const GroceryProduct(
      barcode: '9988',
      name: 'زيت طعام',
      sellingPrice: 3000,
    ));

    expect((await repository.search('زيت')).length, 1);
    expect((await repository.search('9988')).length, 1);
    expect((await repository.search('غير موجود')), isEmpty);
  });

  test('يرفض حفظ صنف بلا اسم', () async {
    await expectLater(
      repository.add(const GroceryProduct(name: '   ')),
      throwsArgumentError,
    );
  });

  test('يعطّل الصنف بدل حذفه من قاعدة البيانات', () async {
    final id = await repository.add(
      const GroceryProduct(name: 'شاي', sellingPrice: 2500),
    );

    await repository.archive(id);

    expect(await repository.getById(id), isNotNull);
    expect(await repository.search('شاي'), isEmpty);
    expect(
      (await repository.search('شاي', includeInactive: true)).length,
      1,
    );
  });
}
