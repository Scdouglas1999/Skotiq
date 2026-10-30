import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_design/skotiq_design.dart';

void main() {
  test(
    'light-mode accents cannot turn semantic error text white on pale red',
    () {
      for (final accent in [
        Colors.yellow,
        Colors.indigo,
        Colors.green,
        Colors.red,
      ]) {
        for (final colors in [
          SkotiqColors.lightWithAccent(accent),
          SkotiqColors.darkWithAccent(accent),
        ]) {
          for (final fill in [colors.primary, colors.error, colors.accent]) {
            final foreground = colors.inkOn(fill).computeLuminance();
            final background = fill.computeLuminance();
            final ratio = foreground > background
                ? (foreground + 0.05) / (background + 0.05)
                : (background + 0.05) / (foreground + 0.05);
            expect(ratio, greaterThanOrEqualTo(4.5));
          }
        }
      }
    },
  );
}
