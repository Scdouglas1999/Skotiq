// Regressions for the planetarium HUD stating things that were not true.
//
// All three were found live at 40.00N / 75.20W on 2026-07-29:
//
//  1. Clicking a star at 11:52 local showed "Selected Alt: 63.6 Az: 136.1" in
//     above-horizon green. Pressing TONIGHT jumped the clock ~10 hours; the
//     readout did not move, even though the target was by then 17 deg BELOW the
//     horizon. The alt/az had been cached on the selection instead of derived
//     from the sky clock.
//  2. In Alt/Az view the bar read "Center RA 0h 0m 0s / Center Dec +0 0'" no
//     matter where the view was dragged, because `SkyViewState.centerRA/Dec`
//     hold the preserved *inactive* equatorial pose in that frame.
//  3. The same 63-deg-up target was badged a green "Excellent" at midday with
//     the Sun 63 deg up, on the same screen whose dashboard said "Dark in
//     10h 36m".
//
// Plus Home/reset, which pointed the map at RA 0h / Dec 0 — 14 deg below the
// horizon at the audited site and time.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// The audited site.
const _lat = 40.0;
const _lon = -75.2;

/// HIP42327: RA 8h37m46.7s, Dec +19d16'02".
const _target = CelestialCoordinate(
  ra: 8 + 37 / 60 + 46.7 / 3600,
  dec: 19 + 16 / 60 + 2 / 3600,
);

ProviderContainer _container() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container
      .read(observerLocationProvider.notifier)
      .setLocation(latitude: _lat, longitude: _lon);
  return container;
}

/// Local sidereal time in hours at [utc] for the audited longitude.
double _lst(DateTime utc) => AstronomyCalculations.localSiderealTime(utc, _lon);

void main() {
  group('selected object alt/az follows the planetarium clock', () {
    test(
      'scrubbing the clock moves a selected target from up to below horizon',
      () {
        final container = _container();
        container
            .read(selectedObjectProvider.notifier)
            .selectCoordinates(_target);

        // ~11:52 local (15:52 UTC) — the target is high.
        container
            .read(observationTimeProvider.notifier)
            .setTime(DateTime.utc(2026, 7, 29, 15, 52));
        final atMidday = container.read(selectedObjectAltAzProvider);
        expect(atMidday, isNotNull);
        expect(atMidday!.$1, closeTo(63.5, 1.5));

        // TONIGHT: ~22:07 local (02:07 UTC the next day) — the target has set.
        container
            .read(observationTimeProvider.notifier)
            .setTime(DateTime.utc(2026, 7, 30, 2, 7));
        final atNight = container.read(selectedObjectAltAzProvider);
        expect(atNight, isNotNull);
        expect(
          atNight!.$1,
          lessThan(0),
          reason:
              'the target is below the horizon at this hour; a HUD altitude '
              'that does not move when you scrub time is worse than none',
        );
        expect(atNight.$1, closeTo(-17.4, 2.0));
      },
    );

    test('the selection carries no cached alt/az to go stale', () {
      final container = _container();
      container
          .read(selectedObjectProvider.notifier)
          .selectCoordinates(_target);

      // Identity only. If a derived, time-dependent value is ever added back to
      // this state class it will freeze again the moment the user time-travels.
      final state = container.read(selectedObjectProvider);
      expect(state.coordinates, same(_target));
      expect(state.object, isNull);
    });

    test('clearing the selection clears the derived readouts', () {
      final container = _container();
      container
          .read(selectedObjectProvider.notifier)
          .selectCoordinates(_target);
      expect(container.read(selectedObjectAltAzProvider), isNotNull);

      container.read(selectedObjectProvider.notifier).clearSelection();
      expect(container.read(selectedObjectAltAzProvider), isNull);
      expect(container.read(selectedObjectVisibilityProvider), isNull);
    });
  });

  group('view centre readout in the horizontal frame', () {
    test('tracks the alt/az camera instead of the stale equatorial pose', () {
      final container = _container();
      final time = DateTime.utc(2026, 7, 29, 15, 52);
      container.read(observationTimeProvider.notifier).setTime(time);

      final view = container.read(skyViewStateProvider.notifier);
      // A deliberately misleading equatorial pose left behind by the last
      // equatorial session.
      view.setCenter(0, 0);
      view.setViewMode(
        SkyViewMode.horizontal,
        observer: container.read(observerLocationProvider),
        instant: time,
      );
      view.setHorizontalCenter(134, 90); // zenith

      final (ra, dec) = container.read(viewCenterEquatorialProvider);
      expect(
        dec,
        closeTo(_lat, 0.5),
        reason: 'the zenith is at Dec = observer latitude',
      );
      expect(
        ra,
        closeTo(_lst(time) % 24, 0.2),
        reason: 'the zenith is at RA = local sidereal time',
      );
      expect(
        ra,
        isNot(closeTo(0, 0.2)),
        reason: 'reporting the preserved 0h/0deg pose is the original bug',
      );
    });

    test('dragging the alt/az camera changes the reported centre', () {
      final container = _container();
      container
          .read(observationTimeProvider.notifier)
          .setTime(DateTime.utc(2026, 7, 29, 15, 52));

      final view = container.read(skyViewStateProvider.notifier);
      view.setViewMode(
        SkyViewMode.horizontal,
        observer: container.read(observerLocationProvider),
        instant: DateTime.utc(2026, 7, 29, 15, 52),
      );
      view.setHorizontalCenter(134, 90);
      final before = container.read(viewCenterEquatorialProvider);

      view.setHorizontalCenter(134, -12);
      final after = container.read(viewCenterEquatorialProvider);

      expect(after, isNot(before));
    });

    test('the equatorial frame still reports its own centre verbatim', () {
      final container = _container();
      final view = container.read(skyViewStateProvider.notifier);
      view.setCenter(22.5, 10.35);

      expect(container.read(viewCenterEquatorialProvider), (22.5, 10.35));
    });
  });

  group('observability grading', () {
    test('daylight outranks a high altitude', () {
      expect(
        gradeObservability(altitudeDeg: 63.6, sunAltitudeDeg: 63.0),
        ObservabilityGrade.daylight,
      );
      expect(
        gradeObservability(altitudeDeg: 63.6, sunAltitudeDeg: 63.0).label,
        'Daylight',
      );
    });

    test('twilight is still not observable', () {
      expect(
        gradeObservability(altitudeDeg: 63.6, sunAltitudeDeg: -6),
        ObservabilityGrade.twilight,
      );
      expect(
        gradeObservability(altitudeDeg: 63.6, sunAltitudeDeg: -13),
        ObservabilityGrade.excellent,
      );
    });

    test('below the horizon beats every sky condition', () {
      for (final sunAlt in [30.0, 0.0, -6.0, -30.0]) {
        expect(
          gradeObservability(altitudeDeg: -5, sunAltitudeDeg: sunAlt),
          ObservabilityGrade.belowHorizon,
        );
      }
    });

    test(
      'an unknown site falls back to altitude rather than inventing a sky',
      () {
        expect(
          gradeObservability(altitudeDeg: 63.6),
          ObservabilityGrade.excellent,
        );
        expect(gradeObservability(altitudeDeg: 20), ObservabilityGrade.good);
        expect(gradeObservability(altitudeDeg: 5), ObservabilityGrade.low);
      },
    );

    test('the effective horizon is respected', () {
      expect(
        gradeObservability(altitudeDeg: 15, horizonDeg: 20),
        ObservabilityGrade.belowHorizon,
      );
    });

    test('blocked and sky-too-bright classify the pills correctly', () {
      expect(ObservabilityGrade.daylight.isBlocked, isTrue);
      expect(ObservabilityGrade.belowHorizon.isBlocked, isTrue);
      expect(ObservabilityGrade.twilight.isBlocked, isFalse);
      expect(ObservabilityGrade.twilight.isSkyTooBright, isTrue);
      expect(ObservabilityGrade.excellent.isSkyTooBright, isFalse);
    });

    test('the live sun-altitude provider agrees at the audited instant', () {
      final container = _container();
      container
          .read(observationTimeProvider.notifier)
          .setTime(DateTime.utc(2026, 7, 29, 15, 52));

      final sunAlt = container.read(sunAltitudeProvider);
      expect(
        sunAlt,
        greaterThan(0),
        reason: 'it is late morning at the site; the Sun is up',
      );
      expect(sunAlt, closeTo(63, 5));
    });
  });

  group('Home / reset view', () {
    test(
      'points at the zenith, which is above the horizon by construction',
      () {
        final container = _container();
        final time = DateTime.utc(2026, 7, 29, 15, 52);
        container.read(observationTimeProvider.notifier).setTime(time);

        final (ra, dec) = container.read(skyViewHomeCenterProvider)!;
        expect(dec, closeTo(_lat, 0.5));
        expect(ra, closeTo(_lst(time) % 24, 0.2));

        final (alt, _) = AstronomyCalculations.objectAltAz(
          raDeg: ra * 15,
          decDeg: dec,
          dt: time,
          latitudeDeg: _lat,
          longitudeDeg: _lon,
        );
        expect(alt, greaterThan(85));
      },
    );

    test(
      'the old fixed home target really was underground at that instant',
      () {
        // Pins WHY the default moved, so nobody restores setCenter(0, 0).
        final (alt, _) = AstronomyCalculations.objectAltAz(
          raDeg: 0,
          decDeg: 0,
          dt: DateTime.utc(2026, 7, 29, 15, 52),
          latitudeDeg: _lat,
          longitudeDeg: _lon,
        );
        expect(alt, lessThan(0));
      },
    );

    test('RA stays inside 0..24 at every longitude', () {
      for (final lon in [-179.9, -75.2, 0.0, 121.0, 179.9]) {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container
            .read(observerLocationProvider.notifier)
            .setLocation(latitude: 40, longitude: lon);
        container
            .read(observationTimeProvider.notifier)
            .setTime(DateTime.utc(2026, 7, 29, 15, 52));

        final (ra, dec) = container.read(skyViewHomeCenterProvider)!;
        expect(ra, inInclusiveRange(0, 24));
        expect(dec.abs(), lessThanOrEqualTo(89.5));
      }
    });
  });
}
