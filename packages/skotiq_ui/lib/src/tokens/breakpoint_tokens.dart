/// Named width breakpoints for responsive layout decisions.
///
/// The single source of truth for layout width bands, so a screen never
/// hardcodes a raw pixel threshold.
///
/// Bands:
///   * phone:         w <  600
///   * tablet:        600  <= w <  768
///   * desktop:       768  <= w < 1024
///   * desktopWide:  1024  <= w < 1280
///   * ultraWide:    w >= 1280
///
/// Deliberately separate from the `SkotiqTokens` responsive scale, which
/// drives the planetarium and the type scale: layout decisions (sidebar
/// collapse, toolbar overflow) switch at different widths, and merging the two
/// would shift the type-scale breakpoints.
abstract final class BreakpointTokens {
  BreakpointTokens._();

  /// 600 — phone vs tablet boundary.
  static const double breakpointPhone = 600.0;

  /// 768 — tablet vs desktop boundary.
  static const double breakpointTablet = 768.0;

  /// 1024 — desktop vs wide-desktop boundary (laptops).
  static const double breakpointDesktop = 1024.0;

  /// 1280 — wide-desktop vs ultra-wide boundary (large monitors).
  static const double breakpointDesktopWide = 1280.0;

  /// True when [width] is below the phone breakpoint.
  static bool isPhone(double width) => width < breakpointPhone;

  /// True when [width] is in the tablet band: [600, 768).
  static bool isTablet(double width) =>
      width >= breakpointPhone && width < breakpointTablet;

  /// True when [width] is in the desktop band: [768, 1024).
  static bool isDesktop(double width) =>
      width >= breakpointTablet && width < breakpointDesktop;

  /// True when [width] is in the wide-desktop band: [1024, 1280).
  static bool isDesktopWide(double width) =>
      width >= breakpointDesktop && width < breakpointDesktopWide;

  /// True when [width] is at or above the ultra-wide breakpoint.
  static bool isUltraWide(double width) => width >= breakpointDesktopWide;

  /// True when [width] is at-or-above the desktop breakpoint (>= 768).
  /// Convenience for code that just wants "not phone/tablet".
  static bool isAtLeastDesktop(double width) => width >= breakpointTablet;
}
