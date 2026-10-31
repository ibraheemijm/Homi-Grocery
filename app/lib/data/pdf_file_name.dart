// إنشاء أسماء موحدة وفريدة لملفات PDF بحسب لغة الاسم ووقت التصدير.

String buildPdfFileName({
  required String language,
  required String arabicLabel,
  required String englishLabel,
  DateTime? exportedAt,
}) {
  final date = exportedAt ?? DateTime.now();
  final timestamp = '${date.year.toString().padLeft(4, '0')}'
      '${date.month.toString().padLeft(2, '0')}'
      '${date.day.toString().padLeft(2, '0')}-'
      '${date.hour.toString().padLeft(2, '0')}'
      '${date.minute.toString().padLeft(2, '0')}'
      '${date.second.toString().padLeft(2, '0')}';
  final label = switch (language) {
    'en' => englishLabel,
    'both' => '$arabicLabel-$englishLabel',
    _ => arabicLabel,
  };
  final safeLabel = label
      .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '-')
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return '$safeLabel-$timestamp.pdf';
}
