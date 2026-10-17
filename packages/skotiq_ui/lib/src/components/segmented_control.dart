import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import '../utils/touch_target.dart';

/// A second-level switch INSIDE a panel — Sequencer's Nodes / Snippets /
/// Targets.
///
/// Never in a page header: that is [AdaptiveTabBar]'s job and the app has one
/// tab style. A segmented control has no outer container and no border either;
/// the selected segment is a `surfaceHover` fill and the rest are muted labels,
/// which is as much weight as a switch inside a panel is allowed.
class SegmentedControl extends StatelessWidget {
  const SegmentedControl({
    super.key,
    required this.segments,
    required this.selectedIndex,
    required this.onSelected,
  });

  /// The segment labels, in display order.
  final List<String> segments;

  /// Index of the selected segment.
  final int selectedIndex;

  /// Called with the tapped segment's index.
  final ValueChanged<int> onSelected;

  /// A segment's height in logical pixels.
  static const double segmentHeight = 30;

  /// A segment's horizontal padding.
  static const double segmentPadding = 10;

  /// Gap between segments.
  static const double gap = 2;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < segments.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: gap),
          _Segment(
            label: segments[i],
            selected: i == selectedIndex,
            colors: colors,
            onTap: () => onSelected(i),
          ),
        ],
      ],
    );
  }
}

class _Segment extends StatefulWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final SkotiqColors colors;
  final VoidCallback onTap;

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (!mounted || _hovered == value) return;
    setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final foreground = widget.selected
        ? colors.textPrimary
        : (_hovered ? colors.textSecondary : colors.textMuted);

    return Semantics(
      button: true,
      // Semantics publishes isEnabled only when the field is given; a segment
      // without it announces as dimmed while being perfectly operable.
      enabled: true,
      selected: widget.selected,
      label: widget.label,
      // 30px is a POINTER size; a finger needs 48. The box grows, the
      // painted segment does not.
      child: SkotiqTouchTarget.hitBox(
        context,
        MouseRegion(
          onEnter: (_) => _setHovered(true),
          onExit: (_) => _setHovered(false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.onTap,
            behavior: HitTestBehavior.opaque,
            child: ExcludeSemantics(
              child: AnimatedContainer(
                duration: SkotiqTokens.durationFast,
                curve: SkotiqTokens.curveStandard,
                height: SegmentedControl.segmentHeight,
                padding: const EdgeInsets.symmetric(
                  horizontal: SegmentedControl.segmentPadding,
                ),
                // No `alignment:` — it would make the segment expand to the
                // width of the row instead of to its own label.
                decoration: BoxDecoration(
                  color: widget.selected || _hovered
                      ? colors.surfaceHover
                      : Colors.transparent,
                  borderRadius: SkotiqTokens.borderRadiusSm,
                ),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    widget.label,
                    style: SkotiqTypography.buttonSm.copyWith(
                      color: foreground,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
