// Red night is a WAVELENGTH constraint, not just a dark palette.
//
// `SkotiqChartColors` series are `static const`, so they were theme-blind:
// with red night active the dashboard guiding chart drew its Dec series and
// legend swatch in #6B95B8 — measured on device as rgb(107,149,184), a solid
// blue — while every other pixel on screen was red. Blue light is precisely
// what destroys the dark adaptation the mode exists to protect.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Fraction of total channel energy carried by red.
double _redPurity(Color c) {
  final total = c.r + c.g + c.b;
  return total == 0 ? 1.0 : c.r / total;
}

void main() {
  group('SkotiqChartColors.forTheme', () {
    test('is the identity for the non-red-night themes', () {
      for (final theme in [SkotiqColors.dark, SkotiqColors.light]) {
        expect(theme.isRedNight, isFalse);
        for (final series in SkotiqChartColors.series) {
          expect(SkotiqChartColors.forTheme(series, theme), series);
        }
      }
    });

    test('red night maps every series onto the red axis', () {
      const redNight = SkotiqColors.redNight;
      expect(redNight.isRedNight, isTrue);

      for (final series in [
        ...SkotiqChartColors.series,
        SkotiqChartColors.seriesRed,
        SkotiqChartColors.seriesOrange,
      ]) {
        final mapped = SkotiqChartColors.forTheme(series, redNight);
        expect(
          mapped.g,
          lessThanOrEqualTo(mapped.r),
          reason: 'green channel outranks red for $series',
        );
        expect(
          mapped.b,
          lessThanOrEqualTo(mapped.r),
          reason:
              'blue channel outranks red for $series -- this is the '
              'dark-adaptation regression',
        );
        expect(
          _redPurity(mapped),
          greaterThan(0.5),
          reason: 'red must dominate the emitted spectrum for $series',
        );
      }
    });

    test('the specific blue that shipped is no longer blue in red night', () {
      // #6B95B8, the Dec series measured on the device.
      final mapped = SkotiqChartColors.forTheme(
        SkotiqChartColors.seriesBlue,
        SkotiqColors.redNight,
      );
      expect(mapped.b, lessThan(mapped.r));
      expect(_redPurity(mapped), greaterThan(0.5));
    });

    test('two different series stay visually distinct in red night', () {
      final ra = SkotiqChartColors.forTheme(
        SkotiqChartColors.seriesRed,
        SkotiqColors.redNight,
      );
      final dec = SkotiqChartColors.forTheme(
        SkotiqChartColors.seriesBlue,
        SkotiqColors.redNight,
      );
      // Distinguished by lightness rather than hue.
      final delta =
          (HSLColor.fromColor(ra).lightness - HSLColor.fromColor(dec).lightness)
              .abs();
      expect(
        delta,
        greaterThan(0.02),
        reason: 'RA and Dec collapsed to the same colour in red night',
      );
    });
  });
}
