// Tests for SchedulerService moon illumination and astronomical calculations.
//
// Uses direct imports to avoid pre-existing compilation errors in the wider
// package (polar_alignment_history_dao, equipment_profile type mismatches).
// The SchedulerService itself is pure math with no database dependencies,
// so we instantiate it via ProviderContainer with a targeted import.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/services/scheduler_service.dart';

void main() {
  group('SchedulerService', () {
    late ProviderContainer container;
    late SchedulerService scheduler;

    setUp(() {
      container = ProviderContainer();
      scheduler = container.read(schedulerServiceProvider);
    });

    tearDown(() {
      container.dispose();
    });

    group('calculateMoonPosition - illumination', () {
      // The illumination formula is: (1 - cos(d)) / 2
      // where d is the mean elongation of the moon.
      // New Moon: d ~ 0 deg  -> illumination ~ 0.0
      // Full Moon: d ~ 180 deg -> illumination ~ 1.0
      // Quarter Moon: d ~ 90 or 270 deg -> illumination ~ 0.5

      test('new moon produces illumination near 0.0', () {
        // Jan 13 2021 was a known new moon (UTC)
        final newMoonDate = DateTime.utc(2021, 1, 13, 5, 0);
        final result = scheduler.calculateMoonPosition(newMoonDate);

        // Simplified ephemeris won't be exact, but should be close to 0
        expect(
          result.illumination,
          lessThan(0.15),
          reason: 'New moon illumination should be near 0',
        );
      });

      test('full moon produces illumination near 1.0', () {
        // Jan 28 2021 was a known full moon (UTC)
        final fullMoonDate = DateTime.utc(2021, 1, 28, 19, 16);
        final result = scheduler.calculateMoonPosition(fullMoonDate);

        // Should be close to 1.0
        expect(
          result.illumination,
          greaterThan(0.85),
          reason: 'Full moon illumination should be near 1.0',
        );
      });

      test('first quarter moon produces illumination near 0.5', () {
        // Jan 20 2021 was first quarter moon (UTC)
        final quarterDate = DateTime.utc(2021, 1, 20, 21, 2);
        final result = scheduler.calculateMoonPosition(quarterDate);

        // Should be roughly 0.5 with some tolerance for the simplified model
        expect(
          result.illumination,
          greaterThan(0.3),
          reason: 'Quarter moon illumination should be in the 0.3-0.7 range',
        );
        expect(
          result.illumination,
          lessThan(0.7),
          reason: 'Quarter moon illumination should be in the 0.3-0.7 range',
        );
      });

      test('known date produces consistent illumination value', () {
        // Use a fixed date and verify the formula produces a deterministic result
        final fixedDate = DateTime.utc(2024, 3, 25, 12, 0);
        final result1 = scheduler.calculateMoonPosition(fixedDate);
        final result2 = scheduler.calculateMoonPosition(fixedDate);

        expect(
          result1.illumination,
          equals(result2.illumination),
          reason: 'Same input date must produce identical illumination',
        );
        // Also verify it's in a valid range
        expect(result1.illumination, greaterThanOrEqualTo(0.0));
        expect(result1.illumination, lessThanOrEqualTo(1.0));
      });

      test('illumination is always in 0..1 range across many dates', () {
        // Sample monthly for 2 years to ensure the formula never escapes [0, 1]
        for (int month = 1; month <= 24; month++) {
          final date = DateTime.utc(2023, month, 15, 0, 0);
          final result = scheduler.calculateMoonPosition(date);

          expect(
            result.illumination,
            greaterThanOrEqualTo(0.0),
            reason: 'Illumination must be >= 0 for $date',
          );
          expect(
            result.illumination,
            lessThanOrEqualTo(1.0),
            reason: 'Illumination must be <= 1 for $date',
          );
        }
      });

      test('moon RA is in 0..24 range', () {
        final date = DateTime.utc(2024, 6, 15, 0, 0);
        final result = scheduler.calculateMoonPosition(date);

        expect(result.raHours, greaterThanOrEqualTo(0.0));
        expect(result.raHours, lessThan(24.0));
      });

      test('moon declination is in -90..90 range', () {
        final date = DateTime.utc(2024, 6, 15, 0, 0);
        final result = scheduler.calculateMoonPosition(date);

        expect(result.decDegrees, greaterThanOrEqualTo(-90.0));
        expect(result.decDegrees, lessThanOrEqualTo(90.0));
      });
    });

    group('calculateAltitude', () {
      test('object at zenith has altitude near 90 degrees', () {
        // At transit with dec == lat, altitude should be 90 degrees
        // sin(alt) = sin(dec)*sin(lat) + cos(dec)*cos(lat)*cos(0)
        //          = sin^2(lat) + cos^2(lat) = 1 => alt = 90
        final testDate = DateTime.utc(2024, 6, 15, 0, 0);
        const lat = 45.0;
        const lon = -90.0;
        const dec = 45.0;
        const ra = 12.0;

        final transitTime = scheduler.calculateTransitTime(
          raHours: ra,
          date: testDate,
          longitudeDegrees: lon,
        );

        final alt = scheduler.calculateAltitude(
          raHours: ra,
          decDegrees: dec,
          time: transitTime,
          latitudeDegrees: lat,
          longitudeDegrees: lon,
        );

        expect(alt, closeTo(90.0, 1.0));
      });

      test('object below horizon has negative altitude', () {
        // A far-south object viewed from a far-north latitude
        // Dec = -80, Lat = 60 should never be visible
        final date = DateTime.utc(2024, 6, 15, 12, 0);
        final alt = scheduler.calculateAltitude(
          raHours: 6.0,
          decDegrees: -80.0,
          time: date,
          latitudeDegrees: 60.0,
          longitudeDegrees: 0.0,
        );

        expect(
          alt,
          lessThan(0.0),
          reason: 'Far south object should be below horizon at lat 60 N',
        );
      });

      test('alt/az remains finite at zenith singularity', () {
        final testDate = DateTime.utc(2024, 6, 15, 0, 0);
        const lat = 45.0;
        const lon = -90.0;
        const dec = 45.0;
        const ra = 12.0;

        final transitTime = scheduler.calculateTransitTime(
          raHours: ra,
          date: testDate,
          longitudeDegrees: lon,
        );

        final (alt, az) = scheduler.calculateAltAz(
          raHours: ra,
          decDegrees: dec,
          time: transitTime,
          latitudeDegrees: lat,
          longitudeDegrees: lon,
        );

        expect(alt.isFinite, isTrue);
        expect(az.isFinite, isTrue);
        expect(az, greaterThanOrEqualTo(0.0));
        expect(az, lessThan(360.0));
      });
    });

    group('calculateTargetAltitudes', () {
      test(
        'polar always-visible target reports finite hours above horizon',
        () {
          final data = scheduler.calculateTargetAltitudes(
            targets: [
              TargetHeaderNode(
                id: 'north-pole',
                name: 'North pole',
                targetName: 'North pole',
                raHours: 0,
                decDegrees: 90,
              ),
            ],
            observationTime: DateTime.utc(2024, 6, 15, 0, 0),
            latitudeDegrees: 45,
            longitudeDegrees: 0,
            minAltitude: 0,
          );

          expect(data.single.hoursAboveHorizon, 24.0);
        },
      );
    });

    group('optimizeTargetOrder', () {
      test(
        'priority strategy puts higher values first and keeps ties stable',
        () {
          TargetHeaderNode target(String id, int priority) => TargetHeaderNode(
            id: id,
            name: id,
            targetName: id,
            raHours: 5,
            decDegrees: 20,
            priority: priority,
          );
          final result = scheduler.optimizeTargetOrder(
            targets: [
              target('low', 2),
              target('high-first', 9),
              target('high-second', 9),
            ],
            strategy: OptimizationStrategy.priority,
            observationTime: DateTime.utc(2026, 1, 1),
            latitudeDegrees: 40,
            longitudeDegrees: -74,
          );

          expect(result.map((target) => target.id), [
            'high-first',
            'high-second',
            'low',
          ]);
        },
      );
    });

    group('calculateSeparation', () {
      test('identical positions have zero separation', () {
        final sep = scheduler.calculateSeparation(
          ra1Hours: 12.0,
          dec1Degrees: 45.0,
          ra2Hours: 12.0,
          dec2Degrees: 45.0,
        );

        expect(sep, closeTo(0.0, 0.001));
      });

      test('opposite poles have 180 degree separation', () {
        final sep = scheduler.calculateSeparation(
          ra1Hours: 0.0,
          dec1Degrees: 90.0,
          ra2Hours: 0.0,
          dec2Degrees: -90.0,
        );

        expect(sep, closeTo(180.0, 0.001));
      });

      test('known separation for 90 degree case', () {
        // North pole (dec=90) to equator at any RA should be 90 degrees
        final sep = scheduler.calculateSeparation(
          ra1Hours: 6.0,
          dec1Degrees: 90.0,
          ra2Hours: 18.0,
          dec2Degrees: 0.0,
        );

        expect(sep, closeTo(90.0, 0.001));
      });
    });

    group('isNearMoon', () {
      test('returns true when target is near moon position', () {
        final date = DateTime.utc(2024, 6, 15, 0, 0);
        final moonPos = scheduler.calculateMoonPosition(date);

        // Place target exactly at moon position
        final result = scheduler.isNearMoon(
          targetRaHours: moonPos.raHours,
          targetDecDegrees: moonPos.decDegrees,
          time: date,
          minSeparationDegrees: 30.0,
        );

        expect(result, isTrue);
      });

      test('returns false when target is far from moon', () {
        final date = DateTime.utc(2024, 6, 15, 0, 0);
        final moonPos = scheduler.calculateMoonPosition(date);

        // Place target on opposite side of sky
        final oppositeRa = (moonPos.raHours + 12.0) % 24.0;
        final oppositeDec = -moonPos.decDegrees;

        final result = scheduler.isNearMoon(
          targetRaHours: oppositeRa,
          targetDecDegrees: oppositeDec,
          time: date,
          minSeparationDegrees: 30.0,
        );

        expect(result, isFalse);
      });
    });
  });
}
