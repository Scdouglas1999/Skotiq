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
  const NightSafetyReading({
    required this.monitoring,
    this.safe,
    this.decidedBy = WeatherDecisionSource.none,
    this.forecastHoldsRun = false,
    this.overrideUntil,
    this.overrideReason,
    this.starEvidence,
    this.starsOutweighForecast = false,
  });

  /// Weather safety is switched on and evaluating.
  final bool monitoring;

  /// The verdict; null while monitoring is off or snoozed.
  final bool? safe;

  /// Which input decides an unsafe verdict.
  final WeatherDecisionSource decidedBy;

  /// A cloudy forecast holds the run rather than only warning.
  final bool forecastHoldsRun;

  /// Until when the operator has set the verdict aside; null when not.
  final DateTime? overrideUntil;

  /// Why the operator set it aside.
  final String? overrideReason;

  /// What the run's own recent frames say about the sky.
  final SkyStarEvidence? starEvidence;

  /// The forecast says cloudy but the frames outweigh it.
  final bool starsOutweighForecast;

  @override
  bool operator ==(Object other) =>
      other is NightSafetyReading &&
      other.monitoring == monitoring &&
      other.safe == safe &&
      other.decidedBy == decidedBy &&
      other.forecastHoldsRun == forecastHoldsRun &&
      other.overrideUntil == overrideUntil &&
      other.overrideReason == overrideReason &&
      other.starEvidence == starEvidence &&
      other.starsOutweighForecast == starsOutweighForecast;

  @override
  int get hashCode => Object.hash(
        monitoring,
        safe,
        decidedBy,
        forecastHoldsRun,
        overrideUntil,
        overrideReason,
        starEvidence,
        starsOutweighForecast,
      );
}

/// The weather-safety verdict. Its own provider so a test can pin it without
/// standing up the evaluator and its timers.
final nightSafetyReadingProvider = Provider<NightSafetyReading>((ref) {
  final state = ref.watch(weatherSafetyProvider);
  if (!state.monitoringEnabled) {
    return const NightSafetyReading(monitoring: false);
  }
  final snoozed = state.status == WeatherSafetyStatus.snoozed;
  return NightSafetyReading(
    monitoring: true,
    safe: switch (state.status) {
      WeatherSafetyStatus.safe => true,
      WeatherSafetyStatus.unsafe => false,
      WeatherSafetyStatus.snoozed => null,
    },
    decidedBy: state.status == WeatherSafetyStatus.unsafe
        ? state.decisionSource
        : WeatherDecisionSource.none,
    forecastHoldsRun: state.forecastHoldsRun,
    overrideUntil: snoozed ? state.snoozeUntil : null,
    overrideReason: snoozed ? state.snoozeReason : null,
    starEvidence: state.starEvidence,
    starsOutweighForecast: state.starEvidenceOverridesForecast,
  );
});

/// How long "the sky is clear" sets the weather verdict aside.
const Duration nightSkyClearOverride = Duration(minutes: 30);

/// The Conditions block's explanation lines and its override offer, from the
/// safety reading alone.
({List<NightText> notes, NightSkyOverride skyOverride}) nightSafetyNotes(
  NightSafetyReading reading,
  Clock clock,
) {
  final notes = <NightText>[];
  if (!reading.monitoring) {
    return (notes: notes, skyOverride: NightSkyOverride.none);
  }
  switch (reading.decidedBy) {
    case WeatherDecisionSource.forecast:
      notes.add(
        NightText(
          reading.forecastHoldsRun
              ? 'nightWeatherForecastHolds'
              : 'nightWeatherForecastWarns',
        ),
      );
    case WeatherDecisionSource.weatherDevice:
      notes.add(const NightText('nightWeatherDecidedByDevice'));
    case WeatherDecisionSource.safetyMonitor:
      notes.add(const NightText('nightWeatherDecidedByMonitor'));
    case WeatherDecisionSource.dawn:
      notes.add(const NightText('nightWeatherDecidedByDawn'));
    case WeatherDecisionSource.noData:
      notes.add(const NightText('nightWeatherDecidedByNoData'));
    case WeatherDecisionSource.none:
      break;
  }
  if (reading.starsOutweighForecast) {
    notes.add(const NightText('nightWeatherStarsOutweighForecast'));
  }
  final evidence = reading.starEvidence;
  if (evidence != null) {
    notes.add(
      NightText(
        evidence.clear ? 'nightWeatherStarsClear' : 'nightWeatherStarsFew',
        params: <String, String>{
          'stars': '${evidence.latestStars}',
          'usual': '${evidence.typicalStars}',
        },
      ),
    );
  }
  final until = reading.overrideUntil;
  if (until != null) {
    notes.add(
      NightText(
        'nightWeatherOverrideActive',
        params: <String, String>{'time': nightClockTime(clock, until)},
      ),
    );
    return (notes: notes, skyOverride: NightSkyOverride.active);
  }
  // A safety monitor is a reading at the site; it is not set aside from here.
  final offer = reading.safe == false &&
      reading.decidedBy != WeatherDecisionSource.safetyMonitor &&
      reading.decidedBy != WeatherDecisionSource.dawn;
  return (
    notes: notes,
    skyOverride: offer ? NightSkyOverride.offer : NightSkyOverride.none,
  );
}

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
  final reading = ref.watch(nightSafetyReadingProvider);
  final safe = reading.safe;
  final (:notes, :skyOverride) = nightSafetyNotes(
    reading,
    ref.watch(clockProvider),
  );
  switch (source) {
    case ConditionsSource.device:
      final w = ref.watch(weatherStateProvider);
      return NightConditionsVm(
        source: source,
        safe: safe,
        notes: notes,
        skyOverride: skyOverride,
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
        notes: notes,
        skyOverride: skyOverride,
        metrics: <MetricVm>[
          if (cloud != null)
            MetricVm(
              label: const NightText('nightSessionCloudsForecast'),
              value: _percent(cloud),
            ),
        ],
      );
    case ConditionsSource.none:
      return NightConditionsVm(
        source: source,
        safe: safe,
        notes: notes,
        skyOverride: skyOverride,
      );
  }
});
