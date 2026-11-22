import 'package:flutter/material.dart';
import 'package:skotiq_astro/filters.dart';

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

  static const _bandColors = <String, Color>{
    'L': luminance,
    'R': red,
    'G': green,
    'B': blue,
    'HA': hydrogenAlpha,
    'OIII': oxygen,
    'SII': sulfur,
    'NII': nitrogen,
  };

  static final RegExp _wordSplit = RegExp(r'[\s/\-_+|]+');
  static final RegExp _notAlphanumeric = RegExp(r'[^A-Za-z0-9]');
  static final RegExp _bandwidthSuffix = RegExp(r'^[0-9]');

  /// The color of the band [name] names by the filter-name rule
  /// (`package:skotiq_astro/filters.dart`), the rule the run moves the wheel
  /// by. A name that spells its bands as separate words ("Ha/OIII",
  /// "Ha+OIII") takes the first one's color; a product of several bands
  /// ("L-eXtreme") or a name of none has no color.
  static Color? knownColor(String name) {
    final bands = filterBands(name);
    if (bands.length > 1) return _firstBandWordColor(name, bands);
    if (bands.length == 1) {
      final color = _bandColors[bands.single];
      if (color != null) return color;
    }
    return _gluedBandwidthColor(name);
  }

  /// The color of the first word of [name] that is by itself one of [bands].
  static Color? _firstBandWordColor(String name, Set<String> bands) {
    for (final word in name.split(_wordSplit)) {
      final wordBands = filterBands(word);
      if (wordBands.length == 1 && bands.contains(wordBands.single)) {
        return _bandColors[wordBands.single];
      }
    }
    return null;
  }

  /// A band word with a bare number glued on ("Ha7"), which the rule does not
  /// read as the band; with its unit ("Ha7nm") the rule already does.
  static Color? _gluedBandwidthColor(String name) {
    for (final word in name.split(_wordSplit)) {
      final token = word.replaceAll(_notAlphanumeric, '').toUpperCase();
      for (final entry in _bandColors.entries) {
        final band = entry.key;
        if (token.length > band.length &&
            token.startsWith(band) &&
            _bandwidthSuffix.hasMatch(token.substring(band.length))) {
          return entry.value;
        }
      }
    }
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
