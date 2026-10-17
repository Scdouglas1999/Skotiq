import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart' show AnnotationStatus, ObjectType;
import 'skotiq_colors.dart';

/// Domain-specific hues for catalog object types in annotation UI.
///
/// Static constants hold fixed type hues. Resolver methods take
/// [SkotiqColors] for semantic fallbacks on unknown types.
/// Follow this pattern for new domain color helpers.
abstract final class AnnotationTypeColors {
  AnnotationTypeColors._();

  static const Color galaxy = Color(0xFFBD8EC4);
  static const Color nebula = Color(0xFF6B95B8);
  static const Color starCluster = Color(0xFFC4A055);
  static const Color planetaryNebula = Color(0xFF4A9A72);
  static const Color star = Color(0xFFE8E4DC);
  static const Color doubleStar = Color(0xFFCF8FAD);
  static const Color asterism = Color(0xFF8A82B0);

  /// Resolves a catalog object type to a display color.
  static Color forType(ObjectType type, [SkotiqColors? colors]) {
    final palette = colors ?? SkotiqColors.dark;
    return switch (type) {
      ObjectType.galaxy => galaxy,
      ObjectType.nebula => nebula,
      ObjectType.starCluster => starCluster,
      ObjectType.planetaryNebula => planetaryNebula,
      ObjectType.star => star,
      ObjectType.doubleStar => doubleStar,
      ObjectType.asterism => asterism,
      ObjectType.unknown => palette.textMuted,
    };
  }
}

/// Theme-derived colors for annotation pipeline status indicators.
///
/// All methods take [SkotiqColors] and derive from semantic status tokens.
abstract final class AnnotationStatusColors {
  AnnotationStatusColors._();

  static Color background(AnnotationStatus status, [SkotiqColors? colors]) {
    final palette = colors ?? SkotiqColors.dark;
    final semantic = _semantic(status, palette);
    if (semantic == null) return Colors.transparent;
    return Color.lerp(
      semantic,
      palette.background,
      0.88,
    )!.withValues(alpha: 0.9);
  }

  static Color border(AnnotationStatus status, [SkotiqColors? colors]) {
    final palette = colors ?? SkotiqColors.dark;
    final semantic = _semantic(status, palette);
    if (semantic == null) return Colors.transparent;
    return semantic.withValues(alpha: 0.5);
  }

  static Color text(AnnotationStatus status, [SkotiqColors? colors]) {
    final palette = colors ?? SkotiqColors.dark;
    final semantic = _semantic(status, palette);
    if (semantic == null) return Colors.white70;
    return Color.lerp(semantic, palette.textPrimary, 0.35)!;
  }

  static Color? _semantic(AnnotationStatus status, SkotiqColors colors) {
    return switch (status) {
      AnnotationStatus.checkingCatalogs ||
      AnnotationStatus.plateSolving ||
      AnnotationStatus.searchingCatalogs => colors.info,
      AnnotationStatus.complete => colors.success,
      AnnotationStatus.error ||
      AnnotationStatus.plateSolveFailed => colors.error,
      AnnotationStatus.catalogsNotInstalled => colors.warning,
      AnnotationStatus.idle => null,
    };
  }
}
