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
    final remote = _ref.read(linkedHostWeatherProvider);
    final link = _ref.read(linkedHostLinkProvider);
    if (remote == null || link == null) return;
    // isAuthTokenRejected: terminal credentials — polling can only 403, so
    // don't. But the last verdict fetched is no longer known to hold, and
    // leaving it on show would keep a stale "Safe" on the card all night.
    // Replace it once with the same unavailable state a failed poll writes.
    if (link.isAuthTokenRejected) {
      if (state.failModeWarning != _authRejectedSafetyWarning) {
        state = WeatherSafetyState.initial().copyWith(
          failModeWarning: _authRejectedSafetyWarning,
          lastEvaluation: DateTime.now(),
          hostVerdictUnavailable: true,
        );
      }
      return;
    }
    _remoteFetchInFlight = true;
    try {
      final response = await remote.getSafetyStatus();
      if (!mounted) return;
      final status = WeatherSafetyStatus.values.byName(
        response['safetyStatus'] as String,
      );
      final dataSource = SafetyDataSource.values.byName(
        response['dataSource'] as String,
      );
      final failModeWarning = response['failModeWarning'] as String?;
      final rawActions = response['actions'] as Map;
      bool actionFlag(String key) => rawActions[key] as bool;
      String? actionText(String key) => rawActions[key] as String?;
      DateTime? wireDate(Object? value) =>
          value is String ? tryParseWireTime(value) : null;
      final alertLevel = AlertLevel.values.byName(
        response['currentAlertLevel'] as String,
      );
      final lastEvaluationRaw = response['lastEvaluation'];
      final snoozeUntilRaw = response['snoozeUntil'];
      final hardwareWeatherSafe = response['hardwareWeatherSafe'] as bool;
      final safetyMonitorSafe = response['safetyMonitorSafe'] as bool;
      state = WeatherSafetyState(
        status: status,
        actions: WeatherSafetyActions(
          shouldPause: actionFlag('shouldPause'),
          shouldPark: actionFlag('shouldPark'),
          shouldCloseDome: actionFlag('shouldCloseDome'),
          reason: actionText('reason'),
          resumeCheckTime: wireDate(actionText('resumeCheckTime')),
          advisoryOnly: actionFlag('advisoryOnly'),
        ),
        snoozeUntil: wireDate(snoozeUntilRaw),
        currentAlertLevel: alertLevel,
        dataSource: dataSource,
        hardwareWeatherSafe: hardwareWeatherSafe,
        safetyMonitorSafe: safetyMonitorSafe,
        apiWeatherSafe: response['apiWeatherSafe'] as bool,
        hardwareWeatherReading: _readingFromWire(
          response['hardwareWeatherReading'],
        ),
        safetyMonitorReading: _readingFromWire(
          response['safetyMonitorReading'],
        ),
        failModeWarning: failModeWarning,
        lastEvaluation: wireDate(lastEvaluationRaw),
        monitoringEnabled: response['monitoringEnabled'] as bool,
        autoParkArmed: response['autoParkArmed'] as bool,
        autoResumeArmed: response['autoResumeArmed'] as bool,
        decisionSource: WeatherDecisionSource.values.byName(
          response['decisionSource'] as String,
        ),
        forecastUnsafe: response['forecastUnsafe'] as bool,
        forecastHoldsRun: response['forecastHoldsRun'] as bool,
        starEvidence: _starEvidenceFromWire(response['starEvidence']),
        starEvidenceOverridesForecast:
            response['starEvidenceOverridesForecast'] as bool,
        snoozeReason: response['snoozeReason'] as String?,
      );
    } catch (error) {
      if (!mounted) return;
      state = WeatherSafetyState.initial().copyWith(
        failModeWarning:
            'Imaging host safety status unavailable: ${userFacingError(error)}',
        lastEvaluation: DateTime.now(),
        hostVerdictUnavailable: true,
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

SafetySourceReading _readingFromWire(Object? raw) =>
    SafetySourceReading.values.byName(raw as String);
