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

  static final RegExp _wordSplit = RegExp(r'[\s/\-_+|]+');
  static final RegExp _notAlphanumeric = RegExp(r'[^A-Za-z0-9]');
  static final RegExp _bandwidthSuffix = RegExp(r'^[0-9]');

  /// Whole names whose letters include a band letter but are not that band.
  /// "L-Pro" and "L-eXtreme" would otherwise read as luminance.
  static const _notASingleBand = {'LPRO', 'LEXTREME', 'LULTIMATE', 'LENHANCE'};

  static const _bandColors = <String, Color>{
    'L': luminance,
    'LUM': luminance,
    'LUMINANCE': luminance,
    'LUMINOSITY': luminance,
    'CLEAR': luminance,
    'R': red,
    'RED': red,
    'G': green,
    'GREEN': green,
    'B': blue,
    'BLUE': blue,
    'HA': hydrogenAlpha,
    'HALPHA': hydrogenAlpha,
    'ALPHA': hydrogenAlpha,
    'HYDROGENALPHA': hydrogenAlpha,
    'OIII': oxygen,
    'O3': oxygen,
    'OXYGEN': oxygen,
    'OXYGENIII': oxygen,
    'SII': sulfur,
    'S2': sulfur,
    'SULFUR': sulfur,
    'SULPHUR': sulfur,
    'SULFURII': sulfur,
    'SULPHURII': sulfur,
    'NII': nitrogen,
    'N2': nitrogen,
  };

  static String _letters(String text) =>
      text.replaceAll(_notAlphanumeric, '').toUpperCase();

  /// [token] as a band, or that band with a bandwidth glued on ("Ha7nm").
  /// A band matches the whole token, never a piece of a longer word, so
  /// "Unfiltered" is not red.
  static Color? _colorOfToken(String token) {
    final exact = _bandColors[token];
    if (exact != null) return exact;
    for (final entry in _bandColors.entries) {
      final band = entry.key;
      if (token.length <= band.length || !token.startsWith(band)) continue;
      if (_bandwidthSuffix.hasMatch(token.substring(band.length))) {
        return entry.value;
      }
    }
    return null;
  }

  static Color? knownColor(String name) {
    final collapsed = name.toUpperCase().replaceAll(RegExp(r'[\s_\-]'), '');
    // Hα: Greek alpha is not a word separator and is not an ASCII letter.
    if (collapsed == 'H\u0391') return hydrogenAlpha;

    final whole = _letters(name);
    if (whole.isEmpty) return null;
    if (_notASingleBand.contains(whole)) return null;
    final direct = _colorOfToken(whole);
    if (direct != null) return direct;

    final words = [
      for (final word in name.split(_wordSplit))
        if (_letters(word).isNotEmpty) _letters(word),
    ];
    for (var i = 0; i < words.length; i++) {
      final longest = words.length - i < 3 ? words.length - i : 3;
      for (var run = longest; run >= 1; run--) {
        final color = _colorOfToken(words.sublist(i, i + run).join());
        if (color != null) return color;
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
