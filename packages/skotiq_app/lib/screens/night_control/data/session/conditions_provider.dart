// Overview's "Conditions" block.
//
// A connected weather device is the source when there is one. Without it the
// Open-Meteo cloud cover is shown, and only as a forecast, because it is a
// model of the sky over the site and not a reading of it. With neither the
// block says "no weather source" and shows nothing. Seeing has no source in
// the app and never appears; SQM appears only when the device reports it.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../night_control_contracts.dart';
import 'session_format.dart';

/// What the weather-safety evaluator says, reduced to what Tonight shows.
@immutable
class NightSafetyReading {
  const NightSafetyReading({required this.monitoring, this.safe});

  /// Weather safety is switched on and evaluating.
  final bool monitoring;

  /// The verdict; null while monitoring is off or snoozed.
  final bool? safe;
}

/// The weather-safety verdict. Its own provider so a test can pin it without
/// standing up the evaluator and its timers.
final nightSafetyReadingProvider = Provider<NightSafetyReading>((ref) {
  final state = ref.watch(weatherSafetyProvider);
  if (!state.monitoringEnabled) {
    return const NightSafetyReading(monitoring: false);
  }
  return NightSafetyReading(
    monitoring: true,
    safe: switch (state.status) {
      WeatherSafetyStatus.safe => true,
      WeatherSafetyStatus.unsafe => false,
      WeatherSafetyStatus.snoozed => null,
    },
  );
});

/// The forecast cloud cover for the site, percent; null without a site or
/// while it loads.
final nightForecastCloudProvider = Provider<double?>((ref) {
  return ref.watch(cloudCoverPercentageProvider).valueOrNull;
});

/// Where the Conditions block gets its numbers.
final nightConditionsSourceProvider = Provider<ConditionsSource>((ref) {
  final weather = ref.watch(weatherStateProvider);
  if (nightConnected(weather.connectionState)) return ConditionsSource.device;
  if (ref.watch(nightForecastCloudProvider) != null) {
    return ConditionsSource.forecast;
  }
  return ConditionsSource.none;
});

String _percent(double value) => '${value.round()}%';

final nightConditionsProvider = Provider<NightConditionsVm>((ref) {
  final source = ref.watch(nightConditionsSourceProvider);
  final safe = ref.watch(nightSafetyReadingProvider).safe;
  switch (source) {
    case ConditionsSource.device:
      final w = ref.watch(weatherStateProvider);
      return NightConditionsVm(
        source: source,
        safe: safe,
        metrics: <MetricVm>[
          if (w.cloudCover != null)
            MetricVm(
              label: const NightText('nightSessionClouds'),
              value: _percent(w.cloudCover!),
            ),
          if (w.humidity != null)
            MetricVm(
              label: const NightText('nightSessionHumidity'),
              value: _percent(w.humidity!),
            ),
          if (w.dewPoint != null)
            MetricVm(
              label: const NightText('nightSessionDewPoint'),
              value: nightCelsius(w.dewPoint!),
            ),
          if (w.windSpeedKph != null)
            MetricVm(
              label: const NightText('nightSessionWind'),
              value: '${w.windSpeedKph!.round()} km/h',
            ),
          if (w.skyQuality != null)
            MetricVm(
              label: const NightText('nightSessionSqm'),
              value: nightFixed(w.skyQuality!, 1),
            ),
          if (w.temperature != null)
            MetricVm(
              label: const NightText('nightSessionAmbient'),
              value: nightCelsius(w.temperature!),
            ),
        ],
      );
    case ConditionsSource.forecast:
      final cloud = ref.watch(nightForecastCloudProvider);
      return NightConditionsVm(
        source: source,
        safe: safe,
        metrics: <MetricVm>[
          if (cloud != null)
            MetricVm(
              label: const NightText('nightSessionCloudsForecast'),
              value: _percent(cloud),
            ),
        ],
      );
    case ConditionsSource.none:
      return NightConditionsVm(source: source, safe: safe);
  }
});
