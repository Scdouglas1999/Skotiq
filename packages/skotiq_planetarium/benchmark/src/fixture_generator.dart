// Seeded, deterministic generator for the planetarium stress fixture.
//
// Produces a worst-case-dense synthetic sky around a fixed anchor so the paint
// benchmark exercises the hot loops (dense star atlas pass, many DSO glyphs,
// constellation lines, Milky Way band). Everything is driven by a single fixed
// integer seed via [math.Random] — no wall-clock, no network, no live catalog —
// so re-running yields byte-identical output.
//
// This is the *source of truth* for the committed fixtures/stress_scene.json.
// Run it via tools/generate_fixture.dart when you intentionally want to change
// the stress scene.

import 'dart:math' as math;

import 'package:skotiq_planetarium/src/astronomy/milky_way_data.dart';
import 'package:skotiq_planetarium/src/astronomy/planetary_positions.dart';
import 'package:skotiq_planetarium/src/catalogs/constellation_data.dart';
import 'package:skotiq_planetarium/src/celestial_object.dart';
import 'package:skotiq_planetarium/src/coordinate_system.dart';

import 'stress_fixture.dart';

/// Fixed RNG seed. Any value works; pinning it is what makes the field
/// reproducible. Do not derive from the clock.
const int kFixtureSeed = 0x5EED5301;

/// Scene anchor (a Milky-Way-rich winter region near Orion / Monoceros) chosen
/// so the Milky Way band, dense star fields and many DSOs all fall inside the
/// camera path. RA in hours, Dec in degrees.
const double kAnchorRaHours = 6.0;
const double kAnchorDecDeg = 5.0;

/// Half-width of the populated patch (degrees). The camera timeline pans/zooms
/// within this patch so the visible set stays dense at every keyframe.
const double kPatchHalfWidthDeg = 30.0;

/// Counts tuned so a wide (~60 deg FOV) frame is genuinely worst-case dense
/// while staying small enough to commit and load quickly.
const int kStarCount = 14000;
const int kDsoCount = 900;
const double kStarMagBright = 1.0;
const double kStarMagFaint = 13.0;

/// Build the full stress fixture from the fixed seed.
StressFixture generateStressFixture() {
  final rng = math.Random(kFixtureSeed);

  final stars = _generateStars(rng);
  final dsos = _generateDsos(rng);
  final constellations = _generateConstellations(rng);
  // Real Milky Way band geometry (deterministic — no RNG). The full all-sky
  // band is generated; the renderer culls to the FOV per frame.
  final milkyWay = MilkyWayData.generateMilkyWayPoints(
    longitudeSteps: 144,
    latitudeSteps: 21,
  );
  final planets = _planets();

  final composition =
      '''
Seeded synthetic worst-case stress scene (seed 0x${kFixtureSeed.toRadixString(16)}).
Anchor: RA ${kAnchorRaHours}h Dec $kAnchorDecDeg deg, patch +/-$kPatchHalfWidthDeg deg.
Stars: $kStarCount over mag $kStarMagBright..$kStarMagFaint (steep faint-end power law).
DSOs: $kDsoCount of mixed types (galaxies/nebulae/clusters) with extents 0.5..60 arcmin.
Constellation line figures: ${constellations.length} sets, ${constellations.fold<int>(0, (a, c) => a + c.lines.length)} segments.
Milky Way: ${milkyWay.length} band points (144x21 galactic grid).
Planets: ${planets.length}. Observer 40N 75W. Base time 2026-01-15T06:00:00Z.''';

  return StressFixture(
    composition: composition,
    seed: kFixtureSeed,
    stars: stars,
    dsos: dsos,
    constellations: constellations,
    milkyWayPoints: milkyWay,
    planets: planets,
    latitude: 40.0,
    longitude: -75.0,
    baseTimeUtc: DateTime.utc(2026, 1, 15, 6, 0, 0),
    sunPosition: (kAnchorRaHours + 12.0, -20.0),
    // Illumination is a PERCENT (SkyCanvasPainter.moonPosition); 55 keeps the
    // scene identical to the frozen baseline, which was captured when this slot
    // was fed the fraction 0.55.
    moonPosition: (kAnchorRaHours + 1.5, kAnchorDecDeg + 4.0, 55.0),
  );
}

/// Random RA (hours) / Dec (deg) inside the populated patch, with Dec drawn so
/// the angular area is roughly uniform (avoids a pole-pinched cluster).
(double ra, double dec) _randomInPatch(math.Random rng) {
  final decMin = (kAnchorDecDeg - kPatchHalfWidthDeg).clamp(-89.0, 89.0);
  final decMax = (kAnchorDecDeg + kPatchHalfWidthDeg).clamp(-89.0, 89.0);
  final dec = decMin + rng.nextDouble() * (decMax - decMin);
  // Widen RA spread by 1/cos(dec) so projected density stays even.
  final cosDec = math.cos(dec * math.pi / 180).clamp(0.2, 1.0);
  final raHalfHours = (kPatchHalfWidthDeg / 15.0) / cosDec;
  var ra = kAnchorRaHours + (rng.nextDouble() * 2 - 1) * raHalfHours;
  ra = ra % 24.0;
  if (ra < 0) ra += 24.0;
  return (ra, dec);
}

List<Star> _generateStars(math.Random rng) {
  final stars = <Star>[];
  for (var i = 0; i < kStarCount; i++) {
    final (ra, dec) = _randomInPatch(rng);
    // Steep faint-end distribution: cube the uniform draw so most stars sit
    // near the faint limit (mimics a real magnitude histogram and stresses the
    // dim-star atlas batch hardest).
    final u = rng.nextDouble();
    final mag = kStarMagBright + (kStarMagFaint - kStarMagBright) * (u * u);
    // B-V color index spread -0.3..1.8 so the color-graded sprite path runs.
    final colorIndex = -0.3 + rng.nextDouble() * 2.1;
    stars.add(
      Star(
        id: 'BENCH-STAR-$i',
        name: 'BENCH-STAR-$i',
        coordinates: CelestialCoordinate(ra: ra, dec: dec),
        magnitude: double.parse(mag.toStringAsFixed(3)),
        colorIndex: double.parse(colorIndex.toStringAsFixed(3)),
      ),
    );
  }
  return stars;
}

List<DeepSkyObject> _generateDsos(math.Random rng) {
  // A representative mix weighted toward galaxies (the deepest, most numerous
  // real catalogs) but covering clusters and nebulae so every glyph branch in
  // the DSO painter is exercised.
  const palette = <DsoType>[
    DsoType.galaxy,
    DsoType.galaxy,
    DsoType.galaxy,
    DsoType.openCluster,
    DsoType.globularCluster,
    DsoType.planetaryNebula,
    DsoType.emissionNebula,
    DsoType.reflectionNebula,
    DsoType.nebula,
    DsoType.supernova,
  ];
  final dsos = <DeepSkyObject>[];
  for (var i = 0; i < kDsoCount; i++) {
    final (ra, dec) = _randomInPatch(rng);
    final type = palette[rng.nextInt(palette.length)];
    // Sizes 0.5..60 arcmin; small ones render as points, big ones as ellipses.
    final major = 0.5 + rng.nextDouble() * 59.5;
    final axisRatio = 0.3 + rng.nextDouble() * 0.7;
    final minor = major * axisRatio;
    final pa = rng.nextDouble() * 180.0;
    final mag = 6.0 + rng.nextDouble() * 7.0; // 6..13
    dsos.add(
      DeepSkyObject(
        id: 'BENCH-DSO-$i',
        name: 'BENCH-DSO-$i',
        coordinates: CelestialCoordinate(ra: ra, dec: dec),
        type: type,
        magnitude: double.parse(mag.toStringAsFixed(2)),
        sizeArcMin: double.parse(major.toStringAsFixed(2)),
        minorAxisArcMin: double.parse(minor.toStringAsFixed(2)),
        positionAngle: double.parse(pa.toStringAsFixed(1)),
      ),
    );
  }
  return dsos;
}

/// Synthetic constellation line figures: a handful of multi-segment polylines
/// scattered across the patch so the constellation-line and label layers carry
/// real work without depending on the bundled catalog.
List<ConstellationData> _generateConstellations(math.Random rng) {
  const figureCount = 18;
  final out = <ConstellationData>[];
  for (var f = 0; f < figureCount; f++) {
    final (cra, cdec) = _randomInPatch(rng);
    final segCount = 5 + rng.nextInt(8); // 5..12 segments
    final lines = <ConstellationLine>[];
    var (pra, pdec) = (cra, cdec);
    for (var s = 0; s < segCount; s++) {
      final nra = pra + (rng.nextDouble() * 2 - 1) * 1.2; // up to ~1.2h step
      final ndec = (pdec + (rng.nextDouble() * 2 - 1) * 8.0).clamp(-89.0, 89.0);
      lines.add(
        ConstellationLine(
          start: CelestialCoordinate(ra: pra, dec: pdec),
          end: CelestialCoordinate(ra: nra, dec: ndec),
        ),
      );
      pra = nra;
      pdec = ndec;
    }
    out.add(
      ConstellationData(
        abbreviation: 'B$f',
        name: 'Bench Figure $f',
        lines: lines,
        center: CelestialCoordinate(ra: cra, dec: cdec),
      ),
    );
  }
  return out;
}

List<PlanetData> _planets() => const [
  PlanetData(
    name: 'Jupiter',
    ra: 6.4,
    dec: 6.0,
    magnitude: -2.3,
    color: 0xFFFFD180,
  ),
  PlanetData(
    name: 'Mars',
    ra: 5.6,
    dec: 8.0,
    magnitude: 0.9,
    color: 0xFFFF7043,
  ),
  PlanetData(
    name: 'Saturn',
    ra: 7.1,
    dec: 2.0,
    magnitude: 0.6,
    color: 0xFFFFE082,
  ),
  PlanetData(
    name: 'Venus',
    ra: 4.9,
    dec: 1.0,
    magnitude: -4.0,
    color: 0xFFFFFFFF,
  ),
];
