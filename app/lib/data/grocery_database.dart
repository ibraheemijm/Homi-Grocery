// طبقة الوصول إلى SQLite: مسؤولة عن فتح قاعدة البيانات وإنشاء الجداول فقط.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// تهيئة وفتح قاعدة البيانات المحلية حسب نظام التشغيل.
class GroceryDatabase {
  GroceryDatabase._();

  static const int _version = 2;
  static Database? _instance;

  /// فتح قاعدة البيانات مرة واحدة وإعادة استعمال الاتصال نفسه.
  static Future<Database> open() async {
    if (_instance != null) return _instance!;

    // Linux يحتاج إلى مشغل SQLite المبني على FFI، بينما Android يستخدم sqflite.
    if (Platform.isLinux || Platform.isWindows) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final databasePath = p.join(directory.path, 'homi_grocery.db');

    _instance = await openDatabase(
      databasePath,
      version: _version,
      onConfigure: (db) async {
        // تفعيل المفاتيح الخارجية لضمان سلامة العلاقات عند إضافتها لاحقًا.
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await createSchema(db);
        await createSalesSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // ترحيل قواعد البيانات القديمة بإضافة جداول المبيعات دون حذف بيانات الأصناف.
        if (oldVersion < 2) {
          await createSalesSchema(db);
        }
      },
    );
    return _instance!;
  }

  /// إنشاء مخطط البيانات؛ إتاحته تسمح باختباره دون الوصول إلى ملفات المستخدم.
  static Future<void> createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE products (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        barcode TEXT UNIQUE,
        name TEXT NOT NULL,
        unit TEXT NOT NULL DEFAULT 'حبة',
        purchase_price INTEGER NOT NULL DEFAULT 0 CHECK (purchase_price >= 0),
        selling_price INTEGER NOT NULL DEFAULT 0 CHECK (selling_price >= 0),
        stock_quantity REAL NOT NULL DEFAULT 0,
        minimum_quantity REAL NOT NULL DEFAULT 0 CHECK (minimum_quantity >= 0),
        is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
        created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_products_name ON products(name)
    ''');

    // سجل بسيط لإصدارات المخطط يساعد على ترحيل البيانات مستقبلًا دون فقدها.
    await db.execute('''
      CREATE TABLE app_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.insert('app_metadata', {
      'key': 'schema_version',
      'value': _version.toString(),
    });
  }

  // إنشاء جداول الفواتير وبنودها داخل معاملة واحدة لكل عملية بيع.
  static Future<void> createSalesSchema(Database db) async {
    await db.execute('''
      CREATE TABLE sales (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        invoice_number TEXT NOT NULL UNIQUE,
        customer_name TEXT,
        subtotal INTEGER NOT NULL CHECK (subtotal >= 0),
        discount INTEGER NOT NULL DEFAULT 0 CHECK (discount >= 0),
        total INTEGER NOT NULL CHECK (total >= 0),
        paid_amount INTEGER NOT NULL DEFAULT 0 CHECK (paid_amount >= 0),
        payment_method TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE sale_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sale_id INTEGER NOT NULL REFERENCES sales(id),
        product_id INTEGER NOT NULL REFERENCES products(id),
        product_name TEXT NOT NULL,
        unit TEXT NOT NULL,
        quantity REAL NOT NULL CHECK (quantity > 0),
        unit_price INTEGER NOT NULL CHECK (unit_price >= 0),
        line_total INTEGER NOT NULL CHECK (line_total >= 0)
      )
    ''');
    await db.execute('CREATE INDEX idx_sales_created_at ON sales(created_at)');
    await db.execute('CREATE INDEX idx_sale_items_sale_id ON sale_items(sale_id)');
  }

  /// إغلاق الاتصال؛ مفيد عند إنهاء التطبيق أو في الاختبارات.
  static Future<void> close() async {
    final database = _instance;
    _instance = null;
    if (database != null && database.isOpen) {
      await database.close();
    }
  }
}
