import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  group('SkotiqTheme caching', () {
    test('the three fixed themes are built once', () {
      expect(identical(SkotiqTheme.dark, SkotiqTheme.dark), isTrue);
      expect(identical(SkotiqTheme.light, SkotiqTheme.light), isTrue);
      expect(identical(SkotiqTheme.redNight, SkotiqTheme.redNight), isTrue);
    });

    test('the fixed themes are still distinct from each other', () {
      expect(identical(SkotiqTheme.dark, SkotiqTheme.light), isFalse);
      expect(identical(SkotiqTheme.dark, SkotiqTheme.redNight), isFalse);
      expect(SkotiqTheme.dark.brightness, Brightness.dark);
      expect(SkotiqTheme.light.brightness, Brightness.light);
      expect(SkotiqTheme.redNight.brightness, Brightness.dark);
    });

    test('repeating an accent reuses the cached theme', () {
      const accent = Color(0xFF33AA77);

      final first = SkotiqTheme.darkWithAccent(accent);
      final second = SkotiqTheme.darkWithAccent(accent);

      expect(identical(first, second), isTrue);
    });

    test('the dark and light accent caches do not collide', () {
      const accent = Color(0xFF33AA77);

      final dark = SkotiqTheme.darkWithAccent(accent);
      final light = SkotiqTheme.lightWithAccent(accent);

      expect(identical(dark, light), isFalse);
      expect(dark.brightness, Brightness.dark);
      expect(light.brightness, Brightness.light);
      // Still cached after the other brightness was asked for.
      expect(identical(SkotiqTheme.darkWithAccent(accent), dark), isTrue);
      expect(identical(SkotiqTheme.lightWithAccent(accent), light), isTrue);
    });

    test('a new accent evicts the previous one but stays correct', () {
      const first = Color(0xFF33AA77);
      const second = Color(0xFFAA3377);

      final firstTheme = SkotiqTheme.darkWithAccent(first);
      final secondTheme = SkotiqTheme.darkWithAccent(second);

      expect(identical(firstTheme, secondTheme), isFalse);
      expect(secondTheme.extension<SkotiqColors>()!.primary, second);
      // Evicted: asking again rebuilds rather than returning the stale entry.
      final firstAgain = SkotiqTheme.darkWithAccent(first);
      expect(firstAgain.extension<SkotiqColors>()!.primary, first);
    });

    test('resolveSkotiqThemeData is stable across calls', () {
      final a = resolveSkotiqThemeData(
        themeSetting: 'dark',
        accentColorHex: '#33AA77',
      );
      final b = resolveSkotiqThemeData(
        themeSetting: 'dark',
        accentColorHex: '#33AA77',
      );

      expect(identical(a, b), isTrue);
      expect(
        identical(
          resolveSkotiqThemeData(themeSetting: 'redNight'),
          resolveSkotiqThemeData(themeSetting: 'redNight'),
        ),
        isTrue,
      );
    });
  });
}
