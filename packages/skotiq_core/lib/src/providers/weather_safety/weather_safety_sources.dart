part of '../weather_safety_provider.dart';

/// State for weather safety
/// How old a hardware source's last successful read may be before it stops
/// counting as live data.
const Duration _sourceFreshnessBudget = Duration(minutes: 5);

/// A source counts as configured once the operator has selected a device for
/// it. A never-selected source stays [SafetySourceReading.absent] so a rig
/// without that sensor is not permanently unsafe.
bool _isSourceConfigured(
  DeviceConnectionState connectionState,
  String? deviceId,
) =>
    (deviceId != null && deviceId.isNotEmpty) ||
    connectionState != DeviceConnectionState.disconnected;

bool _isStaleReading(DateTime? timestamp) =>
    timestamp == null ||
    DateTime.now().difference(timestamp) > _sourceFreshnessBudget;

/// Evaluate hardware weather device for safety.
///
/// Architecture-unification 2026-06-05 (Subsystem 2 step 3): the threshold
/// comparison logic lives in the pure [WeatherThresholdEvaluator] so it has one
/// definition and is unit-testable in isolation. This just adapts the
/// provider's [WeatherState] / [WeatherSettings] into the evaluator's inputs.
bool _evaluateHardwareWeather(
  WeatherState weatherState,
  WeatherSettings settings,
) {
  const evaluator = WeatherThresholdEvaluator();
  final result = evaluator.evaluate(
    WeatherReading(
      humidityPercent: weatherState.humidity,
      windSpeedKph: weatherState.windSpeedKph,
      rainRate: weatherState.rainRate,
      cloudCoverPercent: weatherState.cloudCover,
    ),
    WeatherThresholds(
      maxHumidityPercent: settings.maxHumidityPercent,
      maxWindSpeedKph: settings.maxWindSpeedKph,
      maxCloudCoverPercent: settings.maxCloudCoverPercent,
    ),
  );
  return result.isSafe;
}

/// Read the hardware weather device as a three-state source verdict.
///
/// Top-level (not a method) so any surface that has to REPORT which sources
/// are usable applies the identical rule the safety evaluation acts on, without
/// standing up the evaluator.
SafetySourceReading readHardwareWeatherSource(
  WeatherState weatherState,
  WeatherSettings settings,
) {
  if (!_isSourceConfigured(
    weatherState.connectionState,
    weatherState.deviceId,
  )) {
    return SafetySourceReading.absent;
  }
  if (weatherState.connectionState != DeviceConnectionState.connected ||
      _isStaleReading(weatherState.lastUpdated)) {
    return SafetySourceReading.unknown;
  }
  return _evaluateHardwareWeather(weatherState, settings)
      ? SafetySourceReading.safe
      : SafetySourceReading.unsafe;
}

/// Read the safety monitor as a three-state source verdict. See
/// [readHardwareWeatherSource].
SafetySourceReading readSafetyMonitorSource(SafetyMonitorState monitorState) {
  if (!_isSourceConfigured(
    monitorState.connectionState,
    monitorState.deviceId,
  )) {
    return SafetySourceReading.absent;
  }
  if (monitorState.connectionState != DeviceConnectionState.connected ||
      _isStaleReading(monitorState.lastChecked)) {
    return SafetySourceReading.unknown;
  }
  return monitorState.isSafe
      ? SafetySourceReading.safe
      : SafetySourceReading.unsafe;
}

/// The three-state read of each hardware safety source.
///
/// Lets a settings surface state which sources are attached and usable without
/// building the whole evaluation (and its timers / API polling), while applying
/// exactly the rule [WeatherSafetyNotifier] acts on.
final weatherSafetySourceReadingsProvider =
    Provider<({SafetySourceReading weather, SafetySourceReading monitor})>((
      ref,
    ) {
      final settings =
          ref.watch(weatherSettingsDataProvider).valueOrNull ??
          const WeatherSettings();
      return (
        weather: readHardwareWeatherSource(
          ref.watch(weatherStateProvider),
          settings,
        ),
        monitor: readSafetyMonitorSource(ref.watch(safetyMonitorStateProvider)),
      );
    });
