// The transit a night's score reports is the culmination during that night,
// whatever the host computer's time zone and whether a daylight-saving change
// falls inside it.
import 'package:test/test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

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

const double _latitude = 39.9;
const double _longitude = 116.4;

/// A target on the meridian at [instant] for the test site.
_Target _transitingAt(DateTime instant) =>
    _Target(AstronomyCalculations.localSiderealTime(instant, _longitude), 24);

void _expectTransitNear(DateTime? actual, DateTime expected, String label) {
  expect(actual, isNotNull, reason: label);
  final error = actual!.difference(expected).inSeconds.abs();
  expect(
    error,
    lessThan(90),
    reason:
        '$label: transit reported at ${actual.toUtc()}, the night culminates '
        'at ${expected.toUtc()}',
  );
}

void main() {
  // The night's midpoint sits just before the host's local noon, so the
  // host's noon-to-noon day ends one hour into the second half of the night.
  // A site far from the host's zone (a Beijing rig planned from New York)
  // lands here.
  final nightMid = DateTime(2026, 11, 1, 11);
  final nightStart = nightMid.subtract(const Duration(hours: 5));
  final nightEnd = nightMid.add(const Duration(hours: 5));
  final culmination = nightMid.add(const Duration(hours: 3));

  TargetScoringService scorer() => TargetScoringService(
    latitude: _latitude,
    longitude: _longitude,
    observationTime: nightStart,
  );

  test('a single score reports the transit inside the night', () {
    final score = scorer().scoreTargetForNight(
      target: _transitingAt(culmination),
      nightStart: nightStart,
      nightEnd: nightEnd,
    );
    _expectTransitNear(score.visibility.transitTime, culmination, 'single');
  });

  test('a catalog score reports the transit inside the night', () {
    final score = scorer()
        .scoreTargetsForNight(
          targets: [_transitingAt(culmination)],
          nightStart: nightStart,
          nightEnd: nightEnd,
        )
        .single;
    _expectTransitNear(score.visibility.transitTime, culmination, 'batch');
  });

  test('a night spanning the end of US daylight time keeps its transit', () {
    // New York falls back at 06:00 UTC on 1 November 2026. A night at a
    // western-hemisphere site from 22:00 UTC to 10:00 UTC spans it.
    final start = DateTime.utc(2026, 10, 31, 22);
    final end = DateTime.utc(2026, 11, 1, 10);
    final culminationUtc = DateTime.utc(2026, 11, 1, 8);
    final westScorer = TargetScoringService(
      latitude: 39.97,
      longitude: -75.36,
      observationTime: start,
    );
    final target = _Target(
      AstronomyCalculations.localSiderealTime(culminationUtc, -75.36),
      24,
    );
    for (final score in [
      westScorer.scoreTargetForNight(
        target: target,
        nightStart: start,
        nightEnd: end,
      ),
      westScorer
          .scoreTargetsForNight(
            targets: [target],
            nightStart: start,
            nightEnd: end,
          )
          .single,
    ]) {
      _expectTransitNear(score.visibility.transitTime, culminationUtc, 'DST');
    }
  });
}
