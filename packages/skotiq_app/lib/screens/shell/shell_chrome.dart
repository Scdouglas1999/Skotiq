import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:skotiq_core/utils.dart' show DeviceTraits;
import 'package:skotiq_ui/skotiq_ui.dart';

/// The desktop window's own chrome: whether the app draws the frame.
/// How the shell navigates is [ShellLayout.navigation].
abstract final class ShellChrome {
  ShellChrome._();

  /// True when this process owns an OS window it must draw the chrome for.
  ///
  /// The desktop runners set `TitleBarStyle.hidden`, so the platform draws no
  /// minimize/maximize/close buttons at ANY width. That makes window controls
  /// a property of the platform, never of the layout — a narrow desktop window
  /// on the bottom bar must still render them or the operator
  /// is left with no mouse-reachable way to close, minimize or move the app.
  /// False when [usesSystemDecorations] hands the frame to the desktop.
  static bool get isDesktopWindow {
    if (DeviceTraits.current.touchOs || kIsWeb) return false;
    if (usesSystemDecorations) return false;
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  /// True when the Linux desktop draws the window frame instead of the app.
  ///
  /// `SKOTIQ_SYSTEM_DECORATIONS=1` is the escape hatch for desktops where the
  /// frameless window misbehaves; the GTK runner reads the same variable and
  /// leaves the window decorated.
  static bool get usesSystemDecorations {
    if (kIsWeb) return false;
    return usesSystemDecorationsFor(
      isLinux: Platform.isLinux,
      environment: Platform.environment,
    );
  }

  static bool usesSystemDecorationsFor({
    required bool isLinux,
    required Map<String, String> environment,
  }) =>
      isLinux && environment['SKOTIQ_SYSTEM_DECORATIONS'] == '1';
}

/// Publishes this device's platform facts for [ShellLayout] to everything
/// under it. The app mounts it above its navigator so routes and dialogs
/// read the same layout as the shell.
class DeviceShellLayoutScope extends StatelessWidget {
  const DeviceShellLayoutScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ShellLayoutScope(
        touchDevice: DeviceTraits.current.touchOs,
        drawsWindowFrame: ShellChrome.isDesktopWindow,
        child: child,
      );
}
