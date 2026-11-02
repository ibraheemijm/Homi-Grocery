// اختبار ترحيل الأرصدة الافتتاحية مع الحفاظ على سجلات الحسابات القديمة.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/grocery_database.dart';

void main() {
  late Database database;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.execute('''
      CREATE TABLE customers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        phone TEXT,
        notes TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE suppliers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        phone TEXT,
        notes TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await database.insert('customers', {'name': 'زبون قديم', 'created_at': '2026-01-01'});
    await database.insert('suppliers', {'name': 'مورد قديم', 'created_at': '2026-01-01'});
  });

  tearDown(() async => database.close());

  test('يضيف حقول الأرصدة بصفر افتراضي دون فقد السجلات القديمة', () async {
    await GroceryDatabase.createOpeningBalancesSchema(database);
    final customers = await database.query('customers');
    final suppliers = await database.query('suppliers');
    expect(customers.single['name'], 'زبون قديم');
    expect(customers.single['opening_balance'], 0);
    expect(suppliers.single['name'], 'مورد قديم');
    expect(suppliers.single['opening_balance'], 0);
  });

  test('ينشئ تاريخ بدء النظام في أول يناير افتراضيًا ويحافظ على اختيار المدير', () async {
    await database.execute('''
      CREATE TABLE app_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await GroceryDatabase.createSystemSettingsSchema(database);
    var rows = await database.query('app_metadata', where: 'key = ?', whereArgs: ['system_start_date']);
    expect(rows.single['value'], '${DateTime.now().year.toString().padLeft(4, '0')}-01-01');

    await database.update('app_metadata', {'value': '2026-11-02'}, where: 'key = ?', whereArgs: ['system_start_date']);
    await GroceryDatabase.createSystemSettingsSchema(database);
    rows = await database.query('app_metadata', where: 'key = ?', whereArgs: ['system_start_date']);
    expect(rows.single['value'], '2026-11-02');
  });

  test('يمكن إعادة تطبيق ترحيل الأرصدة الافتتاحية دون خطأ', () async {
    await GroceryDatabase.createOpeningBalancesSchema(database);
    await expectLater(GroceryDatabase.createOpeningBalancesSchema(database), completes);
  });
}
