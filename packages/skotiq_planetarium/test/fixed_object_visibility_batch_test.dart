import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

List<Object?> fields(ObjectVisibility v) => [
  v.riseTime,
  v.transitTime,
  v.setTime,
  v.transitAltitude,
  v.isCircumpolar,
  v.neverRises,
];

class _Target implements CelestialObject {
  @override
  final CelestialCoordinate coordinates;
  _Target(double ra, double dec)
    : coordinates = CelestialCoordinate(ra: ra, dec: dec);
  @override
  String get id => '$coordinates';
  @override
  String get name => id;
  @override
  double? get magnitude => null;
}

List<Object?> scoreFields(TargetScore s) {
  final v = s.visibility;
  return [
    s.totalScore,
    s.altitudeScore,
    s.airmassScore,
    s.darknessScore,
    s.moonDistanceScore,
    s.transitProximityScore,
    v.currentAltitude,
    v.currentAzimuth,
    v.airmass,
    v.moonDistance,
    v.riseTime,
    v.transitTime,
    v.setTime,
    v.transitAltitude,
    v.isCircumpolar,
    v.neverRises,
    v.peakAltitude,
    v.peakAzimuth,
    v.peakAltitudeTime,
    v.hoursAboveMinAlt,
    s.warnings
        .map((w) => [w.type, w.severity, w.message, w.suggestion])
        .toList(),
  ];
}

void main() {
  test(
    'batch scores preserve order, skyline constraints, warnings and timing',
    () {
      final targets = [
        _Target(1.6117, 15.7836),
        _Target(2.3759, 42.3492),
        _Target(0, 89),
        _Target(12, -80),
      ];
      final start = DateTime.utc(2026, 10, 31, 23);
      final end = start.add(const Duration(hours: 10));
      for (final horizon in <HorizonMask?>[
        null,
        (_) => 90,
        (az) => az > 180 ? 55 : 10,
      ]) {
        final scorer = TargetScoringService(
          latitude: 39.9719,
          longitude: -75.3576,
          observationTime: start,
          moonPosition: (80, 20),
          moonIllumination: 0.7,
          horizonMask: horizon,
        );
        final expected = targets
            .map(
              (t) => scoreFields(
                scorer.scoreTargetForNight(
                  target: t,
                  nightStart: start,
                  nightEnd: end,
                  minAltitude: 30,
                ),
              ),
            )
            .toList();
        final actual = scorer
            .scoreTargetsForNight(
              targets: targets,
              nightStart: start,
              nightEnd: end,
              minAltitude: 30,
            )
            .map(scoreFields)
            .toList();
        expect(actual, expected);
      }
    },
  );

  test(
    'shared time samples preserve all fixed-object visibility results exactly',
    () {
      for (final latitude in [-70.0, -33.0, 0.0, 39.97, 70.0]) {
        for (final date in [
          DateTime(2026, 3, 8),
          DateTime(2026, 10, 31),
          DateTime.utc(2026, 11, 1),
        ]) {
          final batch = FixedObjectVisibilityCalculator(
            date: date,
            latitudeDeg: latitude,
            longitudeDeg: -75.36,
          );
          for (final dec in [-89.0, -60.0, -10.0, 0.0, 15.78, 60.0, 89.0]) {
            for (var ra = 0.0; ra < 360; ra += 45) {
              final expected = AstronomyCalculations.calculateObjectVisibility(
                raDeg: ra,
                decDeg: dec,
                date: date,
                latitudeDeg: latitude,
                longitudeDeg: -75.36,
              );
              expect(
                fields(batch.calculate(raDeg: ra, decDeg: dec)),
                fields(expected),
                reason: '$latitude $date RA=$ra Dec=$dec',
              );
            }
          }
        }
      }
    },
  );
}
