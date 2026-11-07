// حفظ ملفات PDF باسم مقترح عبر نافذة اختيار مكان الحفظ.
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// يفتح نافذة حفظ فعلية ويكتب محتوى PDF إلى المسار الذي اختاره المستخدم.
/// إرجاع null يعني أن المستخدم ألغى العملية دون إنشاء ملف.
Future<String?> savePdfBytes({
  required Uint8List bytes,
  required String fileName,
  required String dialogTitle,
}) async {
  final selectedPath = await FilePicker.platform.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: const ['pdf'],
  );
  if (selectedPath == null || selectedPath.trim().isEmpty) return null;

  final path = selectedPath.toLowerCase().endsWith('.pdf')
      ? selectedPath
      : '$selectedPath.pdf';
  await File(path).writeAsBytes(bytes, flush: true);
  return path;
}
