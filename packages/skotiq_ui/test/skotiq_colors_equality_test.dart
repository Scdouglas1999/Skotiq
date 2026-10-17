import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  group('SkotiqColors value equality', () {
    test('two instances with identical fields compare equal', () {
      final a = SkotiqColors.darkWithAccent(const Color(0xFF33AA77));
      final b = SkotiqColors.darkWithAccent(const Color(0xFF33AA77));

      expect(identical(a, b), isFalse);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('a differing field breaks equality', () {
      const base = SkotiqColors.dark;

      expect(base.copyWith(primary: const Color(0xFF010203)), isNot(base));
      expect(base.copyWith(isRedNight: true), isNot(base));
      expect(base.copyWith(useDarkOnPrimary: false), isNot(base));
    });

    test('every constructor field participates in equality', () {
      const base = SkotiqColors.light;
      const probe = Color(0xFF0B0C0D);

      final variants = <String, SkotiqColors>{
        'primary': base.copyWith(primary: probe),
        'accent': base.copyWith(accent: probe),
        'background': base.copyWith(background: probe),
        'surface': base.copyWith(surface: probe),
        'surfaceAlt': base.copyWith(surfaceAlt: probe),
        'surfaceHover': base.copyWith(surfaceHover: probe),
        'surfaceElevated': base.copyWith(surfaceElevated: probe),
        'surfaceOverlay': base.copyWith(surfaceOverlay: probe),
        'border': base.copyWith(border: probe),
        'borderHighlight': base.copyWith(borderHighlight: probe),
        'textPrimary': base.copyWith(textPrimary: probe),
        'textSecondary': base.copyWith(textSecondary: probe),
        'textMuted': base.copyWith(textMuted: probe),
        'success': base.copyWith(success: probe),
        'warning': base.copyWith(warning: probe),
        'error': base.copyWith(error: probe),
        'info': base.copyWith(info: probe),
        'useDarkOnPrimary': base.copyWith(useDarkOnPrimary: true),
        'isRedNight': base.copyWith(isRedNight: true),
      };

      for (final entry in variants.entries) {
        expect(
          entry.value,
          isNot(base),
          reason: 'changing ${entry.key} must break equality',
        );
      }
    });

    test('a full copyWith() round trip equals the original', () {
      const base = SkotiqColors.redNight;
      expect(base.copyWith(), equals(base));
    });

    test('ThemeData carrying equal palettes compares equal '
        '(this is what stops the accent-color rebuild storm)', () {
      final one = ThemeData(
        extensions: [SkotiqColors.darkWithAccent(const Color(0xFF884422))],
      );
      final two = ThemeData(
        extensions: [SkotiqColors.darkWithAccent(const Color(0xFF884422))],
      );

      expect(one, equals(two));
    });
  });
}
