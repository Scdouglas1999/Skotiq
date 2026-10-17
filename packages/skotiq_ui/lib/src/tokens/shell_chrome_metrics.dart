import 'package:flutter/widgets.dart';

import '../theme/skotiq_tokens.dart';
import '../utils/responsive_utils.dart';

/// Layout metrics for app shell chrome (title bar, status bar, bottom nav).
///
/// Desktop uses a compact custom title bar ([titleBarHeight]) distinct from
/// in-screen [SkotiqTokens.appBarHeight] headers.
abstract final class ShellChromeMetrics {
  ShellChromeMetrics._();

  /// Width at which desktop shell switches side nav ↔ bottom nav.
  static const double shellLayoutBreakpoint = SkotiqTokens.breakpointTablet;

  /// The top bar: brand, command field, global actions, window controls.
  static const double titleBarHeight = 44.0;

  /// Windows-style caption button width.
  static const double windowControlWidth = 46.0;

  /// Caption button height; matches [titleBarHeight].
  static const double windowControlHeight = titleBarHeight;

  /// The instrument bar — the app's ONE persistent status surface.
  static const double statusBarHeight = 32.0;

  /// The page header row every routed screen starts with.
  static const double pageHeaderHeight = 56.0;

  /// The page header below [shellLayoutBreakpoint], where the tabs move to
  /// their own scrollable second row.
  static const double pageHeaderHeightNarrow = 48.0;

  /// The 28px status strip that stands in for the instrument bar inside the
  /// Tonight and Imaging page headers below [shellLayoutBreakpoint].
  static const double narrowStatusStripHeight = 28.0;

  /// A right-hand side panel column.
  static const double sidePanelWidth = 320.0;

  /// The vertical icon strip that selects a side panel's sections.
  static const double sidePanelStripWidth = 44.0;

  /// One rail destination: a 40x40 square when collapsed, 40 high when
  /// expanded.
  static const double railItemSize = 40.0;

  /// How long the pointer rests on a collapsed rail item before its label
  /// appears (04 §3.1).
  ///
  /// A hover DELAY, not a transition, which is why it is not on the motion
  /// scale (120 / 160 / 220): those say how long a change takes, this says how
  /// long to wait before deciding the pointer meant to stop there.
  static const Duration railTooltipDelay = Duration(milliseconds: 200);

  /// Rail width, icons only. The default.
  static const double railWidthCollapsed = SkotiqTokens.sidebarCollapsed;

  /// Rail width with labels.
  static const double railWidthExpanded = SkotiqTokens.sidebarExpanded;

  /// Base max width for device-name text in status pills before ellipsis.
  static const double statusPillValueMaxWidth = 120.0;

  /// Preferred width for the remote-access share dialog content.
  static const double shareDialogPreferredWidth = 420.0;

  /// Instrument separator height inside the instrument bar.
  static const double statusBarDividerHeight = 14.0;

  /// Chrome below the main content [Stack].
  ///
  /// Below [shellLayoutBreakpoint] that is the bottom nav ALONE: the narrow
  /// shell has no instrument bar at all (04 §5), so adding a status-bar height
  /// there reserved 40px of empty window for a surface that is not mounted.
  static double contentStackBottomChromeHeight({required bool useBottomNav}) {
    return useBottomNav ? BottomNavMetrics.barHeight : statusBarHeight;
  }

  /// Minimum bottom offset for floating overlays in the content stack
  /// (autofocus progress, mobile sequence controls, etc.).
  static double floatingOverlayBottomInset(
    BuildContext context, {
    required bool useBottomNav,
    double margin = 16.0,
  }) {
    return MediaQuery.paddingOf(context).bottom +
        contentStackBottomChromeHeight(useBottomNav: useBottomNav) +
        margin;
  }

  /// Scales [statusPillValueMaxWidth] for viewport size with sane bounds.
  static double scaledStatusPillValueMaxWidth(BuildContext context) {
    final scaled = statusPillValueMaxWidth * Responsive.scaleFactor(context);
    return scaled.clamp(72.0, 180.0);
  }
}

/// Bottom navigation strip metrics used by [SkotiqBottomNavigation].
abstract final class BottomNavMetrics {
  BottomNavMetrics._();

  static const double barHeight = 64.0;

  /// The selected-state pill behind a slot's icon: 48 x 28, fully rounded.
  static const double itemPillWidth = 48.0;
  static const double itemPillHeight = 28.0;

  static const double itemGap = 8.0;
  static const double listHorizontalPadding = 10.0;
  static const double listVerticalPadding = 8.0;

  static const double itemWidthMin = 84.0;
  static const double itemWidthMax = 116.0;

  static const double breakpointSlots8 = 960.0;
  static const double breakpointSlots7 = 780.0;
  static const double breakpointSlots6 = 640.0;
  static const double breakpointSlots5 = 520.0;

  /// Aspect ratio (width/height) above which fewer slots are shown.
  static const double narrowAspectRatioThreshold = 0.56;

  static const double visibleSlotsUltraWide = 8.0;
  static const double visibleSlotsWide = 7.0;
  static const double visibleSlotsMedium = 6.0;
  static const double visibleSlotsNarrow = 5.25;
  static const double visibleSlotsPortrait = 4.6;
  static const double visibleSlotsDefault = 4.15;

  static const Duration scrollAnimationDuration = Duration(milliseconds: 220);

  static const Duration itemSelectionAnimationDuration = Duration(
    milliseconds: 180,
  );

  static const EdgeInsets itemPadding = EdgeInsets.symmetric(
    horizontal: 10,
    vertical: 8,
  );

  /// The pill is fully rounded, so its radius is half its height.
  static const double itemBorderRadius = itemPillHeight / 2;
  static const double itemIconSize = 21.0;
  static const double itemIconLabelGap = 4.0;
  static const double itemLabelFontSize = 11.0;

  /// Computes per-item width from viewport and screen size.
  static double itemWidth(Size screenSize, double viewportWidth) {
    final aspectRatio = screenSize.width / screenSize.height;
    final visibleSlots = switch (viewportWidth) {
      >= breakpointSlots8 => visibleSlotsUltraWide,
      >= breakpointSlots7 => visibleSlotsWide,
      >= breakpointSlots6 => visibleSlotsMedium,
      >= breakpointSlots5 => visibleSlotsNarrow,
      _ when aspectRatio > narrowAspectRatioThreshold => visibleSlotsPortrait,
      _ => visibleSlotsDefault,
    };

    const horizontalInset = listHorizontalPadding * 2;
    final computed = (viewportWidth - horizontalInset) / visibleSlots;
    return computed.clamp(itemWidthMin, itemWidthMax);
  }
}
