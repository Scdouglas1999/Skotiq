// The night's span above the altitude floor is what the planner draws as a
// target's window tonight; it must be the same span the "hours above the
// floor" figure counts, not the target's horizon rise and set.

import 'package:test/test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

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
  const lat = 40.0;
  const lon = -75.0;
  const dec = 30.0;
  final nightStart = DateTime(2026, 11, 15, 18, 30);
  final nightEnd = DateTime(2026, 11, 16, 5, 30);

  double altitudeAt(double ra, DateTime when) =>
      AstronomyCalculations.objectAltAz(
        raDeg: ra * 15.0,
        decDeg: dec,
        dt: when,
        latitudeDeg: lat,
        longitudeDeg: lon,
      ).$1;

  TargetScore score(double ra, double floor) =>
      TargetScoringService(
        latitude: lat,
        longitude: lon,
        observationTime: nightStart,
        floorAt: (_) => floor,
      ).scoreTargetForNight(
        target: _Fixture(
          id: 'ra$ra',
          name: 'ra$ra',
          coordinates: CelestialCoordinate(ra: ra, dec: dec),
        ),
        nightStart: nightStart,
        nightEnd: nightEnd,
      );

  // A target high at dusk that sinks below 30 degrees during the night but
  // stays above the horizon until after dawn's start of the search window.
  final ra = [for (var r = 0.0; r < 24; r += 0.25) r].firstWhere(
    (r) =>
        altitudeAt(r, nightStart) > 60 &&
        altitudeAt(r, nightEnd.subtract(const Duration(hours: 4))) < 30 &&
        altitudeAt(r, nightEnd.subtract(const Duration(hours: 4))) > 0,
  );

  test(
    'the span above a 30 degree floor ends when the target sinks below it',
    () {
      final visibility = score(ra, 30).visibility;
      final from = visibility.aboveFloorFrom!;
      final until = visibility.aboveFloorUntil!;

      expect(from, nightStart);
      expect(until.isBefore(nightEnd), isTrue);
      expect(altitudeAt(ra, until), lessThan(31));
      expect(
        until.difference(from).inMinutes / 60,
        closeTo(visibility.hoursAboveMinAlt!, 1e-9),
      );
    },
  );

  test('the span follows the floor, not the horizon', () {
    final horizon = score(ra, 0).visibility;
    final floor = score(ra, 30).visibility;

    expect(horizon.aboveFloorUntil!.isAfter(floor.aboveFloorUntil!), isTrue);
  });

  test('a target that never clears the floor has no span', () {
    final visibility = score(ra, 89).visibility;

    expect(visibility.aboveFloorFrom, isNull);
    expect(visibility.aboveFloorUntil, isNull);
  });
}
