// Tests for SchedulerService moon illumination and astronomical calculations.
//
// Uses direct imports to avoid pre-existing compilation errors in the wider
// package (polar_alignment_history_dao, equipment_profile type mismatches).
// The SchedulerService itself is pure math with no database dependencies,
// so we instantiate it via ProviderContainer with a targeted import.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
          decDegrees: dec,
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
          decDegrees: dec,
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
  });
}
