// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

part of '../weather_safety_provider.dart';

/// Remote (companion) safety-status polling for [WeatherSafetyNotifier].
extension _WeatherSafetyRemote on WeatherSafetyNotifier {
  void _startRemoteStatusPolling() {
    unawaited(_refreshRemoteStatus());
    _remoteStatusTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(_refreshRemoteStatus());
    });
  }

  Future<void> _refreshRemoteStatus() async {
    if (_remoteFetchInFlight || !mounted) return;
    final backend = _ref.read(backendProvider);
    if (backend is! NetworkBackend) return;
    // isAuthTokenRejected: terminal credentials — polling can only 403, so
    // don't. But the last verdict fetched is no longer known to hold, and
    // leaving it on show would keep a stale "Safe" on the card all night.
    // Replace it once with the same unavailable state a failed poll writes.
    if (backend.isAuthTokenRejected) {
      if (state.failModeWarning != _authRejectedSafetyWarning) {
        state = WeatherSafetyState.initial().copyWith(
          failModeWarning: _authRejectedSafetyWarning,
          lastEvaluation: DateTime.now(),
        );
      }
      return;
    }
    _remoteFetchInFlight = true;
    try {
      final response = await backend.getSafetyStatus();
      if (!mounted) return;
      final rawStatus = response['safetyStatus'];
      final status = WeatherSafetyStatus.values.firstWhere(
        (candidate) => candidate.name == rawStatus,
        orElse: () => WeatherSafetyStatus.unsafe,
      );
      final rawSource = response['dataSource'];
      final dataSource = SafetyDataSource.values.firstWhere(
        (candidate) => candidate.name == rawSource,
        orElse: () => SafetyDataSource.unavailable,
      );
      final isSafe = status == WeatherSafetyStatus.safe;
      final failModeWarning = response['failModeWarning'] is String
          ? response['failModeWarning'] as String
          : null;
      final rawActions = response['actions'];
      bool actionFlag(String key, bool fallback) {
        if (rawActions is! Map) return fallback;
        final value = rawActions[key];
        return value is bool ? value : fallback;
      }

      String? actionText(String key) {
        if (rawActions is! Map) return null;
        final value = rawActions[key];
        return value is String ? value : null;
      }

      DateTime? wireDate(Object? value) =>
          value is String ? DateTime.tryParse(value) : null;

      final rawAlertLevel = response['currentAlertLevel'];
      final alertLevel = AlertLevel.values.firstWhere(
        (candidate) => candidate.name == rawAlertLevel,
        // A host whose aggregate response carries no severity projects
        // conservatively: unsafe maps to warning, never an unknown value to
        // clear.
        orElse: () => isSafe ? AlertLevel.clear : AlertLevel.warning,
      );
      final lastEvaluationRaw = response['lastEvaluation'];
      final snoozeUntilRaw = response['snoozeUntil'];
      final hardwareWeatherSafe =
          response['hardwareWeatherSafe'] as bool? ?? isSafe;
      final safetyMonitorSafe =
          response['safetyMonitorSafe'] as bool? ?? isSafe;
      state = WeatherSafetyState(
        status: status,
        actions: WeatherSafetyActions(
          shouldPause: actionFlag(
            'shouldPause',
            status == WeatherSafetyStatus.unsafe,
          ),
          shouldPark: actionFlag('shouldPark', false),
          shouldCloseDome: actionFlag('shouldCloseDome', false),
          reason:
              actionText('reason') ??
              (status == WeatherSafetyStatus.unsafe ? failModeWarning : null),
          resumeCheckTime: wireDate(actionText('resumeCheckTime')),
          advisoryOnly: actionFlag('advisoryOnly', false),
        ),
        snoozeUntil: wireDate(snoozeUntilRaw),
        currentAlertLevel: alertLevel,
        dataSource: dataSource,
        hardwareWeatherSafe: hardwareWeatherSafe,
        safetyMonitorSafe: safetyMonitorSafe,
        apiWeatherSafe: response['apiWeatherSafe'] as bool? ?? isSafe,
        hardwareWeatherReading: _readingFromWire(
          response['hardwareWeatherReading'],
          hardwareWeatherSafe,
        ),
        safetyMonitorReading: _readingFromWire(
          response['safetyMonitorReading'],
          safetyMonitorSafe,
        ),
        failModeWarning: failModeWarning,
        lastEvaluation: wireDate(lastEvaluationRaw),
        // Pre-parity hosts do not report whether monitoring is on or whether
        // the park/resume policies are armed. Assume the host IS monitoring
        // (claiming "not monitoring" about a host that is would be its own
        // lie) but never claim protection we have not been told about.
        monitoringEnabled: response['monitoringEnabled'] as bool? ?? true,
        autoParkArmed: response['autoParkArmed'] as bool? ?? false,
        autoResumeArmed: response['autoResumeArmed'] as bool? ?? false,
        decisionSource: WeatherDecisionSource.values.firstWhere(
          (candidate) => candidate.name == response['decisionSource'],
          orElse: () => WeatherDecisionSource.none,
        ),
        forecastUnsafe: response['forecastUnsafe'] as bool? ?? false,
        forecastHoldsRun: response['forecastHoldsRun'] as bool? ?? false,
        starEvidence: _starEvidenceFromWire(response['starEvidence']),
        starEvidenceOverridesForecast:
            response['starEvidenceOverridesForecast'] as bool? ?? false,
        snoozeReason: response['snoozeReason'] as String?,
      );
    } catch (error) {
      if (!mounted) return;
      state = WeatherSafetyState.initial().copyWith(
        failModeWarning: 'Imaging host safety status unavailable: $error',
        lastEvaluation: DateTime.now(),
      );
    } finally {
      _remoteFetchInFlight = false;
    }
  }
}

const _authRejectedSafetyWarning =
    'Imaging host safety status unavailable: the host rejected this '
    "device's access token";

SkyStarEvidence? _starEvidenceFromWire(Object? raw) {
  if (raw is! Map) return null;
  final latest = raw['latestStars'];
  final typical = raw['typicalStars'];
  final at = raw['latestAt'] is String
      ? DateTime.tryParse(raw['latestAt'] as String)
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

/// Pre-parity hosts do not send the per-source reading, so fall back to the
/// boolean they do send.
SafetySourceReading _readingFromWire(Object? raw, bool sourceSafe) {
  if (raw is String) {
    for (final candidate in SafetySourceReading.values) {
      if (candidate.name == raw) return candidate;
    }
  }
  return sourceSafe ? SafetySourceReading.safe : SafetySourceReading.unsafe;
}
