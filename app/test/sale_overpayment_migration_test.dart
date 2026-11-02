// اختبارات ترحيل حقل الزيادة في الفواتير القديمة دون فقد بياناتها.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:homi_grocery/data/grocery_database.dart';

void main() {
  late Database database;
  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createSalesSchema(database);
  });
  tearDown(() async => database.close());

  test('يضيف حقل الزيادة إلى الفواتير السابقة ويحتفظ بقيمها', () async {
    final id = await database.insert('sales', {
      'invoice_number': 'OVERPAY-MIGRATION-001', 'customer_name': null,
      'subtotal': 250, 'discount': 0, 'total': 250, 'paid_amount': 250,
      'payment_method': 'نقدي', 'created_at': '2026-02-01T00:00:00.000Z',
    });
    final before = (await database.query('sales', where: 'id = ?', whereArgs: [id])).single;
    expect(before['overpayment_amount'], 0);
    await GroceryDatabase.createSalesOverpaymentSchema(database);
    final after = (await database.query('sales', where: 'id = ?', whereArgs: [id])).single;
    expect(after['invoice_number'], 'OVERPAY-MIGRATION-001');
    expect(after['total'], 250);
    expect(after['overpayment_amount'], 0);
    await expectLater(GroceryDatabase.createSalesOverpaymentSchema(database), completes);
  });
}
