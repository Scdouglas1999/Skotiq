import 'package:skotiq_remote_protocol/wire.dart'
    show WireTime, tryParseWireTime;

import '../settings/app_settings.dart' show SafetyFailMode;
import 'weather_alert.dart' show AlertLevel;
import 'sky_star_evidence.dart';

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

  /// The unsafe verdict rests only on a forecast. The sequencer holds a run
  /// for it (when the operator chose that) and resumes it by itself; the app
  /// sends no pause, park or close of its own.
  final bool advisoryOnly;

  const WeatherSafetyActions({
    this.shouldPause = false,
    this.shouldPark = false,
    this.shouldCloseDome = false,
    this.reason,
    this.resumeCheckTime,
    this.advisoryOnly = false,
  });

  static const safe = WeatherSafetyActions();
}

/// Which input is deciding the weather verdict right now.
enum WeatherDecisionSource {
  /// Nothing says unsafe.
  none,

  /// An internet forecast or cloud model. Advisory: it warns or holds the
  /// run, never parks it or ends it.
  forecast,

  /// A weather device at the site, judged against the configured limits.
  weatherDevice,

  /// A safety monitor at the site.
  safetyMonitor,

  /// Astronomical dawn is near.
  dawn,

  /// No usable weather data; the fail mode decides.
  noData,
}

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

  /// Which input decides the verdict.
  final WeatherDecisionSource decisionSource;

  /// The forecast says cloudy, whether or not that is acted on.
  final bool forecastUnsafe;

  /// A forecast that says cloudy holds the run rather than only warning.
  final bool forecastHoldsRun;

  /// What the run's own recent frames say about the sky, when they can say.
  final SkyStarEvidence? starEvidence;

  /// The forecast says cloudy but recent frames full of stars outweigh it.
  final bool starEvidenceOverridesForecast;

  /// Why the operator set the verdict aside (the "sky is clear" override).
  final String? snoozeReason;

  /// On a remote client: the host's verdict could not be read, so [status]
  /// is a placeholder and the safety state is unknown, not unsafe.
  final bool hostVerdictUnavailable;

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
    this.decisionSource = WeatherDecisionSource.none,
    this.forecastUnsafe = false,
    this.forecastHoldsRun = false,
    this.starEvidence,
    this.starEvidenceOverridesForecast = false,
    this.snoozeReason,
    this.hostVerdictUnavailable = false,
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

  /// The imaging host's verdict as `GET /api/safety/status` reports it and
  /// a linked client reads it back with [WeatherSafetyState.fromJson].
  ///
  /// `isSafe` is true both when conditions were checked and found good and
  /// when nothing was checked at all; `monitoringEnabled`, `autoParkArmed`
  /// and `autoResumeArmed` tell a client which, so a phone cannot show
  /// "conditions safe for imaging" over a host that is not monitoring, or
  /// claim auto-park protection the composed policy does not arm.
  Map<String, dynamic> toJson() => {
    'isSafe': isSafe,
    'safetyStatus': status.name,
    'currentAlertLevel': currentAlertLevel.name,
    'dataSource': dataSource.name,
    'hardwareWeatherSafe': hardwareWeatherSafe,
    'safetyMonitorSafe': safetyMonitorSafe,
    'apiWeatherSafe': apiWeatherSafe,
    'hardwareWeatherReading': hardwareWeatherReading.name,
    'safetyMonitorReading': safetyMonitorReading.name,
    'monitoringEnabled': monitoringEnabled,
    'autoParkArmed': autoParkArmed,
    'autoResumeArmed': autoResumeArmed,
    'actions': {
      'shouldPause': actions.shouldPause,
      'shouldPark': actions.shouldPark,
      'shouldCloseDome': actions.shouldCloseDome,
      'reason': actions.reason,
      'resumeCheckTime': actions.resumeCheckTime?.toWireTime(),
      'advisoryOnly': actions.advisoryOnly,
    },
    'decisionSource': decisionSource.name,
    'advisoryOnly': advisoryOnly,
    'forecastUnsafe': forecastUnsafe,
    'forecastHoldsRun': forecastHoldsRun,
    'starEvidenceOverridesForecast': starEvidenceOverridesForecast,
    'starEvidence': switch (starEvidence) {
      final evidence? => {
        'latestStars': evidence.latestStars,
        'typicalStars': evidence.typicalStars,
        'latestAt': evidence.latestAt.toWireTime(),
        'clear': evidence.clear,
      },
      null => null,
    },
    'snoozeReason': snoozeReason,
    'failModeWarning': failModeWarning,
    'lastEvaluation': lastEvaluation?.toWireTime(),
    'snoozeUntil': snoozeUntil?.toWireTime(),
  };

  /// The host verdict [toJson] wrote. Throws when a field is missing or of
  /// the wrong type: the two ends disagree, and no verdict is shown.
  factory WeatherSafetyState.fromJson(Map<String, dynamic> json) {
    final rawActions = json['actions'] as Map;
    bool actionFlag(String key) => rawActions[key] as bool;
    String? actionText(String key) => rawActions[key] as String?;
    DateTime? wireDate(Object? value) =>
        value is String ? tryParseWireTime(value) : null;
    SafetySourceReading reading(Object? raw) =>
        SafetySourceReading.values.byName(raw as String);
    return WeatherSafetyState(
      status: WeatherSafetyStatus.values.byName(json['safetyStatus'] as String),
      actions: WeatherSafetyActions(
        shouldPause: actionFlag('shouldPause'),
        shouldPark: actionFlag('shouldPark'),
        shouldCloseDome: actionFlag('shouldCloseDome'),
        reason: actionText('reason'),
        resumeCheckTime: wireDate(actionText('resumeCheckTime')),
        advisoryOnly: actionFlag('advisoryOnly'),
      ),
      snoozeUntil: wireDate(json['snoozeUntil']),
      currentAlertLevel: AlertLevel.values.byName(
        json['currentAlertLevel'] as String,
      ),
      dataSource: SafetyDataSource.values.byName(json['dataSource'] as String),
      hardwareWeatherSafe: json['hardwareWeatherSafe'] as bool,
      safetyMonitorSafe: json['safetyMonitorSafe'] as bool,
      apiWeatherSafe: json['apiWeatherSafe'] as bool,
      hardwareWeatherReading: reading(json['hardwareWeatherReading']),
      safetyMonitorReading: reading(json['safetyMonitorReading']),
      failModeWarning: json['failModeWarning'] as String?,
      lastEvaluation: wireDate(json['lastEvaluation']),
      monitoringEnabled: json['monitoringEnabled'] as bool,
      autoParkArmed: json['autoParkArmed'] as bool,
      autoResumeArmed: json['autoResumeArmed'] as bool,
      decisionSource: WeatherDecisionSource.values.byName(
        json['decisionSource'] as String,
      ),
      forecastUnsafe: json['forecastUnsafe'] as bool,
      forecastHoldsRun: json['forecastHoldsRun'] as bool,
      starEvidence: _starEvidenceFromJson(json['starEvidence']),
      starEvidenceOverridesForecast:
          json['starEvidenceOverridesForecast'] as bool,
      snoozeReason: json['snoozeReason'] as String?,
    );
  }

  bool get isSafe => status == WeatherSafetyStatus.safe;

  /// The unsafe verdict rests only on a forecast: it warns, or holds the run
  /// when [forecastHoldsRun], and never parks or ends it.
  bool get advisoryOnly =>
      status == WeatherSafetyStatus.unsafe && actions.advisoryOnly;

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
    WeatherDecisionSource? decisionSource,
    bool? forecastUnsafe,
    bool? forecastHoldsRun,
    SkyStarEvidence? starEvidence,
    bool clearStarEvidence = false,
    bool? starEvidenceOverridesForecast,
    String? snoozeReason,
    bool? hostVerdictUnavailable,
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
      decisionSource: decisionSource ?? this.decisionSource,
      forecastUnsafe: forecastUnsafe ?? this.forecastUnsafe,
      forecastHoldsRun: forecastHoldsRun ?? this.forecastHoldsRun,
      starEvidence: clearStarEvidence
          ? null
          : (starEvidence ?? this.starEvidence),
      starEvidenceOverridesForecast:
          starEvidenceOverridesForecast ?? this.starEvidenceOverridesForecast,
      snoozeReason: clearSnooze ? null : (snoozeReason ?? this.snoozeReason),
      hostVerdictUnavailable:
          hostVerdictUnavailable ?? this.hostVerdictUnavailable,
    );
  }
}

SkyStarEvidence? _starEvidenceFromJson(Object? raw) {
  if (raw is! Map) return null;
  final latest = raw['latestStars'];
  final typical = raw['typicalStars'];
  final at = raw['latestAt'] is String
      ? tryParseWireTime(raw['latestAt'] as String)
      : null;
  final clear = raw['clear'];
  if (latest is! int || typical is! int || at == null || clear is! bool) {
    return null;
  }
  return SkyStarEvidence(
    latestStars: latest,
    typicalStars: typical,
    latestAt: at,
    clear: clear,
  );
}
