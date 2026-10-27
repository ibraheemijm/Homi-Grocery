// إعدادات اسم البقالة والتحية والساعة، محفوظة محليًا في بيانات التطبيق.
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../data/grocery_database.dart';
import '../data/font_preferences.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _storeName = TextEditingController();
  final _occasionText = TextEditingController();
  final _occasionStart = TextEditingController();
  final _occasionEnd = TextEditingController();
  bool _clock24 = true;
  String _uiFont = FontPreferences.defaultUiFont;
  String _documentFont = FontPreferences.defaultDocumentFont;
  String _salesViewMode = 'grid';
  bool _importingFont = false;
  bool _occasionEnabled = false;
  bool _loading = true;
  bool _saving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _storeName.dispose();
    _occasionText.dispose();
    _occasionStart.dispose();
    _occasionEnd.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await FontPreferences.load();
      final db = await GroceryDatabase.open();
      final rows = await db.query(
        'app_metadata',
        columns: ['key', 'value'],
        where: 'key IN (?, ?, ?, ?, ?, ?)',
        whereArgs: [
          'store_name',
          'clock_24h',
          'occasion_enabled',
          'occasion_text',
          'occasion_start',
          'sales_view_mode',
        ],
      );
      final values = {
        for (final row in rows) row['key'] as String: row['value'] as String,
      };
      final endRows = await db.query(
        'app_metadata',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: ['occasion_end'],
        limit: 1,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _storeName.text = values['store_name'] ?? '';
        _uiFont = FontPreferences.uiFont;
        _documentFont = FontPreferences.documentFont;
        _salesViewMode = values['sales_view_mode'] ?? 'grid';
        _clock24 = values['clock_24h'] != 'false';
        _occasionEnabled = values['occasion_enabled'] == 'true';
        _occasionText.text = values['occasion_text'] ?? '';
        _occasionStart.text = values['occasion_start'] ?? '';
        _occasionEnd.text = endRows.isEmpty ? '' : endRows.first['value'] as String;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _message = 'تعذر تحميل الإعدادات: $error';
        });
      }
    }
  }

  Future<void> _importFont() async {
    setState(() {
      _importingFont = true;
      _message = null;
    });
    try {
      final name = await FontPreferences.importFont();
      if (name != null && mounted) {
        setState(() {
          _uiFont = FontPreferences.importedFontFamily;
          _documentFont = FontPreferences.importedFontFamily;
          _message = 'تم استيراد الخط «$name». تحقق من دعمه للعربية قبل استخدامه في الفواتير.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = 'تعذر استيراد الخط: $error');
    } finally {
      if (mounted) setState(() => _importingFont = false);
    }
  }

  Future<void> _save() async {
    final name = _storeName.text.trim();
    if (name.isEmpty) {
      setState(() => _message = 'أدخل اسم البقالة أولًا.');
      return;
    }
    if (_occasionEnabled) {
      final datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');
      if (_occasionText.text.trim().isEmpty ||
          !datePattern.hasMatch(_occasionStart.text.trim()) ||
          !datePattern.hasMatch(_occasionEnd.text.trim())) {
        setState(() => _message = 'أدخل نص المناسبة وتاريخ البداية والنهاية بصيغة YYYY-MM-DD.');
        return;
      }
      if (_occasionStart.text.trim().compareTo(_occasionEnd.text.trim()) > 0) {
        setState(() => _message = 'تاريخ البداية يجب ألا يتجاوز تاريخ النهاية.');
        return;
      }
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final db = await GroceryDatabase.open();
      final values = <String, String>{
        'store_name': name,
        'clock_24h': _clock24.toString(),
        'sales_view_mode': _salesViewMode,
        'occasion_enabled': _occasionEnabled.toString(),
        'occasion_text': _occasionText.text.trim(),
        'occasion_start': _occasionStart.text.trim(),
        'occasion_end': _occasionEnd.text.trim(),
      };
      await db.transaction((txn) async {
        for (final entry in values.entries) {
          await txn.insert(
            'app_metadata',
            {'key': entry.key, 'value': entry.value},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
      await FontPreferences.save(uiFamily: _uiFont, documentFamily: _documentFont);
      if (mounted) setState(() => _message = 'تم حفظ الإعدادات. طُبّق خط الواجهة، وسيُستخدم خط المستندات عند إنشاء الفواتير وملفات PDF.');
    } catch (error) {
      if (mounted) setState(() => _message = 'تعذر حفظ الإعدادات: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('إعدادات البرنامج')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('بيانات البقالة',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _storeName,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'اسم البقالة',
                              hintText: 'مثال: بقالة الحي',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 18),
                          const Text('الساعة الرقمية',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          DropdownButtonFormField<String>(
                            initialValue: _salesViewMode,
                            decoration: const InputDecoration(
                              labelText: 'طريقة عرض الأصناف في شاشة البيع',
                              border: OutlineInputBorder(),
                            ),
                            items: const [
                              DropdownMenuItem(value: 'grid', child: Text('شبكة بطاقات')),
                              DropdownMenuItem(value: 'rowsWithIcons', child: Text('صفوف مع أيقونة')),
                              DropdownMenuItem(value: 'rows', child: Text('صفوف وكتابة فقط')),
                            ],
                            onChanged: (value) {
                              if (value != null) setState(() => _salesViewMode = value);
                            },
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<bool>(
                            initialValue: _clock24,
                            decoration: const InputDecoration(
                              labelText: 'نظام الوقت',
                              border: OutlineInputBorder(),
                            ),
                            items: const [
                              DropdownMenuItem(value: true, child: Text('24 ساعة — 18:45:09')),
                              DropdownMenuItem(value: false, child: Text('12 ساعة — 06:45:09 م')),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setState(() => _clock24 = value);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('تحية المناسبات',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 4),
                          const Text('يمكن ضبط تهنئة العيد أو رمضان أو أي مناسبة خلال فترة محددة.'),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('تفعيل تحية المناسبة'),
                            value: _occasionEnabled,
                            onChanged: (value) => setState(() => _occasionEnabled = value),
                          ),
                          if (_occasionEnabled) ...[
                            TextField(
                              controller: _occasionText,
                              decoration: const InputDecoration(
                                labelText: 'نص التهنئة',
                                hintText: 'رمضان كريم',
                                border: OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _occasionStart,
                              keyboardType: TextInputType.datetime,
                              decoration: const InputDecoration(
                                labelText: 'تاريخ البداية',
                                hintText: 'YYYY-MM-DD',
                                border: OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _occasionEnd,
                              keyboardType: TextInputType.datetime,
                              decoration: const InputDecoration(
                                labelText: 'تاريخ النهاية',
                                hintText: 'YYYY-MM-DD',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('الخطوط والطباعة',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 8),
                          const Text('اختر خط الواجهة وخط الفواتير كلٌّ على حدة. Cairo وAmiri مضمّنان ويعملان دون إنترنت. يعتمد ظهور Arial على توفره في النظام.'),
                          const SizedBox(height: 14),
                          DropdownButtonFormField<String>(
                            initialValue: _uiFont,
                            decoration: const InputDecoration(
                              labelText: 'خط واجهة البرنامج',
                              border: OutlineInputBorder(),
                            ),
                            items: [
                              const DropdownMenuItem(value: 'Arial', child: Text('Arial (خط النظام)')),
                              const DropdownMenuItem(value: 'Cairo', child: Text('Cairo')),
                              const DropdownMenuItem(value: 'Amiri', child: Text('Amiri')),
                              if (FontPreferences.importedFontPath != null)
                                DropdownMenuItem(
                                  value: FontPreferences.importedFontFamily,
                                  child: Text(FontPreferences.importedFontName ?? 'الخط المستورد'),
                                ),
                            ],
                            onChanged: (value) {
                              if (value != null) setState(() => _uiFont = value);
                            },
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            initialValue: _documentFont,
                            decoration: const InputDecoration(
                              labelText: 'خط الفواتير وPDF',
                              border: OutlineInputBorder(),
                            ),
                            items: [
                              const DropdownMenuItem(value: 'Arial', child: Text('Arial (إذا أمكن تحميله)')),
                              const DropdownMenuItem(value: 'Cairo', child: Text('Cairo')),
                              const DropdownMenuItem(value: 'Amiri', child: Text('Amiri')),
                              if (FontPreferences.importedFontPath != null)
                                DropdownMenuItem(
                                  value: FontPreferences.importedFontFamily,
                                  child: Text(FontPreferences.importedFontName ?? 'الخط المستورد'),
                                ),
                            ],
                            onChanged: (value) {
                              if (value != null) setState(() => _documentFont = value);
                            },
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _importingFont ? null : _importFont,
                            icon: _importingFont
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.file_upload_outlined),
                            label: Text(_importingFont ? 'جارٍ استيراد الخط…' : 'استيراد خط TTF / OTF'),
                          ),
                          if (FontPreferences.importedFontName != null) ...[
                            const SizedBox(height: 4),
                            Text('الخط المستورد: ${FontPreferences.importedFontName}'),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 10),
                    Text(_message!, textAlign: TextAlign.center),
                  ],
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.save_rounded),
                    label: Text(_saving ? 'جارٍ الحفظ…' : 'حفظ الإعدادات'),
                  ),
                ],
              ),
      ),
    );
  }
}
