import 'package:flutter/widgets.dart';
import 'responsive_utils.dart';

/// Provides pre-computed scaling configuration to descendant widgets.
///
/// This widget computes scaling values once at the top of the widget tree
/// and makes them available to all descendants via [ScaledConfig.of(context)].
///
/// Usage:
/// ```dart
/// // Wrap your app or screen
/// ScaledConfigProvider(
///   child: MyApp(),
/// )
///
/// // Access values anywhere in the tree
/// final config = ScaledConfig.of(context);
/// final padding = config.spacing(16);
/// ```
class ScaledConfigProvider extends StatelessWidget {
  final Widget child;

  const ScaledConfigProvider({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    // Compute all scaling values based on current screen size
    final scaleFactor = Responsive.scaleFactor(context);
    final size = MediaQuery.sizeOf(context);

    return ScaledConfig._(
      scaleFactor: scaleFactor,
      screenWidth: size.width,
      screenHeight: size.height,
      isMobile: Responsive.isMobile(context),
      isTablet: Responsive.isTablet(context),
      isDesktop: Responsive.isDesktop(context),
      isUltraWide: Responsive.isUltraWide(context),
      isPortrait: Responsive.isPortrait(context),
      isUltraWideAspect: Responsive.isUltraWideAspect(context),
      child: child,
    );
  }
}

/// Pre-computed scaling configuration accessible via [ScaledConfig.of(context)].
///
/// This provides efficient access to scaling values without repeatedly
/// calling MediaQuery or calculating breakpoints.
class ScaledConfig extends InheritedWidget {
  /// The universal UI scale factor (0.85 to 1.25)
  final double scaleFactor;

  /// Screen dimensions
  final double screenWidth;
  final double screenHeight;

  /// Cached breakpoint checks
  final bool isMobile;
  final bool isTablet;
  final bool isDesktop;
  final bool isUltraWide;
  final bool isPortrait;
  final bool isUltraWideAspect;

  const ScaledConfig._({
    required this.scaleFactor,
    required this.screenWidth,
    required this.screenHeight,
    required this.isMobile,
    required this.isTablet,
    required this.isDesktop,
    required this.isUltraWide,
    required this.isPortrait,
    required this.isUltraWideAspect,
    required super.child,
  });

  /// Access the scaling configuration from the widget tree.
  ///
  /// Returns null if no [ScaledConfigProvider] is found.
  static ScaledConfig? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ScaledConfig>();
  }

  /// Access the scaling configuration from the widget tree.
  ///
  /// Throws an error if no [ScaledConfigProvider] is found.
  static ScaledConfig of(BuildContext context) {
    final config = maybeOf(context);
    assert(
      config != null,
      'No ScaledConfig found in widget tree. '
      'Wrap your app with ScaledConfigProvider.',
    );
    return config!;
  }

  // Scaling methods

  /// Returns a spacing value scaled by the universal scale factor.
  double spacing(double baseValue) => baseValue * scaleFactor;

  /// Returns a font size with conservative scaling (0.9-1.15 range).
  double fontSize(double baseSize) {
    final fontScale = 0.9 + (scaleFactor - 0.85) * (0.25 / 0.4);
    return baseSize * fontScale.clamp(0.9, 1.15);
  }

  /// Returns an icon size scaled by the universal scale factor.
  double iconSize(double baseSize) => baseSize * scaleFactor;

  /// Returns scaled EdgeInsets.
  EdgeInsets edgeInsets({
    double? all,
    double? horizontal,
    double? vertical,
    double? left,
    double? top,
    double? right,
    double? bottom,
  }) {
    if (all != null) {
      return EdgeInsets.all(all * scaleFactor);
    }

    return EdgeInsets.only(
      left: (left ?? horizontal ?? 0) * scaleFactor,
      top: (top ?? vertical ?? 0) * scaleFactor,
      right: (right ?? horizontal ?? 0) * scaleFactor,
      bottom: (bottom ?? vertical ?? 0) * scaleFactor,
    );
  }

  /// Returns a scaled symmetric EdgeInsets.
  EdgeInsets symmetricPadding({double horizontal = 0, double vertical = 0}) {
    return EdgeInsets.symmetric(
      horizontal: horizontal * scaleFactor,
      vertical: vertical * scaleFactor,
    );
  }

  // Responsive value selection

  /// Select a value based on screen size breakpoint.
  T breakpointValue<T>({
    required T mobile,
    T? tablet,
    required T desktop,
    T? desktopLarge,
    T? ultraWide,
  }) {
    if (isMobile) return mobile;
    if (isTablet) return tablet ?? desktop;
    if (isUltraWide) return ultraWide ?? desktopLarge ?? desktop;
    return desktop;
  }

  /// Select a value based on aspect ratio.
  T aspectValue<T>({
    required T portrait,
    T? square,
    required T landscape,
    T? ultrawide,
  }) {
    if (isPortrait) return portrait;
    if (isUltraWideAspect) return ultrawide ?? landscape;
    // Check for approximately square
    final ratio = screenWidth / screenHeight;
    if (ratio >= 0.8 && ratio <= 1.25) return square ?? landscape;
    return landscape;
  }

  // Computed properties

  /// Suggested number of grid columns based on screen width.
  int gridColumns({double minItemWidth = 300, int maxColumns = 6}) {
    final columns = (screenWidth / minItemWidth).floor();
    return columns.clamp(1, maxColumns);
  }

  /// Suggested panel width for slide-out panels.
  double get panelWidth {
    if (isMobile) return screenWidth;
    if (isTablet) return (screenWidth * 0.6).clamp(300, 400);
    if (isUltraWideAspect) return (screenWidth * 0.25).clamp(350, 500);
    return (screenWidth * 0.35).clamp(350, 450);
  }

  /// Aspect ratio (width / height)
  double get aspectRatio => screenWidth / screenHeight;

  @override
  bool updateShouldNotify(ScaledConfig oldWidget) {
    return scaleFactor != oldWidget.scaleFactor ||
        screenWidth != oldWidget.screenWidth ||
        screenHeight != oldWidget.screenHeight ||
        isMobile != oldWidget.isMobile ||
        isTablet != oldWidget.isTablet ||
        isDesktop != oldWidget.isDesktop;
  }
}
