import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/weather/weather_models.dart';
import '../models/equipment/equipment_models.dart';
import '../models/settings/app_settings.dart';
import '../models/sequence/sequence_models.dart'
    show
        ConditionsScoreWeights,
        SequenceExecutionState,
        SequenceExecutionStateCapabilities;
import '../backend/disconnected_backend.dart';
import '../backend/skotiq_backend.dart';
import '../backend/network_backend.dart';
import '../services/scheduler/sky_calculations.dart';
import '../services/adaptive_swap_service.dart';
import '../services/safe_rig_service.dart';
import '../services/safety_config_service.dart';
import '../services/weather/weather_threshold_evaluator.dart';
import '../services/logging_service.dart';
import '../database/database.dart' as db;
import 'session_provider.dart';
import 'database_provider.dart';
import 'imaging_provider.dart';
import 'science_provider.dart';
import 'secondary_rig_provider.dart';
import 'weather_providers.dart';
import 'equipment_provider.dart';
import 'settings_provider.dart';
import 'ui_notification_provider.dart';
import 'backend_provider.dart';
import 'sequence_provider.dart';
import '../services/end_of_night_calibration/eon_providers.dart'
    show calibrationOnlyRunActiveProvider;

part 'weather_safety/weather_safety_models.dart';
part 'weather_safety/weather_safety_sources.dart';
part 'weather_safety/weather_safety_remote.dart';
part 'weather_safety/weather_safety_enforcement.dart';
part 'weather_safety/weather_safety_executor_push.dart';
part 'weather_safety/weather_star_evidence.dart';

// Note: All async callbacks and stream listeners check `mounted`
// before updating state to prevent updates after disposal.

/// Notifier for weather safety state
class WeatherSafetyNotifier extends StateNotifier<WeatherSafetyState> {
  final Ref _ref;
  final BackendNotifier _backendNotifier;
  final Duration _autoResumeDelay;
  StreamSubscription? _alertSubscription;
  Timer? _snoozeTimer;
  Timer? _periodicEvalTimer;
  Timer? _resumeDelayTimer;
  // Periodic push of the cloud-motion analyzer output to
  // the Rust executor. Independent of the 5-min evaluation tick so the
  // Rust-side cloud-aware triggers see fresh data even between full
  // re-evaluations.
  Timer? _cloudMotionPushTimer;
  Timer? _adaptiveConditionsPushTimer;
  Timer? _remoteStatusTimer;
  Timer? _sourceChangeEvaluationTimer;
  Timer? _verdictHeartbeatTimer;
  bool _remoteFetchInFlight = false;
  bool _forecastRefreshInFlight = false;
  DateTime? _lastForecastRefreshAt;
  bool _evaluationInFlight = false;
  DateTime? _evaluationStartedAt;

  /// The verdict last sent to the sequencer, re-sent on every heartbeat so a
  /// quiet spell in the evaluation never reads as a dead feed.
  ({bool? unsafe, bool advisory})? _lastVerdict;
  int? _lastResumeAfterSecs;

  SkyStarEvidence? _starEvidence;
  bool _decisionPolicyWatched = false;
  bool _starEvidenceRefreshInFlight = false;

  /// Whether the operator has been told, this forecast episode, that a
  /// forecast is only being warned about.
  bool _forecastWarningAnnounced = false;
  bool _evaluationPending = false;
  bool _resumeInFlight = false;
  int _autoResumeGeneration = 0;

  /// Latch ensuring a successful safe-the-rig enforcement fires exactly once
  /// per unsafe episode. Set only after every requested action succeeds and
  /// cleared when conditions return to safe. A failed attempt stays re-armed
  /// for the next periodic evaluation.
  bool _safeRigEnforced = false;

  /// One-shot guard for the "nothing to safe" disclosure so the periodic
  /// evaluator cannot repeat it every 5 minutes for a whole unsafe episode.
  /// Cleared with [_safeRigEnforced] when conditions return to safe.
  bool _nothingToSafeAnnounced = false;
  bool _enforceInFlight = false;
  bool _weatherPausedSequence = false;
  bool _weatherParkedMount = false;

  /// Periodic re-evaluation interval (5 minutes)
  static const _evaluationInterval = Duration(minutes: 5);
  static const _parkBeforeDawnLeadTime = Duration(minutes: 30);

  /// Ceiling on how long [evaluateNow] waits for an evaluation to settle.
  static const _evaluateNowTimeout = Duration(seconds: 10);

  /// How old a hardware source's last successful read may be before it stops
  /// counting as data. Device telemetry is polled every 5 seconds, so this is
  /// generous; it exists to catch a source that has frozen while still
  /// reporting itself connected.

  /// Push cadence for cloud-motion data into the Rust
  /// executor. 60 seconds matches the brief's "every 60s say".
  static const _cloudMotionPushInterval = Duration(seconds: 60);

  /// How often the verdict is re-sent to the sequencer and the forecast's age
  /// checked. Well inside the sequencer's six-minute staleness window.
  static const _verdictHeartbeatInterval = Duration(seconds: 60);

  /// How long switching weather safety off sets the app's verdict aside in
  /// the sequencer: the rest of any night. Switching it back on ends it.
  static const _safetyOffClearSecs = 24 * 3600;

  /// An evaluation that has not finished in this long is treated as lost so
  /// the next one can run; a wedged evaluation must not freeze the verdict.
  static const _evaluationWedgeTimeout = Duration(seconds: 60);
  static const _adaptiveConditionsPushInterval = Duration(seconds: 30);

  /// `cloudCoverPercentageProvider` is a one-shot FutureProvider: without an
  /// explicit invalidation its first result (including a transient-failure
  /// null) is cached for the whole session, so the safety pushes would feed
  /// the executor the same startup sample all night. Re-fetch on a TTL from
  /// this notifier's existing push cadence — no extra Timer, so widget tests
  /// that mount cloud-cover consumers stay timer-leak free. Failures retry
  /// sooner than successes so an Open-Meteo blip doesn't blind the safety
  /// triggers for long.
  static const _cloudCoverTtl = Duration(minutes: 10);
  static const _cloudCoverErrorRetryTtl = Duration(minutes: 2);
  DateTime? _cloudCoverFetchedAt;

  /// Why: when weather first reads "safe" after an unsafe stretch we wait a
  /// hold-off period before unparking. Astronomical conditions are noisy —
  /// a transient cloud break can read as "safe" for a single sample before
  /// the front re-arrives, and unparking immediately can leave the rig
  /// mid-recovery when the next gust/cloud hits. Default 5 minutes matches
  /// the periodic re-evaluation cadence so we have at least one confirmation
  /// sample before committing to the resume.
  static const _autoResumeHoldoff = Duration(minutes: 5);

  /// Wall clock for the park-before-dawn check. Injectable so a test can
  /// stand half an hour before dawn without waiting for one.
  final DateTime Function() _clock;

  WeatherSafetyNotifier(
    Ref ref, {
    Duration autoResumeDelay = _autoResumeHoldoff,
    @visibleForTesting DateTime Function()? clock,
  }) : _ref = ref,
       _backendNotifier = ref.read(backendProvider.notifier),
       _autoResumeDelay = autoResumeDelay,
       _clock = clock ?? DateTime.now,
       super(WeatherSafetyState.initial()) {
    final backend = _ref.read(backendProvider);
    if (backend is NetworkBackend) {
      _startRemoteStatusPolling();
      return;
    }
    if (backend is DisconnectedBackend) {
      // UI-only mode has no rig to protect and no authority to issue hardware
      // commands. Keep the conservative unknown/unsafe verdict so imaging is
      // never presented as weather-safe, but make the state passive: evaluating
      // the fail-closed policy here would invoke SafeRig against a deliberately
      // disconnected backend and report a pair of false CRITICAL failures.
      state = state.copyWith(
        actions: WeatherSafetyActions.safe,
        failModeWarning:
            'Connect to an imaging host to evaluate weather safety.',
      );
      return;
    }
    _subscribeToAlerts();
    // Hardware connection and telemetry changes are evaluation triggers, not
    // just alert changes and the five-minute timer: a newly connected
    // weather/safety device would otherwise read "unavailable" for minutes.
    // The environment poll re-reports these every 5 seconds, refreshing only
    // `lastUpdated`/`lastChecked`. Evaluating on a bare freshness bump would
    // re-run the whole safety assessment and re-push the verdict over FFI all
    // night on a rig whose weather is simply not changing; any OTHER field
    // difference still evaluates immediately. Freshness itself is a function of
    // wall-clock, and the periodic evaluation timer owns the stale transition.
    _ref.listen<WeatherState>(weatherStateProvider, (previous, next) {
      if (previous != null &&
          previous.copyWith(lastUpdated: next.lastUpdated) == next) {
        return;
      }
      _scheduleSourceChangeEvaluation();
    });
    _ref.listen<SafetyMonitorState>(safetyMonitorStateProvider, (
      previous,
      next,
    ) {
      if (previous != null &&
          previous.copyWith(lastChecked: next.lastChecked) == next) {
        return;
      }
      _scheduleSourceChangeEvaluation();
    });
    // Configuration changes are safety inputs too: persisting
    // weatherSafetyEnabled/failMode has to move this notifier's verdict, not
    // wait for the five-minute timer or an unrelated device event.
    _ref.listen<AsyncValue<WeatherSettings>>(weatherSettingsDataProvider, (
      previous,
      next,
    ) {
      // Switching weather safety off releases a held run at once: the verdict
      // is withdrawn and the sequencer is told to stop acting on the app's
      // weather, without waiting for an evaluation (that might itself be what
      // is stuck) or for the safe period. A hardware safety monitor still
      // counts. Switching it back on ends that.
      final was = previous?.valueOrNull?.weatherSafetyEnabled;
      final now = next.valueOrNull?.weatherSafetyEnabled;
      if (now == false) {
        unawaited(_pushWeatherVerdict(null));
        if (was != false) {
          unawaited(
            _pushOperatorClear(
              WeatherSafetyNotifier._safetyOffClearSecs,
              'Weather safety switched off',
            ),
          );
        }
      } else if (now == true && was == false) {
        unawaited(_pushOperatorClear(0, 'Weather safety switched on'));
      }
      _scheduleSourceChangeEvaluation();
    });

    _ref.listen<AsyncValue<AppSettingsState>>(appSettingsProvider, (_, __) {
      _scheduleSourceChangeEvaluation();
    });
    _startPeriodicEvaluation();
    // Start the cloud-motion forwarding loop so the Rust
    // sequencer's cloud-aware triggers see live data the first time the
    // notifier is constructed (typically at app launch).
    _startCloudMotionPush();
    _startAdaptiveConditionsPush();
    _startVerdictHeartbeat();
  }

  /// Start periodic re-evaluation timer independent of weather screen
  void _startPeriodicEvaluation() {
    _periodicEvalTimer?.cancel();
    _periodicEvalTimer = Timer.periodic(_evaluationInterval, (_) {
      if (!mounted) return;
      _evaluateAllSources();
    });
    // Also run initial evaluation, but not synchronously from the provider
    // constructor: evaluation can post UI notifications when conditions are
    // unsafe, and Riverpod forbids modifying another provider while this one is
    // still initializing.
    Timer.run(() {
      if (!mounted) return;
      _evaluateAllSources();
    });
  }

  void _scheduleSourceChangeEvaluation() {
    _sourceChangeEvaluationTimer?.cancel();
    _sourceChangeEvaluationTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        _evaluateAllSources();
      }
    });
  }

  /// Evaluate all safety sources (API weather, hardware weather, safety monitor)
  void _evaluateAllSources() {
    unawaited(_evaluateAllSourcesAsync());
  }

  Future<void> _evaluateAllSourcesAsync() async {
    if (!mounted) return;
    if (_evaluationInFlight) {
      final startedAt = _evaluationStartedAt;
      final wedged =
          startedAt != null &&
          DateTime.now().difference(startedAt) >
              WeatherSafetyNotifier._evaluationWedgeTimeout;
      if (!wedged) {
        _evaluationPending = true;
        return;
      }
      developer.log(
        'weather: an evaluation has not finished in '
        '${WeatherSafetyNotifier._evaluationWedgeTimeout.inSeconds} s; '
        'starting a fresh one',
        name: 'WeatherSafety',
        level: 900,
      );
    }
    _evaluationInFlight = true;
    final startedAt = DateTime.now();
    _evaluationStartedAt = startedAt;
    try {
      final weatherSettings = await _ref.read(
        weatherSettingsDataProvider.future,
      );
      final appSettings = await _ref.read(appSettingsProvider.future);
      if (!mounted) return;
      // Both are read from what is already loaded; each schedules a fresh
      // evaluation when it changes, so a verdict is never held up on them.
      final policy = _currentDecisionPolicy();
      _evaluateAllSourcesWithConfiguration(
        weatherSettings,
        appSettings,
        policy: policy,
        starEvidence: _starEvidence,
      );
    } catch (error) {
      if (!mounted) return;
      final failure = WeatherSafetyState.initial().copyWith(
        failModeWarning: 'Weather safety configuration unavailable: $error',
        lastEvaluation: DateTime.now(),
      );
      state = failure;
      _cancelPendingAutoResume();
      unawaited(_pushWeatherVerdict(true));
      if (!_safeRigEnforced) {
        unawaited(_enforceSafetyActionsAndLatch(failure.actions));
      }
    } finally {
      // A newer evaluation that replaced a wedged one owns the flag now.
      if (identical(_evaluationStartedAt, startedAt)) {
        _evaluationInFlight = false;
      }
      if (_evaluationPending && mounted) {
        _evaluationPending = false;
        _evaluateAllSources();
      }
    }
  }

  void _evaluateAllSourcesWithConfiguration(
    WeatherSettings weatherSettings,
    AppSettingsState appSettings, {
    WeatherDecisionPolicy policy = WeatherDecisionPolicy.defaults,
    SkyStarEvidence? starEvidence,
  }) {
    if (!mounted) return;
    final failMode = appSettings.safetyFailMode;
    final parkPolicyEnabled = appSettings.parkOnUnsafeWeather;
    final shouldAutoPark = parkPolicyEnabled && weatherSettings.autoParkEnabled;
    final dawnParkDue = _isParkBeforeDawnDue(appSettings);
    var shouldShowFailModeWarning = false;

    // Read each hardware source as a three-state verdict. A source the
    // operator has configured but that is unreachable or stale reads `unknown`
    // and is resolved through the fail mode below; it must never keep an
    // optimistic "safe" just because its device is no longer connected.
    final weatherDeviceState = _ref.read(weatherStateProvider);
    final safetyMonitorState = _ref.read(safetyMonitorStateProvider);
    final hardwareWeatherReading = readHardwareWeatherSource(
      weatherDeviceState,
      weatherSettings,
    );
    final safetyMonitorReading = readSafetyMonitorSource(safetyMonitorState);

    final unknownIsUnsafe =
        noDataFailModeResolution(failMode) == NoDataResolution.unsafe;
    bool resolveSource(SafetySourceReading reading) => switch (reading) {
      SafetySourceReading.unsafe => false,
      SafetySourceReading.unknown => !unknownIsUnsafe,
      SafetySourceReading.safe || SafetySourceReading.absent => true,
    };
    final hardwareWeatherSafe = resolveSource(hardwareWeatherReading);
    final safetyMonitorSafe = resolveSource(safetyMonitorReading);

    final unreachableSources = <String>[
      if (hardwareWeatherReading == SafetySourceReading.unknown)
        'Weather device',
      if (safetyMonitorReading == SafetySourceReading.unknown) 'Safety monitor',
    ];
    final unreachableWarning = unreachableSources.isEmpty
        ? null
        : '${unreachableSources.join(' and ')} is not reporting; '
              'no current safety data';

    // The internet forecast. One that has not refreshed in a while is no
    // data at all: acting on it is what held a run for a cloud that had long
    // gone.
    final alertService = _ref.read(weatherAlertServiceProvider);
    final rawAlert = alertService.currentAlert;
    final alertStale =
        rawAlert != null && _isForecastStale(rawAlert, weatherSettings);
    final currentAlert = alertStale ? null : rawAlert;
    if (alertStale) _requestForecastRefresh();
    final apiWeatherSafe =
        currentAlert == null ||
        currentAlert.level == AlertLevel.clear ||
        currentAlert.level == AlertLevel.watch;
    final forecastUnsafe = !apiWeatherSafe;
    // Frames full of stars are a reading of the sky; a forecast is a model
    // of it. When the two disagree the frames win, if the operator allows it.
    final starsOverrideForecast =
        forecastUnsafe &&
        policy.starEvidenceOverridesForecast &&
        starEvidence?.clear == true;
    final forecastActs = forecastUnsafe && !starsOverrideForecast;
    if (forecastUnsafe) {
      // Only a cloudy forecast needs the policy and the frames' evidence, so
      // they are read from the database only then.
      _watchDecisionPolicy();
      unawaited(_refreshStarEvidence());
    }

    // Determine data source
    final hasLiveHardwareSource =
        _isLiveReading(hardwareWeatherReading) ||
        _isLiveReading(safetyMonitorReading);
    SafetyDataSource dataSource;
    if (hasLiveHardwareSource) {
      dataSource = SafetyDataSource.combined;
    } else {
      dataSource = SafetyDataSource.weatherApi;
    }

    // Check for failures requiring fail mode handling
    String? failModeWarning = unreachableWarning;
    if (alertStale) {
      failModeWarning ??=
          'The weather forecast has not refreshed since '
          '${_clockTime(rawAlert.generatedAt)}; it is not being acted on';
    }
    bool useFailMode = false;

    // If no data sources are available, apply fail mode
    if (!hasLiveHardwareSource && currentAlert == null) {
      useFailMode = true;
      dataSource = SafetyDataSource.unavailable;
      failModeWarning ??=
          unreachableWarning ?? 'No weather data sources available';
    }

    final sensorsSafe = hardwareWeatherSafe && safetyMonitorSafe;

    WeatherSafetyStatus finalStatus;
    WeatherSafetyActions finalActions;
    var decisionSource = WeatherDecisionSource.none;

    final previousStatus = state.status;

    if (state.status == WeatherSafetyStatus.snoozed &&
        state.snoozeUntil != null &&
        DateTime.now().isBefore(state.snoozeUntil!)) {
      // Keep snoozed state
      finalStatus = WeatherSafetyStatus.snoozed;
      finalActions = WeatherSafetyActions.safe;
    } else if (!weatherSettings.weatherSafetyEnabled) {
      // Safety disabled: nothing was assessed. `safe` here means "no verdict to
      // act on", NOT "conditions are good" — the `monitoringEnabled: false`
      // flag on the state below is what surfaces must render, and the reason
      // carries the same statement in words for anything that only shows text.
      finalStatus = WeatherSafetyStatus.safe;
      finalActions = const WeatherSafetyActions(
        reason: 'Weather safety is off — conditions are not being checked',
      );
    } else if (useFailMode) {
      // The no-data fail-mode resolution comes from the single shared truth
      // table ([noDataFailModeResolution], mirrored by the Rust
      // `safety_fail_mode_no_data_resolution`), so this path and the
      // executor-facing [_computePushedVerdict] cannot disagree.
      switch (noDataFailModeResolution(failMode)) {
        case NoDataResolution.unsafe:
          // Most conservative: treat unavailable data as unsafe, block operations.
          finalStatus = WeatherSafetyStatus.unsafe;
          decisionSource = WeatherDecisionSource.noData;
          finalActions = WeatherSafetyActions(
            shouldPause: true,
            shouldPark: shouldAutoPark,
            reason: failModeWarning,
          );
          break;
        case NoDataResolution.safe:
          // Permissive: treat unavailable data as safe, allow operations to continue.
          finalStatus = WeatherSafetyStatus.safe;
          finalActions = WeatherSafetyActions.safe;
          break;
        case NoDataResolution.preserve:
          // Warn-only: treat as safe for operations but emit a UI warning so the
          // operator knows the safety data is missing.
          finalStatus = WeatherSafetyStatus.safe;
          finalActions = WeatherSafetyActions.safe;
          shouldShowFailModeWarning = true;
          break;
      }
    } else if (sensorsSafe && !forecastActs) {
      finalStatus = WeatherSafetyStatus.safe;
      finalActions = WeatherSafetyActions.safe;
      // A permissive fail mode may have resolved an unreachable source to safe.
      // warnOnly still owes the operator the disclosure.
      shouldShowFailModeWarning =
          unreachableWarning != null &&
          noDataFailModeResolution(failMode) == NoDataResolution.preserve;
    } else if (sensorsSafe) {
      // Only the forecast says unsafe. It is a model, not a reading: it never
      // parks or closes anything. It holds the run if the operator chose
      // that, and otherwise only warns.
      finalStatus = WeatherSafetyStatus.unsafe;
      decisionSource = WeatherDecisionSource.forecast;
      final forecastReason =
          currentAlert?.message ?? 'The weather forecast reports clouds';
      finalActions = WeatherSafetyActions(
        shouldPause: policy.forecastHoldsRun,
        advisoryOnly: true,
        reason: policy.forecastHoldsRun
            ? '$forecastReason. Exposures are held until it clears; '
                  'the mount keeps tracking.'
            : '$forecastReason. Forecasts only warn; the run continues.',
        resumeCheckTime: currentAlert?.eta?.add(const Duration(minutes: 15)),
      );
    } else {
      // A sensor at the site, or an unreachable one under fail closed.
      String reason;
      if (safetyMonitorReading == SafetySourceReading.unsafe) {
        reason = 'Safety monitor reports unsafe conditions';
        decisionSource = WeatherDecisionSource.safetyMonitor;
      } else if (hardwareWeatherReading == SafetySourceReading.unsafe) {
        reason = 'Weather device reports unsafe conditions';
        decisionSource = WeatherDecisionSource.weatherDevice;
      } else {
        reason = unreachableWarning!;
        decisionSource = WeatherDecisionSource.noData;
      }

      finalStatus = WeatherSafetyStatus.unsafe;
      finalActions = WeatherSafetyActions(
        shouldPause: true,
        shouldPark: shouldAutoPark,
        shouldCloseDome: _shouldCloseDome(currentAlert),
        reason: reason,
        resumeCheckTime: currentAlert?.eta?.add(const Duration(minutes: 15)),
      );
    }

    if (dawnParkDue &&
        (finalStatus == WeatherSafetyStatus.safe ||
            finalActions.advisoryOnly)) {
      finalStatus = WeatherSafetyStatus.unsafe;
      decisionSource = WeatherDecisionSource.dawn;
      finalActions = WeatherSafetyActions(
        shouldPause: true,
        shouldPark: shouldAutoPark,
        shouldCloseDome: shouldAutoPark,
        reason: 'Astronomical dawn is approaching',
      );
    }

    state = state.copyWith(
      status: finalStatus,
      actions: finalActions,
      currentAlertLevel: currentAlert?.level ?? AlertLevel.clear,
      dataSource: dataSource,
      hardwareWeatherSafe: hardwareWeatherSafe,
      safetyMonitorSafe: safetyMonitorSafe,
      apiWeatherSafe: apiWeatherSafe,
      hardwareWeatherReading: hardwareWeatherReading,
      safetyMonitorReading: safetyMonitorReading,
      failModeWarning: failModeWarning,
      clearWarning: failModeWarning == null,
      lastEvaluation: DateTime.now(),
      monitoringEnabled: weatherSettings.weatherSafetyEnabled,
      autoParkArmed: shouldAutoPark && weatherSettings.weatherSafetyEnabled,
      autoResumeArmed:
          weatherSettings.autoResumeEnabled &&
          weatherSettings.weatherSafetyEnabled,
      decisionSource: decisionSource,
      forecastUnsafe: forecastUnsafe,
      forecastHoldsRun: policy.forecastHoldsRun,
      starEvidence: starEvidence,
      clearStarEvidence: starEvidence == null,
      starEvidenceOverridesForecast: starsOverrideForecast,
    );

    if (shouldShowFailModeWarning) {
      Future<void>.microtask(() {
        if (!mounted) return;
        _ref
            .read(uiNotificationProvider.notifier)
            .showWarning(
              failModeWarning ?? 'No weather data sources available',
              title: 'Weather Safety',
              duration: const Duration(seconds: 10),
            );
      });
    }
    _announceForecastOnlyWarning(finalStatus, finalActions);

    // Send this verdict to the sequencer's own WeatherUnsafe trigger, which
    // holds or parks a run independently of the app. See
    // [_computePushedVerdict] for what is sent and when the app abstains.
    final pushed = _computePushedVerdict(
      weatherSettings: weatherSettings,
      finalStatus: finalStatus,
      failMode: failMode,
      useFailMode: useFailMode,
      hardwareWeatherSafe: hardwareWeatherSafe,
      forecastActs: forecastActs,
      forecastHoldsRun: policy.forecastHoldsRun,
    );
    if (_decisionPolicyWatched) {
      _lastResumeAfterSecs = policy.requiredSafeDurationSeconds;
    }
    unawaited(_pushWeatherVerdict(pushed.unsafe, advisory: pushed.advisory));

    if (previousStatus == WeatherSafetyStatus.unsafe &&
        finalStatus == WeatherSafetyStatus.safe &&
        weatherSettings.autoResumeEnabled &&
        (_weatherPausedSequence || _weatherParkedMount)) {
      _scheduleAutoResume();
    } else if (finalStatus == WeatherSafetyStatus.unsafe) {
      // Why: if conditions re-degrade during the hold-off window we cancel
      // the pending resume so we don't unpark into renewed unsafe weather.
      _cancelPendingAutoResume();
    }

    // Enforce the computed safety actions on the hardware, once per unsafe
    // episode, re-armed while an attempt fails. A forecast-only verdict sends
    // nothing: the sequencer holds the run for it and resumes it.
    if (finalStatus == WeatherSafetyStatus.unsafe) {
      if (!_safeRigEnforced && !finalActions.advisoryOnly) {
        unawaited(_enforceSafetyActionsAndLatch(finalActions));
      }
    } else if (finalStatus == WeatherSafetyStatus.safe) {
      // Episode over (or never started) — re-arm enforcement for the next one.
      _safeRigEnforced = false;
      _nothingToSafeAnnounced = false;
    }
    // Snoozed: leave the latch as-is. A snooze means the operator explicitly
    // suppressed enforcement; if it expires back to unsafe the latch state
    // already reflects whether we enforced for this episode.
  }

  /// Tell the operator once per episode that a forecast says cloudy and is
  /// only being warned about, so a run that keeps imaging is not a surprise.
  void _announceForecastOnlyWarning(
    WeatherSafetyStatus status,
    WeatherSafetyActions actions,
  ) {
    final warnOnly =
        status == WeatherSafetyStatus.unsafe &&
        actions.advisoryOnly &&
        !actions.shouldPause;
    if (!warnOnly) {
      _forecastWarningAnnounced = false;
      return;
    }
    if (_forecastWarningAnnounced) return;
    _forecastWarningAnnounced = true;
    final message = actions.reason ?? 'The weather forecast reports clouds';
    Future<void>.microtask(() {
      if (!mounted) return;
      _ref
          .read(uiNotificationProvider.notifier)
          .showWarning(
            message,
            title: 'Weather forecast',
            duration: const Duration(seconds: 10),
          );
    });
  }

  /// Whether the forecast alert is too old to act on: older than two of its
  /// refresh intervals, and never less than fifteen minutes.
  bool _isForecastStale(WeatherAlert alert, WeatherSettings settings) {
    final twoRefreshes = Duration(seconds: settings.refreshIntervalSeconds * 2);
    const floor = Duration(minutes: 15);
    final maxAge = twoRefreshes > floor ? twoRefreshes : floor;
    return _clock().difference(alert.generatedAt) > maxAge;
  }

  static String _clockTime(DateTime at) {
    final local = at.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  /// The decision policy as loaded so far; the defaults until it is.
  WeatherDecisionPolicy _currentDecisionPolicy() {
    if (!_decisionPolicyWatched) return WeatherDecisionPolicy.defaults;
    return _ref.read(weatherDecisionPolicyProvider).valueOrNull ??
        WeatherDecisionPolicy.defaults;
  }

  /// Start following the decision policy, re-evaluating when it loads or
  /// changes.
  void _watchDecisionPolicy() {
    if (_decisionPolicyWatched || !mounted) return;
    _decisionPolicyWatched = true;
    _ref.listen<AsyncValue<WeatherDecisionPolicy>>(
      weatherDecisionPolicyProvider,
      (_, __) => _scheduleSourceChangeEvaluation(),
    );
  }

  /// Re-read the run's own evidence about the sky — the active session's
  /// light frames and their detected star counts — and re-evaluate when it
  /// changed. No session, no database, or too little to judge by reads as no
  /// evidence.
  Future<void> _refreshStarEvidence() async {
    if (_starEvidenceRefreshInFlight) return;
    _starEvidenceRefreshInFlight = true;
    SkyStarEvidence? evidence;
    try {
      final sessionId = _ref.read(sessionStateProvider).dbSessionId;
      if (sessionId != null) {
        final rows = await _ref
            .read(imagesDaoProvider)
            .getImagesForSession(sessionId)
            .timeout(const Duration(seconds: 5));
        evidence = evaluateStarEvidence(_starSamples(rows), _clock());
      }
    } catch (_) {
      evidence = null;
    } finally {
      _starEvidenceRefreshInFlight = false;
    }
    if (!mounted || evidence == _starEvidence) return;
    _starEvidence = evidence;
    _scheduleSourceChangeEvaluation();
  }

  static List<StarSample> _starSamples(List<db.CapturedImage> rows) => [
    for (final row in rows)
      if (row.frameType.toLowerCase() == 'light' && row.starCount != null)
        (
          capturedAt: row.capturedAt,
          stars: row.starCount!,
          exposureSecs: row.exposureDuration,
        ),
  ];

  /// Determine if dome should be closed
  bool _shouldCloseDome(WeatherAlert? alert) {
    if (alert == null || alert.level != AlertLevel.critical) {
      return false;
    }
    final domeState = _ref.read(domeStateProvider);
    return domeState.connectionState == DeviceConnectionState.connected;
  }

  /// Subscribe to weather alert stream and update state based on alerts
  void _subscribeToAlerts() {
    final alertService = _ref.read(weatherAlertServiceProvider);

    _alertSubscription = alertService.alertStream.listen((alert) {
      if (!mounted) return;
      // Re-evaluate all sources when API alert changes
      _evaluateAllSources();
    });
  }

  /// The operator says the sky is clear: set the weather verdict aside for
  /// [duration]. A run held for weather resumes now, and the app's verdict is
  /// not acted on until the time is up. A hardware safety monitor that reads
  /// unsafe still holds the run. [reason] is logged with the action.
  void snooze(Duration duration, {String? reason}) {
    final snoozeUntil = DateTime.now().add(duration);
    final why = reason ?? 'Operator says the sky is clear';

    // Cancel existing snooze timer if any
    _snoozeTimer?.cancel();

    // Set snooze state
    state = state.copyWith(
      status: WeatherSafetyStatus.snoozed,
      snoozeUntil: snoozeUntil,
      snoozeReason: why,
      actions: WeatherSafetyActions.safe,
    );

    final backend = _ref.read(backendProvider);
    if (backend is NetworkBackend) {
      unawaited(
        backend
            .acknowledgeSafetyCondition(
              reason: why,
              durationMinutes: duration.inMinutes.clamp(1, 1440),
            )
            .then((_) => _refreshRemoteStatus())
            .catchError((Object error) {
              if (mounted) {
                state = WeatherSafetyState.initial().copyWith(
                  failModeWarning: 'Could not snooze host safety: $error',
                  lastEvaluation: DateTime.now(),
                );
              }
            }),
      );
      return;
    }

    _logOperatorWeatherAction(
      'Weather verdict set aside for ${duration.inMinutes} min: $why',
    );
    // Tell the sequencer now rather than at the next evaluation: the held run
    // resumes at once, and the verdict it holds on is withdrawn.
    unawaited(_pushWeatherVerdict(null));
    unawaited(_pushOperatorClear(duration.inSeconds, why));

    // Start timer to end snooze
    _snoozeTimer = Timer(duration, () {
      if (!mounted) return;
      cancelSnooze();
    });
  }

  void _logOperatorWeatherAction(String message) {
    try {
      _ref.read(loggingServiceProvider).info(message, source: 'WeatherSafety');
    } catch (_) {
      developer.log(message, name: 'WeatherSafety');
    }
  }

  Future<void> _pushOperatorClear(int seconds, String reason) async {
    try {
      await _ref
          .read(backendProvider)
          .sequencerSetWeatherOperatorClear(
            durationSecs: seconds,
            reason: reason,
          );
    } catch (error) {
      developer.log(
        'weather: could not send the clear-sky override: $error',
        name: 'WeatherSafety',
        level: 900,
      );
    }
  }

  /// Cancel snooze early and re-evaluate current conditions
  void cancelSnooze() {
    _snoozeTimer?.cancel();
    _snoozeTimer = null;

    // Clear the acknowledgement immediately and fail closed while fresh
    // conditions are being fetched. Clearing `snoozeUntil` alone leaves
    // `status == snoozed` until an asynchronous evaluation completes, so the
    // button reads as doing nothing and a stalled remote refresh leaves the
    // client snoozed indefinitely.
    state = state.copyWith(
      status: WeatherSafetyStatus.unsafe,
      actions: const WeatherSafetyActions(
        shouldPause: true,
        reason: 'Weather safety snooze cancelled; re-evaluating conditions',
      ),
      clearSnooze: true,
    );
    final backend = _ref.read(backendProvider);
    if (backend is! NetworkBackend) {
      _logOperatorWeatherAction('Weather verdict override ended');
      unawaited(_pushOperatorClear(0, 'Override ended'));
    }
    if (backend is NetworkBackend) {
      unawaited(
        backend
            .cancelSafetyAcknowledgement()
            .then((_) => _refreshRemoteStatus())
            .catchError((Object error) {
              if (mounted) {
                state = WeatherSafetyState.initial().copyWith(
                  failModeWarning: 'Could not cancel host snooze: $error',
                  lastEvaluation: DateTime.now(),
                );
              }
            }),
      );
      return;
    }
    _evaluateAllSources();
  }

  /// Force immediate re-evaluation of all safety sources
  void forceEvaluation() {
    if (_ref.read(backendProvider) is NetworkBackend) {
      unawaited(_refreshRemoteStatus());
      return;
    }
    _evaluateAllSources();
  }

  /// Force a safety evaluation and wait until it and any coalesced follow-up
  /// evaluation have completed.
  ///
  /// Bounded by [timeout]: an evaluation waits on the settings and app-settings
  /// futures, which a stalled backend may never resolve. The headless settings
  /// route awaits this before answering, so an unbounded wait would hang the
  /// request rather than merely delaying it.
  Future<void> evaluateNow({Duration timeout = _evaluateNowTimeout}) async {
    if (_ref.read(backendProvider) is NetworkBackend) {
      await _refreshRemoteStatus();
      return;
    }
    _evaluateAllSources();
    final deadline = DateTime.now().add(timeout);
    while (mounted && (_evaluationInFlight || _evaluationPending)) {
      if (!DateTime.now().isBefore(deadline)) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  @override
  void dispose() {
    _alertSubscription?.cancel();
    _snoozeTimer?.cancel();
    _periodicEvalTimer?.cancel();
    _cancelPendingAutoResume();
    _cloudMotionPushTimer?.cancel();
    _adaptiveConditionsPushTimer?.cancel();
    _remoteStatusTimer?.cancel();
    _sourceChangeEvaluationTimer?.cancel();
    _verdictHeartbeatTimer?.cancel();
    super.dispose();
  }
}

/// Provider for weather safety state
final weatherSafetyProvider =
    StateNotifierProvider<WeatherSafetyNotifier, WeatherSafetyState>((ref) {
      ref.watch(backendProvider);
      return WeatherSafetyNotifier(ref);
    });

/// The single read/write path for the consolidated [SafetyConfig].
///
/// The one logical safety config spans `weatherSettingsDao`, `appSettings` and
/// `settingsDao`. [SafetyConfigStore] owns the field→store routing so callers
/// never fan writes across stores themselves. See [SafetyConfigStore] for the
/// field map.
final safetyConfigStoreProvider = Provider<SafetyConfigStore>((ref) {
  return SafetyConfigStore(ref.watch(databaseProvider));
});
