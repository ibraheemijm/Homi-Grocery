import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/data/font_preferences.dart';

void main() {
  test('rejects a selected imported font when its path is missing', () async {
    final previousUiFont = FontPreferences.uiFont;
    final previousDocumentFont = FontPreferences.documentFont;
    final previousPath = FontPreferences.importedFontPath;

    FontPreferences.uiFont = FontPreferences.importedFontFamily;
    FontPreferences.documentFont = FontPreferences.defaultDocumentFont;
    FontPreferences.importedFontPath = null;
    try {
      await expectLater(
        FontPreferences.registerImportedFont(),
        throwsStateError,
      );
    } finally {
      FontPreferences.uiFont = previousUiFont;
      FontPreferences.documentFont = previousDocumentFont;
      FontPreferences.importedFontPath = previousPath;
    }
  });

  group('FontPreferences.hasSupportedSignature', () {
    test('accepts the supported TrueType signature', () {
      expect(FontPreferences.hasSupportedSignature([0, 1, 0, 0]), isTrue);
    });

    test('accepts OpenType CFF signature', () {
      expect(FontPreferences.hasSupportedSignature([79, 84, 84, 79]), isTrue);
    });

    test('rejects unknown and truncated signatures', () {
      expect(FontPreferences.hasSupportedSignature([1, 2, 3, 4]), isFalse);
      expect(FontPreferences.hasSupportedSignature([0, 1, 0]), isFalse);
      expect(FontPreferences.hasSupportedSignature([]), isFalse);
    });
  });

  group('FontPreferences.familyForBytes', () {
    test('returns a stable family for identical font bytes', () {
      expect(
        FontPreferences.familyForBytes([0, 1, 0, 0, 1, 2, 3]),
        FontPreferences.familyForBytes([0, 1, 0, 0, 1, 2, 3]),
      );
    });

    test('uses distinct families for different font contents', () {
      expect(
        FontPreferences.familyForBytes([0, 1, 0, 0, 1, 2, 3]),
        isNot(FontPreferences.familyForBytes([0, 1, 0, 0, 1, 2, 4])),
      );
    });
  });
}
