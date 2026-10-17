import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// [SegmentedButton] themed with [SkotiqColors] (avoids Material default blue).
class PolarAlignmentSegmentedButton<T extends Object> extends StatelessWidget {
  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final void Function(Set<T>)? onSelectionChanged;
  final bool showSelectedIcon;
  final bool emptySelectionAllowed;
  final Key? buttonKey;

  const PolarAlignmentSegmentedButton({
    super.key,
    this.buttonKey,
    required this.segments,
    required this.selected,
    this.onSelectionChanged,
    this.showSelectedIcon = true,
    this.emptySelectionAllowed = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return SegmentedButton<T>(
      key: buttonKey,
      segments: segments,
      selected: selected,
      showSelectedIcon: showSelectedIcon,
      emptySelectionAllowed: emptySelectionAllowed,
      onSelectionChanged: onSelectionChanged,
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: colors.primary.withValues(alpha: 0.18),
        selectedForegroundColor: colors.primary,
        foregroundColor: colors.textSecondary,
        disabledForegroundColor: colors.textMuted,
        backgroundColor: colors.surfaceAlt,
        disabledBackgroundColor: colors.surfaceAlt,
        side: BorderSide(color: colors.border),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: SkotiqTypography.fontSize12),
      ),
    );
  }
}
