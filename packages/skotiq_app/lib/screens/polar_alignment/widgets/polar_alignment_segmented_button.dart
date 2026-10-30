import 'package:flutter/material.dart';

/// Compact polar-alignment selector using the shared Material control theme.
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
    return SegmentedButton<T>(
      key: buttonKey,
      segments: segments,
      selected: selected,
      showSelectedIcon: showSelectedIcon,
      emptySelectionAllowed: emptySelectionAllowed,
      onSelectionChanged: onSelectionChanged,
      style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
