import 'package:flutter/material.dart';

import 'skotiq_colors.dart';
import 'skotiq_tokens.dart';

/// State colors shared by Skotiq controls and their Material counterparts.
abstract final class SkotiqControlStyles {
  static Color iconForeground(
    SkotiqColors colors,
    Set<WidgetState> states, {
    Color? override,
  }) {
    final disabled = states.contains(WidgetState.disabled);
    final color = states.contains(WidgetState.selected)
        ? colors.primary
        : override ??
              (states.contains(WidgetState.hovered) && !disabled
                  ? colors.textPrimary
                  : colors.textSecondary);
    return disabled
        ? color.withValues(alpha: color.a * SkotiqTokens.opacityDisabled)
        : color;
  }

  static Color iconFill(SkotiqColors colors, Set<WidgetState> states) {
    final hover =
        states.contains(WidgetState.hovered) &&
        !states.contains(WidgetState.disabled);
    if (states.contains(WidgetState.selected)) {
      return colors.primary.withValues(
        alpha:
            (hover
                ? SkotiqTokens.opacityAccentTintHover
                : SkotiqTokens.opacityAccentTint) *
            (states.contains(WidgetState.disabled)
                ? SkotiqTokens.opacityDisabled
                : 1),
      );
    }
    return hover ? colors.surfaceHover : Colors.transparent;
  }

  static Color segmentForeground(SkotiqColors colors, Set<WidgetState> states) {
    if (states.contains(WidgetState.disabled)) return colors.textMuted;
    if (states.contains(WidgetState.selected)) return colors.textPrimary;
    return states.contains(WidgetState.hovered)
        ? colors.textSecondary
        : colors.textMuted;
  }

  static Color segmentFill(SkotiqColors colors, Set<WidgetState> states) =>
      states.contains(WidgetState.selected) ||
          (states.contains(WidgetState.hovered) &&
              !states.contains(WidgetState.disabled))
      ? colors.surfaceHover
      : Colors.transparent;
}
