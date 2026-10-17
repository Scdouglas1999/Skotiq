import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Viewport-aware constraints for large fixed-layout dialogs.
///
/// Design dimensions are treated as maximums on large screens and shrink on
/// smaller viewports so dialogs never overflow the window.
abstract final class AdaptiveDialogConstraints {
  AdaptiveDialogConstraints._();

  static const double defaultWidthFraction = 0.92;
  static const double defaultHeightFraction = 0.85;

  /// Returns max constraints: width capped by [designMaxWidth] and
  /// [widthFraction] of the viewport; height capped by optional
  /// [designMaxHeight] and [heightFraction] of the viewport.
  static BoxConstraints hybrid(
    BuildContext context, {
    required double designMaxWidth,
    double? designMaxHeight,
    double widthFraction = defaultWidthFraction,
    double heightFraction = defaultHeightFraction,
  }) {
    final size = MediaQuery.sizeOf(context);
    return BoxConstraints(
      maxWidth: math.min(designMaxWidth, size.width * widthFraction),
      maxHeight: designMaxHeight != null
          ? math.min(designMaxHeight, size.height * heightFraction)
          : size.height * heightFraction,
    );
  }

  /// Effective width and height for dialogs that need explicit dimensions
  /// (for example [SkotiqDialog] with a fixed body layout).
  static ({double width, double? height}) dialogSize(
    BuildContext context, {
    required double designWidth,
    double? designHeight,
    double widthFraction = defaultWidthFraction,
    double heightFraction = defaultHeightFraction,
  }) {
    final size = MediaQuery.sizeOf(context);
    return (
      width: math.min(designWidth, size.width * widthFraction),
      height: designHeight != null
          ? math.min(designHeight, size.height * heightFraction)
          : null,
    );
  }

  /// Clamps a sidebar or panel to a design width while respecting viewport
  /// limits.
  ///
  /// The viewport cap wins over [minWidth] when the two disagree. A caller that
  /// takes the defaults on a phone asks for a 200 px floor against a cap of
  /// 0.4 x 411 = 164 px; ordering the bounds before clamping keeps that from
  /// throwing `Invalid argument(s)` mid-layout and blanking the screen behind
  /// a release-mode [ErrorWidget]. A panel narrower than its design floor is a
  /// cramped panel; a thrown build is no panel at all.
  static double clampPanelWidth(
    BuildContext context, {
    required double designWidth,
    double minWidth = 200,
    double? maxWidth,
    double maxWidthFractionOfViewport = 0.4,
  }) {
    final viewportCap =
        MediaQuery.sizeOf(context).width * maxWidthFractionOfViewport;
    final cap = maxWidth ?? viewportCap;
    return designWidth.clamp(math.min(minWidth, cap), cap);
  }
}
