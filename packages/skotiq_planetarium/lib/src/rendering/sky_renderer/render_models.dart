// ignore_for_file: unused_element, unused_field

part of '../sky_renderer.dart';

/// Which slice of the scene a [SkyCanvasPainter] should render.
///
/// The interactive sky view splits rendering into two RepaintBoundary-isolated
/// layers so a static view paints the expensive base once then idles while
/// cheap animated bits repaint at 60fps:
///
/// * [SkyRenderScope.base] — everything that is NOT continuously animated:
///   background, Milky Way, grids, constellations, DSOs, dim+medium stars,
///   solar-system bodies, satellites, labels, the non-pulsing mount/selection
///   markers. Repaints only when the pose / minute / config / catalog changes.
/// * [SkyRenderScope.overlay] — only the cheap animated bits drawn on top:
///   the bright-star (twinkle) pass and the pulsing selection ring. Repaints
///   at animation cadence.
/// * [SkyRenderScope.full] — the complete scene in a single painter. Used when
///   the painter is driven standalone (tests, thumbnails, anywhere the
///   two-layer host isn't involved).
enum SkyRenderScope { base, overlay, full }

/// Mount tracking status for rendering
enum MountRenderStatus { disconnected, parked, slewing, tracking, stopped }

/// Configuration for sky rendering
class SkyRenderConfig {
  final bool showStars;
  final bool showConstellationLines;
  final bool showConstellationLabels;
  final bool showConstellationBoundaries;
  final bool showDSOs;
  final bool showDSOLabels;
  final bool showCoordinateGrid;
  final bool showAltAzGrid;
  final bool showEquatorialGrid;
  final bool showEcliptic;
  final bool showGalacticPlane;
  final bool showHorizon;
  final bool showCardinalDirections;
  final bool showMilkyWay;
  final bool showMountPosition;
  final bool showSun;
  final bool showMoon;
  final bool showPlanets;
  final bool showGroundPlane;
  final bool showMeridian;
  final bool showSatellites;
  final bool showVariableStars;
  final bool showMinorPlanets;
  final bool showConstellationArt;

  /// Whether to draw the selected target's planning overlays directly on the
  /// sky: its altitude track for tonight, the meridian-flip / transit marker,
  /// and the twilight (dusk/dawn) indicator. These are target-specific aids for
  /// session planning, drawn on the animated overlay layer. Off by default.
  final bool showPlanningOverlays;

  final Color groundColorDark;
  final Color groundColorLight;
  final Color horizonGlowColor;
  final double starMagnitudeLimit;
  final double dsoMagnitudeLimit;
  final Color gridColor;
  final Color constellationLineColor;
  final Color constellationBoundaryColor;
  final Color eclipticColor;
  final Color galacticPlaneColor;
  final Color horizonColor;
  final Color mountPositionColor;

  const SkyRenderConfig({
    this.showStars = true,
    this.showConstellationLines = true,
    this.showConstellationLabels = true,
    this.showConstellationBoundaries = false,
    this.showDSOs = true,
    this.showDSOLabels = true,
    this.showCoordinateGrid = false,
    this.showAltAzGrid = false,
    this.showEquatorialGrid = false,
    this.showEcliptic = false,
    this.showGalacticPlane = false,
    this.showHorizon = true,
    this.showCardinalDirections = true,
    this.showMilkyWay = false,
    this.showMountPosition = true,
    this.showSun = true,
    this.showMoon = true,
    this.showPlanets = true,
    this.showGroundPlane = true,
    this.showMeridian = false,
    this.showSatellites = false,
    this.showVariableStars = false,
    this.showMinorPlanets = false,
    this.showConstellationArt = false,
    this.showPlanningOverlays = false,
    this.groundColorDark = const Color(0xFF0A0805),
    this.groundColorLight = const Color(0xFF1A1510),
    this.horizonGlowColor = const Color(0xFF2A2015),
    this.starMagnitudeLimit = 6.0,
    this.dsoMagnitudeLimit = 12.0,
    this.gridColor = const Color(0x33FFFFFF),
    this.constellationLineColor = const Color(0x40FFFFFF),
    this.constellationBoundaryColor = const Color(0x20FFFFFF),
    this.eclipticColor = const Color(0x40FFEB3B),
    this.galacticPlaneColor = const Color(0x4000BCD4),
    this.horizonColor = const Color(0x30FF8A65),
    this.mountPositionColor = const Color(0xFFE53935),
  });

  SkyRenderConfig copyWith({
    bool? showStars,
    bool? showConstellationLines,
    bool? showConstellationLabels,
    bool? showConstellationBoundaries,
    bool? showDSOs,
    bool? showDSOLabels,
    bool? showCoordinateGrid,
    bool? showAltAzGrid,
    bool? showEquatorialGrid,
    bool? showEcliptic,
    bool? showGalacticPlane,
    bool? showHorizon,
    bool? showCardinalDirections,
    bool? showMilkyWay,
    bool? showMountPosition,
    bool? showSun,
    bool? showMoon,
    bool? showPlanets,
    bool? showGroundPlane,
    bool? showMeridian,
    bool? showSatellites,
    bool? showVariableStars,
    bool? showMinorPlanets,
    bool? showConstellationArt,
    bool? showPlanningOverlays,
    Color? groundColorDark,
    Color? groundColorLight,
    Color? horizonGlowColor,
    double? starMagnitudeLimit,
    double? dsoMagnitudeLimit,
    Color? gridColor,
    Color? constellationLineColor,
    Color? constellationBoundaryColor,
    Color? eclipticColor,
    Color? galacticPlaneColor,
    Color? horizonColor,
    Color? mountPositionColor,
  }) {
    return SkyRenderConfig(
      showStars: showStars ?? this.showStars,
      showConstellationLines:
          showConstellationLines ?? this.showConstellationLines,
      showConstellationLabels:
          showConstellationLabels ?? this.showConstellationLabels,
      showConstellationBoundaries:
          showConstellationBoundaries ?? this.showConstellationBoundaries,
      showDSOs: showDSOs ?? this.showDSOs,
      showDSOLabels: showDSOLabels ?? this.showDSOLabels,
      showCoordinateGrid: showCoordinateGrid ?? this.showCoordinateGrid,
      showAltAzGrid: showAltAzGrid ?? this.showAltAzGrid,
      showEquatorialGrid: showEquatorialGrid ?? this.showEquatorialGrid,
      showEcliptic: showEcliptic ?? this.showEcliptic,
      showGalacticPlane: showGalacticPlane ?? this.showGalacticPlane,
      showHorizon: showHorizon ?? this.showHorizon,
      showCardinalDirections:
          showCardinalDirections ?? this.showCardinalDirections,
      showMilkyWay: showMilkyWay ?? this.showMilkyWay,
      showMountPosition: showMountPosition ?? this.showMountPosition,
      showSun: showSun ?? this.showSun,
      showMoon: showMoon ?? this.showMoon,
      showPlanets: showPlanets ?? this.showPlanets,
      showGroundPlane: showGroundPlane ?? this.showGroundPlane,
      showMeridian: showMeridian ?? this.showMeridian,
      showSatellites: showSatellites ?? this.showSatellites,
      showVariableStars: showVariableStars ?? this.showVariableStars,
      showMinorPlanets: showMinorPlanets ?? this.showMinorPlanets,
      showConstellationArt: showConstellationArt ?? this.showConstellationArt,
      showPlanningOverlays: showPlanningOverlays ?? this.showPlanningOverlays,
      groundColorDark: groundColorDark ?? this.groundColorDark,
      groundColorLight: groundColorLight ?? this.groundColorLight,
      horizonGlowColor: horizonGlowColor ?? this.horizonGlowColor,
      starMagnitudeLimit: starMagnitudeLimit ?? this.starMagnitudeLimit,
      dsoMagnitudeLimit: dsoMagnitudeLimit ?? this.dsoMagnitudeLimit,
      gridColor: gridColor ?? this.gridColor,
      constellationLineColor:
          constellationLineColor ?? this.constellationLineColor,
      constellationBoundaryColor:
          constellationBoundaryColor ?? this.constellationBoundaryColor,
      eclipticColor: eclipticColor ?? this.eclipticColor,
      galacticPlaneColor: galacticPlaneColor ?? this.galacticPlaneColor,
      horizonColor: horizonColor ?? this.horizonColor,
      mountPositionColor: mountPositionColor ?? this.mountPositionColor,
    );
  }

  /// Value equality.
  ///
  /// Without this the painter's `config != oldDelegate.config` check was an
  /// identity compare, so any rebuild that produced an equal-but-new config —
  /// which [effectiveSkyRenderConfigProvider] does on every recompute, since
  /// `copyWith` always allocates — forced a full repaint of the expensive base
  /// layer for no visual change.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SkyRenderConfig &&
          runtimeType == other.runtimeType &&
          showStars == other.showStars &&
          showConstellationLines == other.showConstellationLines &&
          showConstellationLabels == other.showConstellationLabels &&
          showConstellationBoundaries == other.showConstellationBoundaries &&
          showDSOs == other.showDSOs &&
          showDSOLabels == other.showDSOLabels &&
          showCoordinateGrid == other.showCoordinateGrid &&
          showAltAzGrid == other.showAltAzGrid &&
          showEquatorialGrid == other.showEquatorialGrid &&
          showEcliptic == other.showEcliptic &&
          showGalacticPlane == other.showGalacticPlane &&
          showHorizon == other.showHorizon &&
          showCardinalDirections == other.showCardinalDirections &&
          showMilkyWay == other.showMilkyWay &&
          showMountPosition == other.showMountPosition &&
          showSun == other.showSun &&
          showMoon == other.showMoon &&
          showPlanets == other.showPlanets &&
          showGroundPlane == other.showGroundPlane &&
          showMeridian == other.showMeridian &&
          showSatellites == other.showSatellites &&
          showVariableStars == other.showVariableStars &&
          showMinorPlanets == other.showMinorPlanets &&
          showConstellationArt == other.showConstellationArt &&
          showPlanningOverlays == other.showPlanningOverlays &&
          starMagnitudeLimit == other.starMagnitudeLimit &&
          dsoMagnitudeLimit == other.dsoMagnitudeLimit &&
          groundColorDark == other.groundColorDark &&
          groundColorLight == other.groundColorLight &&
          horizonGlowColor == other.horizonGlowColor &&
          gridColor == other.gridColor &&
          constellationLineColor == other.constellationLineColor &&
          constellationBoundaryColor == other.constellationBoundaryColor &&
          eclipticColor == other.eclipticColor &&
          galacticPlaneColor == other.galacticPlaneColor &&
          horizonColor == other.horizonColor &&
          mountPositionColor == other.mountPositionColor;

  @override
  int get hashCode => Object.hashAll([
    showStars,
    showConstellationLines,
    showConstellationLabels,
    showConstellationBoundaries,
    showDSOs,
    showDSOLabels,
    showCoordinateGrid,
    showAltAzGrid,
    showEquatorialGrid,
    showEcliptic,
    showGalacticPlane,
    showHorizon,
    showCardinalDirections,
    showMilkyWay,
    showMountPosition,
    showSun,
    showMoon,
    showPlanets,
    showGroundPlane,
    showMeridian,
    showSatellites,
    showVariableStars,
    showMinorPlanets,
    showConstellationArt,
    showPlanningOverlays,
    starMagnitudeLimit,
    dsoMagnitudeLimit,
    groundColorDark,
    groundColorLight,
    horizonGlowColor,
    gridColor,
    constellationLineColor,
    constellationBoundaryColor,
    eclipticColor,
    galacticPlaneColor,
    horizonColor,
    mountPositionColor,
  ]);
}

/// Sky view projection type
enum SkyProjection { stereographic, orthographic, azimuthalEquidistant }

/// The celestial frame the sky view is centered on and panned in.
///
/// * [equatorial] — the default. The view is centered on an RA/Dec point and
///   "up" on screen tracks the celestial pole, so the sky appears as it does on
///   a star atlas (the orientation the committed goldens were captured in).
/// * [horizontal] — the "tonight from my site" frame. The view is centered on
///   an alt/az point (zenith by default) with the local horizon at the bottom
///   and altitude increasing upward, exactly what an observer sees standing at
///   the eyepiece. Objects rise on the east side and set on the west; the
///   equatorial grid curves while the alt/az grid runs straight.
enum SkyViewMode { equatorial, horizontal }

/// View state for sky rendering.
///
/// Two centers are carried so a mode switch is non-destructive: [centerRA] /
/// [centerDec] anchor the [SkyViewMode.equatorial] frame, while [centerAz] /
/// [centerAltitude] anchor the [SkyViewMode.horizontal] frame. Only the pair
/// matching [viewMode] is read by the projection; the other is preserved so
/// toggling back restores the previous pose.
class SkyViewState {
  final double centerRA; // hours
  final double centerDec; // degrees
  final double fieldOfView; // degrees
  final double rotation; // degrees
  final SkyProjection projection;

  /// Which celestial frame the view is centered on. Equatorial by default so
  /// the default pose and the committed render goldens are unchanged.
  final SkyViewMode viewMode;

  /// Azimuth of the view center in degrees (0 = North, 90 = East). Read only in
  /// [SkyViewMode.horizontal].
  final double centerAz;

  /// Altitude of the view center in degrees (90 = zenith, 0 = horizon). Read
  /// only in [SkyViewMode.horizontal]. Defaults to the zenith so the horizontal
  /// frame opens looking straight up.
  final double centerAltitude;

  const SkyViewState({
    this.centerRA = 0,
    this.centerDec = 0,
    this.fieldOfView = 90,
    this.rotation = 0,
    this.projection = SkyProjection.stereographic,
    this.viewMode = SkyViewMode.equatorial,
    this.centerAz = 0,
    this.centerAltitude = 90,
  });

  SkyViewState copyWith({
    double? centerRA,
    double? centerDec,
    double? fieldOfView,
    double? rotation,
    SkyProjection? projection,
    SkyViewMode? viewMode,
    double? centerAz,
    double? centerAltitude,
  }) {
    return SkyViewState(
      centerRA: centerRA ?? this.centerRA,
      centerDec: centerDec ?? this.centerDec,
      fieldOfView: fieldOfView ?? this.fieldOfView,
      rotation: rotation ?? this.rotation,
      projection: projection ?? this.projection,
      viewMode: viewMode ?? this.viewMode,
      centerAz: centerAz ?? this.centerAz,
      centerAltitude: centerAltitude ?? this.centerAltitude,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SkyViewState &&
          runtimeType == other.runtimeType &&
          centerRA == other.centerRA &&
          centerDec == other.centerDec &&
          fieldOfView == other.fieldOfView &&
          rotation == other.rotation &&
          projection == other.projection &&
          viewMode == other.viewMode &&
          centerAz == other.centerAz &&
          centerAltitude == other.centerAltitude;

  @override
  int get hashCode => Object.hash(
    centerRA,
    centerDec,
    fieldOfView,
    rotation,
    projection,
    viewMode,
    centerAz,
    centerAltitude,
  );
}

/// Precomputed atmospheric extinction lookup table.
///
/// 91 entries for altitudes 0-90 degrees. The extinction factor combines
/// dimming and reddening from atmospheric scattering. Below 30 degrees the
/// effect is significant; above 30 degrees the factor is 1.0 (no extinction).
///
/// The table is static since extinction depends only on altitude (geometric
/// airmass), not observer location. Uses linear interpolation for fractional
/// altitudes.
class AtmosphericExtinctionLUT {
  /// 91-entry LUT: index = integer altitude in degrees (0..90).
  /// Each entry is (brightnessFactor, redShift) where:
  ///   brightnessFactor: multiplier for star brightness [0.5..1.0]
  ///   redShift: Color.lerp amount toward warm horizon color [0.0..0.4]
  static final List<(double, double)> _lut = _buildLUT();

  static List<(double, double)> _buildLUT() {
    final table = List<(double, double)>.filled(91, (1.0, 0.0));
    for (int alt = 0; alt <= 90; alt++) {
      if (alt >= 30) {
        table[alt] = (1.0, 0.0);
      } else {
        // extinctionFactor ramps from 0.5 at 0 deg to 1.0 at 30 deg
        final extinctionFactor = (alt / 30.0).clamp(0.0, 1.0) * 0.5 + 0.5;
        final redShift = (1.0 - extinctionFactor) * 0.4;
        table[alt] = (extinctionFactor, redShift);
      }
    }
    return table;
  }

  /// Look up extinction for a given altitude in degrees.
  /// Returns (brightnessFactor, redShift).
  /// Uses linear interpolation between integer entries.
  static (double, double) lookup(double altitudeDeg) {
    if (altitudeDeg >= 30.0) return (1.0, 0.0);
    if (altitudeDeg <= 0.0) return _lut[0];

    final lower = altitudeDeg.floor();
    final upper = lower + 1;
    if (upper > 90) return _lut[90];

    final t = altitudeDeg - lower;
    final (bLow, rLow) = _lut[lower];
    final (bHigh, rHigh) = _lut[upper];
    return (bLow + (bHigh - bLow) * t, rLow + (rHigh - rLow) * t);
  }
}

/// Tracks rendered label bounding boxes to avoid overlap.
///
/// Caches its spatial grid across frames when the view hasn't moved
/// significantly. Only rebuilds when view center moves >0.5 degrees
/// or zoom changes >5%.
class LabelLayoutManager {
  final List<Rect> _renderedLabels = [];
  final Map<int, List<Rect>> _grid = <int, List<Rect>>{};
  static const double _cellSize = 96.0;

  /// Clear the layout grid unconditionally.
  void clear() {
    _renderedLabels.clear();
    _grid.clear();
  }

  int _cellKey(int x, int y) => Object.hash(x, y);

  Iterable<Rect> _nearbyRects(Rect rect) sync* {
    final minCellX = (rect.left / _cellSize).floor();
    final maxCellX = (rect.right / _cellSize).floor();
    final minCellY = (rect.top / _cellSize).floor();
    final maxCellY = (rect.bottom / _cellSize).floor();

    for (int x = minCellX - 1; x <= maxCellX + 1; x++) {
      for (int y = minCellY - 1; y <= maxCellY + 1; y++) {
        final bucket = _grid[_cellKey(x, y)];
        if (bucket == null) continue;
        yield* bucket;
      }
    }
  }

  void _register(Rect rect) {
    _renderedLabels.add(rect);

    final minCellX = (rect.left / _cellSize).floor();
    final maxCellX = (rect.right / _cellSize).floor();
    final minCellY = (rect.top / _cellSize).floor();
    final maxCellY = (rect.bottom / _cellSize).floor();

    for (int x = minCellX; x <= maxCellX; x++) {
      for (int y = minCellY; y <= maxCellY; y++) {
        _grid.putIfAbsent(_cellKey(x, y), () => <Rect>[]).add(rect);
      }
    }
  }

  /// Returns true if label can be placed without overlap
  bool canPlace(Rect labelRect) {
    final paddedRect = labelRect.inflate(2);
    for (final existing in _nearbyRects(paddedRect)) {
      if (paddedRect.overlaps(existing)) return false;
    }
    return true;
  }

  /// The rectangles placed so far, so one layer's occupancy can seed another's.
  ///
  /// The base and overlay render layers are painted by separate painter
  /// instances; without sharing this, each starts empty and their labels
  /// collide (bright-star names are laid out on the overlay, DSO/planet labels
  /// on the base).
  List<Rect> get occupancy => List<Rect>.unmodifiable(_renderedLabels);

  /// Replace the occupancy with [rects] — used to seed the overlay layer with
  /// the base layer's placements before it lays out its own labels.
  void seed(List<Rect> rects) {
    clear();
    for (final r in rects) {
      _register(r);
    }
  }

  /// Try to find a placement, returning the offset or null if the label cannot
  /// be shown without overlapping something already placed.
  ///
  /// Candidates radiate outward from [preferred] in eight directions at two
  /// distances. Each candidate is nudged inside the canvas rather than rejected
  /// for crossing an edge; requiring the box to be fully in bounds drops every
  /// label near a screen edge even when free space sits a few pixels inward.
  Offset? findPlacement(Offset preferred, Size labelSize, Size canvasSize) {
    for (final offset in _candidates(preferred)) {
      final clamped = _clampIntoBounds(offset, labelSize, canvasSize);
      if (clamped == null) continue; // label is larger than the canvas
      final rect = Rect.fromLTWH(
        clamped.dx,
        clamped.dy,
        labelSize.width,
        labelSize.height,
      );
      if (canPlace(rect)) {
        _register(rect);
        return clamped;
      }
    }
    return null;
  }

  static Iterable<Offset> _candidates(Offset preferred) sync* {
    yield preferred;
    for (final radius in const [12.0, 24.0]) {
      yield preferred + Offset(0, -radius); // above
      yield preferred + Offset(radius, 0); // right
      yield preferred + Offset(-radius, 0); // left
      yield preferred + Offset(0, radius); // below
      yield preferred + Offset(radius, -radius);
      yield preferred + Offset(-radius, -radius);
      yield preferred + Offset(radius, radius);
      yield preferred + Offset(-radius, radius);
    }
  }

  /// Shift [offset] so a [labelSize] box sits fully inside [canvasSize].
  ///
  /// Only a box that already OVERLAPS the canvas is nudged. A label whose
  /// anchor is entirely off-screen is refused instead, so labels belonging to
  /// objects outside the view do not pile up along the edges — clamping those
  /// in would advertise objects that are not on screen.
  ///
  /// Returns null when the label cannot fit or does not overlap at all.
  static Offset? _clampIntoBounds(
    Offset offset,
    Size labelSize,
    Size canvasSize,
  ) {
    if (labelSize.width > canvasSize.width ||
        labelSize.height > canvasSize.height) {
      return null;
    }
    final rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      labelSize.width,
      labelSize.height,
    );
    if (!rect.overlaps(Offset.zero & canvasSize)) return null;
    return Offset(
      offset.dx.clamp(0.0, canvasSize.width - labelSize.width),
      offset.dy.clamp(0.0, canvasSize.height - labelSize.height),
    );
  }
}

/// Static paint cache to avoid per-frame allocation of expensive Paint objects
/// Creating Paint objects, MaskFilters, and Shaders every frame causes significant
/// GC pressure and CPU overhead. This cache provides reusable instances.
