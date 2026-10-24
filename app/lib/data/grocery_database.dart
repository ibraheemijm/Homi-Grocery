// طبقة الوصول إلى SQLite: مسؤولة عن فتح قاعدة البيانات وإنشاء الجداول فقط.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// تهيئة وفتح قاعدة البيانات المحلية حسب نظام التشغيل.
class GroceryDatabase {
  GroceryDatabase._();

  static const int _version = 11;
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
        await createCustomersSchema(db);
        await createStockMovementsSchema(db);
        await createSalesReturnsSchema(db);
        await createPurchasesSchema(db);
        await createSaleReturnRefundsSchema(db);
        await createCashTransactionsSchema(db);
        await createSupplierReturnsSchema(db);
        await createCostOfGoodsSchema(db);
        await createSupplierReturnRefundsSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // ترحيل قواعد البيانات القديمة بإضافة جداول المبيعات دون حذف بيانات الأصناف.
        if (oldVersion < 2) {
          await createSalesSchema(db);
        }
        if (oldVersion < 3) {
          await createCustomersSchema(db);
        }
        if (oldVersion < 4) {
          await createStockMovementsSchema(db);
        }
        if (oldVersion < 5) {
          await createSalesReturnsSchema(db);
        }
        if (oldVersion < 6) {
          await createPurchasesSchema(db);
        }
        if (oldVersion < 7) {
          await createSaleReturnRefundsSchema(db);
        }
        if (oldVersion < 8) {
          await createCashTransactionsSchema(db);
        }
        if (oldVersion < 9) {
          await createSupplierReturnsSchema(db);
        }
        if (oldVersion < 10) {
          await createCostOfGoodsSchema(db);
        }
        if (oldVersion < 11) {
          await createSupplierReturnRefundsSchema(db);
        }
        await db.insert('app_metadata', {'key': 'schema_version', 'value': _version.toString()}, conflictAlgorithm: ConflictAlgorithm.replace);
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

  // إنشاء سجل الزبائن والتحصيلات، مع ربط فواتير المبيعات القديمة دون حذفها.
  static Future<void> createCustomersSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS customers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL COLLATE NOCASE UNIQUE,
        phone TEXT,
        notes TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    final columns = await db.rawQuery('PRAGMA table_info(sales)');
    if (!columns.any((column) => column['name'] == 'customer_id')) {
      await db.execute(
        'ALTER TABLE sales ADD COLUMN customer_id INTEGER REFERENCES customers(id)',
      );
    }
    // ترحيل أسماء الزبائن القديمة إلى السجل الجديد مع الحفاظ على الفواتير.
    final oldSales = await db.query(
      'sales',
      columns: ['customer_name'],
      where: "customer_name IS NOT NULL AND TRIM(customer_name) <> ''",
      distinct: true,
    );
    for (final row in oldSales) {
      final name = (row['customer_name'] as String).trim();
      await db.insert(
        'customers',
        {'name': name, 'created_at': DateTime.now().toUtc().toIso8601String()},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await db.rawUpdate('''
      UPDATE sales
      SET customer_id = (
        SELECT customers.id FROM customers
        WHERE customers.name = sales.customer_name COLLATE NOCASE
        LIMIT 1
      )
      WHERE customer_id IS NULL
        AND customer_name IS NOT NULL
        AND TRIM(customer_name) <> ''
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS customer_payments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        customer_id INTEGER NOT NULL REFERENCES customers(id),
        amount INTEGER NOT NULL CHECK (amount > 0),
        note TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_customer_payments_customer ON customer_payments(customer_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sales_customer_id ON sales(customer_id)',
    );
  }

  // سجل دائم لحركات المخزون بما فيها الحركات الناتجة عن المبيعات.
  static Future<void> createStockMovementsSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS stock_movements (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        product_id INTEGER NOT NULL REFERENCES products(id),
        movement_type TEXT NOT NULL,
        quantity_delta REAL NOT NULL CHECK (quantity_delta <> 0),
        stock_before REAL NOT NULL,
        stock_after REAL NOT NULL,
        note TEXT,
        reference_type TEXT,
        reference_id INTEGER,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_stock_movements_product ON stock_movements(product_id, created_at)',
    );
  }

  // سجل المرتجعات وبنودها لضمان عدم تجاوز الكميات المباعة.
  static Future<void> createSalesReturnsSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sale_returns (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sale_id INTEGER NOT NULL REFERENCES sales(id),
        amount INTEGER NOT NULL CHECK (amount >= 0),
        note TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sale_return_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        return_id INTEGER NOT NULL REFERENCES sale_returns(id),
        sale_item_id INTEGER NOT NULL REFERENCES sale_items(id),
        quantity REAL NOT NULL CHECK (quantity > 0),
        amount INTEGER NOT NULL CHECK (amount >= 0)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sale_returns_sale ON sale_returns(sale_id, created_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sale_return_items_item ON sale_return_items(sale_item_id)',
    );
  }


  // الموردون وفواتير الشراء وبنودها ومدفوعات الموردين.
  static Future<void> createPurchasesSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS suppliers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL COLLATE NOCASE UNIQUE,
        phone TEXT,
        notes TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS purchases (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        invoice_number TEXT NOT NULL UNIQUE,
        supplier_id INTEGER NOT NULL REFERENCES suppliers(id),
        subtotal INTEGER NOT NULL CHECK (subtotal >= 0),
        discount INTEGER NOT NULL DEFAULT 0 CHECK (discount >= 0),
        total INTEGER NOT NULL CHECK (total >= 0),
        paid_amount INTEGER NOT NULL DEFAULT 0 CHECK (paid_amount >= 0),
        payment_method TEXT NOT NULL,
        note TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS purchase_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        purchase_id INTEGER NOT NULL REFERENCES purchases(id),
        product_id INTEGER NOT NULL REFERENCES products(id),
        product_name TEXT NOT NULL,
        unit TEXT NOT NULL,
        quantity REAL NOT NULL CHECK (quantity > 0),
        unit_cost INTEGER NOT NULL CHECK (unit_cost >= 0),
        line_total INTEGER NOT NULL CHECK (line_total >= 0)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS supplier_payments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        supplier_id INTEGER NOT NULL REFERENCES suppliers(id),
        amount INTEGER NOT NULL CHECK (amount > 0),
        note TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_purchases_supplier ON purchases(supplier_id, created_at)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_purchase_items_purchase ON purchase_items(purchase_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_supplier_payments_supplier ON supplier_payments(supplier_id, created_at)');
  }

  // سجل مستقل للمبالغ النقدية التي دُفعت فعليًا للزبون بسبب المرتجعات.
  static Future<void> createSaleReturnRefundsSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sale_return_refunds (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sale_id INTEGER NOT NULL REFERENCES sales(id),
        amount INTEGER NOT NULL CHECK (amount > 0),
        payment_method TEXT NOT NULL DEFAULT 'نقدي',
        note TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sale_return_refunds_sale ON sale_return_refunds(sale_id, created_at)',
    );
  }

  // سجل موحد للمقبوضات والمدفوعات الفعلية، مرتبط بمصدر الحركة لمنع الخلط مع الديون.
  static Future<void> createCashTransactionsSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cash_transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        direction TEXT NOT NULL CHECK (direction IN ('in', 'out')),
        category TEXT NOT NULL,
        amount INTEGER NOT NULL CHECK (amount > 0),
        payment_method TEXT NOT NULL DEFAULT 'نقدي',
        reference_type TEXT,
        reference_id INTEGER,
        note TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_cash_transactions_created ON cash_transactions(created_at, direction)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_cash_transactions_reference ON cash_transactions(reference_type, reference_id)',
    );
  }

  // مرتجعات الموردين وبنودها؛ تُحفظ مع حركات المخزون ضمن معاملة واحدة.
  static Future<void> createSupplierReturnsSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS supplier_returns (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        purchase_id INTEGER NOT NULL REFERENCES purchases(id),
        amount INTEGER NOT NULL CHECK (amount > 0),
        note TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS supplier_return_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        return_id INTEGER NOT NULL REFERENCES supplier_returns(id),
        purchase_item_id INTEGER NOT NULL REFERENCES purchase_items(id),
        product_id INTEGER NOT NULL REFERENCES products(id),
        product_name TEXT NOT NULL,
        quantity REAL NOT NULL CHECK (quantity > 0),
        unit_cost INTEGER NOT NULL CHECK (unit_cost >= 0),
        line_total INTEGER NOT NULL CHECK (line_total >= 0)
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_supplier_returns_purchase ON supplier_returns(purchase_id, created_at)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_supplier_return_items_item ON supplier_return_items(purchase_item_id)');
  }

  // تكلفة الصنف المحفوظة وقت البيع؛ null تعني أن الفاتورة قديمة ولا يمكن إثبات تكلفتها.
  static Future<void> createCostOfGoodsSchema(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info(sale_items)');
    if (!columns.any((column) => column['name'] == 'cost_price')) {
      await db.execute('ALTER TABLE sale_items ADD COLUMN cost_price INTEGER CHECK (cost_price IS NULL OR cost_price >= 0)');
    }
  }

  // المبالغ التي استُلمت فعليًا من المورد بعد مرتجع؛ مستقلة عن رصيد المرتجع نفسه.
  static Future<void> createSupplierReturnRefundsSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS supplier_return_refunds (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        supplier_return_id INTEGER NOT NULL REFERENCES supplier_returns(id),
        amount INTEGER NOT NULL CHECK (amount > 0),
        payment_method TEXT NOT NULL DEFAULT 'نقدي',
        note TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_supplier_return_refunds_return ON supplier_return_refunds(supplier_return_id, created_at)');
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
