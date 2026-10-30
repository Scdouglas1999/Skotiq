import 'package:flutter/material.dart';
import 'skotiq_colors.dart';

/// Desaturated chart and data-viz colors aligned with the Skotiq palette.
///
/// Static series constants hold fixed chart hues. Resolver methods take
/// [SkotiqColors] to map interactive states to theme semantics.
/// Follow this pattern for new domain color helpers.
abstract final class SkotiqChartColors {
  SkotiqChartColors._();

  /// Map a fixed series colour onto the active theme.
  ///
  /// In every theme but red night this is the identity — the series hues are
  /// chosen to work on the dark and light surfaces as-is. Red night is
  /// different in kind: it is a WAVELENGTH constraint, so a blue series is not
  /// merely off-palette, it undoes the dark adaptation the mode exists to
  /// protect. Measured on device, the dashboard guiding chart drew its Dec
  /// series and legend swatch in `#6B95B8` (a solid blue) while every other
  /// pixel on the screen was red.
  ///
  /// Series stay distinguishable in red night by LIGHTNESS rather than hue:
  /// the source colour's perceptual luminance is preserved and re-expressed on
  /// the red axis, so a two-series chart still reads as two lines.
  static Color forTheme(Color series, SkotiqColors colors) {
    if (!colors.isRedNight) return series;
    // Drive lightness from PERCEPTUAL luminance, not HSL lightness: the source
    // series are near-equal in HSL lightness (seriesRed 0.59 vs seriesBlue
    // 0.57), so mapping that collapsed a two-line chart to one colour. Relative
    // luminance separates them because the eye weights green/blue differently.
    // Saturation is high enough that red stays the dominant channel — at the
    // 0.55 used first, a mid-lightness red still emitted 51% green+blue.
    // Upper clamp is 0.62, not 0.75: a red hue washes toward PINK as HSL
    // lightness rises, and by 0.75 the bright series (amber) emitted 55%
    // green+blue -- nominally "red" while still bleaching dark adaptation.
    final lightness = (0.32 + series.computeLuminance()).clamp(0.25, 0.62);
    return HSLColor.fromAHSL(
      HSLColor.fromColor(series).alpha,
      0, // red
      0.75,
      lightness,
    ).toColor();
  }

  static const Color seriesBlue = Color(0xFF6B95B8);
  static const Color seriesViolet = Color(0xFF8A82B0);
  static const Color seriesGreen = Color(0xFF4A9A72);
  static const Color seriesAmber = Color(0xFFC4A055);
  static const Color seriesIndigo = Color(0xFF5A6690);
  static const Color seriesDeepBlue = Color(0xFF4A6E9A);

  static const Color seriesRed = Color(0xFFBF6B6B);
  static const Color seriesOrange = Color(0xFFCB8847);
  static const Color neutralDark = Color(0xFF1F2937);

  static const List<Color> series = [
    seriesBlue,
    seriesViolet,
    seriesGreen,
    seriesAmber,
    seriesIndigo,
    seriesDeepBlue,
  ];

  /// PSF heatmap: tight → average → bloated.
  static const List<Color> psfGradient = [seriesGreen, seriesAmber, seriesRed];

  /// Uniformity: flat → mild → strong gradient.
  static const List<Color> uniformityGradient = [
    seriesGreen,
    seriesAmber,
    seriesOrange,
  ];

  /// Clip-high: safe → some clip → saturated.
  static const List<Color> clipHighGradient = [
    neutralDark,
    seriesAmber,
    seriesRed,
  ];

  /// Clip-low: safe → some clip → noise floor.
  static const List<Color> clipLowGradient = [
    neutralDark,
    seriesBlue,
    seriesDeepBlue,
  ];

  static Color twilightCivil({double alpha = 0.2}) =>
      seriesBlue.withValues(alpha: alpha);

  static Color twilightNautical({double alpha = 0.3}) =>
      seriesDeepBlue.withValues(alpha: alpha);

  /// Astronomical twilight band overlay (sequence timeline).
  static Color twilightAstro({double alpha = 0.4}) =>
      seriesIndigo.withValues(alpha: alpha);

  /// Selected frame highlight from theme semantics.
  static Color selectedFrame([SkotiqColors? colors]) =>
      (colors ?? SkotiqColors.dark).success;

  static Color unselectedFrame({double alpha = 0.65}) =>
      seriesDeepBlue.withValues(alpha: alpha);
}
