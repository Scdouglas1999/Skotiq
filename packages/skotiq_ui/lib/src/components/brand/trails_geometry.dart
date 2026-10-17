import 'dart:math' as math;
import 'dart:ui';

/// The "Trails" mark — the letter S drawn by star trails, the arcs stars
/// leave across a long exposure. Each lane is one star's trail; the lanes
/// start and stop at different points because each star was in frame for a
/// different stretch. That stagger is the mark's signature detail.
///
/// Geometry, levels and colorways are a line-for-line port of the approved
/// reference (`brand-ref/trails_reference.py`); the numbers below are the
/// sign-off, not a starting point for restyling. Everything is expressed in
/// the mark's 100×100 viewBox — callers scale to pixels at paint time.
abstract final class TrailsGeometry {
  TrailsGeometry._();

  /// Side of the square viewBox every measurement below is expressed in.
  static const double viewBox = 100;

  /// Zoom applied to the whole mark so the S fills its tile like an icon:
  /// `translate(50 50) scale(1.08) translate(-50 -50.5)` in viewBox space.
  static const double markScale = 1.08;

  /// Horizontal center of both bowls, and their centers' y positions.
  static const double centerX = 50;
  static const double upperCenterY = 36;
  static const double lowerCenterY = 64;

  /// Centerline radius shared by both bowls. A lane at [TrailsLane.offset] o
  /// has radius `r0 + o` in the upper bowl and `r0 - o` in the lower one, so
  /// the lanes meet seamlessly at the S's waist, (50, 50 + o).
  static const double centerlineRadius = 14;

  /// Where the pole star sits — the upper bowl's center.
  static const Offset poleCenter = Offset(centerX, upperCenterY);

  /// App-icon tile: rounded ground behind the mark. Red night mode renders
  /// the mark on true black instead.
  static const Color tileGround = Color(0xFF0E0C16);
  static const Color tileGroundRed = Color(0xFF000000);

  /// Tile corner radius as a fraction of the tile side (22.5% = the
  /// reference's `rx="22.5"` on the 100-unit tile).
  static const double tileRadiusFraction = 0.225;

  /// Point on a circle of radius [r] centered (cx, cy), at angle [degrees]
  /// measured with the viewBox's y axis pointing down — the same convention
  /// the SVG reference uses.
  static Offset polarPoint(double cx, double cy, double r, double degrees) {
    final a = degrees * math.pi / 180;
    return Offset(cx + r * math.cos(a), cy + r * math.sin(a));
  }
}

/// One star trail: where it enters the upper bowl, where it leaves the lower
/// bowl, and how far off the shared centerline it runs.
final class TrailsLane {
  const TrailsLane({
    required this.offset,
    required this.upStartDegrees,
    required this.loEndDegrees,
  });

  /// Distance from [TrailsGeometry.centerlineRadius]: positive lanes run
  /// wider in the upper bowl and tighter in the lower bowl, negative lanes
  /// the reverse.
  final double offset;

  /// Entry angle in the upper bowl, degrees (y down).
  final double upStartDegrees;

  /// Exit angle in the lower bowl, degrees (y down).
  final double loEndDegrees;
}

/// Detail level — same centerlines at every size, fewer and heavier lanes as
/// the mark shrinks so the trails never merge.
enum TrailsLevel {
  /// 64 px and up: 5 lanes, stroke 3.0, pole radius 2.2.
  full,

  /// 24–63 px: 3 lanes, stroke 4.6, pole radius 3.0.
  mid,

  /// Below 24 px: 2 lanes, stroke 6.4, no pole.
  flat,
}

/// Everything a painter needs for one [TrailsLevel].
final class TrailsLevelSpec {
  const TrailsLevelSpec({
    required this.lanes,
    required this.strokeWidth,
    required this.pick,
    required this.poleRadius,
    required this.loadingPhaseStep,
  });

  /// Lanes outermost (top bowl) to innermost — the last lane carries the
  /// warm accent.
  final List<TrailsLane> lanes;

  /// Lane stroke width in viewBox units.
  final double strokeWidth;

  /// Palette index each lane paints with (indexes the colorway's five-entry
  /// list), so reduced levels keep the outer-to-inner color progression.
  final List<int> pick;

  /// Pole-star radius in viewBox units; 0 at [TrailsLevel.flat], which has
  /// no pole star.
  final double poleRadius;

  /// Phase offset between one lane's travelling dash and the next during
  /// `loading`. The approved demo offsets every lane by −0.25 s at [full]
  /// and by −0.5 s at the reduced levels (`sk-c2`, `sk-c4` classes in
  /// `motion_reference.html`), so the cascade keeps roughly the same spread
  /// with fewer lanes.
  final Duration loadingPhaseStep;
}

/// The mark's colorways, lanes listed outermost (top bowl) to innermost.
/// `mono` paints every lane in one color; [SkotiqMark]'s widget layer
/// resolves it to the ambient icon/text color unless overridden.
enum SkotiqMarkTone {
  /// Primary colorway.
  violet,

  /// For light backgrounds.
  light,

  /// Red night mode, on `#000`.
  red,

  /// Every lane one color.
  mono,
}

/// The mark's lanes: offset, upper-bowl start, lower-bowl end — outermost
/// to innermost in the top bowl. The last lane is the warm accent.
const List<TrailsLane> trailsLanes = [
  TrailsLane(offset: 8.4, upStartDegrees: -38, loEndDegrees: 132),
  TrailsLane(offset: 4.2, upStartDegrees: -22, loEndDegrees: 150),
  TrailsLane(offset: 0, upStartDegrees: -46, loEndDegrees: 140),
  TrailsLane(offset: -4.2, upStartDegrees: -30, loEndDegrees: 160),
  TrailsLane(offset: -8.4, upStartDegrees: -60, loEndDegrees: 118),
];

const List<TrailsLane> _midLanes = [
  TrailsLane(offset: 7.0, upStartDegrees: -38, loEndDegrees: 132),
  TrailsLane(offset: 0, upStartDegrees: -46, loEndDegrees: 140),
  TrailsLane(offset: -7.0, upStartDegrees: -60, loEndDegrees: 118),
];

const List<TrailsLane> _flatLanes = [
  TrailsLane(offset: 4.6, upStartDegrees: -40, loEndDegrees: 134),
  TrailsLane(offset: -4.6, upStartDegrees: -52, loEndDegrees: 124),
];

/// The reference's `LEVELS` table.
const Map<TrailsLevel, TrailsLevelSpec> trailsLevels = {
  TrailsLevel.full: TrailsLevelSpec(
    lanes: trailsLanes,
    strokeWidth: 3.0,
    pick: [0, 1, 2, 3, 4],
    poleRadius: 2.2,
    loadingPhaseStep: Duration(milliseconds: 250),
  ),
  TrailsLevel.mid: TrailsLevelSpec(
    lanes: _midLanes,
    strokeWidth: 4.6,
    pick: [0, 2, 4],
    poleRadius: 3.0,
    loadingPhaseStep: Duration(milliseconds: 500),
  ),
  TrailsLevel.flat: TrailsLevelSpec(
    lanes: _flatLanes,
    strokeWidth: 6.4,
    pick: [1, 4],
    poleRadius: 0,
    loadingPhaseStep: Duration(milliseconds: 500),
  ),
};

/// The reference's `PALETTES`, keyed by tone. Every list holds the five
/// lane colors outermost-to-innermost; the mark's pole star uses index 3.
const Map<SkotiqMarkTone, List<Color>> trailsPalettes = {
  SkotiqMarkTone.violet: [
    Color(0xFF6E56CF),
    Color(0xFF8F7BEA),
    Color(0xFFB9ABFF),
    Color(0xFFE4DEFF),
    Color(0xFFFFD9A8),
  ],
  SkotiqMarkTone.light: [
    Color(0xFF4B36A8),
    Color(0xFF6A55CC),
    Color(0xFF8E7BE3),
    Color(0xFF2B2347),
    Color(0xFFE08A3C),
  ],
  SkotiqMarkTone.red: [
    Color(0xFF7A1C14),
    Color(0xFFA3271C),
    Color(0xFFCC3426),
    Color(0xFFF04A38),
    Color(0xFFFF7A66),
  ],
  SkotiqMarkTone.mono: [
    Color(0xFFEDEAF7),
    Color(0xFFEDEAF7),
    Color(0xFFEDEAF7),
    Color(0xFFEDEAF7),
    Color(0xFFEDEAF7),
  ],
};

/// Picks the detail level for a logical pixel size: [TrailsLevel.full] from
/// 64 px, [TrailsLevel.mid] from 24 to 63, [TrailsLevel.flat] below 24.
TrailsLevel trailsLevelForSize(double size) {
  if (size >= 64) return TrailsLevel.full;
  if (size >= 24) return TrailsLevel.mid;
  return TrailsLevel.flat;
}

/// The three points a lane's two arcs run through: entry, the waist shared
/// by both arcs, and exit. Exposed for tests pinning the reference geometry.
final class TrailsLanePoints {
  const TrailsLanePoints({
    required this.start,
    required this.waist,
    required this.end,
  });

  final Offset start;
  final Offset waist;
  final Offset end;
}

/// Computes a lane's [TrailsLanePoints] — the reference's `pt()` calls.
TrailsLanePoints trailsLanePoints(TrailsLane lane) {
  final ru = TrailsGeometry.centerlineRadius + lane.offset;
  final rl = TrailsGeometry.centerlineRadius - lane.offset;
  return TrailsLanePoints(
    start: TrailsGeometry.polarPoint(
      TrailsGeometry.centerX,
      TrailsGeometry.upperCenterY,
      ru,
      lane.upStartDegrees,
    ),
    waist: TrailsGeometry.polarPoint(
      TrailsGeometry.centerX,
      TrailsGeometry.upperCenterY,
      ru,
      90,
    ),
    end: TrailsGeometry.polarPoint(
      TrailsGeometry.centerX,
      TrailsGeometry.lowerCenterY,
      rl,
      lane.loEndDegrees,
    ),
  );
}

/// Builds a lane as a [Path] of two arcs — the reference's `lane()` and its
/// SVG `A` commands. The upper arc runs counterclockwise from the entry
/// angle to the waist, the lower clockwise from the waist to the exit; each
/// takes the large-arc flag when its angular sweep exceeds 180°.
Path trailsLanePath(TrailsLane lane) {
  final ru = TrailsGeometry.centerlineRadius + lane.offset;
  final rl = TrailsGeometry.centerlineRadius - lane.offset;
  final p = trailsLanePoints(lane);
  // sweep_up = (up_start - (90 - 360)) % 360; large when the run exceeds
  // half the circle. Same for sweep_lo against -90°. Dart's % matches
  // Python's here — non-negative for a positive modulus.
  final largeUp = (lane.upStartDegrees + 270) % 360 > 180;
  final largeLo = (lane.loEndDegrees + 90) % 360 > 180;
  return Path()
    ..moveTo(p.start.dx, p.start.dy)
    ..arcToPoint(
      p.waist,
      radius: Radius.circular(ru),
      largeArc: largeUp,
      clockwise: false,
    )
    ..arcToPoint(
      p.end,
      radius: Radius.circular(rl),
      largeArc: largeLo,
      clockwise: true,
    );
}
