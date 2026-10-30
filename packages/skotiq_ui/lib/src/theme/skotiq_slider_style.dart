import 'package:flutter/material.dart';

import 'skotiq_colors.dart';
import 'skotiq_tokens.dart';

abstract final class SkotiqSliderStyle {
  static SliderThemeData theme(SkotiqColors colors, {Color? accent}) {
    final active = accent ?? colors.primary;
    return SliderThemeData(
      activeTrackColor: active,
      inactiveTrackColor: colors.surfaceHover,
      thumbColor: active,
      overlayColor: active.withValues(
        alpha: SkotiqTokens.opacityAccentTintHover,
      ),
      disabledActiveTrackColor: colors.border,
      disabledInactiveTrackColor: colors.well,
      disabledThumbColor: colors.textMuted,
      activeTickMarkColor: colors.inkOn(active),
      inactiveTickMarkColor: colors.textMuted,
      trackHeight: SkotiqTokens.spaceXs,
      thumbShape: const RoundSliderThumbShape(
        enabledThumbRadius: SkotiqTokens.radiusSm,
      ),
      overlayShape: const RoundSliderOverlayShape(
        overlayRadius: SkotiqTokens.radiusXl,
      ),
    );
  }
}
