import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../utils/adaptive_dialog_constraints.dart';

/// A panel width that tracks the available space: [fraction] of [available],
/// clamped between [min] and [max].
///
/// Breakpoints answer "which layout?"; this answers "how wide in this layout?".
/// Not [AdaptiveDialogConstraints.clampPanelWidth], which reads the viewport off
/// a [BuildContext] and caps a *design* width.
double panelWidthFromFraction(
  double available, {
  required double fraction,
  required double min,
  required double max,
}) {
  assert(available >= 0, 'available width must be non-negative');
  assert(fraction >= 0 && fraction <= 1, 'fraction must be between 0 and 1');
  assert(min <= max, 'min must be <= max');
  return (available * fraction).clamp(min, max);
}

@Deprecated(
  'Renamed to panelWidthFromFraction — it was indistinguishable at the call '
  'site from AdaptiveDialogConstraints.clampPanelWidth, which does something '
  'else. Will be removed one release after 6.1.0.',
)
double clampPanelWidth(
  double available, {
  required double fraction,
  required double min,
  required double max,
}) => panelWidthFromFraction(available, fraction: fraction, min: min, max: max);

/// Caps a dialog's design width to
/// [AdaptiveDialogConstraints.defaultWidthFraction] of the viewport width.
///
/// Prefer this over a raw `designMax` when showing modals on narrow windows or
/// mobile web. Pair with [Responsive.dialogConstraints] when you also need
/// height limits and minimum sizes.
double dialogMaxWidth(BuildContext context, double designMax) {
  final viewportWidth = MediaQuery.sizeOf(context).width;
  return math.min(
    designMax,
    viewportWidth * AdaptiveDialogConstraints.defaultWidthFraction,
  );
}
