import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/daos/settings_dao.dart';
import '../providers/database_provider.dart';

/// Choices frozen into each build, independent of later preference changes.
class DarkroomProcessingOptions {
  const DarkroomProcessingOptions({
    this.normalization = 'global',
    this.drizzleScale = 0,
    this.pixfrac = .9,
  });

  final String normalization;

  /// Zero means conventional registration; 1–4 select drizzle output scale.
  final int drizzleScale;
  final double pixfrac;
  int get outputScale => drizzleScale == 0 ? 1 : drizzleScale;

  factory DarkroomProcessingOptions.fromJson(Map value) {
    final normalization = value['normalization'] ?? 'global';
    final scale = value['drizzleScale'] ?? 0;
    final fraction = value['pixfrac'] ?? .9;
    if (!['global', 'local'].contains(normalization) ||
        scale is! int ||
        scale < 0 ||
        scale > 4 ||
        fraction is! num ||
        !fraction.isFinite ||
        fraction < .5 ||
        fraction > 1) {
      throw const FormatException('Invalid normalization or drizzle options.');
    }
    return DarkroomProcessingOptions(
      normalization: normalization as String,
      drizzleScale: scale,
      pixfrac: fraction.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
    'normalization': normalization,
    'drizzleScale': drizzleScale,
    'pixfrac': pixfrac,
  };
  Map<String, dynamic> get nativeNormalization => {
    'enabled': true,
    'mode': normalization,
    if (normalization == 'local') ...{'localRows': 8, 'localCols': 8},
  };
  Map<String, dynamic>? get nativeDrizzle =>
      drizzleScale == 0 ? null : {'scale': drizzleScale, 'pixfrac': pixfrac};

  DarkroomProcessingOptions copyWith({
    String? normalization,
    int? drizzleScale,
    double? pixfrac,
  }) => DarkroomProcessingOptions.fromJson({
    ...toJson(),
    if (normalization != null) 'normalization': normalization,
    if (drizzleScale != null) 'drizzleScale': drizzleScale,
    if (pixfrac != null) 'pixfrac': pixfrac,
  });

  static const settingsKey = 'darkroom.processing.options';
  static Future<DarkroomProcessingOptions> load(SettingsDao dao) async {
    final raw = await dao.getSetting(settingsKey);
    return raw == null
        ? const DarkroomProcessingOptions()
        : DarkroomProcessingOptions.fromJson(jsonDecode(raw) as Map);
  }
}

final darkroomProcessingOptionsProvider =
    FutureProvider<DarkroomProcessingOptions>(
      (ref) => DarkroomProcessingOptions.load(ref.watch(settingsDaoProvider)),
    );
