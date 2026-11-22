import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:homi_grocery/data/app_data_location.dart';
import 'package:homi_grocery/data/grocery_database.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  late Directory supportDirectory;
  late Directory targetParent;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    supportDirectory = await Directory.systemTemp.createTemp('homi-data-source-');
    targetParent = await Directory.systemTemp.createTemp('homi-data-target-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      if (call.method == 'getApplicationSupportDirectory') {
        return supportDirectory.path;
      }
      return null;
    });
  });

  tearDownAll(() async {
    await GroceryDatabase.closeForMaintenance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
    if (await targetParent.exists()) {
      await targetParent.delete(recursive: true);
    }
  });

  test('ينقل قاعدة البيانات والصور والخطوط والنسخ الاحتياطية مع تحديث المسارات', () async {
    final db = await GroceryDatabase.open();
    final imageDirectory = Directory(p.join(supportDirectory.path, 'product-images'));
    final fontDirectory = Directory(p.join(supportDirectory.path, 'fonts'));
    final backupDirectory = Directory(p.join(supportDirectory.path, 'backups'));
    await imageDirectory.create();
    await fontDirectory.create();
    await backupDirectory.create();

    final image = File(p.join(imageDirectory.path, 'product-test.png'));
    final font = File(p.join(fontDirectory.path, 'homi_imported.ttf'));
    final backup = File(p.join(backupDirectory.path, 'homi-grocery-test.db'));
    await image.writeAsBytes([1, 2, 3]);
    await font.writeAsBytes([4, 5, 6]);
    await backup.writeAsBytes([7, 8, 9]);

    await db.insert('products', {
      'name': 'صنف النقل',
      'purchase_price': 10,
      'selling_price': 15,
      'stock_quantity': 2,
      'image_path': image.path,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await db.insert('app_metadata', {
      'key': 'imported_font_path',
      'value': font.path,
    });

    final blockedParent = Directory(p.join(targetParent.path, 'blocked'));
    final blockedTarget = Directory(p.join(blockedParent.path, 'Homi Grocery Data'));
    await blockedTarget.create(recursive: true);
    await File(p.join(blockedTarget.path, 'keep.txt')).writeAsString('existing');
    await expectLater(
      AppDataLocation.migrate(
        currentDatabase: db,
        closeDatabase: GroceryDatabase.closeForMaintenance,
        reopenDatabase: GroceryDatabase.open,
        selectedParentPath: blockedParent.path,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(db.isOpen, isTrue, reason: 'يجب ألا يغلق التطبيق قاعدة البيانات قبل قبول المجلد الهدف.');
    await blockedParent.delete(recursive: true);

    final target = await AppDataLocation.migrate(
      currentDatabase: db,
      closeDatabase: GroceryDatabase.closeForMaintenance,
      reopenDatabase: GroceryDatabase.open,
      selectedParentPath: targetParent.path,
    );

    expect(target.path, p.join(targetParent.path, 'Homi Grocery Data'));
    expect(await File(p.join(target.path, 'homi_grocery.db')).exists(), isTrue);
    expect(await File(p.join(target.path, 'product-images', 'product-test.png')).exists(), isTrue);
    expect(await File(p.join(target.path, 'fonts', 'homi_imported.ttf')).exists(), isTrue);
    expect(await File(p.join(target.path, 'backups', 'homi-grocery-test.db')).exists(), isTrue);
    expect(await image.exists(), isTrue, reason: 'يجب الاحتفاظ بالمصدر القديم كنسخة رجوع.');

    await GroceryDatabase.closeForMaintenance();
    final unavailable = Directory('${target.path}.offline');
    await target.rename(unavailable.path);
    await expectLater(
      AppDataLocation.resolveDataDirectory(),
      throwsA(isA<FileSystemException>()),
      reason: 'يجب ألا ينشئ التطبيق قاعدة بيانات فارغة عند فقدان القسم المحدد.',
    );
    await unavailable.rename(target.path);

    final reopened = await GroceryDatabase.open();
    final products = await reopened.query('products', columns: ['image_path']);
    expect(products.single['image_path'], p.join(target.path, 'product-images', 'product-test.png'));
    final fonts = await reopened.query('app_metadata',
        columns: ['value'], where: 'key = ?', whereArgs: ['imported_font_path']);
    expect(fonts.single['value'], p.join(target.path, 'fonts', 'homi_imported.ttf'));
    expect(await AppDataLocation.currentPath(), target.path);

    // محاكاة إعادة تثبيت النظام وفقدان ملف إعداد الموقع مع بقاء القسم الآخر.
    await GroceryDatabase.closeForMaintenance();
    await supportDirectory.delete(recursive: true);
    await supportDirectory.create();
    final freshDatabase = await GroceryDatabase.open();
    expect(await freshDatabase.query('products'), isEmpty);

    final reconnected = await AppDataLocation.connectExisting(
      currentDatabase: freshDatabase,
      closeDatabase: GroceryDatabase.closeForMaintenance,
      reopenDatabase: GroceryDatabase.open,
      selectedParentPath: targetParent.path,
    );
    expect(reconnected.path, target.path);
    final recoveredDatabase = await GroceryDatabase.open();
    final recoveredProducts = await recoveredDatabase.query('products');
    expect(recoveredProducts, hasLength(1));
    expect(recoveredProducts.single['name'], 'صنف النقل');

    // محاكاة فشل إعادة فتح قاعدة البيانات بعد اعتماد المسار الجديد،
    // والتأكد من الرجوع للمسار السابق مع بقاء البيانات سليمة.
    final rollbackParent = await Directory.systemTemp.createTemp('homi-data-rollback-');
    var reopenAttempts = 0;
    await expectLater(
      AppDataLocation.migrate(
        currentDatabase: recoveredDatabase,
        closeDatabase: GroceryDatabase.closeForMaintenance,
        reopenDatabase: () async {
          reopenAttempts++;
          if (reopenAttempts == 1) {
            throw StateError('فشل تجريبي بعد اعتماد مسار النقل.');
          }
          return GroceryDatabase.open();
        },
        selectedParentPath: rollbackParent.path,
      ),
      throwsA(isA<StateError>()),
    );
    expect(reopenAttempts, 2);
    expect(await AppDataLocation.currentPath(), target.path);
    expect(
      await Directory(p.join(rollbackParent.path, 'Homi Grocery Data')).exists(),
      isFalse,
      reason: 'يجب تنظيف مجلد النقل الجزئي بعد فشل إعادة الفتح.',
    );
    final restoredDatabase = await GroceryDatabase.open();
    final restoredProducts = await restoredDatabase.query('products');
    expect(restoredProducts, hasLength(1));
    expect(restoredProducts.single['name'], 'صنف النقل');
    await rollbackParent.delete(recursive: true);

    // يجب أن يمكن إعادة الربط حتى عندما يكون المسار المحفوظ نفسه غير متاح.
    await GroceryDatabase.closeForMaintenance();
    final disconnectedTarget = Directory('${target.path}.disconnected');
    await target.rename(disconnectedTarget.path);
    final recoveryParent = await Directory.systemTemp.createTemp('homi-data-reconnect-');
    final recoveryTarget = Directory(p.join(recoveryParent.path, 'Homi Grocery Data'));
    await recoveryTarget.create(recursive: true);
    await for (final entity in disconnectedTarget.list(
      recursive: true,
      followLinks: false,
    )) {
      final relative = p.relative(entity.path, from: disconnectedTarget.path);
      final destination = p.join(recoveryTarget.path, relative);
      if (entity is Directory) {
        await Directory(destination).create(recursive: true);
      } else if (entity is File) {
        await Directory(p.dirname(destination)).create(recursive: true);
        await entity.copy(destination);
      }
    }

    final fallbackDatabase = await databaseFactory.openDatabase(
      p.join(supportDirectory.path, 'homi_grocery.db'),
    );
    final reconnectedAfterDisconnect = await AppDataLocation.connectExisting(
      currentDatabase: fallbackDatabase,
      closeDatabase: () async {
        if (fallbackDatabase.isOpen) await fallbackDatabase.close();
      },
      reopenDatabase: GroceryDatabase.open,
      selectedParentPath: recoveryParent.path,
    );
    expect(reconnectedAfterDisconnect.path, recoveryTarget.path);
    final databaseAfterReconnect = await GroceryDatabase.open();
    final productsAfterReconnect = await databaseAfterReconnect.query('products');
    expect(productsAfterReconnect, hasLength(1));
    expect(productsAfterReconnect.single['name'], 'صنف النقل');
    await GroceryDatabase.closeForMaintenance();
    await disconnectedTarget.rename(target.path);
    await recoveryParent.delete(recursive: true);
  });
}
