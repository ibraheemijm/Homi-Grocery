import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/grocery_database.dart';
import 'package:homi_grocery/data/notification_repository.dart';

void main() {
  late Database database;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await GroceryDatabase.createSchema(database);
    await GroceryDatabase.createNotificationsSchema(database);
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
    await repo.decide(id: initial, approved: true, note: 'موافقة المالك');
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
    await repo.decide(id: initial, approved: true);
    await repo.revokeInitialApproval();

    await expectLater(
      repo.requestImportantChange(
        changeKey: 'catalog-v2',
        summary: 'تغيير الأسعار',
        dataScope: 'بيانات الكتالوج فقط',
      ),
      throwsStateError,
    );
    expect((await repo.list()).first.status, 'revoked');
  });

  test('لا يسمح باتخاذ قرار ثانٍ على طلب حُسم مسبقًا', () async {
    final repo = DeliveryApprovalRepository(database);
    final id = await repo.requestInitialEnable(
      summary: 'تفعيل الكتالوج',
      dataScope: 'بيانات الكتالوج فقط',
    );
    await repo.decide(id: id, approved: false, note: 'غير جاهز');
    await expectLater(
      repo.decide(id: id, approved: true),
      throwsStateError,
    );
    expect((await repo.list()).single.status, 'rejected');
  });
}
