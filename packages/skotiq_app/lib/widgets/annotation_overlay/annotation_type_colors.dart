import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart' show ObjectType;
import 'package:skotiq_ui/skotiq_ui.dart' show SkotiqColors;

/// Hues for catalog object types in annotation UI.
abstract final class AnnotationTypeColors {
  AnnotationTypeColors._();

  static const Color galaxy = Color(0xFFBD8EC4);
  static const Color nebula = Color(0xFF6B95B8);
  static const Color starCluster = Color(0xFFC4A055);
  static const Color planetaryNebula = Color(0xFF4A9A72);
  static const Color star = Color(0xFFE8E4DC);
  static const Color doubleStar = Color(0xFFCF8FAD);
  static const Color asterism = Color(0xFF8A82B0);

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
