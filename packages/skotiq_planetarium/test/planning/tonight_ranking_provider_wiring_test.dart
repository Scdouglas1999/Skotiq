// Best Targets Tonight end to end: the provider, the app's scorer it is
// handed, and the ranking.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_astro/testing.dart';

const _lat = 40.0;
const _lon = -105.0;

/// Evening of the night under test, so `nightDateOf` resolves to 2026-08-02.
final _observationTime = DateTime(2026, 8, 2, 22, 0);
final _nightDate = DateTime(2026, 8, 2);

/// RA (hours) of an object that culminates at [instant] from this site.
double _raHoursTransitingAt(DateTime instant) =>
    AstronomyCalculations.localSiderealTime(instant, _lon);

void main() {
  final twilight = AstronomyCalculations.calculateTwilightTimes(
    date: _nightDate,
    latitudeDeg: _lat,
    longitudeDeg: _lon,
  );
  final window = darknessWindowOf(twilight)!;
  final darkMid = window.start.add(
    Duration(seconds: window.duration.inSeconds ~/ 2),
  );
  final daylightMid = window.end.add(
    Duration(
      seconds: (const Duration(hours: 24) - window.duration).inSeconds ~/ 2,
    ),
  );

  // Culminates at the midpoint of daylight with dec == latitude: straight
  // through the zenith, but never above the imaging floor during darkness.
  // It is also the brighter object, so no tie-break can be doing the work.
  final zenithAtBreakfast = DeepSkyObject(
    id: 'DECOY-ZENITH',
    name: 'Culminates in daylight',
    coordinates: CelestialCoordinate(
      ra: _raHoursTransitingAt(daylightMid),
      dec: _lat,
    ),
    type: DsoType.galaxy,
    magnitude: 6.0,
  );

  // Transits in the middle of the dark window, and lower.
  final usableInDarkness = DeepSkyObject(
    id: 'REAL-TARGET',
    name: 'Culminates in the dark',
    coordinates: CelestialCoordinate(
      ra: _raHoursTransitingAt(darkMid),
      dec: 20.0,
    ),
    type: DsoType.galaxy,
    magnitude: 11.0,
  );

  ProviderContainer createContainer(
    List<DeepSkyObject> dsos, {
    ScriptedNightScorer? scorer,
  }) {
    final container = ProviderContainer(
      overrides: [
        loadedDsosProvider.overrideWith((ref) async => dsos),
        planetariumNightScorerProvider.overrideWith(
          (ref) => (scorer ?? ScriptedNightScorer()).call,
        ),
        // The site's floor as the app pumps it: no horizon, 30 degrees.
        planetariumAltitudeFloorProvider.overrideWith(
          (ref) => AltitudeFloorSamples.flat(30),
        ),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: _lat, longitude: _lon);
    container.read(observationTimeProvider.notifier).setTime(_observationTime);
    return container;
  }

  test('the card lists what the app\'s scorer finds usable tonight', () async {
    // The scorer leaves the zenith-at-breakfast decoy out: it has no dark time.
    final scorer = ScriptedNightScorer(byIndex: {0: null});
    final container = createContainer([
      zenithAtBreakfast,
      usableInDarkness,
    ], scorer: scorer);

    final best = (await container.read(bestTargetsProvider.future))!;

    expect(best.map((t) => t.object.id), ['REAL-TARGET']);
    expect(scorer.requests.single.targets, hasLength(2));
  });

  test('without the app\'s scorer the card is not ranked yet', () async {
    final container = ProviderContainer(
      overrides: [
        loadedDsosProvider.overrideWith((ref) async => [usableInDarkness]),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: _lat, longitude: _lon);

    expect(await container.read(bestTargetsProvider.future), isNull);
  });

  test('every target the card offers has dark hours and a dark peak', () async {
    final container = createContainer([zenithAtBreakfast, usableInDarkness]);

    final best = (await container.read(bestTargetsProvider.future))!;

    for (final target in best) {
      expect(target.hoursInDarkness, greaterThan(0));
      expect(target.peakTime, isNotNull);
      expect(target.peakTime!.isBefore(window.start), isFalse);
      expect(target.peakTime!.isAfter(window.end), isFalse);
    }
  });

  test('active equipment FOV reaches the ranking', () async {
    final ra = _raHoursTransitingAt(darkMid);
    final objects = [
      DeepSkyObject(
        id: 'SMALL',
        name: 'Small target',
        coordinates: CelestialCoordinate(ra: ra, dec: 20),
        type: DsoType.galaxy,
        sizeArcMin: 2,
      ),
      DeepSkyObject(
        id: 'LARGE',
        name: 'Large target',
        coordinates: CelestialCoordinate(ra: ra, dec: 20),
        type: DsoType.galaxy,
        sizeArcMin: 200,
      ),
    ];
    final container = createContainer(objects);
    final fov = container.read(equipmentFOVProvider.notifier);
    const camera = CameraSensorSpecs(
      name: 'Test camera',
      widthMm: 10,
      heightMm: 10,
      pixelsX: 1000,
      pixelsY: 1000,
      pixelSizeMicrons: 10,
    );

    fov.setRig(
      camera: camera,
      telescope: const TelescopeSpecs(
        name: 'Narrow scope',
        focalLengthMm: 1000,
        apertureMm: 200,
      ),
    );
    final narrow = (await container.read(bestTargetsProvider.future))!;
    expect(narrow.first.object.id, 'SMALL');

    fov.setRig(
      camera: camera,
      telescope: const TelescopeSpecs(
        name: 'Wide scope',
        focalLengthMm: 100,
        apertureMm: 40,
      ),
    );
    container.invalidate(bestTargetsProvider);
    final wide = (await container.read(bestTargetsProvider.future))!;
    expect(wide.first.object.id, 'LARGE');
  });
}
