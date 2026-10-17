import 'package:flutter/material.dart';

/// Stacks two children in portrait and places them side-by-side in landscape
/// (when there is enough width).
///
/// A cheap way to add landscape support to a screen: the [start] child (often
/// the image/canvas or primary status) and the [end] child (controls/detail)
/// flow vertically on a narrow / portrait viewport and split horizontally once
/// the viewport is wide enough.
///
/// Layout is driven by the region's own constraints (via [LayoutBuilder]), so
/// it is correct inside embedded panels — not just at the top level. It splits
/// when `width >= minSplitWidth` AND `width > height` (landscape) unless
/// [splitOnlyInLandscape] is false, in which case width alone decides.
///
/// ```dart
/// TwoPane(
///   start: ImageViewer(),         // left in landscape, top in portrait
///   end: ControlsPanel(),         // right in landscape, bottom in portrait
///   startFlex: 3, endFlex: 2,
/// )
/// ```
class TwoPane extends StatelessWidget {
  /// Left (landscape) / top (portrait) child.
  final Widget start;

  /// Right (landscape) / bottom (portrait) child.
  final Widget end;

  /// Flex weight of [start] in the landscape split.
  final int startFlex;

  /// Flex weight of [end] in the landscape split.
  final int endFlex;

  /// Minimum width before a side-by-side split is allowed. Defaults to 560.
  final double minSplitWidth;

  /// Gap between the two panes (both orientations).
  final double spacing;

  /// When true (default) a split additionally requires landscape orientation
  /// (`width > height`). When false, width alone decides — useful for content
  /// that benefits from two columns even on a wide portrait tablet.
  final bool splitOnlyInLandscape;

  /// In portrait/stacked mode, whether [start] gets a fixed height fraction of
  /// the viewport (so the image keeps dominant space and the rest scrolls).
  /// When null, both panes size to content inside a scroll view.
  final double? portraitStartHeightFraction;

  const TwoPane({
    super.key,
    required this.start,
    required this.end,
    this.startFlex = 1,
    this.endFlex = 1,
    this.minSplitWidth = 560,
    this.spacing = 0,
    this.splitOnlyInLandscape = true,
    this.portraitStartHeightFraction,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final wideEnough = w >= minSplitWidth;
        final landscape = w > h;
        final split = wideEnough && (!splitOnlyInLandscape || landscape);

        if (split) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: startFlex, child: start),
              if (spacing > 0) SizedBox(width: spacing),
              Expanded(flex: endFlex, child: end),
            ],
          );
        }

        // Stacked (portrait / narrow).
        if (portraitStartHeightFraction != null && h.isFinite) {
          final startHeight = (h * portraitStartHeightFraction!).clamp(0.0, h);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: startHeight, child: start),
              if (spacing > 0) SizedBox(height: spacing),
              Expanded(child: end),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            start,
            if (spacing > 0) SizedBox(height: spacing),
            end,
          ],
        );
      },
    );
  }
}
