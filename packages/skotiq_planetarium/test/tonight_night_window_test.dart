// "Tonight" means the night in progress, not the calendar day.
//
// Feeding AstronomyCalculations.calculateObjectVisibility the astronomical-dusk
// TIMESTAMP as its `date` scans local noon of THAT date to the following noon,
// and at 40N / 105W dusk falls at 00:00-00:02 local — already tomorrow's
// calendar day — so the whole "Best Targets Tonight" list describes the NEXT
// night with every transit time one sidereal day (~4 min) out. The sidebar then
// contradicts itself on the same screen: the Info tab reports NGC6685
// transiting at 00:52 while the Best Targets card two tabs away says 00:48.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

const _lat = 40.0;
const _lon = -105.0;

/// NGC6685: the object the two surfaces disagreed about.
const _ngc6685 = CelestialCoordinate(
  ra: 18 + 39 / 60 + 58.0 / 3600,
  dec: 39 + 58 / 60,
);

ProviderContainer _container(DateTime observationTime) {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container
      .read(observerLocationProvider.notifier)
      .setLocation(latitude: _lat, longitude: _lon);
  container.read(observationTimeProvider.notifier).setTime(observationTime);
  return container;
}

void main() {
  group('nightDateOf', () {
    test('an evening instant names its own day', () {
      expect(
        AstronomyCalculations.nightDateOf(DateTime(2026, 8, 2, 21, 30)),
        DateTime(2026, 8, 2),
      );
    });

    test('an instant past midnight names the day the night STARTED', () {
      expect(
        AstronomyCalculations.nightDateOf(DateTime(2026, 8, 3, 0, 1)),
        DateTime(2026, 8, 2),
      );
      expect(
        AstronomyCalculations.nightDateOf(DateTime(2026, 8, 3, 4, 30)),
        DateTime(2026, 8, 2),
      );
    });

    test('local noon is the boundary, and UTC-ness is preserved', () {
      expect(
        AstronomyCalculations.nightDateOf(DateTime(2026, 8, 3, 11, 59)),
        DateTime(2026, 8, 2),
      );
      expect(
        AstronomyCalculations.nightDateOf(DateTime(2026, 8, 3, 12, 0)),
        DateTime(2026, 8, 3),
      );
      final utc = AstronomyCalculations.nightDateOf(
        DateTime.utc(2026, 8, 3, 13, 0),
      );
      expect(utc.isUtc, isTrue);
    });
  });

  test('the selected-object readout describes the night in progress', () {
    // 02:00 local — the night that began the previous evening.
    final container = _container(DateTime(2026, 8, 3, 2, 0));
    container.read(selectedObjectProvider.notifier).selectCoordinates(_ngc6685);

    final visibility = container.read(selectedObjectVisibilityProvider);
    expect(visibility, isNotNull);

    final expected = AstronomyCalculations.calculateObjectVisibility(
      raDeg: _ngc6685.raDegrees,
      decDeg: _ngc6685.dec,
      date: DateTime(2026, 8, 2),
      latitudeDeg: _lat,
      longitudeDeg: _lon,
    );
    expect(visibility!.transitTime, expected.transitTime);

    // The night AFTER this one is what a calendar-day anchor reports, and it is
    // a whole sidereal day away.
    final nextNight = AstronomyCalculations.calculateObjectVisibility(
      raDeg: _ngc6685.raDegrees,
      decDeg: _ngc6685.dec,
      date: DateTime(2026, 8, 3),
      latitudeDeg: _lat,
      longitudeDeg: _lon,
    );
    expect(visibility.transitTime, isNot(nextNight.transitTime));
    expect(
      nextNight.transitTime!.difference(visibility.transitTime!).inHours,
      greaterThanOrEqualTo(23),
    );
  });

  test(
    'Best Targets and the Info tab agree on which night they describe',
    () async {
      final dsos = [
        const DeepSkyObject(
          id: 'NGC6685',
          name: 'NGC6685',
          coordinates: _ngc6685,
          type: DsoType.galaxy,
          magnitude: 12.0,
        ),
      ];

      final container = ProviderContainer(
        overrides: [loadedDsosProvider.overrideWith((ref) async => dsos)],
      );
      addTearDown(container.dispose);
      container
          .read(observerLocationProvider.notifier)
          .setLocation(latitude: _lat, longitude: _lon);
      // Astronomical dusk at this site in August lands just after local
      // midnight — the case a calendar-day anchor gets wrong.
      container
          .read(observationTimeProvider.notifier)
          .setTime(DateTime(2026, 8, 3, 2, 0));
      container
          .read(selectedObjectProvider.notifier)
          .selectCoordinates(_ngc6685);

      final best = (await container.read(bestTargetsProvider.future))!;
      expect(best, hasLength(1));

      final infoTab = container.read(selectedObjectVisibilityProvider);
      expect(best.first.visibility.transitTime, infoTab!.transitTime);
    },
  );
}
