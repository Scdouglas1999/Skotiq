import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// Tests for the meridian / meridian-flip geometry that feeds the planetarium's
/// on-sky planning overlays (and mirrors the sequencer's flip logic). Framed
/// around physical invariants — hour angle at transit is ~0, the flip time is
/// the transit, the deadline trails the transit by the past-meridian limit —
/// so they hold regardless of the test machine's local timezone.
void main() {
  // New York City.
  const lat = 40.7128;
  const lon = -74.0060;

  group('hourAngleDeg', () {
    test('is zero (within a hair) at the target meridian transit', () {
      // A target near the celestial equator that transits tonight.
      const raDeg = 90.0; // 6h
      const decDeg = 10.0;
      final visibility = AstronomyCalculations.calculateObjectVisibility(
        raDeg: raDeg,
        decDeg: decDeg,
        date: DateTime(2024, 3, 20),
        latitudeDeg: lat,
        longitudeDeg: lon,
      );
      expect(visibility.transitTime, isNotNull);

      final ha = AstronomyCalculations.hourAngleDeg(
        raDeg: raDeg,
        dt: visibility.transitTime!,
        longitudeDeg: lon,
      );
      // Sub-minute transit refinement → well under 0.25 deg (1 min of time).
      expect(ha.abs(), lessThan(0.25));
    });

    test('is normalised to (-180, 180]', () {
      // Sweep a full sidereal day; HA must always stay in range.
      const raDeg = 200.0;
      final base = DateTime.utc(2024, 6, 1);
      for (var h = 0; h < 24; h++) {
        final ha = AstronomyCalculations.hourAngleDeg(
          raDeg: raDeg,
          dt: base.add(Duration(hours: h)),
          longitudeDeg: lon,
        );
        expect(ha, greaterThan(-180.0));
        expect(ha, lessThanOrEqualTo(180.0));
      }
    });

    test('increases with time (target drifts west) at ~15.04 deg/hour', () {
      const raDeg = 120.0;
      final t0 = DateTime.utc(2024, 6, 1, 2);
      final t1 = t0.add(const Duration(hours: 1));
      final ha0 = AstronomyCalculations.hourAngleDeg(
        raDeg: raDeg,
        dt: t0,
        longitudeDeg: lon,
      );
      final ha1 = AstronomyCalculations.hourAngleDeg(
        raDeg: raDeg,
        dt: t1,
        longitudeDeg: lon,
      );
      // One sidereal hour ≈ 15.041 deg of hour-angle advance.
      expect(ha1 - ha0, closeTo(15.041, 0.05));
    });

    test('east of meridian is negative, west is positive', () {
      const raDeg = 80.0;
      const decDeg = 5.0;
      final visibility = AstronomyCalculations.calculateObjectVisibility(
        raDeg: raDeg,
        decDeg: decDeg,
        date: DateTime(2024, 9, 1),
        latitudeDeg: lat,
        longitudeDeg: lon,
      );
      final transit = visibility.transitTime!;
      final before = AstronomyCalculations.hourAngleDeg(
        raDeg: raDeg,
        dt: transit.subtract(const Duration(hours: 1)),
        longitudeDeg: lon,
      );
      final after = AstronomyCalculations.hourAngleDeg(
        raDeg: raDeg,
        dt: transit.add(const Duration(hours: 1)),
        longitudeDeg: lon,
      );
      expect(before, lessThan(0)); // east of meridian
      expect(after, greaterThan(0)); // west of meridian
    });
  });

  group('calculateMeridianFlip', () {
    test('flip time equals the transit time', () {
      const raDeg = 150.0;
      const decDeg = 20.0;
      final date = DateTime(2024, 10, 15);
      final flip = AstronomyCalculations.calculateMeridianFlip(
        raDeg: raDeg,
        decDeg: decDeg,
        date: date,
        latitudeDeg: lat,
        longitudeDeg: lon,
      );
      final visibility = AstronomyCalculations.calculateObjectVisibility(
        raDeg: raDeg,
        decDeg: decDeg,
        date: date,
        latitudeDeg: lat,
        longitudeDeg: lon,
      );
      expect(flip, isNotNull);
      expect(flip!.transitTime, equals(visibility.transitTime));
      // No past-meridian allowance → deadline coincides with the transit.
      expect(flip.flipDeadline, equals(flip.transitTime));
    });

    test(
      'past-meridian allowance pushes the deadline later by that amount',
      () {
        const raDeg = 150.0;
        const decDeg = 20.0;
        final date = DateTime(2024, 10, 15);
        final flip = AstronomyCalculations.calculateMeridianFlip(
          raDeg: raDeg,
          decDeg: decDeg,
          date: date,
          latitudeDeg: lat,
          longitudeDeg: lon,
          pastMeridianMinutes: 20,
        );
        expect(flip, isNotNull);
        expect(
          flip!.flipDeadline.difference(flip.transitTime),
          equals(const Duration(minutes: 20)),
        );
      },
    );

    test('at the flip time the target sits on the meridian (HA ~ 0)', () {
      const raDeg = 60.0;
      const decDeg = 35.0;
      final date = DateTime(2024, 12, 1);
      final flip = AstronomyCalculations.calculateMeridianFlip(
        raDeg: raDeg,
        decDeg: decDeg,
        date: date,
        latitudeDeg: lat,
        longitudeDeg: lon,
      )!;
      final ha = AstronomyCalculations.hourAngleDeg(
        raDeg: raDeg,
        dt: flip.transitTime,
        longitudeDeg: lon,
      );
      expect(ha.abs(), lessThan(0.25));
    });

    test('returns null for a target that never rises', () {
      // Far-southern target from a northern site never transits above horizon;
      // calculateObjectVisibility reports neverRises with a null transit.
      const raDeg = 100.0;
      const decDeg = -85.0;
      final flip = AstronomyCalculations.calculateMeridianFlip(
        raDeg: raDeg,
        decDeg: decDeg,
        date: DateTime(2024, 6, 21),
        latitudeDeg: lat,
        longitudeDeg: lon,
      );
      expect(flip, isNull);
    });
  });
}
