import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:skotiq_ui/skotiq_ui.dart';

/// Shell chrome (side nav vs bottom nav) decisions.
///
/// **Bottom nav** — iOS/Android builds always use bottom navigation so tablet
/// widths do not swap to the desktop side rail ([KEEP] mobile shell rule).
///
/// **Side nav** — Windows/macOS/Linux use the side rail at widths ≥
/// [ShellChromeMetrics.shellLayoutBreakpoint] (768px). Narrow desktop windows
/// keep bottom nav for space.
abstract final class ShellChrome {
  ShellChrome._();

  /// True on phone/tablet native targets (not web).
  static bool get isNativeMobile {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  /// True when this process owns an OS window it must draw the chrome for.
  ///
  /// The desktop runners set `TitleBarStyle.hidden`, so the platform draws no
  /// minimize/maximize/close buttons at ANY width. That makes window controls
  /// a property of the platform, never of the layout — a narrow desktop window
  /// switching to [useBottomNavigation] must still render them or the operator
  /// is left with no mouse-reachable way to close, minimize or move the app.
  static bool get isDesktopWindow {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  /// Whether the shell should render [SkotiqBottomNavigation].
  static bool useBottomNavigation(double width) {
    if (isNativeMobile) return true;
    return width < ShellChromeMetrics.shellLayoutBreakpoint;
  }

  /// Whether the shell should render [SideNavigation].
  static bool useSideNavigation(double width) => !useBottomNavigation(width);
}
