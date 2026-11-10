// إنشاء أسماء موحدة وفريدة لملفات PDF بحسب لغة الاسم ووقت التصدير.

String buildPdfFileName({
  required String language,
  required String arabicLabel,
  required String englishLabel,
  String? sharedSuffix,
  DateTime? exportedAt,
  bool includeExportDate = true,
}) {
  final date = exportedAt ?? DateTime.now();
  final exportDate = '${date.year.toString().padLeft(4, '0')}'
      '${date.month.toString().padLeft(2, '0')}'
      '${date.day.toString().padLeft(2, '0')}';
  final exportTime = '${date.hour.toString().padLeft(2, '0')}'
      '${date.minute.toString().padLeft(2, '0')}'
      '${date.second.toString().padLeft(2, '0')}';
  final timestamp = includeExportDate
      ? '$exportDate-$exportTime'
      : exportTime;
  final baseLabel = switch (language) {
    'en' => englishLabel,
    'both' => '$arabicLabel-$englishLabel',
    _ => arabicLabel,
  };
  final label = sharedSuffix == null || sharedSuffix.trim().isEmpty
      ? baseLabel
      : '$baseLabel-${sharedSuffix.trim()}';
  final safeLabel = label
      .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '-')
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return '$safeLabel-$timestamp.pdf';
}
