import 'package:flutter_test/flutter_test.dart';
import 'package:homi_grocery/data/font_preferences.dart';

void main() {
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
}
