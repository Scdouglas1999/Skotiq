import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../harness/in_memory_database.dart';

WeatherAlert _clearAlert() => WeatherAlert(
  level: AlertLevel.clear,
  message: 'Clear',
  cloudDensityPercent: 0,
  distanceKm: 0,
  generatedAt: DateTime(2026, 7, 13),
);

void main() {
  test(
    'evaluation failure makes combined weather status unavailable',
    () async {
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          weatherRadarFramesProvider.overrideWith(
            (ref) async => const <RadarFrame>[],
          ),
          evaluateWeatherConditionsProvider.overrideWith(
            (ref) => Future<WeatherAlert>.error(
              StateError('weather observations unavailable'),
            ),
          ),
          weatherAlertStreamProvider.overrideWith(
            (ref) => const Stream<WeatherAlert>.empty(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(weatherStatusProvider, (_, __) {});
      addTearDown(subscription.close);

      await container.read(weatherRadarFramesProvider.future);
      await expectLater(
        container.read(evaluateWeatherConditionsProvider.future),
        throwsA(isA<StateError>()),
      );
      await Future<void>.delayed(Duration.zero);

      final status = container.read(weatherStatusProvider);
      expect(status.isLoading, isFalse);
      expect(status.errorMessage, contains('weather observations unavailable'));
      // NULL, not an epoch-zero stand-in. The sentinel was indistinguishable
      // from a real timestamp downstream and the status card rendered it as
      // "Updated 20667 days ago" — for the whole session when, as here, the
      // fetch never succeeds.
      expect(status.lastUpdate, isNull);
    },
  );

  test(
    'weather remains loading until condition evaluation completes',
    () async {
      final evaluation = Completer<WeatherAlert>();
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          weatherRadarFramesProvider.overrideWith(
            (ref) async => const <RadarFrame>[],
          ),
          evaluateWeatherConditionsProvider.overrideWith(
            (ref) => evaluation.future,
          ),
          weatherAlertStreamProvider.overrideWith(
            (ref) => const Stream<WeatherAlert>.empty(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(weatherStatusProvider, (_, __) {});
      addTearDown(subscription.close);

      await container.read(weatherRadarFramesProvider.future);
      expect(container.read(weatherStatusProvider).isLoading, isTrue);

      evaluation.complete(_clearAlert());
      await container.read(evaluateWeatherConditionsProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(weatherStatusProvider).isLoading, isFalse);
    },
  );
}
