import 'package:flutter/material.dart';
import 'package:skotiq_core/models.dart' show ObjectType;
import 'package:skotiq_ui/skotiq_ui.dart'
    show SkotiqColors, CatalogAnnotationColors;

/// Hues for catalog object types in annotation UI.
abstract final class AnnotationTypeColors {
  AnnotationTypeColors._();

  static const Color galaxy = CatalogAnnotationColors.galaxy;
  static const Color nebula = CatalogAnnotationColors.nebula;
  static const Color starCluster = CatalogAnnotationColors.starCluster;
  static const Color planetaryNebula = CatalogAnnotationColors.planetaryNebula;
  static const Color star = CatalogAnnotationColors.star;
  static const Color doubleStar = CatalogAnnotationColors.doubleStar;
  static const Color asterism = CatalogAnnotationColors.asterism;

  static Color forType(ObjectType type, SkotiqColors colors) {
    return switch (type) {
      ObjectType.galaxy => galaxy,
      ObjectType.nebula => nebula,
      ObjectType.starCluster => starCluster,
      ObjectType.planetaryNebula => planetaryNebula,
      ObjectType.star => star,
      ObjectType.doubleStar => doubleStar,
      ObjectType.asterism => asterism,
      ObjectType.unknown => colors.textMuted,
    };
  }
}
