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

part 'weather_safety/weather_safety_models.dart';
part 'weather_safety/weather_safety_sources.dart';
part 'weather_safety/weather_safety_remote.dart';
part 'weather_safety/weather_safety_enforcement.dart';
part 'weather_safety/weather_safety_executor_push.dart';

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
  bool _remoteFetchInFlight = false;
  bool _evaluationInFlight = false;
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
      _,
      __,
    ) {
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
      _evaluationPending = true;
      return;
    }
    _evaluationInFlight = true;
    try {
      final weatherSettings = await _ref.read(
        weatherSettingsDataProvider.future,
      );
      final appSettings = await _ref.read(appSettingsProvider.future);
      if (!mounted) return;
      _evaluateAllSourcesWithConfiguration(weatherSettings, appSettings);
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
      _evaluationInFlight = false;
      if (_evaluationPending && mounted) {
        _evaluationPending = false;
        _evaluateAllSources();
      }
    }
  }

  void _evaluateAllSourcesWithConfiguration(
    WeatherSettings weatherSettings,
    AppSettingsState appSettings,
  ) {
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

    // Get API weather status
    final alertService = _ref.read(weatherAlertServiceProvider);
    final currentAlert = alertService.currentAlert;
    final apiWeatherSafe =
        currentAlert == null ||
        currentAlert.level == AlertLevel.clear ||
        currentAlert.level == AlertLevel.watch;

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
    bool useFailMode = false;

    // If no data sources are available, apply fail mode
    if (!hasLiveHardwareSource && currentAlert == null) {
      useFailMode = true;
      dataSource = SafetyDataSource.unavailable;
      failModeWarning =
          unreachableWarning ?? 'No weather data sources available';
    }

    // Combine all sources for final safety determination
    final allSourcesSafe =
        hardwareWeatherSafe && safetyMonitorSafe && apiWeatherSafe;

    WeatherSafetyStatus finalStatus;
    WeatherSafetyActions finalActions;

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
      // Cross-language parity: the no-data fail-mode resolution comes from the
      // SINGLE shared truth table ([noDataFailModeResolution], mirrored by the
      // Rust `safety_fail_mode_no_data_resolution`). The UI status/actions are
      // derived from that resolution so this screen-facing path and the
      // executor-facing [_computePushedVerdict] cannot disagree about what each
      // fail mode means.
      switch (noDataFailModeResolution(failMode)) {
        case NoDataResolution.unsafe:
          // Most conservative: treat unavailable data as unsafe, block operations.
          finalStatus = WeatherSafetyStatus.unsafe;
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
    } else if (allSourcesSafe) {
      finalStatus = WeatherSafetyStatus.safe;
      finalActions = WeatherSafetyActions.safe;
      // A permissive fail mode may have resolved an unreachable source to safe.
      // warnOnly still owes the operator the disclosure.
      shouldShowFailModeWarning =
          unreachableWarning != null &&
          noDataFailModeResolution(failMode) == NoDataResolution.preserve;
    } else {
      // Determine which source caused unsafe
      String reason;
      if (safetyMonitorReading == SafetySourceReading.unsafe) {
        reason = 'Safety monitor reports unsafe conditions';
      } else if (hardwareWeatherReading == SafetySourceReading.unsafe) {
        reason = 'Weather device reports unsafe conditions';
      } else if (!safetyMonitorSafe || !hardwareWeatherSafe) {
        reason = unreachableWarning!;
      } else {
        reason = currentAlert?.message ?? 'Unsafe weather conditions detected';
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

    if (dawnParkDue && finalStatus == WeatherSafetyStatus.safe) {
      finalStatus = WeatherSafetyStatus.unsafe;
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

    // Defense-in-depth (full-night audit 2026-06-04): push this verdict into
    // the Rust executor so the in-sequencer `WeatherUnsafe` trigger reacts even
    // on a rig with no hardware safety device. The Dart SafeRig enforcement
    // above is the primary path; this is the redundant in-sequencer layer.
    //
    // Architecture-unification 2026-06-05 (Subsystem 2 steps 1+2): compute the
    // pushed verdict from the NON-HARDWARE Dart sources only (API alert /
    // hardware-weather thresholds / dawn) and ABSTAIN (`None`) when the operator
    // has effectively opted out of weather-driven aborts. See
    // [_computePushedVerdict] for the full rationale; in short:
    //   * the safety-monitor component is excluded so it is evaluated ONCE (Rust
    //     polls `safety_is_safe` and ORs it); folding it here too double-counted
    //     it.
    //   * disabled / snoozed / failOpen / warnOnly push `None`, never `false`.
    //     Pushing `false` (SAFE) is only harmless today because Rust ORs it; if a
    //     future refactor ever made Rust trust the verdict, a disabled toggle
    //     asserting SAFE could suppress a hardware-unsafe abort. `None` makes the
    //     channel strictly "add-unsafe-or-abstain" and closes that landmine.
    unawaited(
      _pushWeatherVerdict(
        _computePushedVerdict(
          weatherSettings: weatherSettings,
          finalStatus: finalStatus,
          failMode: failMode,
          useFailMode: useFailMode,
          apiWeatherSafe: apiWeatherSafe,
          hardwareWeatherSafe: hardwareWeatherSafe,
          dawnParkDue: dawnParkDue,
        ),
      ),
    );

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

    // Enforce the computed safety actions on the hardware. Before this the
    // actions were COMPUTED but never EXECUTED — every consumer was UI-only,
    // so an unattended rig kept tracking/exposing into unsafe weather. We
    // enforce until one attempt fully succeeds, then latch for the rest of the
    // unsafe episode. A partial failure must stay re-armed so the next
    // 5-minute evaluation retries any incomplete pause / park / dome action.
    if (finalStatus == WeatherSafetyStatus.unsafe) {
      if (!_safeRigEnforced) {
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

  /// Snooze alerts for specified duration
  void snooze(Duration duration) {
    final snoozeUntil = DateTime.now().add(duration);

    // Cancel existing snooze timer if any
    _snoozeTimer?.cancel();

    // Set snooze state
    state = state.copyWith(
      status: WeatherSafetyStatus.snoozed,
      snoozeUntil: snoozeUntil,
      actions: WeatherSafetyActions.safe,
    );

    final backend = _ref.read(backendProvider);
    if (backend is NetworkBackend) {
      unawaited(
        backend
            .acknowledgeSafetyCondition(
              reason: 'Remote operator snoozed weather safety alerts',
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

    // Start timer to end snooze
    _snoozeTimer = Timer(duration, () {
      if (!mounted) return;
      cancelSnooze();
    });
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
