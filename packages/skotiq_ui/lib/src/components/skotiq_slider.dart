import '../theme/skotiq_slider_style.dart';
import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';

/// Canonical Skotiq slider — Material [Slider] themed with the design
/// system track and thumb colors.
///
/// Pass `null` for [onChanged] to disable the control. The disabled state greys
/// the track and thumb via [SliderThemeData] (not an [Opacity] wrapper).
///
/// For a bare slider with no caption, omit [label].
class SkotiqSlider extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final int? divisions;

  /// Value-change callback. Pass `null` to render a disabled slider.
  final ValueChanged<double>? onChanged;

  /// Called once when a drag or tap ends, with the final value: where a
  /// value is saved rather than previewed.
  final ValueChanged<double>? onChangeEnd;

  /// Optional caption rendered above the track.
  final String? label;

  const SkotiqSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeEnd,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final slider = SliderTheme(
      data: SkotiqSliderStyle.theme(colors),
      child: Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
        onChangeEnd: onChanged == null ? null : onChangeEnd,
      ),
    );

    if (label == null) return slider;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label!,
          style: SkotiqTypography.labelSm.copyWith(
            color: onChanged == null ? colors.textMuted : colors.textSecondary,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        slider,
      ],
    );
  }
}
