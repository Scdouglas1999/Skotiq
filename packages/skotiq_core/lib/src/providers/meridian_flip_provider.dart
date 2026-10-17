import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/network_backend.dart';
import '../database/database.dart';
import '../models/backend/host_mutation_event.dart';
import '../models/equipment/equipment_models.dart'
    show DeviceConnectionState, MountState;
import '../models/meridian_flip_settings.dart';
import '../models/meridian_flip_event.dart';
import '../models/sequence/sequence_models.dart'
    show SequenceExecutionState, SequenceExecutionStateCapabilities;
import '../services/logging_service.dart';
import '../services/notification_service.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show AstronomyCalculations;
import '../services/scheduler/sky_calculations.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import 'equipment_provider.dart'
    show
        cameraStateProvider,
        coverCalibratorStateProvider,
        focuserStateProvider,
        mountStateProvider;
import 'sequence_provider.dart' show sequenceExecutionStateProvider;
import 'settings_provider.dart' show appSettingsProvider;
import 'ui_notification_provider.dart' show uiNotificationProvider;

/// Key used to store global meridian flip settings in app_settings table
const _kMeridianFlipSettingsKey = 'meridian_flip_settings';

/// Initial-load health for [globalMeridianFlipSettingsProvider].
///
/// The settings provider holds a plain [MeridianFlipSettings] state shape
/// because many runtime consumers read it synchronously. This companion state
/// keeps the settings UI and the sequence-start boundary from mistaking the
/// model defaults for a loaded host snapshot.
final globalMeridianFlipSettingsLoadStateProvider =
    StateProvider<AsyncValue<void>>((ref) => const AsyncLoading());

/// Provider for global meridian flip settings
final globalMeridianFlipSettingsProvider =
    StateNotifierProvider<
      GlobalMeridianFlipSettingsNotifier,
      MeridianFlipSettings
    >((ref) {
      final backend = ref.watch(backendProvider);
      return GlobalMeridianFlipSettingsNotifier(
        ref,
        database: backend is NetworkBackend
            ? null
            : ref.watch(databaseProvider),
        remote: backend is NetworkBackend ? backend : null,
      );
    });

/// Notifier for managing global meridian flip settings
///
/// Handles loading and saving meridian flip settings to the app_settings table.
/// These serve as the default settings when no profile-specific overrides exist.
class GlobalMeridianFlipSettingsNotifier
    extends StateNotifier<MeridianFlipSettings> {
  final Ref _ref;
  final SkotiqDatabase? _database;
  final NetworkBackend? _remote;
  StreamSubscription? _remoteEventSubscription;
  late Future<void> _loadFuture;
  Future<void> _writeTail = Future<void>.value();
  Object? _loadError;

  MeridianFlipSettings get settings => state;

  GlobalMeridianFlipSettingsNotifier(
    this._ref, {
    required SkotiqDatabase? database,
    required NetworkBackend? remote,
  }) : _database = database,
       _remote = remote,
       super(const MeridianFlipSettings()) {
    _ref.read(globalMeridianFlipSettingsLoadStateProvider.notifier).state =
        const AsyncLoading();
    if (remote != null) {
      _remoteEventSubscription = remote.eventStream.listen(
        (event) {
          if (event.eventType != hostStateChangedEventType ||
              event.data['entityType'] != HostMutationEntity.settings ||
              event.data['namespace'] != 'meridian-flip') {
            return;
          }
          _loadFuture = _writeTail.then(
            (_) => _loadSettings(showLoading: false),
          );
        },
        onError: (Object error, StackTrace stackTrace) {
          developer.log(
            'Meridian-flip settings event stream failed: $error',
            name: 'MeridianFlip',
            level: 1000,
            error: error,
            stackTrace: stackTrace,
          );
        },
      );
    }
    _loadFuture = _loadSettings(showLoading: true);
  }

  /// Wait until the authoritative settings snapshot has loaded.
  ///
  /// Throws when the host/DB read failed so sequence startup cannot silently
  /// serialize meridian nodes with factory defaults.
  Future<void> ensureLoaded() async {
    await _loadFuture;
    final error = _loadError;
    if (error != null) {
      throw StateError('Meridian-flip settings are unavailable: $error');
    }
  }

  @override
  void dispose() {
    unawaited(_remoteEventSubscription?.cancel());
    super.dispose();
  }

  /// Load settings from the imaging host in network mode, or the local DB on
  /// the host/desktop path.
  Future<void> _loadSettings({required bool showLoading}) async {
    if (showLoading) {
      _ref.read(globalMeridianFlipSettingsLoadStateProvider.notifier).state =
          const AsyncLoading();
    }
    try {
      final MeridianFlipSettings loaded;
      if (_remote case final remote?) {
        loaded = await remote.getMeridianFlipSettings();
      } else {
        final db = _database!;
        final setting =
            await (db.select(db.appSettings)
                  ..where((t) => t.key.equals(_kMeridianFlipSettingsKey)))
                .getSingleOrNull();
        loaded = setting == null || setting.value.isEmpty
            ? const MeridianFlipSettings()
            : MeridianFlipSettings.fromJson(
                jsonDecode(setting.value) as Map<String, dynamic>,
              );
      }
      if (!mounted) return;
      state = loaded;
      _loadError = null;
      _ref.read(globalMeridianFlipSettingsLoadStateProvider.notifier).state =
          const AsyncData(null);
    } catch (e, stackTrace) {
      if (!mounted) return;
      _loadError = e;
      _ref.read(globalMeridianFlipSettingsLoadStateProvider.notifier).state =
          AsyncError(e, stackTrace);
      developer.log(
        'Failed to load meridian-flip settings: $e',
        name: 'MeridianFlip',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Update settings on the authoritative owner and publish the new in-memory
  /// snapshot only after persistence succeeds.
  Future<void> updateSettings(MeridianFlipSettings settings) {
    final validationErrors = settings.validate();
    if (validationErrors.isNotEmpty) {
      return Future<void>.error(ArgumentError(validationErrors.join('; ')));
    }

    final operation = _writeTail.then((_) async {
      await ensureLoaded();
      try {
        if (_remote case final remote?) {
          await remote.updateMeridianFlipSettings(settings);
        } else {
          final db = _database!;
          // app_settings is unique by `key`, while Drift's generic
          // insertOnConflictUpdate targets the integer primary key. Use the
          // canonical DAO upsert so the second and subsequent edits update the
          // existing key instead of failing with UNIQUE(app_settings.key).
          await db.settingsDao.setSetting(
            _kMeridianFlipSettingsKey,
            jsonEncode(settings.toJson()),
          );
        }
        if (!mounted) return;
        state = settings;
        _loadError = null;
        _ref.read(globalMeridianFlipSettingsLoadStateProvider.notifier).state =
            const AsyncData(null);
      } catch (e, stackTrace) {
        developer.log(
          'Failed to save meridian-flip settings: $e',
          name: 'MeridianFlip',
          level: 1000,
          error: e,
          stackTrace: stackTrace,
        );
        _ref
            .read(uiNotificationProvider.notifier)
            .showError(
              'Meridian flip settings were not changed because they could not '
              'be saved on the imaging host.',
              title: 'Settings not saved',
            );
        rethrow;
      }
    });
    _writeTail = operation.then<void>((_) {}, onError: (_, __) {});
    return operation;
  }

  // Individual setting updates
  // These allow updating individual settings without replacing the entire object

  /// Update standalone monitoring enabled
  Future<void> setStandaloneMonitoringEnabled(bool enabled) async {
    if (enabled && !state.triggerMethod.supportsStandaloneMonitoring) {
      return Future<void>.error(
        StateError(
          state.triggerMethod.standaloneMonitoringLimitation ??
              'This trigger requires an active sequence',
        ),
      );
    }
    await updateSettings(state.copyWith(standaloneMonitoringEnabled: enabled));
  }

  /// Update trigger method
  Future<void> setTriggerMethod(MeridianTriggerMethod method) async {
    await updateSettings(
      state.copyWith(
        triggerMethod: method,
        standaloneMonitoringEnabled: method.supportsStandaloneMonitoring
            ? state.standaloneMonitoringEnabled
            : false,
      ),
    );
  }

  /// Update minutes past meridian threshold
  Future<void> setMinutesPastMeridian(double minutes) async {
    await updateSettings(state.copyWith(minutesPastMeridian: minutes));
  }

  /// Update minutes before limit threshold
  Future<void> setMinutesBeforeLimit(double minutes) async {
    await updateSettings(state.copyWith(minutesBeforeLimit: minutes));
  }

  /// Update hour angle threshold
  Future<void> setHourAngleThreshold(double hours) async {
    await updateSettings(state.copyWith(hourAngleThreshold: hours));
  }

  /// Update tracking limit wait minutes
  Future<void> setTrackingLimitWaitMinutes(double minutes) async {
    await updateSettings(state.copyWith(trackingLimitWaitMinutes: minutes));
  }

  /// Update pause guiding before flip
  Future<void> setPauseGuidingBeforeFlip(bool pause) async {
    await updateSettings(state.copyWith(pauseGuidingBeforeFlip: pause));
  }

  /// Update recenter after flip
  Future<void> setRecenterAfterFlip(bool recenter) async {
    await updateSettings(state.copyWith(recenterAfterFlip: recenter));
  }

  /// Update refocus after flip
  Future<void> setRefocusAfterFlip(bool refocus) async {
    await updateSettings(state.copyWith(refocusAfterFlip: refocus));
  }

  /// Update settle time
  Future<void> setSettleTimeSeconds(double seconds) async {
    await updateSettings(state.copyWith(settleTimeSeconds: seconds));
  }

  /// Update resume guiding after flip
  Future<void> setResumeGuidingAfterFlip(bool resume) async {
    await updateSettings(state.copyWith(resumeGuidingAfterFlip: resume));
  }

  /// Update max retries
  Future<void> setMaxRetries(int retries) async {
    await updateSettings(state.copyWith(maxRetries: retries));
  }

  /// Update retry delays
  Future<void> setRetryDelaysSeconds(List<double> delays) async {
    await updateSettings(state.copyWith(retryDelaysSeconds: delays));
  }

  /// Update failure action
  Future<void> setFailureAction(FlipFailureAction action) async {
    await updateSettings(state.copyWith(failureAction: action));
  }

  /// Update sound alert on flip
  Future<void> setSoundAlertOnFlip(bool enabled) async {
    await updateSettings(state.copyWith(soundAlertOnFlip: enabled));
  }

  /// Update push notification on flip
  Future<void> setPushNotificationOnFlip(bool enabled) async {
    await updateSettings(state.copyWith(pushNotificationOnFlip: enabled));
  }

  /// Reset settings to defaults
  Future<void> resetToDefaults() async {
    await updateSettings(const MeridianFlipSettings());
  }
}

/// Provider that returns effective meridian flip settings
/// (profile overrides merged with global defaults)
///
/// This provider watches both the global settings and the active equipment profile.
/// If the active profile has meridian flip overrides, they are merged with the
/// global defaults, with profile values taking precedence.
final effectiveMeridianFlipSettingsProvider = Provider<MeridianFlipSettings>((
  ref,
) {
  final global = ref.watch(globalMeridianFlipSettingsProvider);
  final activeProfile = ref.watch(activeProfileProvider).valueOrNull;

  if (activeProfile == null) {
    return global;
  }

  // Check if profile has overrides
  final overridesJson = activeProfile.meridianFlipOverrides;
  if (overridesJson == null || overridesJson.isEmpty) {
    return global;
  }

  try {
    final overrides = jsonDecode(overridesJson) as Map<String, dynamic>;
    // Merge overrides with global defaults
    final globalJson = global.toJson();
    final merged = {...globalJson, ...overrides};
    return MeridianFlipSettings.fromJson(merged);
  } catch (e) {
    developer.log(
      'Failed to parse profile overrides: $e',
      name: 'MeridianFlip',
      level: 1000,
    );
    return global;
  }
});

/// Current flip state for UI
///
/// Represents the current state of a meridian flip operation.
enum FlipExecutionState {
  /// No flip is in progress
  idle,

  /// Flip is currently executing
  executing,

  /// Flip failed and is being retried
  retrying,

  /// Flip completed successfully
  completed,

  /// Flip failed after all retries
  failed,

  /// Flip was aborted by user
  aborted,
}

/// Provider tracking current flip execution state
///
/// UI components can watch this to show appropriate status indicators,
/// enable/disable controls, and display progress information.
final flipExecutionStateProvider = StateProvider<FlipExecutionState>((ref) {
  return FlipExecutionState.idle;
});

/// Provider for the current flip attempt number during retries
///
/// Returns 0 when no flip is in progress, or the current attempt number
/// (1-indexed) during flip execution.
final flipCurrentAttemptProvider = StateProvider<int>((ref) => 0);

/// Provider for the current flip step being executed
///
/// Returns null when no flip is in progress, or the current FlipStep
/// during flip execution.
final flipCurrentStepProvider = StateProvider<FlipStep?>((ref) => null);

/// Provider for flip progress percentage (0-100)
final flipProgressProvider = StateProvider<int>((ref) => 0);

/// Provider for the last flip error message
final flipLastErrorProvider = StateProvider<String?>((ref) => null);

/// Provider indicating if a flip is currently in progress
final isFlipInProgressProvider = Provider<bool>((ref) {
  final state = ref.watch(flipExecutionStateProvider);
  return state == FlipExecutionState.executing ||
      state == FlipExecutionState.retrying;
});

/// StateNotifier that resets flip execution state when the mount disconnects.
///
/// If a meridian flip is in progress (executing or retrying) and the mount
/// disconnects, the flip can never complete. This notifier listens to the mount
/// connection state and resets the flip providers to prevent the UI from
/// being stuck in a "flipping" state indefinitely.
///
/// Uses ref.listen in its constructor instead of mutating state in a Provider
/// build function, which would be a Riverpod violation.
class MeridianFlipDisconnectGuard extends StateNotifier<void> {
  final Ref _ref;

  MeridianFlipDisconnectGuard(this._ref) : super(null) {
    _ref.listen<MountState>(mountStateProvider, (prev, next) {
      if (next.connectionState == DeviceConnectionState.disconnected) {
        final flipState = _ref.read(flipExecutionStateProvider);
        if (flipState == FlipExecutionState.executing ||
            flipState == FlipExecutionState.retrying) {
          developer.log(
            'Mount disconnected during meridian flip - aborting flip state',
            name: 'MeridianFlip',
            level: 900,
          );
          _ref.read(flipExecutionStateProvider.notifier).state =
              FlipExecutionState.aborted;
          _ref.read(flipCurrentStepProvider.notifier).state = null;
          _ref.read(flipProgressProvider.notifier).state = 0;
          _ref.read(flipCurrentAttemptProvider.notifier).state = 0;
          _ref.read(flipLastErrorProvider.notifier).state =
              'Meridian flip aborted: mount disconnected';
        }
      }
    });
  }
}

/// Provider that resets flip execution state when the mount disconnects.
///
/// This provider must be watched (e.g., by the app shell) so it stays alive.
final meridianFlipDisconnectGuardProvider =
    StateNotifierProvider<MeridianFlipDisconnectGuard, void>((ref) {
      return MeridianFlipDisconnectGuard(ref);
    });

/// Provider for checking if settings indicate flip should be enabled
///
/// This combines the global enable setting with the effective settings
/// to determine if auto-flip should be active.
final isMeridianFlipEnabledProvider = Provider<bool>((ref) {
  // Check if any trigger conditions are configured (non-zero thresholds)
  final settings = ref.watch(effectiveMeridianFlipSettingsProvider);

  // A trigger method is always selected, but check if the threshold is sensible
  switch (settings.triggerMethod) {
    case MeridianTriggerMethod.minutesPastMeridian:
      return settings.minutesPastMeridian >= 0;
    case MeridianTriggerMethod.minutesBeforeLimit:
      return settings.minutesBeforeLimit >= 0;
    case MeridianTriggerMethod.hourAngleThreshold:
      return settings.hourAngleThreshold >= 0;
    case MeridianTriggerMethod.onTrackingLimitHit:
      return true; // Always enabled when selected (wait time >= 0 is valid)
  }
});

/// Compute Local Sidereal Time (hours) for the given UTC instant and observer
/// longitude (degrees, east positive).
///
/// Thin alias over [SkyCalculations.localSiderealTimeHours] — the single
/// shared LST implementation also used by the dynamic scheduler engine. Kept
/// as a free function because `meridian_countdown_provider.dart` imports it by
/// this name; the math now lives in one place.
double computeLocalSiderealTimeHours(DateTime utc, double longitudeDeg) =>
    SkyCalculations.localSiderealTimeHours(utc, longitudeDeg);

/// Compute the mount's hour angle in hours, normalized to (-12, +12].
///
/// HA = LST - RA, where positive HA means the target is west of the meridian
/// (i.e., already crossed). Thin alias over [SkyCalculations.hourAngleHours].
double computeHourAngleHours(double raHours, double lstHours) =>
    SkyCalculations.hourAngleHours(raHours, lstHours);

/// Result of a standalone-monitor poll, exposed so tests can validate the
/// decision logic without faking timers.
enum MeridianMonitorDecision {
  /// Monitoring is off, mount missing, or trigger settings disable it.
  inactive,

  /// Conditions evaluated but no trigger fired.
  noTrigger,

  /// Cooldown active from a recent trigger fire.
  cooldown,

  /// A sequence is running — let the sequencer own the flip.
  sequenceRunning,

  /// Trigger condition met and an alert was emitted.
  triggered,
}

/// Watcher that fires meridian-flip alerts when standalone monitoring is on
/// and the mount crosses the configured trigger condition.
///
/// This is what makes the Sequencer Settings -> Meridian Flip
/// `standaloneMonitoringEnabled` toggle observable: with it on, the mount
/// approaching the meridian must produce an effect with no sequence running.
///
/// When the trigger fires the monitor does BOTH of:
///   1. Alert — `flipExecutionStateProvider` -> `executing`,
///      `NotificationService.notifyMeridianFlip` (Discord / Pushover /
///      push per `pushNotificationOnFlip`), and a diagnostics log entry.
///   2. Execute — `backend.performMeridianFlip(...)`, which runs the
///      canonical native `MeridianFlipExecutor` standalone (same engine,
///      timeouts, altitude check, re-center and refocus as the in-sequence
///      path). The native side refuses while a sequence is running, so the
///      monitor can never double-command the mount; the `evaluateOnce`
///      sequence-running guard makes that the normal path anyway.
///   The flip targets the mount's CURRENT coordinates (the object it is
///   tracking). A cooldown prevents re-firing while a flip is in flight or
///   the operator is responding to a failure notification.
class MeridianFlipStandaloneMonitor extends StateNotifier<void> {
  final Ref _ref;
  Timer? _pollTimer;
  DateTime? _lastTriggerAt;
  bool _flipInFlight = false;

  /// Minimum interval between trigger fires.
  ///
  /// Why: the Rust sequencer trigger has a 10-minute cooldown
  /// (triggers.rs:1268). Match it so a single meridian crossing doesn't
  /// spam the operator with notifications while they are walking to the
  /// scope to act on the alert.
  static const Duration _cooldown = Duration(minutes: 10);

  /// Poll cadence while monitoring is active.
  ///
  /// Why: a 30-second cadence matches the sequencer's trigger evaluation
  /// frequency — finer resolution buys nothing because meridian crossings
  /// move slowly (mount sidereal rate is 15"/sec).
  static const Duration _pollInterval = Duration(seconds: 30);

  MeridianFlipStandaloneMonitor(this._ref) : super(null) {
    // Why: react to settings changes (toggle on/off) immediately rather than
    // waiting for the next poll. ref.listen survives across rebuilds.
    _ref.listen<MeridianFlipSettings>(globalMeridianFlipSettingsProvider, (
      prev,
      next,
    ) {
      if (prev?.standaloneMonitoringEnabled !=
              next.standaloneMonitoringEnabled ||
          prev?.triggerMethod != next.triggerMethod) {
        _reconcileTimer(next);
      }
    });
    final initial = _ref.read(globalMeridianFlipSettingsProvider);
    _reconcileTimer(initial);
  }

  void _reconcileTimer(MeridianFlipSettings settings) {
    _pollTimer?.cancel();
    _pollTimer = null;
    // The imaging host is the single owner of standalone flip automation.
    // A remote phone mirrors mount/settings state but must never run a second
    // timer that can race the GUI/headless host and command the same flip.
    if (!settings.standaloneMonitoringEnabled ||
        !settings.triggerMethod.supportsStandaloneMonitoring ||
        _ref.read(backendProvider) is NetworkBackend) {
      return;
    }
    _pollTimer = Timer.periodic(_pollInterval, (_) => evaluateOnce());
  }

  /// Public for tests — runs a single poll cycle and returns the decision.
  MeridianMonitorDecision evaluateOnce() {
    if (_ref.read(backendProvider) is NetworkBackend) {
      return MeridianMonitorDecision.inactive;
    }
    final settings = _ref.read(globalMeridianFlipSettingsProvider);
    if (!settings.standaloneMonitoringEnabled) {
      return MeridianMonitorDecision.inactive;
    }
    if (!settings.triggerMethod.supportsStandaloneMonitoring) {
      return MeridianMonitorDecision.inactive;
    }

    final execState = _ref.read(sequenceExecutionStateProvider);
    if (execState == SequenceExecutionState.running ||
        execState == SequenceExecutionState.paused) {
      // Why: when a sequence is running the in-sequence MeridianFlipNode (or
      // the always-on `meridian_flip` Rust trigger) owns the decision. A
      // parallel standalone alert would double-fire.
      return MeridianMonitorDecision.sequenceRunning;
    }

    if (_lastTriggerAt != null &&
        DateTime.now().difference(_lastTriggerAt!) < _cooldown) {
      return MeridianMonitorDecision.cooldown;
    }

    final mount = _ref.read(mountStateProvider);
    if (mount.connectionState != DeviceConnectionState.connected ||
        mount.isParked ||
        !mount.isTracking ||
        mount.ra == null) {
      return MeridianMonitorDecision.inactive;
    }

    final appSettings = _ref.read(appSettingsProvider).valueOrNull;
    if (appSettings == null ||
        (appSettings.latitude == 0.0 && appSettings.longitude == 0.0)) {
      // Why: HA computation needs a real longitude. Refuse to alert from a
      // 0,0 default — that would be a spurious notification.
      return MeridianMonitorDecision.inactive;
    }

    final lst = computeLocalSiderealTimeHours(
      DateTime.now().toUtc(),
      appSettings.longitude,
    );
    final ha = computeHourAngleHours(mount.ra!, lst);

    final fired = _evaluateTrigger(settings, ha);
    if (!fired) {
      return MeridianMonitorDecision.noTrigger;
    }

    _emitAlert(settings, ha);
    unawaited(_executeStandaloneFlip(settings, mount));
    _lastTriggerAt = DateTime.now();
    return MeridianMonitorDecision.triggered;
  }

  /// Runs an operator-requested flip through the same authoritative path as
  /// standalone automation.
  ///
  /// Returns false with [flipLastErrorProvider] populated when current run or
  /// mount state makes a flip unsafe. The backend remains the final authority,
  /// but refusing locally avoids presenting a command that the native
  /// sequencer must immediately reject.
  Future<bool> executeNow({String targetName = 'Manual flip'}) async {
    if (_flipInFlight || _ref.read(isFlipInProgressProvider)) {
      _ref.read(flipLastErrorProvider.notifier).state =
          'A meridian flip is already in progress';
      return false;
    }

    final execution = _ref.read(sequenceExecutionStateProvider);
    if (!execution.canStart) {
      _ref.read(flipLastErrorProvider.notifier).state =
          'The active sequence owns the mount; stop it before flipping manually';
      return false;
    }

    try {
      await _ref
          .read(globalMeridianFlipSettingsProvider.notifier)
          .ensureLoaded();
    } catch (error) {
      _ref.read(flipLastErrorProvider.notifier).state =
          'Could not load meridian flip settings: $error';
      return false;
    }

    final mount = _ref.read(mountStateProvider);
    if (mount.connectionState != DeviceConnectionState.connected ||
        mount.deviceId == null ||
        mount.deviceId!.isEmpty ||
        mount.ra == null ||
        mount.dec == null) {
      _ref.read(flipLastErrorProvider.notifier).state =
          'Mount coordinates are unavailable for a manual flip';
      return false;
    }
    if (mount.isParked) {
      _ref.read(flipLastErrorProvider.notifier).state =
          'Unpark the mount before flipping manually';
      return false;
    }
    if (!mount.isTracking) {
      _ref.read(flipLastErrorProvider.notifier).state =
          'Start mount tracking before flipping manually';
      return false;
    }

    _ref.read(flipExecutionStateProvider.notifier).state =
        FlipExecutionState.executing;
    _ref.read(flipCurrentStepProvider.notifier).state = null;
    _ref.read(flipProgressProvider.notifier).state = 0;
    _ref.read(flipLastErrorProvider.notifier).state = null;
    return _executeStandaloneFlip(
      _ref.read(globalMeridianFlipSettingsProvider),
      mount,
      targetName: targetName,
    );
  }

  /// Execute the actual flip via the canonical native flip engine.
  ///
  /// `performMeridianFlip` runs the canonical engine standalone, and the
  /// native side refuses if a sequence owns the mount, so this cannot
  /// double-command it. The alert above fires first so the operator hears
  /// about the flip even if the execution then fails.
  Future<bool> _executeStandaloneFlip(
    MeridianFlipSettings settings,
    MountState mount, {
    String targetName = 'Standalone flip',
  }) async {
    if (_flipInFlight) return false;

    final mountId = mount.deviceId;
    final ra = mount.ra;
    final dec = mount.dec;
    final logger = _ref.read(loggingServiceProvider);
    if (mountId == null || mountId.isEmpty || ra == null || dec == null) {
      logger.warning(
        'Standalone meridian flip skipped: mount id/coordinates unavailable '
        '(id=$mountId, ra=$ra, dec=$dec) — alert-only.',
        source: 'MeridianFlipStandaloneMonitor',
      );
      _ref.read(flipExecutionStateProvider.notifier).state =
          FlipExecutionState.failed;
      _ref.read(flipLastErrorProvider.notifier).state =
          'Flip not executed: mount coordinates unavailable';
      return false;
    }

    final cameraState = _ref.read(cameraStateProvider);
    final focuserState = _ref.read(focuserStateProvider);
    final coverState = _ref.read(coverCalibratorStateProvider);
    final cameraId =
        cameraState.connectionState == DeviceConnectionState.connected
        ? cameraState.deviceId
        : null;
    // Re-center needs a camera for the plate-solve frame; honor the user's
    // setting only when one is connected.
    final autoCenter = settings.recenterAfterFlip && cameraId != null;

    // The flip engine re-slews to a J2000 target and precesses it to the
    // mount's frame on the way out, like every slew. The mount's own position
    // is read back in coordinates of date (every driver, and the simulator),
    // so passing it straight through precessed it twice and moved the framing
    // by ~20' (2026) on every manual or standalone flip.
    final (
      targetRaDeg,
      targetDec,
    ) = AstronomyCalculations.precessFromDateToJ2000(
      raDeg: ra * 15,
      decDeg: dec,
      dt: DateTime.now().toUtc(),
    );

    _flipInFlight = true;
    try {
      await _ref
          .read(backendProvider)
          .performMeridianFlip(
            mountId: mountId,
            cameraId: cameraId,
            focuserId:
                focuserState.connectionState == DeviceConnectionState.connected
                ? focuserState.deviceId
                : null,
            coverCalibratorId:
                coverState.connectionState == DeviceConnectionState.connected
                ? coverState.deviceId
                : null,
            targetName: targetName,
            targetRaHours: targetRaDeg / 15,
            targetDecDegrees: targetDec,
            pauseGuiding: settings.pauseGuidingBeforeFlip,
            autoCenter: autoCenter,
            refocusAfter: settings.refocusAfterFlip,
            resumeGuiding: settings.resumeGuidingAfterFlip,
            settleTimeSecs: settings.settleTimeSeconds,
          );
      _ref.read(flipExecutionStateProvider.notifier).state =
          FlipExecutionState.completed;
      _ref.read(flipProgressProvider.notifier).state = 100;
      logger.info(
        '$targetName completed',
        source: 'MeridianFlipStandaloneMonitor',
      );
      if (settings.pushNotificationOnFlip) {
        unawaited(
          _ref
              .read(notificationServiceProvider)
              .notifyMeridianFlip(isStarting: false)
              .catchError((Object e, StackTrace s) => false),
        );
      }
      return true;
    } catch (e) {
      _ref.read(flipExecutionStateProvider.notifier).state =
          FlipExecutionState.failed;
      _ref.read(flipLastErrorProvider.notifier).state = e.toString();
      logger.error(
        '$targetName failed: $e',
        source: 'MeridianFlipStandaloneMonitor',
      );
      return false;
    } finally {
      _flipInFlight = false;
    }
  }

  bool _evaluateTrigger(MeridianFlipSettings settings, double ha) {
    switch (settings.triggerMethod) {
      case MeridianTriggerMethod.minutesPastMeridian:
        // Positive HA means past meridian (west of zenith).
        if (ha <= 0) return false;
        final minutesPast = ha * 60.0;
        return minutesPast >= settings.minutesPastMeridian;
      case MeridianTriggerMethod.hourAngleThreshold:
        if (ha <= 0) return false;
        return ha >= settings.hourAngleThreshold;
      case MeridianTriggerMethod.minutesBeforeLimit:
        // Why: requires mount-advertised tracking-limit time, which is only
        // surfaced inside the Rust sequencer state. Standalone Dart side
        // has no equivalent today — explicitly skip rather than approximate.
        return false;
      case MeridianTriggerMethod.onTrackingLimitHit:
        // Why: tracking-limit detection lives in the Rust trigger evaluator
        // (triggers.rs::looks_like_tracking_limit_hit) and depends on state
        // history the standalone Dart monitor doesn't carry. Skip.
        return false;
    }
  }

  void _emitAlert(MeridianFlipSettings settings, double hourAngleHours) {
    _ref.read(flipExecutionStateProvider.notifier).state =
        FlipExecutionState.executing;
    _ref.read(flipCurrentStepProvider.notifier).state = null;
    _ref.read(flipProgressProvider.notifier).state = 0;
    _ref.read(flipLastErrorProvider.notifier).state = null;

    final logger = _ref.read(loggingServiceProvider);
    logger.warning(
      'Standalone meridian monitor: trigger fired '
      '(method=${settings.triggerMethod.name}, HA=${hourAngleHours.toStringAsFixed(3)}h)',
      source: 'MeridianFlipStandaloneMonitor',
      fields: {
        'triggerMethod': settings.triggerMethod.name,
        'hourAngleHours': hourAngleHours,
        'pushNotificationOnFlip': settings.pushNotificationOnFlip,
        'soundAlertOnFlip': settings.soundAlertOnFlip,
      },
    );

    if (settings.pushNotificationOnFlip) {
      // Why: the operator opted into push notifications for flip events.
      // Route through NotificationService so Discord / Pushover / system push
      // all honor the toggle. Errors here are reported but never propagate —
      // a missed notification must not stall the monitor.
      unawaited(
        _ref
            .read(notificationServiceProvider)
            .notifyMeridianFlip(isStarting: true)
            .catchError((Object e, StackTrace s) {
              logger.error(
                'Failed to dispatch meridian flip notification: $e',
                source: 'MeridianFlipStandaloneMonitor',
              );
              return false;
            }),
      );
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    super.dispose();
  }
}

/// Standalone meridian-flip watcher.
///
/// Must be watched (e.g., by the app shell) so the timer survives provider
/// invalidation. Operates only while
/// `globalMeridianFlipSettings.standaloneMonitoringEnabled` is true.
final meridianFlipStandaloneMonitorProvider =
    StateNotifierProvider<MeridianFlipStandaloneMonitor, void>((ref) {
      return MeridianFlipStandaloneMonitor(ref);
    });
