// The sky tells the time of the clock the host app gives it, so the
// planetarium's "now" and sidereal time agree with the app's other readouts.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  final stopped = DateTime.utc(2026, 11, 16, 4, 47, 12);

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        skyNowProvider.overrideWithValue(() => stopped),
        observerLocationProvider.overrideWith(
          (ref) =>
              PlanetariumObserverNotifier()
                ..setLocation(latitude: 38.7, longitude: -79.53),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('real-time observation starts at the given clock\'s now', () {
    final time = container().read(observationTimeProvider);
    expect(time.isRealTime, isTrue);
    expect(time.time, stopped);
  });

  test('sidereal time is the given clock\'s', () {
    expect(
      container().read(localSiderealTimeProvider),
      AstronomyCalculations.localSiderealTime(stopped, -79.53),
    );
  });
}
