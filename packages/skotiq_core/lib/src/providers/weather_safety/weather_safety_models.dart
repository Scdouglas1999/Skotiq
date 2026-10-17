part of '../weather_safety_provider.dart';

/// How a [SafetyFailMode] resolves the "no usable safety/weather data"
/// situation (no connected source on the Dart side; poll error on the Rust
/// side).
///
/// Architecture-unification 2026-06-05 (Subsystem 2 step 1, cross-language
/// parity). This is the Dart mirror of the Rust `NoDataResolution` enum in
/// `native/skotiq_native/sequencer/src/lib.rs`. The two MUST agree on the
/// same truth table; [noDataFailModeResolution] below is the single Dart
/// definition and is pinned against the identical table by
/// `test/services/weather/weather_fail_mode_parity_test.dart`, which
/// cross-references the Rust test `safety_fail_mode_no_data_resolution_truth_table`.
enum NoDataResolution {
  /// Treat the absence of data as UNSAFE (fail closed). Dart pushes
  /// `Some(true)`; Rust sets `weather_safe = false`.
  unsafe,

  /// Treat the absence of data as SAFE (fail open). Dart ABSTAINS (`null`)
  /// rather than asserting SAFE — a permissive policy must never gag a
  /// hardware-unsafe device — but the resolution row is "safe". Rust sets
  /// `weather_safe = true`.
  safe,

  /// Preserve the prior reading and emit an operator warning (warn-only). Dart
  /// ABSTAINS (`null`); Rust leaves `weather_safe` unchanged.
  preserve,
}

/// The single Dart definition of how each [SafetyFailMode] resolves a no-data
/// situation. Cross-language parity: mirrors the Rust
/// `safety_fail_mode_no_data_resolution`. If you change a row here, change it in
/// BOTH parity tests (Dart + Rust) or they will fail.
NoDataResolution noDataFailModeResolution(SafetyFailMode mode) {
  switch (mode) {
    case SafetyFailMode.failClosed:
      return NoDataResolution.unsafe;
    case SafetyFailMode.failOpen:
      return NoDataResolution.safe;
    case SafetyFailMode.warnOnly:
      return NoDataResolution.preserve;
  }
}

/// What a single safety source currently contributes to the combined verdict.
///
/// A bare `bool` per source cannot tell "the sensor says safe" apart from "the
/// sensor is configured but has stopped answering", so an unreachable sensor
/// keeps an optimistic `true` and the rig reads SAFE in fail-closed mode while
/// its own device row says `connected: false`.
enum SafetySourceReading {
  /// The operator has no such source configured; it contributes nothing and
  /// must never force unsafe on its own.
  absent,

  /// Configured but currently unreadable: unreachable, erroring, or older than
  /// the freshness budget. Resolved through the fail mode, so fail-closed
  /// treats it as unsafe and the permissive modes do not.
  unknown,

  /// The source has a current reading and it is within limits.
  safe,

  /// The source has a current reading and it is out of limits.
  unsafe,
}

/// Weather safety status for sequencer integration
enum WeatherSafetyStatus {
  /// OK to continue imaging
  safe,

  /// Should pause/park
  unsafe,

  /// Temporarily ignoring alerts
  snoozed,
}

/// Actions recommended by weather safety system
class WeatherSafetyActions {
  final bool shouldPause;
  final bool shouldPark;
  final bool shouldCloseDome;
  final String? reason;
  final DateTime? resumeCheckTime;

  const WeatherSafetyActions({
    this.shouldPause = false,
    this.shouldPark = false,
    this.shouldCloseDome = false,
    this.reason,
    this.resumeCheckTime,
  });

  static const safe = WeatherSafetyActions();
}

/// Source of safety data
enum SafetyDataSource {
  /// Data from external weather API (Open-Meteo, radar, etc.)
  weatherApi,

  /// Data from connected hardware weather device
  hardwareWeather,

  /// Data from connected safety monitor device
  safetyMonitor,

  /// Combined evaluation of multiple sources
  combined,

  /// No data source available (using fail mode)
  unavailable,
}

class WeatherSafetyState {
  final WeatherSafetyStatus status;
  final WeatherSafetyActions actions;
  final DateTime? snoozeUntil;
  final AlertLevel currentAlertLevel;
  final SafetyDataSource dataSource;
  final bool hardwareWeatherSafe;
  final bool safetyMonitorSafe;
  final bool apiWeatherSafe;
  final SafetySourceReading hardwareWeatherReading;
  final SafetySourceReading safetyMonitorReading;
  final String? failModeWarning;
  final DateTime? lastEvaluation;

  /// Whether weather safety is actually being monitored.
  ///
  /// When the operator has "Enable weather safety" switched off nothing is
  /// evaluated, so [status] falls through to [WeatherSafetyStatus.safe] purely
  /// because there is no verdict to report. UI must NOT render that as a green
  /// "conditions safe for imaging" — it is "not assessed". Surfaces read this
  /// flag to tell the two states apart.
  final bool monitoringEnabled;

  /// Whether unsafe WEATHER would actually park the mount.
  ///
  /// Composed truth: auto-park needs the weather-safety master switch, the
  /// Sequencer "Park on unsafe weather" policy AND the Weather Safety
  /// "Auto-park mount" toggle. Any surface that reports auto-park to the
  /// operator must use this instead of a single toggle, otherwise it claims
  /// protection the rig does not have.
  ///
  /// Weather-only by design: the park-before-dawn watchdog also parks with
  /// weather safety off, and folding it in here would let a weather panel
  /// imply the sky is watched when nothing is watching it.
  final bool autoParkArmed;

  /// Whether auto-resume would actually run (needs the master switch too).
  final bool autoResumeArmed;

  const WeatherSafetyState({
    required this.status,
    required this.actions,
    this.snoozeUntil,
    required this.currentAlertLevel,
    this.dataSource = SafetyDataSource.weatherApi,
    this.hardwareWeatherSafe = true,
    this.safetyMonitorSafe = true,
    this.apiWeatherSafe = true,
    this.hardwareWeatherReading = SafetySourceReading.absent,
    this.safetyMonitorReading = SafetySourceReading.absent,
    this.failModeWarning,
    this.lastEvaluation,
    this.monitoringEnabled = true,
    this.autoParkArmed = false,
    this.autoResumeArmed = false,
  });

  factory WeatherSafetyState.initial() => const WeatherSafetyState(
    status: WeatherSafetyStatus.unsafe,
    actions: WeatherSafetyActions(
      shouldPause: true,
      reason: 'Weather safety has not been evaluated yet',
    ),
    currentAlertLevel: AlertLevel.clear,
    dataSource: SafetyDataSource.unavailable,
    hardwareWeatherSafe: false,
    safetyMonitorSafe: false,
    apiWeatherSafe: false,
    hardwareWeatherReading: SafetySourceReading.unknown,
    safetyMonitorReading: SafetySourceReading.unknown,
  );

  /// Check if conditions are safe for imaging
  bool get isSafe => status == WeatherSafetyStatus.safe;

  WeatherSafetyState copyWith({
    WeatherSafetyStatus? status,
    WeatherSafetyActions? actions,
    DateTime? snoozeUntil,
    bool clearSnooze = false,
    AlertLevel? currentAlertLevel,
    SafetyDataSource? dataSource,
    bool? hardwareWeatherSafe,
    bool? safetyMonitorSafe,
    bool? apiWeatherSafe,
    SafetySourceReading? hardwareWeatherReading,
    SafetySourceReading? safetyMonitorReading,
    String? failModeWarning,
    bool clearWarning = false,
    DateTime? lastEvaluation,
    bool? monitoringEnabled,
    bool? autoParkArmed,
    bool? autoResumeArmed,
  }) {
    return WeatherSafetyState(
      status: status ?? this.status,
      actions: actions ?? this.actions,
      snoozeUntil: clearSnooze ? null : (snoozeUntil ?? this.snoozeUntil),
      currentAlertLevel: currentAlertLevel ?? this.currentAlertLevel,
      dataSource: dataSource ?? this.dataSource,
      hardwareWeatherSafe: hardwareWeatherSafe ?? this.hardwareWeatherSafe,
      safetyMonitorSafe: safetyMonitorSafe ?? this.safetyMonitorSafe,
      apiWeatherSafe: apiWeatherSafe ?? this.apiWeatherSafe,
      hardwareWeatherReading:
          hardwareWeatherReading ?? this.hardwareWeatherReading,
      safetyMonitorReading: safetyMonitorReading ?? this.safetyMonitorReading,
      failModeWarning: clearWarning
          ? null
          : (failModeWarning ?? this.failModeWarning),
      lastEvaluation: lastEvaluation ?? this.lastEvaluation,
      monitoringEnabled: monitoringEnabled ?? this.monitoringEnabled,
      autoParkArmed: autoParkArmed ?? this.autoParkArmed,
      autoResumeArmed: autoResumeArmed ?? this.autoResumeArmed,
    );
  }
}
