import 'package:flutter/material.dart';

import '../theme/skotiq_tokens.dart';

/// Platform-aware touch-target sizing.
///
/// Skotiq ships one codebase to phones and to desktops, and the two have
/// opposite requirements: Android's accessibility rule wants every tappable
/// control to be at least [SkotiqTokens.minTouchTarget] on both edges,
/// while the desktop layouts are deliberately dense — a sequencer tree row
/// carries three action chips, and growing them to 48dp re-flows the whole
/// panel for a pointer that has none of the imprecision the rule exists to
/// absorb.
///
/// Every control that needs both behaviours was writing its own
/// `switch (Theme.of(context).platform)`, four at last count, each subtly
/// different. This is that switch, once.
///
/// A note on which knob to reach for: Material's [IconButton] sizes its hit
/// area from `kMinInteractiveDimension` *plus* [VisualDensity.baseSizeAdjustment
/// ], so an `IconButton` carrying `VisualDensity.compact` has a 40dp hit area
/// no matter what `constraints` it is given — `constraints` bound the visual
/// button, not the tap target. Use [visualDensity] there; [constraints] alone
/// will look like it worked and measure 40x40.
abstract final class SkotiqTouchTarget {
  /// Whether [context]'s platform is driven by fingers rather than a pointer.
  static bool isTouch(BuildContext context) {
    switch (Theme.of(context).platform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return true;
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return false;
    }
  }

  /// The minimum interactive edge for [context]'s platform, in logical pixels.
  ///
  /// [SkotiqTokens.minTouchTarget] on touch platforms; [desktopExtent] on
  /// desktop, which defaults to 0 (i.e. "impose no floor").
  static double minExtent(BuildContext context, {double desktopExtent = 0.0}) =>
      isTouch(context) ? SkotiqTokens.minTouchTarget : desktopExtent;

  /// [minExtent] as square minimum [BoxConstraints].
  static BoxConstraints constraints(
    BuildContext context, {
    double desktopExtent = 0.0,
  }) {
    final extent = minExtent(context, desktopExtent: desktopExtent);
    return BoxConstraints(minWidth: extent, minHeight: extent);
  }

  /// Symmetric padding that lifts a [childExtent]-square control up to
  /// [minExtent]; zero when the child already clears it.
  ///
  /// Pad the CHILD, not a wrapping [GestureDetector] — a bare gesture detector
  /// hit-tests its child's box, so padding the detector grows the semantics
  /// rect while leaving the real hit area unchanged.
  static double paddingToReach(
    BuildContext context,
    double childExtent, {
    double desktopExtent = 0.0,
  }) {
    final deficit =
        minExtent(context, desktopExtent: desktopExtent) - childExtent;
    return deficit <= 0 ? 0.0 : deficit / 2;
  }

  /// Wraps [child] so its INTERACTIVE box clears [minExtent] on a touch
  /// platform, while what it PAINTS stays the size the sheet specifies.
  ///
  /// This is the shape `SkotiqIconButton` had to grow after the Android
  /// tap-target audit measured a 32px chrome button, and the shape every other
  /// small control in the kit needed for the same reason: a 22px chip, a 28px
  /// filter chip, a 30px segment and a 32px field are all POINTER sizes. The
  /// box grows around them; the fill, the hover and the ring do not.
  ///
  /// Returns [child] unchanged on desktop, so a dense panel keeps its density.
  static Widget hitBox(
    BuildContext context,
    Widget child, {
    double desktopExtent = 0.0,
  }) {
    final extent = minExtent(context, desktopExtent: desktopExtent);
    if (extent <= 0) return child;
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: extent, minHeight: extent),
      // The factors are what keep this a MINIMUM: without them the box
      // expands to whatever the parent offers, which in a Row is infinite.
      child: Center(widthFactor: 1, heightFactor: 1, child: child),
    );
  }

  /// The [VisualDensity] a dense control should carry.
  ///
  /// [VisualDensity.standard] on touch — anything tighter shrinks Material's
  /// built-in 48dp hit padding by four times the density value — and [desktop]
  /// (compact by default) elsewhere.
  static VisualDensity visualDensity(
    BuildContext context, {
    VisualDensity desktop = VisualDensity.compact,
  }) => isTouch(context) ? VisualDensity.standard : desktop;
}
