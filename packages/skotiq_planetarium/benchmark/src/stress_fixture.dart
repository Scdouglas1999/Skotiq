// Deterministic stress-scene fixture for the planetarium paint benchmark.
//
// The fixture is a *committed* JSON file (benchmark/fixtures/stress_scene.json)
// describing a dense, worst-case sky: many stars to a deep magnitude limit, many
// DSOs of mixed types, constellation line figures, a Milky Way band and the
// solar-system bodies. It is loaded from disk at benchmark time so the run is
// fully offline and reproducible run-to-run (no live catalog download, no
// network, no wall-clock input).
//
// The JSON is produced once by `tools/generate_fixture.dart` from a seeded RNG
// (fixed numeric seed) so re-running the generator yields byte-identical output.
// The benchmark itself never regenerates — it only reads the committed file.

import 'dart:convert';
import 'dart:io';

import 'package:skotiq_planetarium/src/astronomy/milky_way_data.dart';
import 'package:skotiq_planetarium/src/astronomy/planetary_positions.dart';
import 'package:skotiq_planetarium/src/catalogs/constellation_data.dart';
import 'package:skotiq_planetarium/src/celestial_object.dart';
import 'package:skotiq_planetarium/src/coordinate_system.dart';

/// The current on-disk schema version of the fixture JSON. Bump when the shape
/// of [StressFixture.toJson] changes so a stale fixture fails loudly instead of
/// silently decoding into a degenerate scene.
const int kStressFixtureSchemaVersion = 1;

/// A fully-materialised stress scene: the catalog objects the benchmark feeds
/// straight into [SkyCanvasPainter], plus the observer/time context.
class StressFixture {
  /// Free-form description of how this fixture was generated (seed, counts,
  /// magnitude limits) so a reader of results can reproduce it.
  final String composition;

  /// Numeric RNG seed the generator used. Recorded for reproducibility.
  final int seed;

  final List<Star> stars;
  final List<DeepSkyObject> dsos;
  final List<ConstellationData> constellations;
  final List<MilkyWayPoint> milkyWayPoints;
  final List<PlanetData> planets;

  /// Observer latitude/longitude (degrees) used for the alt/az-dependent layers
  /// (horizon, ground plane, atmospheric extinction).
  final double latitude;
  final double longitude;

  /// Base observation instant. The camera timeline advances simulated time from
  /// this anchor; it is a fixed UTC value so timing inputs never read the wall
  /// clock.
  final DateTime baseTimeUtc;

  /// Sun / Moon positions (RA hours, Dec deg [, illumination]).
  final (double, double) sunPosition;
  final (double, double, double) moonPosition;

  const StressFixture({
    required this.composition,
    required this.seed,
    required this.stars,
    required this.dsos,
    required this.constellations,
    required this.milkyWayPoints,
    required this.planets,
    required this.latitude,
    required this.longitude,
    required this.baseTimeUtc,
    required this.sunPosition,
    required this.moonPosition,
  });

  Map<String, dynamic> toJson() => {
    'schemaVersion': kStressFixtureSchemaVersion,
    'composition': composition,
    'seed': seed,
    'latitude': latitude,
    'longitude': longitude,
    'baseTimeUtcMs': baseTimeUtc.toUtc().millisecondsSinceEpoch,
    'sun': [sunPosition.$1, sunPosition.$2],
    'moon': [moonPosition.$1, moonPosition.$2, moonPosition.$3],
    'stars': [
      for (final s in stars)
        [s.id, s.coordinates.ra, s.coordinates.dec, s.magnitude, s.colorIndex],
    ],
    'dsos': [
      for (final d in dsos)
        [
          d.id,
          d.name,
          d.coordinates.ra,
          d.coordinates.dec,
          d.magnitude,
          d.type.index,
          d.sizeArcMin,
          d.minorAxisArcMin,
          d.positionAngle,
        ],
    ],
    'constellations': [
      for (final c in constellations)
        {
          'abbr': c.abbreviation,
          'name': c.name,
          'centerRa': c.center.ra,
          'centerDec': c.center.dec,
          'lines': [
            for (final l in c.lines)
              [l.start.ra, l.start.dec, l.end.ra, l.end.dec],
          ],
        },
    ],
    'milkyWay': [
      for (final p in milkyWayPoints)
        [p.ra, p.dec, p.intensity, p.galacticLon, p.galacticLat],
    ],
    'planets': [
      for (final p in planets) [p.name, p.ra, p.dec, p.magnitude, p.color],
    ],
  };

  factory StressFixture.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'] as int? ?? 0;
    if (version != kStressFixtureSchemaVersion) {
      throw StateError(
        'Stress fixture schema mismatch: file is v$version, '
        'code expects v$kStressFixtureSchemaVersion. '
        'Regenerate with tools/generate_fixture.dart.',
      );
    }

    List<num> nums(dynamic v) => (v as List).cast<num>();

    final stars = <Star>[
      for (final raw in (json['stars'] as List))
        () {
          final r = raw as List;
          return Star(
            id: r[0] as String,
            name: r[0] as String,
            coordinates: CelestialCoordinate(
              ra: (r[1] as num).toDouble(),
              dec: (r[2] as num).toDouble(),
            ),
            magnitude: (r[3] as num).toDouble(),
            colorIndex: (r[4] as num?)?.toDouble(),
          );
        }(),
    ];

    final dsos = <DeepSkyObject>[
      for (final raw in (json['dsos'] as List))
        () {
          final r = raw as List;
          return DeepSkyObject(
            id: r[0] as String,
            name: r[1] as String,
            coordinates: CelestialCoordinate(
              ra: (r[2] as num).toDouble(),
              dec: (r[3] as num).toDouble(),
            ),
            magnitude: (r[4] as num?)?.toDouble(),
            type: DsoType.values[r[5] as int],
            sizeArcMin: (r[6] as num?)?.toDouble(),
            minorAxisArcMin: (r[7] as num?)?.toDouble(),
            positionAngle: (r[8] as num?)?.toDouble(),
          );
        }(),
    ];

    final constellations = <ConstellationData>[
      for (final raw in (json['constellations'] as List))
        () {
          final c = raw as Map<String, dynamic>;
          return ConstellationData(
            abbreviation: c['abbr'] as String,
            name: c['name'] as String,
            center: CelestialCoordinate(
              ra: (c['centerRa'] as num).toDouble(),
              dec: (c['centerDec'] as num).toDouble(),
            ),
            lines: [
              for (final l in (c['lines'] as List))
                () {
                  final n = nums(l);
                  return ConstellationLine(
                    start: CelestialCoordinate(
                      ra: n[0].toDouble(),
                      dec: n[1].toDouble(),
                    ),
                    end: CelestialCoordinate(
                      ra: n[2].toDouble(),
                      dec: n[3].toDouble(),
                    ),
                  );
                }(),
            ],
          );
        }(),
    ];

    final milkyWay = <MilkyWayPoint>[
      for (final raw in (json['milkyWay'] as List))
        () {
          final n = nums(raw);
          return MilkyWayPoint(
            ra: n[0].toDouble(),
            dec: n[1].toDouble(),
            intensity: n[2].toDouble(),
            galacticLon: n[3].toDouble(),
            galacticLat: n[4].toDouble(),
          );
        }(),
    ];

    final planets = <PlanetData>[
      for (final raw in (json['planets'] as List))
        () {
          final r = raw as List;
          return PlanetData(
            name: r[0] as String,
            ra: (r[1] as num).toDouble(),
            dec: (r[2] as num).toDouble(),
            magnitude: (r[3] as num).toDouble(),
            color: r[4] as int,
          );
        }(),
    ];

    final sun = nums(json['sun']);
    final moon = nums(json['moon']);

    return StressFixture(
      composition: json['composition'] as String,
      seed: json['seed'] as int,
      stars: stars,
      dsos: dsos,
      constellations: constellations,
      milkyWayPoints: milkyWay,
      planets: planets,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      baseTimeUtc: DateTime.fromMillisecondsSinceEpoch(
        json['baseTimeUtcMs'] as int,
        isUtc: true,
      ),
      sunPosition: (sun[0].toDouble(), sun[1].toDouble()),
      moonPosition: (
        moon[0].toDouble(),
        moon[1].toDouble(),
        moon[2].toDouble(),
      ),
    );
  }

  /// Absolute path to the committed fixture JSON, resolved relative to the
  /// package root. `flutter test` runs with the package directory as the
  /// current working directory, so the relative path is stable.
  static String defaultPath() => 'benchmark/fixtures/stress_scene.json';

  /// Load the committed fixture from [path] (defaults to [defaultPath]).
  static StressFixture load([String? path]) {
    final file = File(path ?? defaultPath());
    if (!file.existsSync()) {
      throw StateError(
        'Stress fixture not found at ${file.absolute.path}. '
        'Generate it with: dart run tools/generate_fixture.dart',
      );
    }
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return StressFixture.fromJson(json);
  }
}
