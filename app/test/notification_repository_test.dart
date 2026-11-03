import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/auth_repository.dart';
import 'package:homi_grocery/data/grocery_database.dart';
import 'package:homi_grocery/data/notification_repository.dart';

void main() {
  late Database database;
  late AuthRepository auth;
  late AuthUser manager;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createNotificationsSchema(database);
    await GroceryDatabase.createAuthSchema(database);
    auth = AuthRepository(database);
    manager = await auth.createInitialManager(
      username: 'approval_manager',
      displayName: 'مدير الموافقات',
      password: 'StrongPass!2026',
    );
  });

  tearDown(() async => database.close());

  test('يحفظ الإشعارات محليًا ويرتبها ويحسب غير المقروء', () async {
    final repo = NotificationRepository(database);
    final oldId = await repo.add(
      type: 'low_stock',
      title: 'مخزون منخفض',
      body: 'السكر وصل إلى حد التنبيه.',
      now: DateTime.utc(2026, 10, 1),
    );
    await repo.add(
      type: 'backup',
      title: 'اكتملت النسخة الاحتياطية',
      now: DateTime.utc(2026, 10, 2),
    );

    expect(await repo.unreadCount(), 2);
    expect((await repo.list()).first.title, 'اكتملت النسخة الاحتياطية');
    await repo.markRead(oldId, now: DateTime.utc(2026, 10, 3));
    expect(await repo.unreadCount(), 1);
    expect((await repo.list(unreadOnly: true)).single.title, 'اكتملت النسخة الاحتياطية');
  });

  test('يمنع تكرار حدث الإشعار عند إعادة تسجيل event key نفسه', () async {
    final repo = NotificationRepository(database);
    final first = await repo.add(
      type: 'sync',
      title: 'تحديث',
      eventKey: 'backup:2026-10-27',
    );
    final duplicate = await repo.add(
      type: 'sync',
      title: 'تحديث مكرر',
      eventKey: 'backup:2026-10-27',
    );

    expect(first, greaterThan(0));
    expect(duplicate, 0);
    expect((await repo.list()).length, 1);
  });

  test('يرسل إشعارًا واحدًا عند دخول الصنف حالة المخزون المنخفض', () async {
    final productId = await database.insert('products', {
      'name': 'سكر',
      'unit': 'كجم',
      'stock_quantity': 10,
      'minimum_quantity': 5,
      'created_at': DateTime.utc(2026, 11, 3).toIso8601String(),
    });

    // أول انتقال إلى الحد الأدنى أو دونه ينشئ إشعارًا.
    await database.update(
      'products',
      {'stock_quantity': 5},
      where: 'id = ?',
      whereArgs: [productId],
    );
    // الحركات الإضافية أثناء استمرار الانخفاض لا تكرر الإشعار.
    await database.update(
      'products',
      {'stock_quantity': 2},
      where: 'id = ?',
      whereArgs: [productId],
    );
    var notifications = await NotificationRepository(database).list();
    expect(notifications.where((item) => item.type == 'low_stock'), hasLength(1));

    // العودة فوق الحد الأدنى تعيد تسليح التنبيه دون إرسال إشعار.
    await database.update(
      'products',
      {'stock_quantity': 8},
      where: 'id = ?',
      whereArgs: [productId],
    );
    expect(
      (await NotificationRepository(database).list())
          .where((item) => item.type == 'low_stock'),
      hasLength(1),
    );

    // انخفاض جديد بعد التعافي يسمح بإشعار جديد مستقل.
    await database.update(
      'products',
      {'stock_quantity': 4},
      where: 'id = ?',
      whereArgs: [productId],
    );
    notifications = await NotificationRepository(database).list();
    expect(notifications.where((item) => item.type == 'low_stock'), hasLength(2));
    expect(notifications.first.relatedId, productId.toString());
  });

  test('لا يرسل إشعارات جماعية للأصناف المنخفضة الموجودة قبل تفعيل التتبع', () async {
    // محاكاة صنف موجود قبل تثبيت مشغلات التنبيه في قاعدة قديمة.
    await database.execute('DROP TRIGGER IF EXISTS trg_products_low_stock_insert');
    await database.execute('DROP TRIGGER IF EXISTS trg_products_low_stock_update');
    await database.insert('products', {
      'name': 'أرز',
      'unit': 'كجم',
      'stock_quantity': 1,
      'minimum_quantity': 3,
      'created_at': DateTime.utc(2026, 11, 3).toIso8601String(),
    });

    await GroceryDatabase.createLowStockAlertSchema(database);
    expect(
      (await NotificationRepository(database).list())
          .where((item) => item.type == 'low_stock'),
      isEmpty,
    );

    final rows = await database.query('products', columns: ['id'], limit: 1);
    final productId = rows.single['id'] as int;
    await database.update(
      'products',
      {'stock_quantity': 4},
      where: 'id = ?',
      whereArgs: [productId],
    );
    await database.update(
      'products',
      {'stock_quantity': 2},
      where: 'id = ?',
      whereArgs: [productId],
    );
    expect(
      (await NotificationRepository(database).list())
          .where((item) => item.type == 'low_stock'),
      hasLength(1),
    );
  });

  test('يشترط الموافقة الأولية قبل طلب نشر تغيير مهم', () async {
    final repo = DeliveryApprovalRepository(database);
    await expectLater(
      repo.requestImportantChange(
        changeKey: 'catalog-v1',
        summary: 'نشر الكتالوج',
        dataScope: 'اسم المنتج والسعر والكمية',
      ),
      throwsStateError,
    );

    final initial = await repo.requestInitialEnable(
      summary: 'تفعيل نشر كتالوج الدليفري',
      dataScope: 'اسم المنتج والسعر والكمية فقط',
    );
    expect((await repo.list()).single.status, 'pending');
    await repo.decide(managerUserId: manager.id, id: initial, approved: true, note: 'موافقة المالك');
    expect((await repo.list()).single.decidedByUserId, manager.id);
    final change = await repo.requestImportantChange(
      changeKey: 'catalog-v2',
      summary: 'تغيير الأسعار المنشورة',
      dataScope: 'اسم المنتج والسعر والكمية',
    );

    expect((await repo.list()).first.id, change);
    expect((await repo.list()).first.status, 'pending');
  });

  test('سحب الموافقة الأولية يمنع طلبات النشر المهمة التالية', () async {
    final repo = DeliveryApprovalRepository(database);
    final initial = await repo.requestInitialEnable(
      summary: 'تفعيل الكتالوج',
      dataScope: 'بيانات الكتالوج فقط',
    );
    await repo.decide(managerUserId: manager.id, id: initial, approved: true);
    await repo.revokeInitialApproval(managerUserId: manager.id);

    await expectLater(
      repo.requestImportantChange(
        changeKey: 'catalog-v2',
        summary: 'تغيير الأسعار',
        dataScope: 'بيانات الكتالوج فقط',
      ),
      throwsStateError,
    );
    expect((await repo.list()).first.status, 'revoked');
    expect((await repo.list()).first.decidedByUserId, manager.id);
  });

  test('سحب الموافقة الأولية يرفض طلبات التغيير المعلقة ويمنع اعتمادها', () async {
    final repo = DeliveryApprovalRepository(database);
    final initial = await repo.requestInitialEnable(
      summary: 'تفعيل الكتالوج',
      dataScope: 'بيانات الكتالوج فقط',
    );
    await repo.decide(managerUserId: manager.id, id: initial, approved: true);
    final pendingChange = await repo.requestImportantChange(
      changeKey: 'catalog-v3',
      summary: 'تحديث أسعار منشورة',
      dataScope: 'الأسعار فقط',
    );

    await repo.revokeInitialApproval(managerUserId: manager.id);

    await expectLater(
      repo.decide(managerUserId: manager.id, id: pendingChange, approved: true),
      throwsStateError,
    );
    final approvals = await repo.list();
    expect(approvals.first.id, pendingChange);
    expect(approvals.first.status, 'rejected');
    expect(approvals.first.decisionNote, contains('سُحبت'));
  });

  test('لا يسمح باعتماد تغيير مهم إذا سُحبت الموافقة الأولية قبل القرار', () async {
    final repo = DeliveryApprovalRepository(database);
    final initial = await repo.requestInitialEnable(
      summary: 'تفعيل الكتالوج',
      dataScope: 'بيانات الكتالوج فقط',
    );
    await repo.decide(managerUserId: manager.id, id: initial, approved: true);
    final pendingChange = await repo.requestImportantChange(
      changeKey: 'catalog-v4',
      summary: 'تحديث الأسعار',
      dataScope: 'الأسعار فقط',
    );

    await database.update(
      'delivery_publication_approvals',
      {'status': 'revoked'},
      where: 'id = ?',
      whereArgs: [initial],
    );

    await expectLater(
      repo.decide(managerUserId: manager.id, id: pendingChange, approved: true),
      throwsStateError,
    );
    expect((await repo.list()).first.status, 'pending');
  });

  test('يرفض قرار مستخدم غير مدير أو مدير غير نشط', () async {
    final repo = DeliveryApprovalRepository(database);
    final id = await repo.requestInitialEnable(
      summary: 'طلب اختبار الحماية',
      dataScope: 'بيانات الكتالوج فقط',
    );

    final cashier = await auth.createCashier(
      manager: manager,
      username: 'approval_cashier',
      displayName: 'كاشير الاختبار',
      password: 'CashierPass!2026',
    );
    await expectLater(
      repo.decide(managerUserId: cashier.id, id: id, approved: true),
      throwsStateError,
    );
    await expectLater(
      repo.decide(managerUserId: manager.id + 999, id: id, approved: true),
      throwsStateError,
    );
    await database.update(
      'users',
      {'is_active': 0},
      where: 'id = ?',
      whereArgs: [manager.id],
    );
    await expectLater(
      repo.decide(managerUserId: manager.id, id: id, approved: true),
      throwsStateError,
    );
    expect((await repo.list()).single.status, 'pending');
    expect((await repo.list()).single.decidedByUserId, isNull);
  });

  test('لا يسمح باتخاذ قرار ثانٍ على طلب حُسم مسبقًا', () async {
    final repo = DeliveryApprovalRepository(database);
    final id = await repo.requestInitialEnable(
      summary: 'تفعيل الكتالوج',
      dataScope: 'بيانات الكتالوج فقط',
    );
    await repo.decide(managerUserId: manager.id, id: id, approved: false, note: 'غير جاهز');
    await expectLater(
      repo.decide(managerUserId: manager.id, id: id, approved: true),
      throwsStateError,
    );
    expect((await repo.list()).single.status, 'rejected');
  });
}
