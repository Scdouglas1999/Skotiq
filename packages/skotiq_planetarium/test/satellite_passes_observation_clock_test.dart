import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

const _iss = OrbitalElements(
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

/// The planetarium's clock set to [when] and held there.
class _HeldClock extends ObservationTimeNotifier {
  _HeldClock(DateTime when) {
    state = ObservationTimeState(
      time: when,
      isRealTime: false,
      speedMultiplier: 0,
    );
  }
}

SatellitePass _passEndingAt(DateTime set) => SatellitePass(
  elements: _iss,
  riseTime: set.subtract(const Duration(minutes: 10)),
  riseAzimuth: 0,
  maxElevationTime: set.subtract(const Duration(minutes: 5)),
  maxElevation: 45,
  maxElevationAzimuth: 90,
  setTime: set,
  setAzimuth: 180,
);

/// Satellite passes follow the planetarium's clock, as satellite positions
/// do: with the clock set to another night, the passes are that night's.
void main() {
  // A night well away from the wall clock, in either direction.
  final observed = DateTime.utc(2031, 3, 4, 2);

  test('passes are predicted from the observation time', () async {
    DateTime? predictedFrom;
    final container = ProviderContainer(
      overrides: [
        observationTimeProvider.overrideWith((ref) => _HeldClock(observed)),
        satelliteTleProvider.overrideWith((ref) async => const [_iss]),
        passPredictionComputerProvider.overrideWithValue(({
          required elements,
          required latitude,
          required longitude,
          required startTime,
          required predictionWindow,
        }) async {
          predictedFrom = startTime;
          return const <SatellitePass>[];
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

    expect(predictedFrom, observed);
  });

  test(
    'upcoming passes are those still to end at the observation time',
    () async {
      final ended = _passEndingAt(observed.subtract(const Duration(hours: 1)));
      final ahead = _passEndingAt(observed.add(const Duration(hours: 1)));
      final container = ProviderContainer(
        overrides: [
          observationTimeProvider.overrideWith((ref) => _HeldClock(observed)),
          satelliteTleProvider.overrideWith((ref) async => const [_iss]),
          passPredictionComputerProvider.overrideWithValue(
            ({
              required elements,
              required latitude,
              required longitude,
              required startTime,
              required predictionWindow,
            }) async => [ended, ahead],
          ),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(observerLocationProvider.notifier)
          .setLocation(latitude: 40, longitude: -74);
      container.listen(upcomingPassesProvider, (_, __) {});
      container.read(showSatellitesProvider.notifier).state = true;
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(passPredictionProvider).passes, hasLength(2));
      expect(container.read(upcomingPassesProvider), [ahead]);
    },
  );
}
