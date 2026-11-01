// يختبر تدفق تسجيل الخروج ثم الدخول بحساب آخر مع قاعدة SQLite معزولة.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:homi_grocery/data/auth_repository.dart';
import 'package:homi_grocery/data/grocery_database.dart';
import 'package:homi_grocery/screens/authentication_gate.dart';

// ينتظر عمليات قاعدة البيانات والانتقالات دون انتظار مؤشر التحميل الدوار.
Future<void> _pumpGate(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  });
  await tester.pump(const Duration(milliseconds: 400));
}

// يعزل اختبار تبديل الجلسات عن كلفة PBKDF2؛ تحقق كلمة المرور مغطى باختبارات المستودع.
class _GateTestAuthRepository extends AuthRepository {
  _GateTestAuthRepository(Database database, {required this.users})
      : super(database);

  final Map<String, AuthUser> users;

  @override
  Future<AuthUser> login({required String username, required String password}) async {
    final user = users[username.trim()];
    if (user == null) {
      throw const AuthException('اسم المستخدم أو كلمة المرور غير صحيحة.');
    }
    return user;
  }
}

void main() {
  late Database database;
  late AuthRepository auth;
  late AuthUser manager;
  late AuthUser cashier;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    database = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      onCreate: (db, version) async {
        await GroceryDatabase.createAuthSchema(db);
        await GroceryDatabase.createCashTransactionsSchema(db);
        await GroceryDatabase.createCashShiftsSchema(db);
      },
    );
    auth = AuthRepository(database);
    manager = await auth.createInitialManager(
      username: 'store_admin',
      displayName: 'مدير المتجر',
      password: 'StrongPass!2026',
    );
    cashier = await auth.createCashier(
      manager: manager,
      username: 'cashier_one',
      displayName: 'الكاشير الأول',
      password: 'CashierPass!2026',
    );
  });

  tearDown(() async {
    await database.close();
  });

  testWidgets('يمسح جلسة الكاشير ويفتح جلسة المدير دون نقل حالة الحساب السابق',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AuthenticationGate(
          databaseProvider: () async => database,
          authRepositoryProvider: (database) => _GateTestAuthRepository(
            database,
            users: {manager.username: manager, cashier.username: cashier},
          ),
          authenticatedBuilder: (user, shiftId, onLogout) => Scaffold(
            body: Column(
              children: [
                Text('الحساب الحالي: ${user.username}'),
                Text('الاسم الظاهر: ${user.displayName}'),
                Text('رقم الوردية: $shiftId'),
                TextButton(
                  onPressed: onLogout,
                  child: const Text('تسجيل الخروج'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await _pumpGate(tester);

    // تسجيل دخول الكاشير وفتح ورديته.
    await tester.enterText(find.byType(TextField).first, cashier.username);
    await tester.enterText(find.byType(TextField).last, 'CashierPass!2026');
    await tester.tap(find.text('دخول'));
    await _pumpGate(tester);

    // لا تُفعّل الجلسة قبل إدخال الرصيد الافتتاحي وإتمام فتح الوردية.
    expect(
      find.text('فتح الوردية'),
      findsOneWidget,
      reason: 'محتوى الشاشة: ${tester.widgetList<Text>(find.byType(Text)).map((widget) => widget.data).join(' | ')}',
    );
    await tester.enterText(find.byType(TextField).last, '0');
    await tester.tap(find.text('فتح الوردية'));
    await _pumpGate(tester);

    expect(find.text('الحساب الحالي: cashier_one'), findsOneWidget);
    expect(find.text('الاسم الظاهر: الكاشير الأول'), findsOneWidget);
    final cashierShiftText = tester.widget<Text>(find.textContaining('رقم الوردية:'));
    final cashierShift = cashierShiftText.data;

    // إغلاق وردية الكاشير؛ يجب أن تعود البوابة إلى نموذج دخول جديد.
    await tester.tap(find.text('تسجيل الخروج'));
    await _pumpGate(tester);
    await tester.enterText(find.byType(TextField).last, '0');
    await tester.tap(find.text('إغلاق الوردية والخروج'));
    await _pumpGate(tester);

    expect(find.text('تسجيل الدخول'), findsOneWidget);
    expect(find.text('الحساب الحالي: cashier_one'), findsNothing);

    // الدخول بحساب المدير يفتح وردية جديدة وهوية جديدة مستقلة.
    await tester.enterText(find.byType(TextField).first, manager.username);
    await tester.enterText(find.byType(TextField).last, 'StrongPass!2026');
    await tester.tap(find.text('دخول'));
    await _pumpGate(tester);

    await tester.enterText(find.byType(TextField).last, '0');
    await tester.tap(find.text('فتح الوردية'));
    await _pumpGate(tester);

    expect(find.text('الحساب الحالي: store_admin'), findsOneWidget);
    expect(find.text('الاسم الظاهر: مدير المتجر'), findsOneWidget);
    expect(find.text('الحساب الحالي: cashier_one'), findsNothing);
    expect(find.text('الاسم الظاهر: الكاشير الأول'), findsNothing);
    expect(find.textContaining('رقم الوردية:'), findsOneWidget);
    expect(tester.widget<Text>(find.textContaining('رقم الوردية:')).data,
        isNot(cashierShift));
  });
}
