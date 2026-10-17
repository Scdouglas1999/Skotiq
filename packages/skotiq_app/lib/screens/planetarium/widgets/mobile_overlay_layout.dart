import 'package:flutter/widgets.dart';

/// Orientation-aware placement for the mobile planetarium sky overlays.
///
/// The mobile planetarium is a single full-bleed sky canvas with floating
/// overlays (top status bar, left tool rail, bottom info bar, time-travel
/// panel, compass HUD, mini-map and the FAB column). Hard-coded
/// `Positioned(top:/bottom:)` offsets tuned for a tall portrait phone stack the
/// tool rail, time panel, compass and mini-map on top of one another in
/// landscape — where the height collapses to ~360 px — and run the FAB column
/// off the bottom.
///
/// [MobileOverlaySlots] recomputes every overlay's rectangle from the *current*
/// viewport size and [SafeArea] insets, so the same layout code lands correctly
/// in portrait and landscape and re-flows the instant the device rotates. It is
/// a pure value type (no widgets) so the geometry can be unit-tested without
/// pumping the GPU sky renderer.
///
/// Coordinate space: logical pixels, origin top-left of the planetarium Stack.
/// Every returned rect is clamped to sit inside the viewport, so an overlay can
/// never clip off-screen at any supported phone size/orientation.
@immutable
class MobileOverlaySlots {
  /// Full viewport (the planetarium Stack's own size).
  final Size viewport;

  /// True when the viewport is wider than it is tall.
  final bool isLandscape;

  /// The left tool rail (view controls above slew controls), bounded between
  /// the top and bottom bars so it scrolls rather than colliding with them.
  final Rect leftRail;

  /// The compass HUD.
  final Rect compass;

  /// The sky mini-map.
  final Rect minimap;

  /// The time-travel panel.
  final Rect timePanel;

  /// The search / filter / info FAB column.
  final Rect fabColumn;

  const MobileOverlaySlots._({
    required this.viewport,
    required this.isLandscape,
    required this.leftRail,
    required this.compass,
    required this.minimap,
    required this.timePanel,
    required this.fabColumn,
  });

  /// Clamps [v] into `[lo, hi]`, tolerating a degenerate `hi < lo` (tiny
  /// viewport) by collapsing to [lo] so the result is always well-defined.
  static double _clamp(double v, double lo, double hi) =>
      hi < lo ? lo : v.clamp(lo, hi);

  /// Builds the slot geometry for a [viewport] with the given [safeArea].
  ///
  /// [edge] is the floating-overlay inset (matches `AdaptiveSizing.edgePadding`
  /// on phone). [compassSize], [minimapSize] and [timePanelSize] are the
  /// intrinsic sizes of those widgets so the resolver can stack them without
  /// overlap; [fabColumnSize] is the measured (or estimated) extent of the
  /// search/filter/info FAB stack.
  factory MobileOverlaySlots.resolve({
    required Size viewport,
    required EdgeInsets safeArea,
    double edge = 12,
    double topBarStripHeight = 48,
    double bottomBarStripHeight = 48,
    double railWidth = 56,
    required double compassSize,
    required double minimapSize,
    required Size timePanelSize,
    required Size fabColumnSize,
  }) {
    final isLandscape = viewport.width > viewport.height;
    final topBarHeight = safeArea.top + topBarStripHeight;
    final bottomBarHeight = safeArea.bottom + bottomBarStripHeight;

    final left = safeArea.left + edge;
    final right = viewport.width - safeArea.right - edge;
    final contentTop = topBarHeight + edge;
    final contentBottom = (viewport.height - bottomBarHeight - edge);
    // The usable vertical band; never let it invert on a tiny viewport.
    final bandBottom = contentBottom < contentTop ? contentTop : contentBottom;

    // Left tool rail
    // Bounded between the top and bottom bars; the rail itself scrolls, so its
    // *box* never needs to grow past this band. This is what keeps the rail
    // from ever colliding with the bottom panels in landscape.
    final leftRail =
        Rect.fromLTRB(left, contentTop, left + railWidth, bandBottom);

    // FAB column (bottom-right)
    final fabLeft = _clamp(right - fabColumnSize.width, left, right);
    final fabTop =
        _clamp(bandBottom - fabColumnSize.height, contentTop, bandBottom);
    final fabColumn = Rect.fromLTWH(
        fabLeft, fabTop, fabColumnSize.width, fabColumnSize.height);

    // Time-travel panel + compass + mini-map
    // The right edge holds the FAB column (bottom) and the mini-map; the
    // compass and time panel share the remaining space differently per
    // orientation:
    //
    // * Portrait — height is plentiful. Mini-map hugs the bottom-right just
    //   above the FAB column; the time panel hugs the bottom-LEFT; the compass
    //   stacks above the time panel. (Left and right columns stay independent.)
    // * Landscape — height collapses to ~360 px so a vertical right-edge stack
    //   (compass + mini-map + FAB) will not fit, and the bottom-anchored FAB
    //   column climbs into the top-right. Instead the TOP edge — just right of
    //   the tool rail, where the top-centre is free in landscape — carries the
    //   mini-map and compass SIDE BY SIDE, the FAB column keeps the
    //   bottom-right, and the time panel anchors along the bottom between them.
    //   Four non-overlapping zones: rail (left), top-centre (HUD), bottom-right
    //   (FAB), bottom-centre (time panel).
    final Rect minimap;
    final Rect timePanel;
    final Rect compass;
    final tpTop =
        _clamp(bandBottom - timePanelSize.height, contentTop, bandBottom);

    if (isLandscape) {
      // Mini-map then compass, left-to-right starting just right of the rail.
      final minimapLeft =
          _clamp(leftRail.right + edge, left, right - minimapSize);
      minimap =
          Rect.fromLTWH(minimapLeft, contentTop, minimapSize, minimapSize);

      final compassLeft =
          _clamp(minimap.right + edge, left, right - compassSize);
      compass =
          Rect.fromLTWH(compassLeft, contentTop, compassSize, compassSize);

      // Time panel hugs the bottom, right of the rail, left of the FAB column.
      final tpLeft =
          _clamp(leftRail.right + edge, left, right - timePanelSize.width);
      timePanel = Rect.fromLTWH(
          tpLeft, tpTop, timePanelSize.width, timePanelSize.height);
    } else {
      final minimapLeft = _clamp(right - minimapSize, left, right);
      final minimapTop = _clamp(fabColumn.top - edge - minimapSize, contentTop,
          bandBottom - minimapSize);
      minimap =
          Rect.fromLTWH(minimapLeft, minimapTop, minimapSize, minimapSize);

      final tpLeft = _clamp(left, left, right - timePanelSize.width);
      timePanel = Rect.fromLTWH(
          tpLeft, tpTop, timePanelSize.width, timePanelSize.height);

      final compassTop = _clamp(timePanel.top - edge - compassSize, contentTop,
          bandBottom - compassSize);
      compass = Rect.fromLTWH(left, compassTop, compassSize, compassSize);
    }

    return MobileOverlaySlots._(
      viewport: viewport,
      isLandscape: isLandscape,
      leftRail: leftRail,
      compass: compass,
      minimap: minimap,
      timePanel: timePanel,
      fabColumn: fabColumn,
    );
  }

  /// True if any two of the resolved floating overlay rects overlap. Used by
  /// tests to assert the overlays never collide after a rotate. (The left rail
  /// is excluded because its box deliberately spans the full content band — its
  /// *children* scroll within it and live near the top.)
  bool get floatingOverlaysOverlap {
    final rects = <Rect>[compass, minimap, timePanel, fabColumn];
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        if (rects[i].overlaps(rects[j])) return true;
      }
    }
    return false;
  }

  /// True if every resolved overlay rect sits fully inside the viewport.
  bool get allWithinBounds {
    final bounds = Offset.zero & viewport;
    for (final r in <Rect>[leftRail, compass, minimap, timePanel, fabColumn]) {
      // A small epsilon absorbs floating-point clamp residue.
      if (r.left < bounds.left - 0.01 ||
          r.top < bounds.top - 0.01 ||
          r.right > bounds.right + 0.01 ||
          r.bottom > bounds.bottom + 0.01) {
        return false;
      }
    }
    return true;
  }
}
