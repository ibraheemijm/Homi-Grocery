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

    final reopened = await GroceryDatabase.open();
    final products = await reopened.query('products', columns: ['image_path']);
    expect(products.single['image_path'], p.join(target.path, 'product-images', 'product-test.png'));
    final fonts = await reopened.query('app_metadata',
        columns: ['value'], where: 'key = ?', whereArgs: ['imported_font_path']);
    expect(fonts.single['value'], p.join(target.path, 'fonts', 'homi_imported.ttf'));
    expect(await AppDataLocation.currentPath(), target.path);
  });
}
