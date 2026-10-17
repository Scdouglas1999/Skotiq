import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  group('SkotiqTheme', () {
    final themes = <String, ThemeData>{
      'dark': SkotiqTheme.dark,
      'light': SkotiqTheme.light,
      'redNight': SkotiqTheme.redNight,
    };

    for (final entry in themes.entries) {
      test('${entry.key} theme registers SkotiqColors extension', () {
        final colors = entry.value.extension<SkotiqColors>();

        expect(colors, isNotNull);
        expect(colors!.primary, isA<Color>());
      });
    }

    test('ColorScheme primary matches SkotiqColors.primary', () {
      for (final theme in themes.values) {
        final colors = theme.extension<SkotiqColors>()!;
        expect(theme.colorScheme.primary, colors.primary);
      }
    });

    test('dark theme uses dark ink on its light-toned primary', () {
      // Was pinned to white, which measured only 2.94:1 against the dark
      // palette's primary #5B9EC4 (and 2.18:1 on accent, 3.75:1 on error) —
      // below the WCAG AA 4.5:1 floor for button labels. Dark ink on a light
      // fill is the correct pairing; the accent hues are unchanged.
      final colors = SkotiqTheme.dark.extension<SkotiqColors>()!;

      expect(colors.useDarkOnPrimary, isTrue);
      expect(colors.onPrimary, colors.background);
      expect(SkotiqTheme.dark.colorScheme.onPrimary, colors.background);
    });

    test('light theme uses white onPrimary', () {
      final colors = SkotiqTheme.light.extension<SkotiqColors>()!;

      expect(colors.useDarkOnPrimary, isFalse);
      expect(colors.onPrimary, const Color(0xFFFFFFFF));
      expect(SkotiqTheme.light.colorScheme.onPrimary, const Color(0xFFFFFFFF));
    });

    test('redNight theme uses dark onPrimary for night vision contrast', () {
      final colors = SkotiqTheme.redNight.extension<SkotiqColors>()!;

      expect(colors.useDarkOnPrimary, isTrue);
      expect(colors.onPrimary, colors.background);
      expect(colors.onPrimary, isNot(const Color(0xFFFFFFFF)));
      expect(SkotiqTheme.redNight.colorScheme.onPrimary, colors.background);
    });

    test('accent theme registers SkotiqColors and matches ColorScheme', () {
      const accent = Color(0xFF10B981);
      final theme = SkotiqTheme.darkWithAccent(accent);
      final colors = theme.extension<SkotiqColors>()!;

      expect(colors.primary, accent);
      expect(theme.colorScheme.primary, accent);
    });

    test('accent ink is chosen by accent luminance, not hardcoded', () {
      // A user accent can be any colour, so neither ink is safe as a blanket
      // default: white on this light emerald is 2.54:1 while dark ink is
      // 7.72:1, and on a dark navy the ratios invert (10.36:1 vs 1.89:1).
      const lightAccent = Color(0xFF10B981); // luminance 0.364 -> dark ink
      const darkAccent = Color(0xFF1E3A8A); // luminance 0.051 -> white

      final lightAccentColors = SkotiqTheme.darkWithAccent(
        lightAccent,
      ).extension<SkotiqColors>()!;
      expect(lightAccentColors.useDarkOnPrimary, isTrue);
      expect(lightAccentColors.onPrimary, lightAccentColors.background);

      final darkAccentColors = SkotiqTheme.darkWithAccent(
        darkAccent,
      ).extension<SkotiqColors>()!;
      expect(darkAccentColors.useDarkOnPrimary, isFalse);
      expect(darkAccentColors.onPrimary, const Color(0xFFFFFFFF));
    });

    test('copyWith preserves useDarkOnPrimary unless overridden', () {
      final copied = SkotiqColors.redNight.copyWith(primary: Colors.red);

      expect(copied.useDarkOnPrimary, isTrue);
      expect(copied.onPrimary, SkotiqColors.redNight.background);
    });
  });

  group('SkotiqThemeContext', () {
    testWidgets('skotiqColors resolves from ThemeData', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
            builder: (context) {
              expect(context.skotiqColors.primary, SkotiqColors.dark.primary);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
    });
  });

  group('SkotiqSwitchStyle.switchThemeData parity', () {
    test('uses colors.onPrimary for selected thumb in dark theme', () {
      const colors = SkotiqColors.dark;
      final theme = SkotiqSwitchStyle.switchThemeData(colors, colors.onPrimary);

      expect(
        theme.thumbColor!.resolve({WidgetState.selected}),
        colors.onPrimary,
      );
    });

    test('uses colors.onPrimary for selected thumb in redNight theme', () {
      const colors = SkotiqColors.redNight;
      final theme = SkotiqSwitchStyle.switchThemeData(colors, colors.onPrimary);

      expect(
        theme.thumbColor!.resolve({WidgetState.selected}),
        colors.background,
      );
    });
  });
}
