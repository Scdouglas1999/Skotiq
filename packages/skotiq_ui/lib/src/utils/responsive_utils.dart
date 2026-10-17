import 'dart:math' as math;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/widgets.dart';
import '../theme/skotiq_tokens.dart';
import '../tokens/breakpoint_tokens.dart';
import 'adaptive_dialog_constraints.dart';

/// Responsive breakpoint utilities for adaptive UI layouts.
///
/// Usage:
/// ```dart
/// if (Responsive.isMobile(context)) {
///   // Mobile layout
/// }
///
/// final padding = Responsive.value(
///   context,
///   mobile: 8.0,
///   tablet: 16.0,
///   desktop: 24.0,
/// );
/// ```
abstract final class Responsive {
  Responsive._();

  /// Width below which the layout is a **phone** (`< 600`,
  /// [BreakpointTokens.breakpointPhone]).
  static const double phoneMaxWidth = BreakpointTokens.breakpointPhone;

  /// Width below which the phone is **compact** (`< 480`,
  /// [SkotiqTokens.breakpointMobile]) and dense rows need extra tightening
  /// — e.g. a stat strip should 2-column or stack rather than stay in one row.
  static const double compactPhoneMaxWidth = SkotiqTokens.breakpointMobile;

  /// Returns true on a true **phone**.
  ///
  /// This is the first-class phone tier and it is **orientation-independent on
  /// mobile**: a phone is a phone whether held in portrait or landscape.
  ///
  /// - On a mobile OS (Android/iOS) phone-ness is a *device-class* fact, keyed
  ///   off the **shortest side** (`shortestSide < 600`). A phone's short edge is
  ///   under 600 logical px in both orientations, so this correctly stays true
  ///   when the device rotates — whereas a width-based check would flip to
  ///   `false` in landscape (long edge ≥ 600) and wrongly send the phone down
  ///   the tablet/desktop layout path. Tablets (`shortestSide >= 600`) are not
  ///   phones.
  /// - On desktop the phone tier is a *window-size* fact, keyed off the live
  ///   **width**, so narrowing a desktop window still reflows to the single
  ///   column exactly as before.
  ///
  /// Prefer this — or a [LayoutBuilder] reading the region's own width — when
  /// building phone layouts. [isMobile] (`< 768`) lumps small tablets in with
  /// phones. Pair with [isPhoneLandscape] / [isPhonePortrait] to choose the
  /// per-orientation reflow.
  static bool isPhone(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (_isMobilePlatform) {
      // Device class: the short edge is orientation-stable.
      return math.min(size.width, size.height) < phoneMaxWidth;
    }
    // Desktop: the available window width drives the reflow.
    return size.width < phoneMaxWidth;
  }

  /// True when running on a phone/tablet operating system (Android or iOS),
  /// where "is this a phone?" is a device-class question answered by the
  /// shortest side rather than the current window width.
  static bool get _isMobilePlatform =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// The width that picks a **device-class tier** ([isMobile] / [isTablet] /
  /// [isDesktop] / [isDesktopLarge] / [isUltraWide]).
  ///
  /// - On a mobile OS this is the **shortest side**, so the tier is
  ///   orientation-stable: a landscape phone (long edge ≥ 768, e.g. the Galaxy
  ///   Z Fold 6 cover screen at 905×369) is still classified by its short edge
  ///   and stays in the mobile tier rather than flipping to the desktop layout.
  ///   This matches the device-class logic in [isPhone].
  /// - On desktop this is the live window **width**, so narrowing or splitting a
  ///   desktop window still reflows tiers exactly as before.
  ///
  /// NOTE: this is for *tier classification* only. Helpers that physically size
  /// to the viewport ([panelWidth], [gridColumns], [panelDimensions],
  /// [scaleFactor], dialog/preview constraints) intentionally keep using the
  /// real width/height.
  static double _classWidth(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (_isMobilePlatform) {
      return math.min(size.width, size.height);
    }
    return size.width;
  }

  /// Returns true on a **compact phone** (`width < 480`).
  ///
  /// Use to tighten further (e.g. drop a stat strip to a single column, hide a
  /// label, reduce a 2-up grid to 1-up) — but never to break the layout.
  static bool isCompactPhone(BuildContext context) =>
      MediaQuery.sizeOf(context).width < compactPhoneMaxWidth;

  /// Returns true if the device-class width is less than the tablet breakpoint
  /// (768px).
  ///
  /// NOTE: This is the legacy "mobile" bucket (`< 768`) and includes small
  /// tablets. For phone-specific reflow use [isPhone] (`< 600`).
  ///
  /// Uses [_classWidth] so a landscape phone / foldable cover screen (long edge
  /// ≥ 768) is still classified by its short edge and correctly resolves to the
  /// mobile layout instead of the desktop split.
  static bool isMobile(BuildContext context) =>
      _classWidth(context) < SkotiqTokens.breakpointTablet;

  /// Returns true if the device-class width is between tablet (768px) and
  /// desktop (1024px) breakpoints.
  static bool isTablet(BuildContext context) {
    final width = _classWidth(context);
    return width >= SkotiqTokens.breakpointTablet &&
        width < SkotiqTokens.breakpointDesktop;
  }

  /// Returns true if the device-class width is at least the desktop breakpoint
  /// (1024px).
  static bool isDesktop(BuildContext context) =>
      _classWidth(context) >= SkotiqTokens.breakpointDesktop;

  /// Returns true if the device-class width is at least the large desktop
  /// breakpoint (1440px).
  static bool isDesktopLarge(BuildContext context) =>
      _classWidth(context) >= SkotiqTokens.breakpointDesktopLg;

  /// Returns true if the device-class width is at least the ultra-wide
  /// breakpoint (1920px).
  static bool isUltraWide(BuildContext context) =>
      _classWidth(context) >= SkotiqTokens.breakpointUltraWide;

  /// Returns a value based on screen size breakpoints.
  ///
  /// If [tablet] is not specified, falls back to [desktop].
  static T value<T>(
    BuildContext context, {
    required T mobile,
    T? tablet,
    required T desktop,
  }) {
    if (isMobile(context)) return mobile;
    if (isTablet(context)) return tablet ?? desktop;
    return desktop;
  }

  /// Returns a value with additional breakpoints for large screens.
  static T valueExtended<T>(
    BuildContext context, {
    required T mobile,
    T? tablet,
    required T desktop,
    T? desktopLarge,
    T? ultraWide,
  }) {
    if (isMobile(context)) return mobile;
    if (isTablet(context)) return tablet ?? desktop;
    if (isDesktopLarge(context)) {
      if (isUltraWide(context)) return ultraWide ?? desktopLarge ?? desktop;
      return desktopLarge ?? desktop;
    }
    return desktop;
  }

  /// Dialog constraints that fit within the viewport: the preferred size capped
  /// at [maxWidthPercent] / [maxHeightPercent] of the screen, floored at
  /// [minWidth] / [minHeight].
  static BoxConstraints dialogConstraints(
    BuildContext context, {
    double maxWidthPercent = AdaptiveDialogConstraints.defaultWidthFraction,
    double maxHeightPercent = AdaptiveDialogConstraints.defaultHeightFraction,
    double? preferredWidth,
    double? preferredHeight,
    double? minWidth,
    double? minHeight,
  }) {
    final size = MediaQuery.sizeOf(context);
    final maxW = size.width * maxWidthPercent;
    final maxH = size.height * maxHeightPercent;
    final resolvedMaxWidth = preferredWidth != null
        ? math.min(preferredWidth, maxW)
        : maxW;
    final resolvedMaxHeight = preferredHeight != null
        ? math.min(preferredHeight, maxH)
        : maxH;

    return BoxConstraints(
      // A desktop-oriented minimum must never make the constraints invalid on
      // a viewport whose responsive maximum is smaller than that minimum.
      minWidth: math.min(minWidth ?? 0.0, resolvedMaxWidth),
      minHeight: math.min(minHeight ?? 0.0, resolvedMaxHeight),
      maxWidth: resolvedMaxWidth,
      maxHeight: resolvedMaxHeight,
    );
  }

  /// Returns adaptive padding based on screen size.
  ///
  /// Mobile: compact padding
  /// Tablet: medium padding
  /// Desktop: standard padding
  static EdgeInsets adaptivePadding(BuildContext context) {
    return value(
      context,
      mobile: SkotiqTokens.screenPaddingCompact,
      tablet: SkotiqTokens.screenPadding,
      desktop: SkotiqTokens.screenPadding,
    );
  }

  /// Calculates responsive panel width based on screen size.
  ///
  /// [initialPercent] - Initial width as percentage of screen width
  /// [minPercent] - Minimum width as percentage of screen width
  /// [maxPercent] - Maximum width as percentage of screen width
  /// [absoluteMin] - Absolute minimum width in logical pixels
  /// [absoluteMax] - Absolute maximum width in logical pixels
  static ({double initial, double min, double max}) panelDimensions(
    BuildContext context, {
    double initialPercent = 0.25,
    double minPercent = 0.15,
    double maxPercent = 0.4,
    double absoluteMin = 200.0,
    double absoluteMax = 500.0,
  }) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    return (
      initial: (screenWidth * initialPercent).clamp(absoluteMin, absoluteMax),
      min: (screenWidth * minPercent).clamp(absoluteMin * 0.8, absoluteMin),
      max: (screenWidth * maxPercent).clamp(absoluteMax * 0.7, absoluteMax),
    );
  }

  /// Returns the current breakpoint name for debugging.
  static String breakpointName(BuildContext context) {
    if (isMobile(context)) return 'mobile';
    if (isTablet(context)) return 'tablet';
    if (isDesktopLarge(context)) {
      if (isUltraWide(context)) return 'ultraWide';
      return 'desktopLarge';
    }
    return 'desktop';
  }

  // Universal scaling

  /// Calculate a universal scale factor based on screen dimensions.
  ///
  /// This provides a 0.85-1.25 range scale factor based on the screen's
  /// minimum dimension relative to a reference size of 900px.
  ///
  /// - Smaller screens (< 900px min dimension): scale 0.85-1.0
  /// - Standard screens (900-1200px): scale 1.0
  /// - Large screens (> 1200px): scale 1.0-1.25
  static double scaleFactor(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final minDimension = math.min(size.width, size.height);

    // Reference: 900px min dimension = 1.0 scale
    if (minDimension < 900) {
      // Scale down linearly from 1.0 to 0.85 as screen shrinks
      return 0.85 + (minDimension / 900) * 0.15;
    } else if (minDimension > 1200) {
      // Scale up linearly from 1.0 to 1.25 as screen grows
      final excess = (minDimension - 1200).clamp(0.0, 600.0);
      return 1.0 + (excess / 600) * 0.25;
    }
    return 1.0;
  }

  /// Returns a spacing value scaled to screen size.
  ///
  /// Use this for padding, margins, and gaps that should adapt to screen size.
  /// ```dart
  /// padding: EdgeInsets.all(Responsive.spacing(context, 16)),
  /// ```
  static double spacing(BuildContext context, double baseValue) {
    return baseValue * scaleFactor(context);
  }

  /// Returns a font size scaled to screen size.
  ///
  /// ```dart
  /// Text('Hello', style: TextStyle(fontSize: Responsive.fontSize(context, 14))),
  /// ```
  static double fontSize(BuildContext context, double baseSize) {
    // Font scaling is more conservative than spacing
    final scale = scaleFactor(context);
    // Keep font scaling in 0.9-1.15 range for readability
    final fontScale = 0.9 + (scale - 0.85) * (0.25 / 0.4);
    return baseSize * fontScale.clamp(0.9, 1.15);
  }

  /// Returns icon size scaled to screen size.
  ///
  /// ```dart
  /// Icon(Icons.home, size: Responsive.iconSize(context, 24)),
  /// ```
  static double iconSize(BuildContext context, double baseSize) {
    return baseSize * scaleFactor(context);
  }

  /// Returns scaled EdgeInsets for consistent responsive padding.
  ///
  /// ```dart
  /// Padding(padding: Responsive.edgeInsets(context, all: 16)),
  /// ```
  static EdgeInsets edgeInsets(
    BuildContext context, {
    double? all,
    double? horizontal,
    double? vertical,
    double? left,
    double? top,
    double? right,
    double? bottom,
  }) {
    final scale = scaleFactor(context);

    if (all != null) {
      return EdgeInsets.all(all * scale);
    }

    return EdgeInsets.only(
      left: (left ?? horizontal ?? 0) * scale,
      top: (top ?? vertical ?? 0) * scale,
      right: (right ?? horizontal ?? 0) * scale,
      bottom: (bottom ?? vertical ?? 0) * scale,
    );
  }

  // Aspect ratio detection

  /// Returns true if the screen is in portrait orientation.
  static bool isPortrait(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.height > size.width;
  }

  /// Returns true if the screen is in landscape orientation.
  static bool isLandscape(BuildContext context) => !isPortrait(context);

  /// True on a **phone held in landscape** (see [isPhone] — device-class on
  /// mobile, so this fires correctly when a phone is rotated).
  ///
  /// In this configuration there is usually enough width to place the
  /// image/canvas beside its controls (a side-by-side split) even though the
  /// device is a phone. Pair with [TwoPane] / [AdaptivePanelLayout]. Do NOT
  /// fall through to the tablet/desktop layout here — a landscape phone is
  /// still a phone and must reflow, not show desktop chrome.
  static bool isPhoneLandscape(BuildContext context) =>
      isPhone(context) && isLandscape(context);

  /// True on a **phone held in portrait** — the canonical
  /// "single vertically-scrolling column" case.
  static bool isPhonePortrait(BuildContext context) =>
      isPhone(context) && isPortrait(context);

  /// Returns true if the screen is ultrawide (aspect ratio > 2.0).
  ///
  /// Ultrawide screens (21:9, 32:9) need special layout considerations.
  static bool isUltraWideAspect(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width / size.height > 2.0;
  }

  /// Returns true if the screen is approximately square (aspect ratio 0.8-1.25).
  static bool isSquareAspect(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final ratio = size.width / size.height;
    return ratio >= 0.8 && ratio <= 1.25;
  }

  /// Returns the aspect ratio of the screen (width / height).
  static double aspectRatio(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width / size.height;
  }

  /// Picks a value by aspect-ratio band: portrait below 1.0, square from 0.8 to
  /// 1.25, ultrawide above 2.0, landscape otherwise. [square] and [ultrawide]
  /// fall back to [landscape].
  static T aspectValue<T>(
    BuildContext context, {
    required T portrait,
    T? square,
    required T landscape,
    T? ultrawide,
  }) {
    if (isPortrait(context)) return portrait;
    if (isSquareAspect(context)) return square ?? landscape;
    if (isUltraWideAspect(context)) return ultrawide ?? landscape;
    return landscape;
  }

  // Layout helpers

  /// Returns the number of columns for a grid based on screen width.
  ///
  /// [minItemWidth] - Minimum width for each item in logical pixels.
  /// [maxColumns] - Maximum number of columns allowed.
  static int gridColumns(
    BuildContext context, {
    double minItemWidth = 300,
    int maxColumns = 6,
  }) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = (width / minItemWidth).floor();
    return columns.clamp(1, maxColumns);
  }

  /// Maximum width for panels overlaid on image/canvas previews.
  ///
  /// Shrinks on narrow viewports using [widthFraction] while never exceeding
  /// [maxAbsolute] (default 320 logical pixels).
  static double previewOverlayMaxWidth(
    double viewportWidth, {
    double maxAbsolute = 320,
    double widthFraction = 0.4,
  }) {
    if (viewportWidth <= 0) return maxAbsolute;
    return math.min(maxAbsolute, viewportWidth * widthFraction);
  }

  /// Returns the optimal panel width for slide-out panels based on screen size.
  static double panelWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (isMobile(context)) return width; // Full width on mobile
    if (isTablet(context)) return math.min(400, width * 0.6);
    if (isUltraWideAspect(context)) return math.min(500, width * 0.25);
    return math.min(450, width * 0.35);
  }
}
