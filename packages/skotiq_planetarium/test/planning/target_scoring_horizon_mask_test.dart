// Feature 3: the night scorer must honor a per-azimuth horizon obstruction
// mask, so "hours above minimum altitude" becomes "hours above the LOCAL
// skyline". A target whose entire nightly track stays behind a hill yields
// zero observable hours and is ranked accordingly.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

class _Fixture implements CelestialObject {
  @override
  final String id;
  @override
  final String name;
  @override
  final CelestialCoordinate coordinates;

  const _Fixture({
    required this.id,
    required this.name,
    required this.coordinates,
  });

  @override
  double? get magnitude => null;
}

void main() {
  // A mid-northern site; a winter night window in UTC.
  const lat = 40.0;
  const lon = -74.0;
  final nightStart = DateTime.utc(2026, 1, 15, 1, 0, 0);
  final nightEnd = DateTime.utc(2026, 1, 15, 11, 0, 0);

  // M42 — rises well above the horizon and transits the southern sky from
  // this site, giving plenty of observable hours under a flat horizon.
  const m42 = _Fixture(
    id: 'm42',
    name: 'M42',
    coordinates: CelestialCoordinate(ra: 5.5880, dec: -5.39),
  );

  group('scoreTargetForNight honors the horizon mask', () {
    test('flat horizon: target has observable hours', () {
      final service = TargetScoringService(
        latitude: lat,
        longitude: lon,
        observationTime: nightStart,
      );
      // observationTime is overridden by the night window for sampling.
      final score = service.scoreTargetForNight(
        target: m42,
        nightStart: nightStart,
        nightEnd: nightEnd,
        minAltitude: 10,
      );
      expect(score.visibility.hoursAboveMinAlt, isNotNull);
      expect(score.visibility.hoursAboveMinAlt!, greaterThan(0));
      expect(score.visibility.peakAltitude!, greaterThan(10));
    });

    test('behind a wall (90° mask everywhere): zero observable hours', () {
      final service = TargetScoringService(
        latitude: lat,
        longitude: lon,
        observationTime: nightStart,
        // A skyline that obstructs the whole sky — nothing clears it.
        horizonMask: _wall,
      );
      final score = service.scoreTargetForNight(
        target: m42,
        nightStart: nightStart,
        nightEnd: nightEnd,
        minAltitude: 10,
      );
      expect(score.visibility.hoursAboveMinAlt, 0.0);
      // With nothing observable the imaging-window score collapses to 0.
      expect(score.darknessScore, 0.0);
      // Best airmass never improves from infinity -> airmass score is 0.
      expect(score.airmassScore, 0.0);
      // Peak altitude still reported for diagnostics (the unobstructed peak).
      expect(score.visibility.peakAltitude!, greaterThan(0));
    });

    test('directional hill removes hours only when target is behind it', () {
      // First, find the azimuth range M42 occupies while above 10° so we can
      // build a hill that blocks exactly that bearing.
      final flat = TargetScoringService(
        latitude: lat,
        longitude: lon,
        observationTime: nightStart,
      );
      final flatScore = flat.scoreTargetForNight(
        target: m42,
        nightStart: nightStart,
        nightEnd: nightEnd,
        minAltitude: 10,
      );
      final flatHours = flatScore.visibility.hoursAboveMinAlt!;
      expect(flatHours, greaterThan(0));

      // A tall hill across the entire southern half of the sky (where M42
      // transits from this site) should remove all observable hours, because
      // M42's peak altitude (~44°) is below the 80° hill.
      final south = TargetScoringService(
        latitude: lat,
        longitude: lon,
        observationTime: nightStart,
        horizonMask: _southernHill,
      );
      final blocked = south.scoreTargetForNight(
        target: m42,
        nightStart: nightStart,
        nightEnd: nightEnd,
        minAltitude: 10,
      );
      expect(blocked.visibility.hoursAboveMinAlt, 0.0);

      // A hill only across the NORTHERN sky must NOT affect M42 (a southern
      // target) — observable hours are unchanged.
      final north = TargetScoringService(
        latitude: lat,
        longitude: lon,
        observationTime: nightStart,
        horizonMask: _northernHill,
      );
      final unaffected = north.scoreTargetForNight(
        target: m42,
        nightStart: nightStart,
        nightEnd: nightEnd,
        minAltitude: 10,
      );
      expect(unaffected.visibility.hoursAboveMinAlt, closeTo(flatHours, 1e-9));
    });

    test('isObservable respects the mask at the current azimuth', () {
      // At a moment M42 is up, a flat scorer says observable; a walled scorer
      // says not.
      final whenUp = DateTime.utc(2026, 1, 15, 6, 0, 0);
      final flatAt = TargetScoringService(
        latitude: lat,
        longitude: lon,
        observationTime: whenUp,
      );
      expect(flatAt.isObservable(m42, minAltitude: 10), isTrue);

      final walledAt = TargetScoringService(
        latitude: lat,
        longitude: lon,
        observationTime: whenUp,
        horizonMask: _wall,
      );
      expect(walledAt.isObservable(m42, minAltitude: 10), isFalse);
    });
  });
}

double _wall(double azimuthDegrees) => 90.0;

double _southernHill(double azimuthDegrees) {
  // Block the southern half of the sky (90°..270°) with an 80° hill.
  return (azimuthDegrees >= 90 && azimuthDegrees <= 270) ? 80.0 : 0.0;
}

double _northernHill(double azimuthDegrees) {
  // Block the northern half (azimuth < 90 or > 270) with an 80° hill.
  return (azimuthDegrees < 90 || azimuthDegrees > 270) ? 80.0 : 0.0;
}
