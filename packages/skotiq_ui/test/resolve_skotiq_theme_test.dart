import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  group('resolveSkotiqThemeData', () {
    test('red night ignores custom accent', () {
      final theme = resolveSkotiqThemeData(
        themeSetting: 'redNight',
        accentColorHex: '#FF0000',
      );
      expect(theme.brightness, Brightness.dark);
      expect(
        theme.extension<SkotiqColors>()!.primary,
        SkotiqColors.redNight.primary,
      );
    });

    test('applies accent to dark theme', () {
      final theme = resolveSkotiqThemeData(
        themeSetting: 'dark',
        accentColorHex: '#FF0000',
      );
      final colors = theme.extension<SkotiqColors>()!;
      expect(colors.primary, const Color(0xFFFF0000));
    });
  });

  group('systemUiOverlayStyleFor', () {
    test('uses dark status icons on light theme', () {
      final style = systemUiOverlayStyleFor(SkotiqTheme.light);
      expect(style.statusBarIconBrightness, Brightness.dark);
    });

    test('uses light status icons on dark theme', () {
      final style = systemUiOverlayStyleFor(SkotiqTheme.dark);
      expect(style.statusBarIconBrightness, Brightness.light);
    });
  });
}
