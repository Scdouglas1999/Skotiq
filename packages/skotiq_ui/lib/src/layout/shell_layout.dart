import 'package:flutter/widgets.dart';
import 'package:skotiq_design/skotiq_design.dart';

import '../tokens/breakpoint_tokens.dart';

/// How the shell navigates between screens.
enum ShellNavKind {
  /// The desktop side bar, with the instrument bar across the top of the page.
  sideBar,

  /// The bottom bar of a phone or a narrow window.
  bottomBar,

  /// A phone or tablet on its side: the bottom bar's destinations in a rail
  /// down the left edge.
  phoneRail,
}

/// What kind of device the window is laid out for.
enum DeviceClass { phone, tablet, desktop }

/// The one answer to "what layout is this window": the device class, the
/// orientation, how the shell navigates, and whether page headers are narrow.
///
/// The shell decides it from the window size and two platform facts the app
/// publishes through [ShellLayoutScope]. Screens, dialogs and [Responsive]
/// read it with [ShellLayout.of]. A decision about the width of a widget's
/// own region (a [LayoutBuilder]'s constraints) is not a form-factor question
/// and stays with that widget.
@immutable
class ShellLayout {
  const ShellLayout({
    required this.size,
    required this.touchDevice,
    required this.drawsWindowFrame,
  });

  /// The window's size in logical pixels.
  final Size size;

  /// A phone or tablet operating system: the device class is fixed by its
  /// short side and the shell always navigates from a bottom bar or rail.
  final bool touchDevice;

  /// The app draws its own window frame (a desktop window without system
  /// decorations), so the shell keeps a strip for the window controls.
  final bool drawsWindowFrame;

  /// The layout of the window [context] is in.
  static ShellLayout of(BuildContext context) {
    final platform = ShellLayoutScope._platformOf(context);
    return ShellLayout(
      size: MediaQuery.sizeOf(context),
      touchDevice: platform.touchDevice,
      drawsWindowFrame: platform.drawsWindowFrame,
    );
  }

  /// A phone in either orientation: the short side is under 600. A desktop
  /// window that small is laid out as a phone too.
  bool get isPhone => size.shortestSide < BreakpointTokens.breakpointPhone;

  /// Wider than tall (a square window counts as landscape).
  bool get isLandscape => !(size.height > size.width);

  /// The width the device-class tiers are measured on: the short side of a
  /// touch device, so a phone on its side stays in the phone tiers, and the
  /// window width on a desktop.
  double get tierWidth => touchDevice ? size.shortestSide : size.width;

  DeviceClass get deviceClass {
    if (isPhone) return DeviceClass.phone;
    if (tierWidth < SkotiqTokens.breakpointDesktop) return DeviceClass.tablet;
    return DeviceClass.desktop;
  }

  ShellNavKind get navigation {
    final bottom =
        touchDevice ||
        isPhone ||
        size.width < BreakpointTokens.breakpointTablet;
    if (!bottom) return ShellNavKind.sideBar;
    if (!drawsWindowFrame && size.width > size.height) {
      return ShellNavKind.phoneRail;
    }
    return ShellNavKind.bottomBar;
  }

  /// The shell navigates from a bottom bar or a rail, not the side bar.
  bool get usesBottomNavigation => navigation != ShellNavKind.sideBar;

  /// The page sits under the instrument bar, the shell's status surface.
  /// Without it a screen carries its own status strip.
  bool get hasInstrumentBar => navigation == ShellNavKind.sideBar;

  /// Phone chrome: no window frame to carry, so the screen's own header is
  /// the top bar.
  bool get phoneChrome => usesBottomNavigation && !drawsWindowFrame;

  /// Narrower than the tablet breakpoint: page headers are one 48 px row with
  /// their tabs on a row of their own, and screens take the compact gutters.
  bool get narrowWindow => size.width < BreakpointTokens.breakpointTablet;

  @override
  bool operator ==(Object other) =>
      other is ShellLayout &&
      other.size == size &&
      other.touchDevice == touchDevice &&
      other.drawsWindowFrame == drawsWindowFrame;

  @override
  int get hashCode => Object.hash(size, touchDevice, drawsWindowFrame);
}

/// Publishes the platform facts [ShellLayout] needs. The app mounts one above
/// its navigator; a widget with none above it is laid out as a desktop window
/// that draws its own frame.
class ShellLayoutScope extends InheritedWidget {
  const ShellLayoutScope({
    super.key,
    required this.touchDevice,
    required this.drawsWindowFrame,
    required super.child,
  });

  final bool touchDevice;
  final bool drawsWindowFrame;

  static ({bool touchDevice, bool drawsWindowFrame}) _platformOf(
    BuildContext context,
  ) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<ShellLayoutScope>();
    if (scope == null) return (touchDevice: false, drawsWindowFrame: true);
    return (
      touchDevice: scope.touchDevice,
      drawsWindowFrame: scope.drawsWindowFrame,
    );
  }

  @override
  bool updateShouldNotify(ShellLayoutScope oldWidget) =>
      touchDevice != oldWidget.touchDevice ||
      drawsWindowFrame != oldWidget.drawsWindowFrame;
}
