// The Weather Safety settings page has to state which safety sources are
// attached. It reads them through weatherSafetySourceReadingsProvider, which
// applies the SAME three-state rule the safety evaluation acts on — a page that
// derived its own answer could tell the operator a source counts when the
// enforcement path has already written it off as stale.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/models/weather/weather_models.dart';
import 'package:skotiq_core/src/providers/equipment/safety_monitor_state_provider.dart';
import 'package:skotiq_core/src/providers/equipment/weather_state_provider.dart';
import 'package:skotiq_core/src/providers/weather_providers.dart';

class _SeedableMonitorNotifier extends SafetyMonitorStateNotifier {
  _SeedableMonitorNotifier(super.ref);

  void seed(SafetyMonitorState seeded) => state = seeded;
}

void main() {
  ProviderContainer build() {
    final container = ProviderContainer(
      overrides: [
        weatherSettingsDataProvider.overrideWith(
          (ref) => Stream.value(const WeatherSettings(maxHumidityPercent: 80)),
        ),
        safetyMonitorStateProvider.overrideWith(
          (ref) => _SeedableMonitorNotifier(ref),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('a rig with nothing attached reads absent on both sources', () {
    final container = build();
    final readings = container.read(weatherSafetySourceReadingsProvider);
    expect(readings.weather, SafetySourceReading.absent);
    expect(readings.monitor, SafetySourceReading.absent);
  });

  test('a connected device that has never reported reads unknown', () async {
    final container = build();
    await container.read(weatherSettingsDataProvider.future);
    final weather = container.read(weatherStateProvider.notifier);
    weather.setConnecting('weather-1');
    weather.setConnected();

    expect(
      container.read(weatherSafetySourceReadingsProvider).weather,
      SafetySourceReading.unknown,
    );
  });

  test('a live reading inside the thresholds reads safe', () async {
    final container = build();
    await container.read(weatherSettingsDataProvider.future);
    final weather = container.read(weatherStateProvider.notifier);
    weather.setConnecting('weather-1');
    weather.setConnected();
    weather.updateConditions(
      humidity: 30,
      windSpeed: 1,
      cloudCover: 5,
      rainRate: 0,
    );

    expect(
      container.read(weatherSafetySourceReadingsProvider).weather,
      SafetySourceReading.safe,
    );
  });

  test('a live reading past a threshold reads unsafe', () async {
    final container = build();
    await container.read(weatherSettingsDataProvider.future);
    final weather = container.read(weatherStateProvider.notifier);
    weather.setConnecting('weather-1');
    weather.setConnected();
    weather.updateConditions(
      humidity: 95,
      windSpeed: 1,
      cloudCover: 5,
      rainRate: 0,
    );

    expect(
      container.read(weatherSafetySourceReadingsProvider).weather,
      SafetySourceReading.unsafe,
    );
  });

  test('a stale monitor reading reads unknown, not safe', () async {
    final container = build();
    await container.read(weatherSettingsDataProvider.future);
    final monitor = container.read(safetyMonitorStateProvider.notifier);
    (monitor as _SeedableMonitorNotifier).seed(
      SafetyMonitorState(
        connectionState: DeviceConnectionState.connected,
        deviceId: 'safety-1',
        isSafe: true,
        lastChecked: DateTime.now().subtract(const Duration(minutes: 30)),
      ),
    );

    expect(
      container.read(weatherSafetySourceReadingsProvider).monitor,
      SafetySourceReading.unknown,
    );
  });
}
