import 'package:flutter/material.dart';

import 'skotiq_chart_colors.dart';
import 'skotiq_colors.dart';

/// Filter identity is consistent across the wheel, timelines and analytics.
abstract final class FilterColors {
  static const luminance = Color(0xFFD4D4D8);
  static const red = Color(0xFFF87171);
  static const green = Color(0xFF4ADE80);
  static const blue = Color(0xFF60A5FA);
  static const hydrogenAlpha = Color(0xFFB91C1C);
  static const oxygen = Color(0xFF2DD4BF);
  static const sulfur = Color(0xFFFB923C);
  static const nitrogen = Color(0xFFA855F7);

  static Color? knownColor(String name) {
    final n = name.toUpperCase().replaceAll(RegExp(r'[\s_\-]'), '');
    if (n == 'HA' ||
        RegExp(r'^HA[0-9]').hasMatch(n) ||
        n.contains('ALPHA') ||
        n == 'HΑ') {
      return hydrogenAlpha;
    }
    if (n == 'R' || n.contains('RED')) return red;
    if (n == 'G' || n.contains('GREEN')) return green;
    if (n == 'B' || n.contains('BLUE')) return blue;
    if (n == 'L' || n.contains('LUM') || n.contains('CLEAR')) return luminance;
    if (n.contains('OIII') || n.contains('O3') || n.contains('OXYGEN')) {
      return oxygen;
    }
    if (n.contains('SII') ||
        n.contains('S2') ||
        n.contains('SULF') ||
        n.contains('SULPH')) {
      return sulfur;
    }
    if (n.contains('NII') || n.contains('N2')) return nitrogen;
    return null;
  }

  static const _lightOxygen = Color(0xFF157567);
  static const _lightSulfur = Color(0xFF965200);
  static const _lightNitrogen = Color(0xFF7B3CB4);
  static const _darkHydrogenAlpha = Color(0xFFE89696);

  static Color forName(String name, {SkotiqColors? colors}) {
    final palette = colors ?? SkotiqColors.dark;
    final color = knownColor(name);
    if (color == null) return palette.textSecondary;
    if (color == luminance) return palette.textSecondary;
    final light = palette.surface.computeLuminance() > 0.5;
    final readable = switch (color) {
      red => palette.error,
      green => palette.success,
      blue => palette.info,
      hydrogenAlpha => light ? hydrogenAlpha : _darkHydrogenAlpha,
      oxygen => light ? _lightOxygen : oxygen,
      sulfur => light ? _lightSulfur : sulfur,
      nitrogen => light ? _lightNitrogen : nitrogen,
      _ => color,
    };
    return SkotiqChartColors.forTheme(readable, palette);
  }
}
