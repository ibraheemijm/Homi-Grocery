import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../data/backup_repository.dart';
import '../data/grocery_database.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});
  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  bool _working = false;
  String? _lastBackupPath;
  String? _message;
  bool _isError = false;
  Future<BackupRepository> _repo() async => BackupRepository(await GroceryDatabase.open());

  Future<void> _createBackup() async {
    setState(() { _working = true; _message = null; });
    try {
      final file = await (await _repo()).createBackup();
      if (!mounted) return;
      setState(() { _lastBackupPath = file.path; _message = 'تم إنشاء النسخة وفحص سلامتها.'; _isError = false; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _message = 'تعذر إنشاء النسخة: $error'; _isError = true; });
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _restore() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['db', 'sqlite', 'sqlite3'], allowMultiple: false, withData: false);
    if (picked == null || picked.files.single.path == null || !mounted) return;
    final path = picked.files.single.path!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تأكيد الاستعادة'),
        content: const Text('ستُستبدل بيانات المتجر الحالية بالنسخة المختارة. سيفحص التطبيق النسخة أولًا ويحتفظ بنسخة تراجع مؤقتة.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('فحص واستعادة')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() { _working = true; _message = 'جارٍ فحص النسخة واستعادتها...'; _isError = false; });
    try {
      await (await _repo()).restoreBackup(path);
      if (!mounted) return;
      setState(() { _message = 'اكتملت الاستعادة واجتازت قاعدة البيانات فحص السلامة.'; _isError = false; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _message = 'لم تكتمل الاستعادة: $error'; _isError = true; });
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _showFolder() async {
    final directory = await (await _repo()).backupDirectory();
    if (!mounted) return;
    await showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: const Text('مجلد النسخ الاحتياطية'),
      content: SelectableText(directory.path),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق'))],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('النسخ الاحتياطي والاستعادة')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.verified_user_outlined, size: 34),
          const SizedBox(height: 12),
          Text('حماية بيانات المتجر', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('إنشاء لقطة SQLite متسقة، وفحص سلامتها والجداول الأساسية قبل اعتمادها.'),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: _working ? null : _createBackup, icon: const Icon(Icons.backup_rounded), label: const Text('إنشاء نسخة احتياطية الآن')),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: _working ? null : _restore, icon: const Icon(Icons.settings_backup_restore_rounded), label: const Text('اختيار نسخة واستعادتها')),
          TextButton.icon(onPressed: _working ? null : _showFolder, icon: const Icon(Icons.folder_open_rounded), label: const Text('عرض مجلد النسخ')),
        ]))),
        if (_working) const LinearProgressIndicator(),
        if (_message != null) Card(color: _isError ? theme.colorScheme.errorContainer : theme.colorScheme.primaryContainer, child: Padding(padding: const EdgeInsets.all(14), child: Text(_message!, style: TextStyle(color: _isError ? theme.colorScheme.onErrorContainer : theme.colorScheme.onPrimaryContainer)))),
        if (_lastBackupPath != null) Card(child: ListTile(
          leading: const Icon(Icons.task_alt_rounded, color: Colors.green),
          title: const Text('آخر نسخة تم إنشاؤها'),
          subtitle: SelectableText(_lastBackupPath!),
          trailing: IconButton(tooltip: 'حجم النسخة', icon: const Icon(Icons.info_outline_rounded), onPressed: () async {
            final file = File(_lastBackupPath!);
            final size = await file.exists() ? await file.length() : 0;
            if (!mounted) return;
            showDialog<void>(context: context, builder: (context) => AlertDialog(
              title: const Text('تفاصيل النسخة'),
              content: Text(file.existsSync() ? 'الحجم: ${(size / 1024).toStringAsFixed(1)} KB' : 'الملف غير موجود.'),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق'))],
            ));
          }),
        )),
        const SizedBox(height: 12),
        const Text('احتفظ بنسخة خارج الجهاز أيضًا؛ فالنسخ المحلية وحدها لا تحمي من فقدان الجهاز أو تلف القرص.'),
      ]),
    );
  }
}
