// The altitude floor as samples by azimuth, and the search for when a target
// clears and leaves it.

import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

void main() {
  // Trees to 40 degrees from north-east to south-east, open sky elsewhere.
  const trees = AltitudeFloorSamples(
    [0, 44, 45, 135, 136, 359],
    [0, 0, 40, 40, 0, 0],
  );
  const latitude = 40.0;
  const longitude = -75.0;
  final night = DateTime.utc(2026, 1, 15, 3);

  group('AltitudeFloorSamples', () {
    test('interpolates between samples and wraps past north', () {
      expect(trees.at(90), 40);
      expect(trees.at(44.5), closeTo(20, 1e-9));
      expect(trees.at(270), 0);
      expect(trees.at(359.5), 0);
      expect(trees.at(-270), 40, reason: 'azimuth -270 is due east');
      expect(trees.at(450), 40);
      expect(trees.isFlat, isFalse);
    });

    test('one sample is the same floor in every direction', () {
      final flat = AltitudeFloorSamples.flat(30);
      expect(flat.isFlat, isTrue);
      expect(flat.at(0), 30);
      expect(flat.at(123.4), 30);
    });
  });

  group('against a floor that changes with direction', () {
    // RA 10 h rises in the east, RA 1.5 h is setting in the west; both are
    // 30 to 40 degrees up at [night].
    test('an eastern target is below until it clears the trees; a western '
        'one is above', () {
      bool above(double raHours) => targetIsAboveFloor(
        trees.at,
        raDeg: raHours * 15,
        decDeg: 20,
        at: night,
        latitudeDeg: latitude,
        longitudeDeg: longitude,
      );
      expect(above(10), isFalse);
      expect(above(1.5), isTrue);

      final clears = firstTimeAgainstFloor(
        trees.at,
        raDeg: 150,
        decDeg: 20,
        from: night,
        until: night.add(const Duration(hours: 8)),
        latitudeDeg: latitude,
        longitudeDeg: longitude,
        above: true,
      )!;
      final (alt, az) = AstronomyCalculations.objectAltAz(
        raDeg: 150,
        decDeg: 20,
        dt: clears,
        latitudeDeg: latitude,
        longitudeDeg: longitude,
      );
      expect(az, inInclusiveRange(45, 135));
      expect(alt, closeTo(40, 0.3));
    });

    test('rise and set are reported where the target crosses the floor', () {
      final visibility = objectVisibilityAboveFloor(
        trees.at,
        raDeg: 150,
        decDeg: 20,
        center: night.add(const Duration(hours: 4)),
        latitudeDeg: latitude,
        longitudeDeg: longitude,
      );
      expect(visibility.neverRises, isFalse);
      expect(visibility.riseTime, isNotNull);
      expect(visibility.setTime, isNotNull);
      // It rises through the trees and sets over the open western horizon.
      double altitudeAt(DateTime t) => AstronomyCalculations.objectAltAz(
        raDeg: 150,
        decDeg: 20,
        dt: t,
        latitudeDeg: latitude,
        longitudeDeg: longitude,
      ).$1;
      expect(altitudeAt(visibility.riseTime!), closeTo(40, 0.3));
      expect(altitudeAt(visibility.setTime!), closeTo(0, 0.3));
    });

    test('a target that never clears the floor never rises', () {
      final visibility = objectVisibilityAboveFloor(
        (_) => 80,
        raDeg: 150,
        decDeg: 20,
        center: night,
        latitudeDeg: latitude,
        longitudeDeg: longitude,
      );
      expect(visibility.neverRises, isTrue);
      expect(visibility.riseTime, isNull);
      expect(visibility.setTime, isNull);
    });
  });

  test('Best Targets drops a target that stays behind the horizon in '
      'darkness and keeps it under an open sky', () {
    final nightDate = DateTime(2026, 1, 14);
    List<TonightRanking> rank(AltitudeFloorSamples floor) => rankTonightTargets(
      // Declination -10 culminates 40 degrees up, due south.
      raDeg: [90],
      decDeg: [-10],
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      nightDate: nightDate,
      floor: floor,
    );
    expect(rank(AltitudeFloorSamples.flat(30)), isNotEmpty);
    // A ridge to 50 degrees across the whole southern sky.
    const ridge = AltitudeFloorSamples(
      [0, 89, 90, 270, 271, 359],
      [0, 0, 50, 50, 0, 0],
    );
    expect(rank(ridge), isEmpty);
  });
}
