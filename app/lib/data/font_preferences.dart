// إعدادات الخطوط المشتركة بين الواجهة والمستندات، محفوظة داخل app_metadata.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'grocery_database.dart';

class FontPreferences {
  FontPreferences._();

  static const defaultUiFont = 'Cairo';
  static const defaultDocumentFont = 'Amiri';
  static const importedFontFamily = 'HomiImportedFont';

  static final ValueNotifier<String> uiFontNotifier = ValueNotifier(defaultUiFont);
  static String uiFont = defaultUiFont;
  static String documentFont = defaultDocumentFont;
  static String? importedFontPath;
  static String? importedFontName;

  static Future<void> load() async {
    final db = await GroceryDatabase.open();
    final rows = await db.query(
      'app_metadata',
      columns: ['key', 'value'],
      where: 'key IN (?, ?, ?, ?, ?)',
      whereArgs: [
        'ui_font_family',
        'document_font_family',
        'imported_font_path',
        'imported_font_name',
        'imported_font_registered',
      ],
    );
    final values = {
      for (final row in rows) row['key'] as String: row['value'] as String,
    };
    uiFont = _validUiFont(values['ui_font_family']);
    uiFontNotifier.value = uiFont;
    documentFont = _validDocumentFont(values['document_font_family']);
    importedFontPath = values['imported_font_path'];
    importedFontName = values['imported_font_name'];
    try {
      await registerImportedFont();
    } on Object {
      // الخط المستورد بيانات اختيارية؛ لا يجوز أن يمنع فتح التطبيق إذا تلف
      // الملف أو تعذر على Flutter تحميله. استخدم الخطوط المضمنة بدلًا منه.
      importedFontPath = null;
      importedFontName = null;
      if (uiFont == importedFontFamily) {
        uiFont = defaultUiFont;
        uiFontNotifier.value = uiFont;
      }
      if (documentFont == importedFontFamily) {
        documentFont = defaultDocumentFont;
      }
    }
  }

  static String _validUiFont(String? value) =>
      const {'Arial', 'Cairo', 'Amiri', importedFontFamily}.contains(value)
          ? value!
          : defaultUiFont;

  static String _validDocumentFont(String? value) =>
      const {'Arial', 'Cairo', 'Amiri', importedFontFamily}.contains(value)
          ? value!
          : defaultDocumentFont;

  static Future<void> save({
    required String uiFamily,
    required String documentFamily,
  }) async {
    final db = await GroceryDatabase.open();
    await db.transaction((txn) async {
      for (final entry in <String, String>{
        'ui_font_family': _validUiFont(uiFamily),
        'document_font_family': _validDocumentFont(documentFamily),
      }.entries) {
        await txn.insert(
          'app_metadata',
          {'key': entry.key, 'value': entry.value},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    uiFont = _validUiFont(uiFamily);
    uiFontNotifier.value = uiFont;
    documentFont = _validDocumentFont(documentFamily);
  }

  /// يستورد TTF/OTF إلى مجلد بيانات التطبيق ولا يحتفظ بمسار مؤقت من مدير الملفات.
  static Future<String?> importFont() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['ttf', 'otf'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final picked = result.files.single;
    final bytes = picked.bytes ??
        (picked.path == null ? null : await File(picked.path!).readAsBytes());
    if (bytes == null || bytes.length < 1024) {
      throw const FormatException('ملف الخط فارغ أو غير صالح.');
    }
    // تحقق أولي من ترويسة OpenType/TrueType، لا يثبت وجود محارف عربية داخل الخط.
    if (!hasSupportedSignature(bytes)) {
      throw const FormatException('الملف ليس خط TTF/OTF معروفًا.');
    }

    final directory = await getApplicationSupportDirectory();
    final fontDirectory = Directory(p.join(directory.path, 'fonts'));
    await fontDirectory.create(recursive: true);
    final extension = p.extension(picked.name).toLowerCase() == '.otf'
        ? '.otf'
        : '.ttf';
    final destination = File(p.join(fontDirectory.path, 'homi_imported$extension'));
    final previousPath = importedFontPath;
    final previousName = importedFontName;
    final previousBytes =
        await destination.exists() ? await destination.readAsBytes() : null;

    // اكتب الملف الجديد أولًا، لكن لا تعتمد بياناته الوصفية إلا بعد نجاح التسجيل.
    await destination.writeAsBytes(bytes, flush: true);
    importedFontPath = destination.path;
    importedFontName = p.basenameWithoutExtension(picked.name);
    try {
      await registerImportedFont();
      final db = await GroceryDatabase.open();
      await db.transaction((txn) async {
        for (final entry in <String, String>{
          'imported_font_path': destination.path,
          'imported_font_name': importedFontName!,
        }.entries) {
          await txn.insert(
            'app_metadata',
            {'key': entry.key, 'value': entry.value},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
    } on Object {
      // أعد الملف والاختيارات السابقة إن فشل التسجيل أو حفظ الإعدادات.
      if (previousBytes == null) {
        if (await destination.exists()) await destination.delete();
      } else {
        await destination.writeAsBytes(previousBytes, flush: true);
      }
      importedFontPath = previousPath;
      importedFontName = previousName;
      rethrow;
    }
    return importedFontName;
  }

  /// يتحقق من ترويسة TTF/OpenType فقط؛ لا يثبت سلامة جداول الخط أو تغطية العربية.
  static bool hasSupportedSignature(List<int> bytes) {
    if (bytes.length < 4) return false;
    final signature = String.fromCharCodes(bytes.take(4));
    return signature == 'OTTO' ||
        signature == 'true' ||
        signature == 'typ1' ||
        (bytes[0] == 0 &&
            bytes[1] == 1 &&
            bytes[2] == 0 &&
            bytes[3] == 0);
  }

  static String? _registeredFontFamily;
  static final Set<String> _registeredFontFamilies = {};

  /// عائلة فعلية فريدة لكل ملف مستورد؛ قيمة importedFontFamily تبقى معرّف
  /// ثابتًا محفوظًا في الإعدادات ولا تُستخدم كاسم عائلة Flutter مباشرة.
  static String get registeredImportedFontFamily =>
      _registeredFontFamily ?? importedFontFamily;

  @visibleForTesting
  static String familyForBytes(List<int> bytes) {
    // FNV-1a 32-bit: اسم حتمي للملف نفسه ومختلف غالبًا بين الملفات المختلفة.
    var hash = 0x811c9dc5;
    for (final byte in bytes) {
      hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
    }
    return 'HomiImportedFont_${hash.toRadixString(16).padLeft(8, '0')}';
  }

  static Future<void> registerImportedFont() async {
    final path = importedFontPath;
    if (path == null || !await File(path).exists()) return;
    final bytes = await File(path).readAsBytes();
    if (!hasSupportedSignature(bytes)) {
      throw const FormatException('الملف ليس خط TTF/OTF معروفًا.');
    }
    final family = familyForBytes(bytes);
    if (_registeredFontFamilies.contains(family)) {
      _registeredFontFamily = family;
      return;
    }
    final loader = FontLoader(family)
      ..addFont(Future<ByteData>.value(ByteData.sublistView(Uint8List.fromList(bytes))));
    await loader.load();
    _registeredFontFamilies.add(family);
    _registeredFontFamily = family;
  }

  static Future<Uint8List?> importedFontBytes() async {
    final path = importedFontPath;
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }
}
