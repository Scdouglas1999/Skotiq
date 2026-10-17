import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';

/// Shared visual metrics and color resolution for [SkotiqSwitch].
///
/// [SkotiqSwitch] is the canonical toggle control. [switchThemeData] is the
/// only place [SwitchThemeData] is defined — Material [Switch] widgets inherit
/// matching colors via theme as a fallback only.
abstract final class SkotiqSwitchStyle {
  SkotiqSwitchStyle._();

  static const double trackWidth = 44;
  static const double trackHeight = 24;
  static const double trackPadding = 2;
  static const double thumbSize = 20;

  static const double compactTrackWidth = 36;
  static const double compactTrackHeight = 20;
  static const double compactThumbSize = 16;

  static Color darken(Color color, double amount) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness - amount).clamp(0.0, 1.0))
        .toColor();
  }

  static Color trackColor(
    SkotiqColors colors, {
    required bool selected,
    bool hovered = false,
  }) {
    if (selected) {
      return hovered ? colors.primary : darken(colors.primary, 0.04);
    }
    return colors.surface;
  }

  static Color trackBorderColor(SkotiqColors colors, {required bool selected}) {
    return selected ? darken(colors.primary, 0.12) : colors.border;
  }

  static Color thumbColor(
    ThemeData theme,
    SkotiqColors colors, {
    required bool selected,
    required bool enabled,
  }) {
    if (selected) {
      return theme.colorScheme.onPrimary;
    }
    return enabled ? colors.textSecondary : colors.textMuted;
  }

  /// Theme fallback for legacy Material [Switch] widgets.
  static SwitchThemeData switchThemeData(SkotiqColors colors, Color onPrimary) {
    return SwitchThemeData(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return colors.textMuted;
        }
        if (states.contains(WidgetState.selected)) {
          return onPrimary;
        }
        return colors.textSecondary;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return colors.primary;
        }
        return colors.surface;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return trackBorderColor(colors, selected: true);
        }
        return colors.border;
      }),
    );
  }
}
