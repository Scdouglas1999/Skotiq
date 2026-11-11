import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart' show AnnotationStatus;
import 'package:skotiq_ui/skotiq_ui.dart' show SkotiqColors;

/// Colors of the annotation pipeline status indicator, derived from the
/// theme's semantic status tokens.
abstract final class AnnotationStatusColors {
  AnnotationStatusColors._();

  static Color background(AnnotationStatus status, SkotiqColors colors) {
    final semantic = _semantic(status, colors);
    if (semantic == null) return Colors.transparent;
    return Color.lerp(
      semantic,
      colors.background,
      0.88,
    )!
        .withValues(alpha: 0.9);
  }

  static Color border(AnnotationStatus status, SkotiqColors colors) {
    final semantic = _semantic(status, colors);
    if (semantic == null) return Colors.transparent;
    return semantic.withValues(alpha: 0.5);
  }

  static Color text(AnnotationStatus status, SkotiqColors colors) {
    final semantic = _semantic(status, colors);
    if (semantic == null) return Colors.white70;
    return Color.lerp(semantic, colors.textPrimary, 0.35)!;
  }

  static Color? _semantic(AnnotationStatus status, SkotiqColors colors) {
    return switch (status) {
      AnnotationStatus.checkingCatalogs ||
      AnnotationStatus.plateSolving ||
      AnnotationStatus.searchingCatalogs =>
        colors.info,
      AnnotationStatus.complete => colors.success,
      AnnotationStatus.error ||
      AnnotationStatus.plateSolveFailed =>
        colors.error,
      AnnotationStatus.catalogsNotInstalled => colors.warning,
      AnnotationStatus.idle => null,
    };
  }
}
