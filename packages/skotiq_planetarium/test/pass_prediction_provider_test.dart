import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

const _elements = OrbitalElements(
  catalogNumber: 25544,
  name: 'ISS',
  epochYear: 26,
  epochDay: 196,
  bstar: 0.0001,
  inclination: 51.6,
  raan: 120,
  eccentricity: 0.0005,
  argumentOfPerigee: 80,
  meanAnomaly: 280,
  meanMotion: 15.5,
);

void main() {
  test(
    'enabling satellites waits for TLE data and computes automatically',
    () async {
      final tle = Completer<List<OrbitalElements>>();
      var computeCalls = 0;
      final container = ProviderContainer(
        overrides: [
          satelliteTleProvider.overrideWith((ref) => tle.future),
          passPredictionComputerProvider.overrideWithValue(({
            required elements,
            required latitude,
            required longitude,
            required startTime,
            required predictionWindow,
          }) async {
            computeCalls++;
            return const <SatellitePass>[];
          }),
        ],
      );
      addTearDown(container.dispose);
      // A pass is a topocentric event: prediction needs a site on record.
      container
          .read(observerLocationProvider.notifier)
          .setLocation(latitude: 40, longitude: -74);
      container.read(passPredictionProvider);

      container.read(showSatellitesProvider.notifier).state = true;
      await Future<void>.delayed(Duration.zero);
      expect(container.read(passPredictionProvider).isComputing, isTrue);
      expect(computeCalls, 0);

      tle.complete(const [_elements]);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(computeCalls, 1);
      expect(container.read(passPredictionProvider).isComputing, isFalse);
      expect(container.read(passPredictionProvider).error, isNull);
    },
  );

  test('a location refresh retires the previous prediction result', () async {
    final first = Completer<List<SatellitePass>>();
    final second = Completer<List<SatellitePass>>();
    var computeCalls = 0;
    final stalePass = SatellitePass(
      elements: _elements,
      riseTime: DateTime.utc(2026, 7, 15, 1),
      riseAzimuth: 0,
      maxElevationTime: DateTime.utc(2026, 7, 15, 1, 5),
      maxElevation: 45,
      maxElevationAzimuth: 90,
      setTime: DateTime.utc(2026, 7, 15, 1, 10),
      setAzimuth: 180,
    );
    final container = ProviderContainer(
      overrides: [
        satelliteTleProvider.overrideWith((ref) async => const [_elements]),
        passPredictionComputerProvider.overrideWithValue(({
          required elements,
          required latitude,
          required longitude,
          required startTime,
          required predictionWindow,
        }) {
          computeCalls++;
          return computeCalls == 1 ? first.future : second.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: 40, longitude: -74);
    container.read(passPredictionProvider);
    container.read(showSatellitesProvider.notifier).state = true;
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(computeCalls, 1);

    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: 40, longitude: -75);
    await Future<void>.delayed(Duration.zero);
    expect(computeCalls, 2);

    second.complete(const []);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(passPredictionProvider).passes, isEmpty);

    first.complete([stalePass]);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(passPredictionProvider).passes, isEmpty);
  });

  test(
    'with no site on record the prediction says so instead of running',
    () async {
      var computeCalls = 0;
      final container = ProviderContainer(
        overrides: [
          satelliteTleProvider.overrideWith((ref) async => const [_elements]),
          passPredictionComputerProvider.overrideWithValue(({
            required elements,
            required latitude,
            required longitude,
            required startTime,
            required predictionWindow,
          }) async {
            computeCalls++;
            return const <SatellitePass>[];
          }),
        ],
      );
      addTearDown(container.dispose);
      container.read(passPredictionProvider);
      container.read(showSatellitesProvider.notifier).state = true;
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(computeCalls, 0);
      final state = container.read(passPredictionProvider);
      expect(state.isComputing, isFalse);
      expect(state.passes, isEmpty);
      expect(state.error, contains('observing site'));
    },
  );
}
