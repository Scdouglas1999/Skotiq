import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Sizes a chart plot area with a floor of [minHeight] and optional growth on
/// large viewports. Use [AdaptiveChartContainer.fixed] for empty and loading
/// placeholders so their height stays stable.
///
/// It also PAINTS the plot area, because 06 puts every Analytics chart inside
/// a `well`. Doing it here rather than at each of the twenty call sites is
/// what makes the rule hold: a chart added tomorrow gets the well without
/// anyone remembering to add it. Pass `well: false` for a plot that is already
/// inside one — `panel -> well` is as deep as the ladder goes.
class AdaptiveChartContainer extends StatelessWidget {
  final Widget child;

  /// Minimum plot height in logical pixels.
  final double minHeight;

  /// Baseline height at standard desktop widths; defaults to [minHeight].
  final double? preferredHeight;

  /// Upper bound when [adaptToViewport] is true.
  final double? maxHeight;

  /// When false, height is exactly [preferredHeight] (or [minHeight]).
  final bool adaptToViewport;

  /// Whether to paint the `well` inset around the plot. False when the caller
  /// already sits in one.
  final bool well;

  static const double defaultMinHeight = 150;

  const AdaptiveChartContainer({
    super.key,
    required this.child,
    this.minHeight = defaultMinHeight,
    this.preferredHeight,
    this.maxHeight,
    this.adaptToViewport = true,
    this.well = true,
  });

  const AdaptiveChartContainer.fixed({
    super.key,
    required this.child,
    required double height,
    this.well = true,
  })  : minHeight = height,
        preferredHeight = height,
        maxHeight = height,
        adaptToViewport = false;

  double _resolveHeight(BuildContext context, BoxConstraints constraints) {
    final base = preferredHeight ?? minHeight;
    if (!adaptToViewport) {
      return base;
    }

    final viewport = MediaQuery.sizeOf(context);
    final minDim = math.min(viewport.width, viewport.height);

    // Modest growth on large screens (up to ~25% above baseline).
    final growthFactor = Responsive.isDesktop(context)
        ? 1.0 + (minDim - 900).clamp(0.0, 500.0) / 500.0 * 0.25
        : 1.0;
    var height = base * growthFactor;

    if (constraints.hasBoundedHeight && constraints.maxHeight.isFinite) {
      final parentBudget = constraints.maxHeight * 0.4;
      if (parentBudget > base) {
        height = math.max(height, math.min(parentBudget, base * 1.35));
      }
    }

    final cap = maxHeight ?? base * 1.35;
    return height.clamp(minHeight, cap);
  }

  /// Padding between the well's edge and the plot.
  static const EdgeInsets wellPadding = EdgeInsets.all(SkotiqTokens.spaceSm);

  Widget _plot(BuildContext context, double height) {
    final box = SizedBox(
      height: height,
      width: double.infinity,
      child: child,
    );
    if (!well) return box;
    return Container(
      padding: wellPadding,
      decoration: SkotiqDecorations.well(SkotiqColors.of(context)),
      child: box,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!adaptToViewport) {
      return _plot(context, preferredHeight ?? minHeight);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return _plot(context, _resolveHeight(context, constraints));
      },
    );
  }
}
