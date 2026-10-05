import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../backend/bridge_events.dart' show depthGoalCompletedDetail;
import '../../backend/frame_capture_metadata.dart';
import '../../backend/nightshade_backend.dart';
import '../../models/equipment/equipment_models.dart';
import '../../models/imaging/imaging_models.dart';
import '../../models/sequence/active_plan_owner.dart';
import '../../models/sequence/instruction_progress_detail.dart';
import '../../models/replay_decision.dart' show DecisionCategory;
import '../../models/sequence/sequence_models.dart';
import '../../models/settings/app_settings.dart'
    show ObserverLocation, SafetyFailMode;
import '../../models/weather/weather_settings.dart' show WeatherSettings;
import '../weather_providers.dart' show weatherSettingsProvider;
import '../../services/disk_space_guard.dart';
import '../../services/sequence_file_service.dart';
import '../../services/sequence_repository.dart'
    show sequenceRepositoryProvider;
import '../../services/live_stacking_broadcast_service.dart';
import '../../services/live_stacking_service.dart' show LiveStackingConfig;
import '../../services/safe_rig_service.dart';
import '../../services/smart_night/guide_rms_collector.dart';
import '../../services/capture_preview_loader.dart';
import '../../services/logging_service.dart';
import '../../utils/remote_path.dart';
import 'log_rate_limiter.dart';
import '../thumbnail_sidecar_provider.dart';
import '../backend_provider.dart';
import '../database_provider.dart'
    show guideRmsHistoryDaoProvider, imagesDaoProvider, targetsDaoProvider;
import '../defect_map_provider.dart' show seedDefectMapRuntimeForSequence;
import '../../database/daos/campaigns_dao.dart' show campaignsDaoProvider;
import '../../database/daos/targets_dao.dart' show TargetsDao;
import '../disk_space_provider.dart';
import '../equipment_provider.dart';
import '../focuser_backlash_provider.dart'
    show focuserBacklashOfferSessionProvider, savedFocuserBacklashProvider;
// Sky-brightness poll reads the tracker via this
// provider (defined in flat_wizard_provider since the tracker is
// shared between flat-wizard and adaptive-exposure paths).
import '../flat_wizard_provider.dart' show skyBrightnessTrackerProvider;
import '../imaging_provider.dart';
import '../live_stacking_provider.dart';
import '../meridian_flip_provider.dart';
// Plugin-node dispatcher abstraction.
import '../plugin_node_dispatcher.dart';
import '../replay_debug_provider.dart';
import '../profiles_provider.dart';
import '../sequence_provider.dart'
    show
        currentSequenceProvider,
        recordSequenceStopEvidence,
        sequenceExecutionStateProvider,
        sequenceLaunchInFlightProvider,
        sequenceProgressProvider,
        sequenceStopEvidenceProvider;
import '../sequence_stats_provider.dart';
import '../session_handoff_provider.dart'
    show
        sessionCarryOverProvider,
        sessionHandoffDecisionProvider,
        sessionHandoffIgnoreUnavailableOnceProvider;
import '../../services/session_handoff_service.dart'
    show SessionCarryOver, SessionHandoffDecision;
import '../session_provider.dart';
import '../settings_provider.dart';
// Session-lifecycle hooks: optical-train baseline capture,
// post-session diagnostics summary, NotificationRouter active-sequence
// tracking, USB disconnect aggregation.
import '../../services/optical_train_diagnostics_service.dart'
    show OpticalTrainDiagnostics;
import '../notification_router_provider.dart';
import '../optical_train_diagnostics_provider.dart';
import '../preflight_providers.dart';
import '../recovery_provider.dart' show recoveryHistoryProvider;
import '../science_provider.dart'
    show sessionPsfTilesProvider, sessionResidualVectorsProvider;
import '../usb_disconnect_log_provider.dart';
import 'exposure_progress_vocabulary.dart';
import 'node_exposure_tally.dart';
import 'structured_progress_json.dart';
import 'run_stop_classification.dart';
import 'target_end_when_notice.dart';
import 'sequence_validation.dart' as validation;
import 'sequencer_defaults.dart';
import 'sequence_executor/frame_attribution.dart';
import 'sequence_executor/eta_smoothing.dart';
import 'sequence_executor/run_finalization.dart';
import 'sequence_executor/sequence_serializer.dart';
import 'sequence_executor/stop_confirmation.dart';
import '../../services/frame_quality_score.dart';

export 'sequence_executor/eta_smoothing.dart'
    show EtaSmoother, kEtaEmaAlpha, kEtaWindowSize;
export 'sequence_executor/run_finalization.dart' show RunFinalization;
export 'sequence_executor/sequence_serializer.dart' show SequenceSerializer;
export 'sequence_executor/stop_confirmation.dart'
    show
        NativeStopConfirmer,
        kNativeStopConfirmationPollInterval,
        kNativeStopConfirmationTimeout,
        kNativeTerminalStates;

part 'sequence_executor/runtime_config_operations.dart';
part 'sequence_executor/event_operations.dart';
part 'sequence_executor/session_diagnostics_operations.dart';
part 'sequence_executor/checkpoint_watchdog_operations.dart';

/// Temperature drift threshold for post-session cooler stability notes.
///
/// A one-degree band is tight enough to catch a cooler that is cycling or
/// saturated, while avoiding noise from normal sub-degree sensor wobble.
const double kCoolerSetpointBandDegC = 1.0;

/// Sequence executor that manages execution.
///
/// The provider wires `ref.onDispose(executor.dispose)` so owned timers and
/// the native event subscription are guaranteed to be torn down with the
/// provider lifetime, even if a sequence is invalidated mid-run.
final sequenceExecutorProvider = Provider<SequenceExecutor>((ref) {
  final backend = ref.watch(backendProvider);
  final executor = SequenceExecutor(ref, backend: backend);
  // Owned timers/subscriptions must be torn down with the provider lifetime —
  // otherwise an invalidation mid-sequence leaks the periodic progress timer,
  // the checkpoint timer, and the native event stream subscription past the
  // disposed Ref. stop() handles the running case; this handles teardown.
  ref.onDispose(executor.dispose);
  return executor;
});

class SequenceExecutor {
  final Ref _ref;
  final NightshadeBackend _backend;

  /// Translates the loaded [Sequence] into the JSON the native executor runs.
  /// Its lookup warnings go into the run record through [_surfaceRunWarning].
  late final SequenceSerializer _serializer = SequenceSerializer(
    ref: _ref,
    warn: _surfaceRunWarning,
  );

  /// Emit an operator-facing warning onto both the log and the live run
  /// stats, so it survives into `sequence_runs.stats_json` and the
  /// post-session report rather than only existing in a log file.
  ///
  /// [persist] = `false` for a warning raised during run START-UP, which is
  /// already covered by the final `finishRun` write. See [_incrementRunStat];
  /// the default `true` keeps mid-run warnings crash-durable.
  void _surfaceRunWarning(String message, {bool persist = true}) {
    _logger.warning(message, source: 'SequenceExecutor');
    // Route through _incrementRunStat so the warning gets the same copy-to-
    // notify + stats-seal handling as every other live-stat mutation (it is a
    // no-op when no run is live or the stats are already sealed for finish).
    _incrementRunStat(
      (stats) => stats.recordWarning(message),
      persist: persist,
    );
  }

  Timer? _progressTimer;
  DateTime? _startTime;
  bool _isPaused = false;
  StreamSubscription? _nativeEventSubscription;
  StreamSubscription<DiskSpaceWatchdogEvent>? _diskWatchdogSubscription;
  Timer? _checkpointTimer;
  bool _runFinalized = false;
  bool _pauseResumeInProgress = false;

  /// In-flight start latch. A start (or checkpoint resume) holds this for the
  /// whole duration of its lifecycle transaction — validation, session/run
  /// creation, timers, watchdogs, native event subscription and native start.
  ///
  /// Chosen concurrency policy (pinned by tests): a second concurrent start is
  /// **rejected** with a [StateError] rather than joined to the first future.
  /// This guarantees two rapid Start taps can never create a second session
  /// row, run row, event subscription, timer set or native start — the second
  /// caller bounces off the latch before touching any resource. Reset in the
  /// `finally` of [start] / [resumeFromCheckpoint].
  bool _startInFlight = false;

  /// The one per-run finalization transaction, or null when no teardown has
  /// been claimed for the current run. Created by whichever path claims teardown
  /// FIRST — a natural terminal event, an explicit [stop], or a start/resume
  /// [_rollbackStart] — and retained across retries (its first-claimed terminal
  /// intent is immutable; a later racing caller joins it, it does not override
  /// it). Reset to null when a fresh run acquires its lifecycle, and cleared on
  /// a fully-successful finalize.
  RunFinalization? _finalization;

  /// The in-flight finalization drive, or null when no drive is currently
  /// running. A racing [stop] / duplicate terminal event JOINS this future
  /// instead of starting a second native stop or a duplicate cleanup, giving
  /// exactly-once finalize / end-session / report. Cleared when the drive
  /// settles (success OR a retryable failure), so a later Stop retry from
  /// stopFailed / cleanupFailed can re-drive the retained [_finalization].
  Future<void>? _finalizationFuture;

  /// Monotonic per-run terminal id, stamped onto each [RunFinalization] and the
  /// published [SequenceTerminalRunResult]. It is never reset (unique across
  /// the whole executor lifetime), so a re-mounted screen cannot mistake an
  /// earlier result for a new one.
  int _finalizationGeneration = 0;

  /// The awaitable finalization future spawned by the NATURAL terminal path.
  /// Tests await [terminalCleanupSettledForTest] on this instead of sleeping a
  /// wall-clock margin. `null` until the first natural terminal event of a run
  /// fires.
  Future<void>? _terminalCleanupFuture;

  /// Set the instant finalization claims the run's stats (inside [_finalizeRun],
  /// before the final `finishRun` write). Blocks any further incremental
  /// `updateStats` write so a late / old-generation live-stat write can never
  /// land after the final stats JSON and clobber it. Reset when a fresh run
  /// acquires its lifecycle.
  bool _statsSealed = false;

  /// The run status a COMPLETED finalization already published for this run, or
  /// null while no run has settled.
  ///
  /// The run's verdict is claimed once and belongs to whoever claimed it first.
  /// The in-flight guards above cover a terminal that arrives DURING
  /// finalization; this covers one that arrives after it finished. The native
  /// emits TWO terminals for a stop-cancelled Slew — a `Stopped` state change
  /// and the node tree's own `SequenceFailed` — so without this the second
  /// opens a second finalization and republishes the operator's deliberate
  /// Stop as `failed`.
  ///
  /// Reset when a fresh run acquires its lifecycle.
  String? _settledRunStatus;

  /// In-flight incremental `updateStats` writes, drained before the final
  /// `finishRun` so no stale write races the final stats JSON.
  final Set<Future<void>> _pendingStatWrites = <Future<void>>{};

  /// True once the current start/resume transaction has issued (or is about to
  /// issue) `backend.sequencerStart()`. A throw at/after that point may mean a
  /// PARTIAL native launch — the Rust executor may have begun imaging — so
  /// [_rollbackStart] must best-effort `sequencerStop()` rather than tear down
  /// blind. Reset to `false` at the top of each acquisition and consumed by
  /// [_rollbackStart]; a failure BEFORE the native launch (validation, session/
  /// run creation, loadJson) leaves it `false`, so those rollbacks skip the
  /// stop and settle cleanly to `failed`.
  bool _nativeLaunchAttempted = false;

  /// Guards the periodic checkpoint save against re-entrancy. A slow
  /// `saveCheckpoint()` (large sequence, slow disk) can outlive the 30 s
  /// timer cadence; without this flag a second save would be issued while
  /// the first is still in flight, racing two writers on the same
  /// checkpoint file. The next tick simply skips while one is running.
  bool _checkpointSaveInFlight = false;

  /// Live-stacking auto-feed: whether the live stacker + LAN broadcast have
  /// been armed for the *current* run yet.
  /// The first accepted frame of a run that contains an enabled
  /// `LiveStackingNode` arms both (the frame becomes the stack
  /// reference); every later accepted frame is added to the existing
  /// stack. Reset to `false` in `start()` and torn down in `stop()` so a
  /// new run never inherits the previous run's reference frame.
  bool _liveStackingArmedForRun = false;

  /// Guards against concurrent re-entrant accepted-frame feeds. FFI
  /// stacking calls are async; without this a fast exposure cadence could
  /// interleave an `addFrameFromFile` with the initial `startFromFile`
  /// and corrupt the reference. We serialise feeds by chaining onto this
  /// future. `null` when no feed is in flight.
  Future<void>? _liveStackingFeedChain;

  /// In-flight fire-and-forget frame-persistence futures from
  /// [_registerSequenceFrame]. Tracked so (a) tests can await quiescence
  /// instead of sleeping a wall-clock margin and (b) the disposed guard
  /// below has a defined set of stragglers it is protecting against.
  final Set<Future<void>> _inFlightFrameRegistrations = <Future<void>>{};

  /// Frames the grader has already ruled on — and that the run record has
  /// therefore already counted — whose `ExposureCompleted` has not arrived yet,
  /// keyed by the frame index all three events carry.
  ///
  /// `FrameAccepted` / `FrameRejected` are the only events that know whether a
  /// frame was kept, the only ones carrying the capture truth the FITS header
  /// was written from, and the only ones EVERY producer emits: native emits one
  /// per frame it saves, from the exposure instruction, whether that instruction
  /// was reached through a TakeExposure node or a Smart Exposure one. They are
  /// consequently where the run's frame counters are incremented (see
  /// `_recordGradedFrame`).
  ///
  /// `ExposureCompleted` cannot carry that job. The executor synthesises it in
  /// `native/nightshade_native/sequencer/src/executor/start/progress_callback.rs`
  /// only for nodes present in `exposure_node_metadata`, which
  /// `executor/start.rs` builds from `NodeType::TakeExposure` alone, and only
  /// when the node's frame index ADVANCES. A Smart Exposure node satisfies
  /// neither condition — it is absent from the map, and its delegated
  /// single-frame bursts report frame 1 of 1 over and over — so a whole night
  /// on the owner's rig emitted not one `ExposureCompleted`, and
  /// `GET /api/sequencer/status` answered `framesCaptured: 0, framesRejected: 0`
  /// for ten minutes while the grader was writing its third reject to disk.
  ///
  /// An entry here therefore means "already counted": the `ExposureCompleted`
  /// that follows consumes it for the preview stamp and adds nothing to the
  /// counters, while a frame that reaches `ExposureCompleted` with NO entry was
  /// never graded (a run with no save path emits no grader event at all) and is
  /// counted there instead. Entries are cleared whenever a new node starts, so
  /// a frame whose `ExposureCompleted` never arrives cannot strand a verdict on
  /// a later frame of a later node.
  final Map<int, ({bool accepted, FrameCapture capture})> _gradedFrames =
      <int, ({bool accepted, FrameCapture capture})>{};

  /// True once [dispose] has run. Late completions of fire-and-forget
  /// work (frame persistence, campaign credit) must not read providers
  /// through [_ref] afterwards — the container may be gone, and the read
  /// throws "Tried to read a provider from a ProviderContainer that was
  /// already disposed" out of an unhandled async error.
  // NOT final: set to true in [dispose].
  bool _disposed = false;

  /// Periodic poller that reads the latest sky brightness
  /// from `skyBrightnessTrackerProvider` and pushes it to the executor.
  /// The cadence is intentionally generous (10s) because sky brightness
  /// changes slowly; running it faster would just add CPU noise for no
  /// adaptive-exposure benefit.
  Timer? _skyBrightnessPollTimer;

  /// Last value pushed to the executor; we suppress redundant pushes
  /// so the runtime config event stream is quiet when conditions are
  /// stable.
  double? _lastPushedSkyMag;

  /// Per-frame cadence smoother backing the run's ETA.
  final EtaSmoother _eta = EtaSmoother();

  /// Subscriptions for propagating settings changes to the backend mid-sequence
  final List<ProviderSubscription> _settingsSubscriptions = [];

  /// Sequence id of the currently running sequence. Held so
  /// the post-session diagnostics summary and the NotificationRouter
  /// override know which sequence just finished even after
  /// `currentSequenceProvider` has been cleared by the UI.
  String? _activeSequenceId;

  /// Wall-clock start time of the current run. Used to
  /// compute the per-session USB disconnect count when building the
  /// post-session diagnostics summary. Distinct from `_startTime`
  /// (which is reset on pause/resume); this one survives until the
  /// post-session hooks have run.
  DateTime? _sessionStartedAt;

  /// Pre-session optical-train snapshot captured at
  /// `start()`. Persists across the run so the post-session finalizer
  /// can publish the baseline alongside the post-session diagnostics
  /// (so the dialog can render "pre" and "post" side by side, even
  /// after the in-memory baseline provider has been overwritten by the
  /// next run).
  OpticalTrainBaseline? _sessionStartBaseline;
  LoggingService get _logger => _ref.read(loggingServiceProvider);

  /// Rate limiter for the per-event debug trace in `_handleSequencerEvent`.
  /// Unlimited, a per-event line consumes the whole in-app log ring — see
  /// `log_rate_limiter.dart`.
  final LogRateLimiter _eventTraceLimiter = LogRateLimiter(
    window: const Duration(seconds: 5),
  );

  SequenceExecutor(this._ref, {NightshadeBackend? backend})
    : _backend = backend ?? _ref.read(backendProvider);

  void _ensureBackendAuthority() {
    if (_disposed || !identical(_ref.read(backendProvider), _backend)) {
      throw StateError(
        'This sequence executor belongs to an imaging host that is no longer '
        'active. Retry the action against the current host.',
      );
    }
  }

  /// Test-only entry point that returns the JSON the executor will send
  /// to the Rust backend. Exposed so unit tests can assert AppSettings
  /// defaults propagate correctly
  @visibleForTesting
  String sequenceToJsonForTest(Sequence sequence) =>
      _serializer.sequenceToJson(sequence);

  /// Test entry point for the session-start hooks. Lets
  /// integration tests exercise the optical-train baseline capture +
  /// NotificationRouter override + sessionStart timestamp without
  /// spinning up the full `start()` pipeline (which requires a current
  /// sequence, settings, validation, native backend, …).
  @visibleForTesting
  void captureSessionStartHooksForTest(String sequenceId) =>
      _captureSessionStartHooks(sequenceId);

  /// Test entry point for the session-end hooks.
  @visibleForTesting
  void captureSessionEndHooksForTest() => _captureSessionEndHooks();

  /// Test entry point that pumps a synthesised
  /// `NightshadeEvent` through the same handler the live native event
  /// subscription uses. Lets unit tests exercise the FrameAccepted /
  /// FrameRejected / PluginNodeRequested handlers without spinning up
  /// the full Rust backend.
  @visibleForTesting
  void handleSequencerEventForTest(NightshadeEvent event) =>
      _handleSequencerEvent(event);

  /// Runs the start-time catalog binding on its own, so a test can assert what
  /// the `targets` rows hold afterwards without driving a whole run.
  @visibleForTesting
  Future<void> bindCatalogTargetsForTest(Sequence sequence) =>
      _bindCatalogTargets(sequence);

  /// Completes when every live-stacking feed AND fire-and-forget frame
  /// persistence queued SO FAR has finished (the feed chain serialises
  /// feeds, so awaiting the current tail covers all frames pumped before
  /// this call). Tests await this instead of sleeping a wall-clock
  /// margin — fixed delays were flaky on slow CI runners, where a
  /// still-running feed outlived the test body and failed it "after
  /// completion".
  @visibleForTesting
  Future<void> get liveStackingFeedSettledForTest async {
    // Re-read in a loop: a feed step can append to the chain while we
    // await (e.g. the reference start queued an add), and frame
    // persistence runs on its own futures outside the chain.
    while (true) {
      final tail = _liveStackingFeedChain;
      final registrations = List.of(_inFlightFrameRegistrations);
      if (tail == null && registrations.isEmpty) return;
      try {
        await Future.wait<void>([if (tail != null) tail, ...registrations]);
      } catch (_) {
        // Feed errors are logged and surfaced by the feed itself; this
        // waiter only cares about quiescence.
      }
      if (identical(tail, _liveStackingFeedChain) &&
          _inFlightFrameRegistrations.isEmpty) {
        return;
      }
    }
  }

  /// Completes when the finalization spawned by the most recent natural terminal
  /// event (Completed / Failed / Stopped) has settled. Tests await this to
  /// observe run/session finalization deterministically instead of sleeping.
  /// Returns immediately when no terminal event has fired yet. A cleanup that
  /// settled to the retryable `cleanupFailed` state completed its drive with an
  /// error; that error is swallowed here so tests can await quiescence and then
  /// assert on the surfaced state rather than on a thrown future.
  @visibleForTesting
  Future<void> get terminalCleanupSettledForTest async {
    try {
      await _terminalCleanupFuture;
    } catch (_) {
      // The truthful state (cleanupFailed) is already published; tests assert
      // on it directly.
    }
  }

  /// Test entry point for the session-handoff carry-over
  /// seed. Lets tests exercise the `Resume` / `Restart` / `ContinueNew`
  /// branches against a mock backend without driving a full sequence
  /// start (which requires Rust, validation, and live settings).
  @visibleForTesting
  Future<void> seedIntegrationCarryOverFromHandoffForTest(
    NightshadeBackend backend,
    Sequence sequence,
  ) => _seedIntegrationCarryOverFromHandoff(backend, sequence);

  /// Convert Dart sequence to JSON for native executor
  ///
  /// Why: this is the point where per-sequence and per-node values are
  /// combined with global AppSettings defaults. Per-node values always win;
  /// AppSettings is consulted only when the node provides no explicit value.
  Future<validation.ValidationResult> validateSequenceForStart(
    Sequence sequence,
  ) async {
    final validator = _ref.read(validation.sequenceValidatorProvider);
    return validator.validate(sequence);
  }

  Future<void> start() async {
    _ensureBackendAuthority();
    // A. Start serialization + admissible-state gate.
    // Reject a second concurrent start (latch) or a start while the executor
    // is already busy (running / paused / stopping / recovering). A
    // completed/failed prior run may start again once its cleanup has settled
    // (idle / completed / failed are admissible). This gate mutates nothing,
    // so a rejected concurrent caller leaves the in-flight run — and its
    // Smart Night / mosaic handoff — completely untouched.
    final admissionState = _ref.read(sequenceExecutionStateProvider);
    if (_startInFlight || !_isStartAdmissible(admissionState)) {
      throw StateError(
        'Cannot start: a sequence start is already in flight or the executor '
        'is not in an admissible state (state: ${admissionState.name}).',
      );
    }
    _startInFlight = true;
    _ref.read(sequenceLaunchInFlightProvider.notifier).state = true;
    try {
      final sequence = _ref.read(currentSequenceProvider);
      if (sequence == null) {
        // Validation rejection BEFORE any run resource exists: do not flash
        // running or create/finalize fake rows. The one permitted ownership
        // mutation is restoring a Smart Night / mosaic handoff the caller
        // performed before calling start() (contract A) so the operator's
        // stashed manual sequence is not stranded behind a rejected launch.
        // "Nothing loaded" is an operator/state error, not a server fault, so
        // we throw the same typed exception the validation path uses — every
        // caller (UI button, headless POST /api/sequencer/start, scheduler)
        // surfaces it as a clean 400 instead of an opaque 500.
        _releaseAutomatedEditorOwnership();
        throw validation.SequenceValidationException(
          validation.ValidationResult(
            issues: const [
              validation.ValidationIssue(
                severity: validation.ValidationSeverity.error,
                category: validation.ValidationCategory.structure,
                title: 'No sequence loaded',
                description:
                    'Load or build a sequence before starting the sequencer.',
                code: 'no_sequence_loaded',
              ),
            ],
            validatedAt: DateTime.now(),
          ),
        );
      }

      // Runtime mode, safety policy, observer location, and save path are
      // launch-authoritative configuration. Never substitute defaults while
      // settings are loading or failed: doing so could turn simulation off,
      // omit the configured safety mode, and clear the native save path. Read
      // one immutable snapshot before acquiring any run/session resource.
      late final AppSettingsState runSettings;
      try {
        runSettings = await _ref.read(appSettingsProvider.future);
      } catch (_) {
        _releaseAutomatedEditorOwnership();
        rethrow;
      }

      // Audit C3 — full pre-flight pass. Every start path (UI button via
      // sequence_action_service, headless POST /api/sequencer/start,
      // scheduler autopilot) reaches this code, so they all see the same
      // equipment / disk-space / dark-library / settings checks the pre-flight
      // dialog already enforced. A validation failure is a pure rejection: no
      // run resource has been acquired yet, so we only restore a Smart Night /
      // mosaic handoff and throw — never a fake failed run/session.
      final result = await validateSequenceForStart(sequence);
      if (result.hasErrors) {
        // Surface the entire [ValidationResult]: a caller that sees only the
        // first error sends the operator back for another round per error.
        _releaseAutomatedEditorOwnership();
        throw validation.SequenceValidationException(result);
      }

      // B. Transactional acquisition.
      // From here, every resource (UI running state, session row, run row +
      // currentRunId, session-start hooks, timers, disk watchdog, native event
      // subscription, native start) is part of ONE lifecycle transaction. Any
      // failure funnels into the single [_rollbackStart] path, which cancels
      // every acquired resource, finalizes the run failed, ends the session,
      // clears the stale run id + transient stats, releases a Smart Night /
      // mosaic handoff, and leaves a truthful non-running state.
      _resetFinalizationForNewRun();
      try {
        await _acquireAndStartRun(sequence, runSettings);
      } catch (e, st) {
        await _rollbackStart(e, st);
        rethrow;
      }
    } finally {
      _startInFlight = false;
      _ref.read(sequenceLaunchInFlightProvider.notifier).state = false;
    }
  }

  /// Open the `imaging_sessions` row for this run.
  ///
  /// One sequence run == one session, labelled with the sequence name.
  ///
  /// targetRa/targetDec stay NULL for a multi-target sequence rather than
  /// picking `targetHeaders.first`, which would misrepresent the session;
  /// per-target coordinates belong to the per-target child rows the scheduler
  /// emits as it walks the tree. A single-target sequence carries its own
  /// coordinates.
  ///
  /// The profile and sequence ids are the run's identity — the Continue Session
  /// handoff dialog builds its whole context out of `imaging_sessions`.
  Future<void> _startSessionRow(Sequence sequence) async {
    final sessionNotifier = _ref.read(sessionStateProvider.notifier);
    final isSingleTarget = sequence.targetHeaders.length == 1;
    await sessionNotifier.startSession(
      targetName: sequence.name,
      targetRa: isSingleTarget ? sequence.targetHeaders.first.raHours : null,
      targetDec: isSingleTarget
          ? sequence.targetHeaders.first.decDegrees
          : null,
      profileId: _ref.read(activeEquipmentProfileProvider)?.id,
      sequenceId: sequence.databaseId,
    );
    sessionNotifier.setTotalExposures(sequence.totalExposures);
  }

  /// Test entry point for the session row a run opens. See [_startSessionRow].
  @visibleForTesting
  Future<void> startSessionRowForTest(Sequence sequence) =>
      _startSessionRow(sequence);

  /// Give the sequence about to run a `sequences` row if it has never had one.
  ///
  /// A tree built in the sequencer and started without a trip through Save
  /// carries `databaseId == null`, which writes `sequence_id` NULL onto both
  /// its `sequence_runs` row and its `imaging_sessions` row. Three surfaces key
  /// off that column: the Continue Session handoff dialog (to name and reload
  /// what it offers), run history's per-sequence grouping, and the run-diff
  /// view.
  ///
  /// A sequence the operator actually ran is worth keeping, so it is persisted
  /// here — once: the editor adopts the new id, so the next run of the same
  /// document updates that row instead of adding another.
  ///
  /// A failure is logged and the run proceeds with the id still null: refusing
  /// to image because a library row could not be written would be far worse
  /// than a night filed without one.
  Future<Sequence> _ensureSequencePersisted(Sequence sequence) async {
    if (sequence.databaseId != null) return sequence;
    // Operator-authored plans only. Autopilot, Smart Night and mosaic generate
    // a fresh tree per target/panel and regenerate it on the next run, so
    // filing each one in the library would bury the operator's own sequences
    // under a night's worth of machine output. Their trees stay recoverable
    // from the run's stored snapshot.
    final notifier = _ref.read(currentSequenceProvider.notifier);
    if (notifier.activeOwner.isAutomated) return sequence;
    try {
      final databaseId = await _ref
          .read(sequenceRepositoryProvider)
          .saveSequence(sequence);
      notifier.applyPersistedSave(
        expectedSequenceId: sequence.id,
        databaseId: databaseId,
        name: sequence.name,
        description: sequence.description,
        isTemplate: sequence.isTemplate,
      );
      return sequence.copyWith(databaseId: databaseId);
    } catch (e) {
      _logger.warning(
        'Could not persist "${sequence.name}" before running it: $e — the run '
        'and its session will be recorded without a sequence id, so the '
        'Continue Session dialog will not be able to name or reload it.',
        source: 'SequenceExecutor',
      );
      return sequence;
    }
  }

  /// `targets.id` for each of the running sequence's Target nodes, keyed by
  /// node id. Rebuilt at every start by [_bindCatalogTargets].
  final Map<String, int> _runCatalogTargetIds = <String, int>{};

  /// Give every Target node in [sequence] a `targets` row so the frames it
  /// produces can be attributed to it.
  ///
  /// `TargetHeaderNode.catalogTargetId` is only populated for sequences
  /// generated from a library/catalog target (planner, scheduler, mosaic). A
  /// target the operator typed into the builder had none, so every frame it
  /// captured was persisted with `captured_images.target_id` NULL: the Session
  /// Report filed the night under "Untargeted", per-target integration goals
  /// could never complete, and project tracking counted nothing — for frames
  /// whose own FITS `OBJECT` card and filename named the target.
  ///
  /// The row is created lazily HERE, at the moment the target is actually
  /// imaged, rather than when a Target node is added to a draft sequence, so
  /// editing the builder does not litter the target library.
  Future<void> _bindCatalogTargets(Sequence sequence) async {
    _runCatalogTargetIds.clear();
    final dao = _ref.read(targetsDaoProvider);
    for (final header in sequence.targetHeaders) {
      final existing = header.catalogTargetId;
      if (existing != null) {
        _runCatalogTargetIds[header.id] = existing;
        // A node bound to a library row can be re-pointed in the builder just
        // like a hand-typed one — skipping the refresh here left the scheduler
        // evaluating the library's original position for exactly the targets
        // the operator picked FROM the library.
        try {
          await _refreshCatalogCoordinates(dao, existing, header);
        } catch (e) {
          _logger.warning(
            'Could not update the catalog coordinates for '
            '"${header.targetName}": $e',
            source: 'SequenceExecutor',
          );
        }
        continue;
      }
      final name = header.targetName.trim();
      // An unnamed target cannot be identified later; NULL stays the honest
      // answer rather than inventing a library entry called "".
      if (name.isEmpty) continue;
      try {
        final targetId = await dao.findOrCreateByName(
          name: name,
          raHours: header.raHours,
          decDegrees: header.decDegrees,
        );
        _runCatalogTargetIds[header.id] = targetId;
        await _refreshCatalogCoordinates(dao, targetId, header);
      } catch (e) {
        _logger.warning(
          'Could not bind target "$name" to a targets row; its frames will be '
          'recorded without a target id: $e',
          source: 'SequenceExecutor',
        );
      }
    }
  }

  /// Bring the catalog row's coordinates up to date with the target the run is
  /// actually imaging.
  ///
  /// `findOrCreateByName` matches on the name alone, so re-pointing a target in
  /// the builder and running it again returned the same row with its ORIGINAL
  /// RA/Dec. That row is the only thing the autopilot reads, so the scheduler
  /// went on rejecting a target at the zenith as "below horizon" — quoting the
  /// altitude of coordinates the operator had replaced half an hour earlier.
  ///
  /// Only the coordinates move, and only for a node carrying real ones: an
  /// unset (0, 0) target must never blank a stored position, and the rest of
  /// the row (priority, altitude floor, goals, notes) belongs to the library.
  Future<void> _refreshCatalogCoordinates(
    TargetsDao dao,
    int targetId,
    TargetHeaderNode header,
  ) async {
    if (header.raHours == 0.0 && header.decDegrees == 0.0) return;
    final row = await dao.getTargetById(targetId);
    if (row == null) return;
    // One arcsecond in each axis — below it the difference is float noise from
    // a round trip, not an operator re-pointing the telescope.
    const raEpsilonHours = 1.0 / 54000.0;
    const decEpsilonDegrees = 1.0 / 3600.0;
    if ((row.ra - header.raHours).abs() < raEpsilonHours &&
        (row.dec - header.decDegrees).abs() < decEpsilonDegrees) {
      return;
    }
    await dao.updateTarget(
      row.copyWith(
        ra: header.raHours,
        dec: header.decDegrees,
        updatedAt: DateTime.now(),
      ),
    );
    _logger.info(
      'Target "${row.name}" re-pointed to RA ${header.raHours}h / '
      'Dec ${header.decDegrees}°; the scheduler now evaluates it there.',
      source: 'SequenceExecutor',
    );
  }

  /// `targets.id` for the frame produced by [nodeId], from the binding made at
  /// run start. Null when the node sits outside any target.
  int? _runTargetIdFor(Sequence sequence, String nodeId) {
    final header = enclosingTargetHeader(sequence, nodeId);
    if (header == null) return null;
    return header.catalogTargetId ?? _runCatalogTargetIds[header.id];
  }

  /// Open the durable records a run owns and stamp its id onto the executor.
  ///
  /// ONE ordered resource-open for both launch paths, [start] and
  /// [resumeFromCheckpoint], so a change to one cannot leave the other behind.
  /// (The `imaging_sessions` row itself stays with each caller — only a fresh
  /// start has a loaded tree to take single-target coordinates and a total
  /// exposure count from.)
  ///
  /// Returns the new `sequence_runs.id`.
  Future<int> _openRunRecords({
    required String sequenceName,
    int? sequenceDatabaseId,
    String? snapshotJson,
  }) async {
    final runId = await _ref
        .read(sequenceRunsDaoProvider)
        .startRun(
          sequenceId: sequenceDatabaseId,
          sequenceName: sequenceName,
          sequenceSnapshotJson: snapshotJson,
        );
    _ref.read(currentRunIdProvider.notifier).state = runId;
    _ref.read(liveSequenceStatsProvider.notifier).state = SequenceRunStats();
    _runFinalized = false;
    // A fresh run must never inherit the previous run's live stack /
    // reference frame. Arming happens lazily on the first accepted frame.
    _liveStackingArmedForRun = false;
    _liveStackingFeedChain = null;
    _gradedFrames.clear();

    // Replay Debug — stamp the active sequence_runs.id onto the
    // Rust executor so every subsequent emitted DecisionEvent carries
    // the FK. We push it before sequencerStart() so the first
    // "Sequence started" lifecycle decision the executor emits already
    // has the right run id. Failure to push is logged but does not
    // abort the run — the replay log will simply have null run_ids
    // for the affected rows, and our Dart-side `_persistReplayDecision`
    // falls back to `currentRunIdProvider`.
    try {
      await _backend.sequencerSetActiveSequenceRunId(runId);
    } catch (e) {
      _logger.warning(
        'Failed to push active sequence_run_id to Rust executor: $e',
        source: 'SequenceExecutor',
      );
    }
    return runId;
  }

  /// Open the same durable run records for a native launch that does NOT come
  /// through [start] / [resumeFromCheckpoint]: the headless
  /// `POST /api/sequencer/load` -> `POST /api/sequencer/start` path.
  ///
  /// That path re-implements a subset of [start] against the already-loaded
  /// native tree, and the `sequence_runs` row was the piece it never opened. A
  /// full successful night therefore left `sequence_runs` EMPTY — the durable
  /// run history `GET /api/sequence-runs` serves, and the record the D1 runbook
  /// points an operator at, showed nothing for a run that had just written
  /// twelve frames and four masters. The same omission also silenced
  /// finalization: `_finalizeRun` needs the run id and the live stats this
  /// opens, so pause/resume status, the run's stats JSON and its end status had
  /// nowhere to land either.
  ///
  /// No `sequenceSnapshotJson`: the snapshot column holds the Dart editor's
  /// sequence map, and the wire JSON the native executor was loaded with is a
  /// different shape. A null snapshot means "no run diff for this run", which
  /// is true; writing the wire JSON there would make the diff view compare
  /// incomparable documents.
  ///
  /// Refuses to open a second row over a live one — a run id already set means
  /// a run is under way, and stamping a new one would orphan it mid-flight in
  /// the `running` state. Returns the run id now in force.
  Future<int> openRunRecordsForNativeStart({
    required String sequenceName,
    int? sequenceDatabaseId,
  }) async {
    final existing = _ref.read(currentRunIdProvider);
    if (existing != null) {
      _logger.warning(
        'A native start asked for a run row while run $existing is still '
        'live; keeping the live run',
        source: 'SequenceExecutor',
      );
      return existing;
    }
    // Clear the PREVIOUS run's progress, the last piece of [_acquireAndStartRun]
    // this path did not mirror.
    //
    // Every producer writes `completedExposures` as the event's ABSOLUTE frame
    // index, so the frame count re-zeroed itself on the second run and made the
    // omission look harmless. `completedIntegrationSecs` accumulates, and
    // nothing on this path cleared it: measured against a scratch database,
    // four 3-and-4-frame runs in one process reported 12.0, then 24.0, then
    // 140.0, then 156.0 seconds — the whole process's integration, next to a
    // frame count covering only the run in front of the operator ("FRAMES 4 / 4"
    // beside "INTEGRATION 2m 36s" on the run-watch page for 4 x 4.0 s). The
    // per-node badges leaked the same way. A run's integration is the run's.
    _ref.read(sequenceProgressProvider.notifier).reset();
    _ref.read(nodeExposureTallyProvider.notifier).reset();
    return _openRunRecords(
      sequenceName: sequenceName,
      sequenceDatabaseId: sequenceDatabaseId,
    );
  }

  /// Close out the records [openRunRecordsForNativeStart] opened for a start
  /// the native executor then refused, so a run that never began does not sit
  /// in the run history as `running` until the next launch reconciles it.
  ///
  /// `failed` rather than a delete: the attempt happened and the operator asked
  /// for it. Errors are logged, not raised — the caller is already returning
  /// the refusal that actually explains why the run did not start.
  Future<void> discardRunRecordsForRefusedNativeStart(int runId) async {
    try {
      final stats = _ref.read(liveSequenceStatsProvider) ?? SequenceRunStats();
      stats.endTime = DateTime.now();
      await _ref
          .read(sequenceRunsDaoProvider)
          .finishRun(runId, 'failed', stats.toJson());
    } catch (e) {
      _logger.warning(
        'The start was refused and run row $runId could not be closed: $e',
        source: 'SequenceExecutor',
      );
    }
    _ref.read(currentRunIdProvider.notifier).state = null;
    _ref.read(liveSequenceStatsProvider.notifier).state = null;
  }

  /// Push every user-controlled RuntimeConfig field into the already-loaded
  /// native executor, for a launch that does NOT come through [start] /
  /// [resumeFromCheckpoint]: the headless `POST /api/sequencer/load` ->
  /// `POST /api/sequencer/start` path.
  ///
  /// The ONE seed site both launch paths share. [_startNativeExecution] calls
  /// this same method rather than the extension directly, so the seed cannot
  /// be extended for the editor path and silently skipped for the headless
  /// one — which is exactly what happened: the bare path hand-mirrored the
  /// simulation mode, the safety fail mode, the device ids and the save path
  /// and never gained the runtime-config push, so image grading, the reject
  /// folder, the autofocus cadence and the autofocus tuning all ran on the
  /// Rust defaults. Proven on the appliance: `image_grading_enabled=true` with
  /// `image_grading_star_count_min=100000` persisted and read back through
  /// `GET /api/settings`, and a 43-star simulated frame still graded `pass` —
  /// twelve of twelve accepted, nothing in `Reject/`, and no
  /// `Updating sequencer default_quality_check` line anywhere in the run.
  ///
  /// Throws on a failed push for the same reason [start] does: a night that
  /// runs with grading the operator switched on silently inert is worse than a
  /// start that refuses and says why.
  Future<void> seedRuntimeConfigForNativeStart() async {
    _ensureBackendAuthority();
    await _seedRuntimeConfigFromSettings(_backend);
  }

  /// Start the periodic work a run owns: the 1 s elapsed/ETA ticker, the
  /// checkpoint saver and the disk-space watchdog.
  ///
  /// Shared by [start] and [resumeFromCheckpoint] — the ticker closure was
  /// byte-identical in both. The ETA EMA is reset rather than carried: a
  /// resume's samples start from the checkpoint's mid-run cadence and must not
  /// be biased by the original session's (different exposure length, focuser,
  /// filter). It is fed from `ExposureCompleted` events either way, so no
  /// frame-counter seed is needed.
  void _startPerRunTimers() {
    final progressNotifier = _ref.read(sequenceProgressProvider.notifier);
    _startTime = DateTime.now();
    _isPaused = false;
    _eta.reset();

    // The ETA is projected from [EtaSmoother]'s EMA rather than from the
    // wall-clock tick, so a single slow download or fast-completing
    // calibration frame does not yank the estimate around.
    _progressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isPaused && _startTime != null) {
        final elapsed = DateTime.now()
            .difference(_startTime!)
            .inSeconds
            .toDouble();
        final progress = _ref.read(sequenceProgressProvider);
        final eta = _eta.remainingSeconds(
          completedFrames: progress.completedExposures,
          totalFrames: progress.totalExposures,
        );
        progressNotifier.updateProgress(
          elapsedSecs: elapsed,
          estimatedRemainingSecs: eta,
        );
      }
    });

    _startCheckpointTimer();
    _startDiskSpaceWatchdog();
  }

  /// Acquire every run resource and hand off to the native executor as one
  /// transaction. Each line here is a resource [_rollbackStart] knows how to
  /// release — keep the two in sync. Throws on the first failure; [start]
  /// funnels that into [_rollbackStart].
  Future<void> _acquireAndStartRun(
    Sequence sequence,
    AppSettingsState runSettings,
  ) async {
    // Before the editor is locked by the running-state flip below, so the
    // adopted database id lands on a document that still accepts it.
    sequence = await _ensureSequencePersisted(sequence);
    final progressNotifier = _ref.read(sequenceProgressProvider.notifier);
    // Clear the PREVIOUS run's progress before seeding this one's.
    //
    // `completedExposures` self-corrected because both writers assign the
    // event's absolute frame index, which masked the fact that nothing reset
    // this provider at run start. The accumulating fields did not self-correct:
    // measured on the live rig, two identical back-to-back runs of the same
    // 8.0 s sequence reported `completedIntegrationSecs` 8.0 then 16.0, while
    // both runs' own vitals and both `imaging_sessions` rows correctly said
    // 8.0. The per-node status/progress maps leaked the same way, leaving the
    // previous run's node badges on the canvas for a run that had not reached
    // those nodes yet.
    progressNotifier.reset();
    // The per-node frame tally is deliberately NOT cleared when a run ENDS:
    // clearing it there erases the frames the finished run captured before any
    // reader sees them. Run START is where the previous run's frames stop
    // being this node's story.
    _ref.read(nodeExposureTallyProvider.notifier).reset();
    progressNotifier.setTotals(
      sequence.totalExposures,
      sequence.totalIntegrationSecs,
    );
    progressNotifier.updateState(SequenceExecutionState.running);
    _ref.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.running;

    await _bindCatalogTargets(sequence);
    await _startSessionRow(sequence);
    // Persist the exact sequence JSON used for this run so the run-history
    // "diff vs previous run" view compares real snapshots rather than the
    // live (possibly since-edited) sequence.
    final snapshotJson = jsonEncode(
      _ref.read(sequenceFileServiceProvider).sequenceToMap(sequence),
    );
    await _openRunRecords(
      sequenceName: sequence.name,
      sequenceDatabaseId: sequence.databaseId,
      snapshotJson: snapshotJson,
    );

    // Session-lifecycle hooks.
    //
    // Done AFTER the session notifier + run row exist so the optical
    // train baseline snapshot has a stable dbSessionId to anchor to,
    // and the NotificationRouter override fires while the session is
    // already in "running" state. Each hook is independent — a failure
    // in one is logged but does not abort the start path. The Rust
    // executor must still start even if diagnostics are unavailable.
    _captureSessionStartHooks(sequence.id);

    _startPerRunTimers();

    // Always use backend/native sequencer engine to avoid divergent semantics.
    // This is the last acquisition step; it sets up the native event
    // subscription + settings watchers and issues sequencerStart(). A throw
    // anywhere in the transaction (including here) is rolled back by [start].
    await _startNativeExecution(sequence, runSettings);
  }

  /// Admissible starting states: idle, completed, failed (see
  /// [SequenceExecutionStateCapabilities.canStart]). A run may only start from
  /// a settled state — running / paused / stopping / recovering are rejected so
  /// a start can never overlap an in-flight or tearing-down run, and the
  /// retryable stopFailed / cleanupFailed states are rejected so a fresh run
  /// can never collide with live hardware or a dangling session.
  bool _isStartAdmissible(SequenceExecutionState state) => state.canStart;

  /// Reset all per-run finalization + stats-sealing state so a fresh run starts
  /// from a clean slate. Called at the top of every start / resume acquisition.
  void _resetFinalizationForNewRun() {
    _finalization = null;
    _finalizationFuture = null;
    _terminalCleanupFuture = null;
    _nativeLaunchAttempted = false;
    _statsSealed = false;
    _settledRunStatus = null;
    _pendingStatWrites.clear();
    // A fresh run has not terminated yet; clear any stale terminal result so the
    // sequencer screen observes a clean null -> result transition (and never
    // re-opens the previous run's report) when this run ends.
    _ref.read(sequenceTerminalRunResultProvider.notifier).state = null;
  }

  /// Release a SETTLED run's terminal latches for a native launch that does not
  /// come through [start] / [resumeFromCheckpoint].
  ///
  /// Those two call [_resetFinalizationForNewRun] as their first acquisition
  /// step. The headless appliance's canonical flow — `POST /api/sequencer/load`
  /// -> `POST /api/sequencer/start` — calls neither: it opens the session row
  /// itself and reaches this executor only through
  /// [attachHostListenersForNativeRun]. Without this release the first run of
  /// such a process finalizes normally and leaves [_settledRunStatus] set, and
  /// the "this run already settled" guard in [_onTerminalEvent] then refuses
  /// every later run's `Completed`: the second night runs, reaches `completed`
  /// on the wire and never finalizes — its `imaging_sessions` row stays open,
  /// no terminal result publishes, and so nothing integrates it and no draft is
  /// ever made.
  ///
  /// A RETAINED transaction is left alone. `stopFailed` / `cleanupFailed` keep
  /// their [RunFinalization] precisely so a retry — or a late authoritative
  /// terminal — resumes that exact transaction; discarding it here would strand
  /// a run whose hardware was never confirmed stopped.
  void _releaseSettledRunForNextNativeRun() {
    if (_finalization != null || _finalizationFuture != null) return;
    if (_settledRunStatus == null) return;
    _logger.info(
      'A new native run is starting on an executor whose previous run settled '
      'as "$_settledRunStatus"; releasing that run\'s terminal state so this '
      'one can finalize',
      source: 'SequenceExecutor',
    );
    _resetFinalizationForNewRun();
  }

  /// Single rollback path for a failed [start] / [resumeFromCheckpoint], routed
  /// through the SAME [_driveFinalization] transaction as a natural terminal and
  /// an explicit stop so their ordering and guarantees can never drift.
  ///
  /// Builds a rollback finalization: finalize any created run as `failed`
  /// (recording [startError]), end any created session as `failed`, clear the
  /// transient run/live ids, release a Smart Night / mosaic handoff and settle
  /// to a truthful `failed`. If the native launch was attempted the drive stops
  /// the (possibly partial) native launch exactly once BEFORE any teardown; if
  /// that stop cannot be confirmed it settles to a controllable `stopFailed`
  /// (identity + native subscription retained). If persistence fails it settles
  /// to the retryable `cleanupFailed` WITHOUT clearing run/session identity. In
  /// every case the drive's own error is swallowed here so [start] rethrows the
  /// ORIGINAL launch error while the truthful cleanup state is surfaced via the
  /// provider. Not called for a pure pre-acquisition validation rejection (no
  /// fake run/session).
  Future<void> _rollbackStart(Object startError, StackTrace startStack) async {
    _logger.error(
      'Sequence start failed; rolling back partial acquisition: $startError\n'
      '$startStack',
      source: 'SequenceExecutor',
    );

    // Record the launch error onto the run stats (if a run row exists) so the
    // failed run row + report carry the cause. Done before the drive seals the
    // stats for the final finishRun write.
    try {
      _recordRunError('Failed to start sequence execution: $startError');
    } catch (_) {
      // Absent live stats (failure before the run row existed) — nothing to
      // record; the drive's finalizeRun is a no-op in that case anyway.
    }

    final f = RunFinalization(
      generation: ++_finalizationGeneration,
      runStatus: 'failed',
      finalUiState: SequenceExecutionState.failed,
      runId: _ref.read(currentRunIdProvider),
      dbSessionId: _ref.read(sessionStateProvider).dbSessionId,
      preserveCheckpoint: false,
      // A throw at/after sequencerStart() may mean a partial native launch; a
      // throw before it (validation / session-row / loadJson) leaves the flag
      // false so the drive skips the native stop entirely and settles cleanly.
      nativeStopRequired: _nativeLaunchAttempted,
      nativeStopConfirmed: false,
      // A rejected launch opens no Session Report.
      publishTerminalResult: false,
      discardCheckpointOnSuccess: false,
      isRollback: true,
      originalError: startError,
      originalStack: startStack,
      // A rollback's native stop is nobody's press: without this, the
      // executor records 'Operator: stop' for a launch that failed on its
      // own — at 2 a.m. under the autopilot, with nobody at the keyboard.
      stopOrigin: 'rollback',
    );
    _nativeLaunchAttempted = false;
    _finalization = f;
    try {
      await _launchDrive(f);
    } catch (_) {
      // The truthful stopFailed / cleanupFailed / failed state is already
      // published inside the drive. Swallow so [start] rethrows the ORIGINAL
      // launch error, not the secondary cleanup error.
    }
  }

  /// Release a Smart Night / mosaic editor handoff, restoring the operator's
  /// stashed manual sequence (and its dirty flag). Idempotent and guarded:
  ///
  ///  * Only fires for Smart Night / mosaic owners. Autopilot is deliberately
  ///    left alone — SchedulerEngine owns the autopilot lifecycle and
  ///    re-dispatches on SequenceCompleted, so releasing here would race and
  ///    destroy a freshly dispatched target (contract E). Manual is a no-op
  ///    (releaseOwnership itself early-returns for the manual owner).
  ///  * A throw during provider teardown is swallowed so it can never prevent
  ///    session / native cleanup from finishing.
  void _releaseAutomatedEditorOwnership() {
    try {
      // Inferred notifier type (CurrentSequenceNotifier) — deliberately NOT a
      // direct `import 'sequence_editor.dart'`, which created a
      // sequence_executor <-> sequence_editor import cycle. The notifier type
      // is reachable through currentSequenceProvider's generic, so inference
      // resolves activeOwner / releaseOwnership without the cyclic import.
      final notifier = _ref.read(currentSequenceProvider.notifier);
      final owner = notifier.activeOwner;
      if (owner == ActivePlanOwner.smartNight ||
          owner == ActivePlanOwner.mosaic) {
        notifier.releaseOwnership();
      }
    } catch (e) {
      _logger.warning(
        'Failed to release automated editor ownership: $e',
        source: 'SequenceExecutor',
      );
    }
  }

  /// Handle a natural terminal event (Completed / Failed / Stopped and their
  /// aliases) — or an authoritative native terminal confirming an explicit
  /// stop — exactly once.
  ///
  /// Enters the nonterminal busy `finalizing` state SYNCHRONOUSLY (before the
  /// first await) so the executor never advertises a settled completed / failed
  /// / idle while durable cleanup is still running: a rapid Start is rejected,
  /// and an old cleanup can never clobber a new run's identity. The settled UI
  /// state + the one-shot terminal result are published only AFTER cleanup
  /// succeeds, inside [_driveFinalization].
  void _onTerminalEvent(
    SequenceExecutionState uiState,
    String runStatus, {
    String? error,
    String? warning,
  }) {
    final state = _ref.read(sequenceExecutionStateProvider);

    // Confirmation path: an explicit stop (including a retry after stopFailed)
    // retains its resources until an authoritative terminal event proves the
    // native exposure abort has completed. The stop API returning only confirms
    // that the command was accepted; it is not the release boundary.
    final pending = _finalization;
    if (pending != null &&
        pending.nativeStopRequired &&
        !pending.nativeStopConfirmed) {
      pending.nativeStopConfirmed = true;
      final confirmation = pending.nativeStopConfirmation;
      if (confirmation != null && !confirmation.isCompleted) {
        confirmation.complete();
      }
      if (error != null) _recordTerminalRunError(error);

      // A terminal arriving while the original drive is waiting wakes that
      // drive above. If the command call had already failed, resume the same
      // retained transaction without issuing a second stop.
      if (state == SequenceExecutionState.stopFailed &&
          _finalizationFuture == null) {
        _setExecutionState(SequenceExecutionState.finalizing);
        _terminalCleanupFuture = _launchDrive(pending);
        _swallowSpawnedFinalizationError(_terminalCleanupFuture!);
      }
      return;
    }

    // Compatibility path for a retained stop whose command failed before this
    // confirmation gate was created.
    if (state == SequenceExecutionState.stopFailed && pending != null) {
      final f = _finalization!;
      f.nativeStopConfirmed = true;
      if (error != null) _recordTerminalRunError(error);
      _setExecutionState(SequenceExecutionState.finalizing);
      _terminalCleanupFuture = _launchDrive(f);
      _swallowSpawnedFinalizationError(_terminalCleanupFuture!);
      return;
    }

    // Exactly-once: any already-claimed finalization (in-flight, succeeded, or
    // awaiting a persistence retry) swallows duplicate / aliased / echo terminal
    // events — including the `Stopped` echo emitted by a SUCCESSFUL explicit
    // stop, whose finalization context is still set.
    if (_finalization != null || _finalizationFuture != null) return;

    // Exactly-once, part two: this run's verdict has already been published and
    // its finalization dropped. A terminal arriving now is the SAME run's second
    // wire event (a stop-cancelled Slew produces both `Stopped` and
    // `SequenceFailed`), and re-finalizing would republish the operator's Stop
    // as a failure. Logged with the shared stop-classification tag so a live log
    // says which producer refused it.
    final settled = _settledRunStatus;
    if (settled != null) {
      _logger.info(
        '[$kStopClassificationLogTag] sequence_executor: late "$runStatus" '
        'terminal ignored — this run already settled as "$settled"'
        '${error == null ? '' : ' (reason: $error)'}',
        source: 'SequenceExecutor',
      );
      return;
    }

    if (warning != null) {
      // The durable cause line ("Parked by the Dawn Approaching trigger") —
      // carried in warningMessages so the Session Report and History detail
      // say WHY the run ended, not just that it did. Recorded here, past
      // every duplicate/echo guard, so a swallowed terminal can never stamp
      // a foreign cause onto a run it did not end.
      _incrementRunStat((stats) => stats.recordWarning(warning));
    }

    if (error != null) {
      _recordTerminalRunError(error);
      _ref
          .read(sequenceProgressProvider.notifier)
          .updateProgress(message: error);
    }

    // Enter the busy finalization phase synchronously, then drive cleanup. The
    // hardware already terminated authoritatively, so no native stop is issued.
    _setExecutionState(SequenceExecutionState.finalizing);
    final f = RunFinalization(
      generation: ++_finalizationGeneration,
      runStatus: runStatus,
      finalUiState: uiState,
      runId: _ref.read(currentRunIdProvider),
      dbSessionId: _ref.read(sessionStateProvider).dbSessionId,
      preserveCheckpoint: false,
      nativeStopRequired: false,
      nativeStopConfirmed: true,
      publishTerminalResult: true,
      discardCheckpointOnSuccess: false,
      isRollback: false,
    );
    _finalization = f;
    _terminalCleanupFuture = _launchDrive(f);
    _swallowSpawnedFinalizationError(_terminalCleanupFuture!);
  }

  /// Attach a no-op error handler to a spawned (un-awaited) finalization drive
  /// so a cleanup that settles to the retryable `cleanupFailed` state does not
  /// surface as an unhandled async error. The truthful state is already
  /// published; tests await [terminalCleanupSettledForTest] and assert on it.
  void _swallowSpawnedFinalizationError(Future<void> future) {
    unawaited(future.catchError((Object _) {}));
  }

  /// Confirm the native executor has actually terminated, from EITHER the
  /// pushed terminal event or its own reported status. See
  /// [NativeStopConfirmer], which owns the bounded wait and the poll fallback.
  Future<void> _awaitNativeStopConfirmation(
    RunFinalization f,
    Completer<void> confirmation,
  ) {
    final confirmer = NativeStopConfirmer(
      readNativeState: () async => (await _backend.sequencerGetStatus()).state,
      logInfo: (message) => _logger.info(message, source: 'SequenceExecutor'),
      logDebug: (message) => _logger.debug(message, source: 'SequenceExecutor'),
    );
    return confirmer.awaitTermination(f, confirmation);
  }

  /// Launch (or relaunch, for a Stop retry) the finalization drive, tracking it
  /// as the in-flight future that racing callers join, and clearing that latch
  /// when it settles so a later Stop retry from stopFailed / cleanupFailed can
  /// re-drive the retained [_finalization].
  Future<void> _launchDrive(RunFinalization f) {
    late final Future<void> wrapped;
    wrapped = _driveFinalization(f).whenComplete(() {
      if (identical(_finalizationFuture, wrapped)) _finalizationFuture = null;
    });
    _finalizationFuture = wrapped;
    return wrapped;
  }

  /// The ONE per-run finalization transaction shared by natural terminals,
  /// explicit stops and start/resume rollbacks. Idempotent and resumable: a Stop
  /// retry from stopFailed / cleanupFailed re-enters here and skips every gate
  /// whose progress flag is already set, so a confirmed native stop, a persisted
  /// finishRun, and the once-only post-run hooks never repeat.
  ///
  /// Required order (contract):
  ///   1. confirm hardware termination (a natural terminal is authoritative and
  ///      NEVER calls sequencerStop; an explicit stop / partial-launch rollback
  ///      call it exactly once);
  ///   2. release per-run timers / watchdog / settings watchers / native
  ///      subscription / live-stacking (once, idempotent);
  ///   3. drain pending live-stat writes, then finishRun, then the once-only
  ///      post-run hooks;
  ///   4. end the durable session (only after finishRun succeeds);
  ///   5. clear run/live identity, release the correct editor ownership, handle
  ///      the checkpoint per the captured policy;
  ///   6. publish one terminal result, then the settled UI state.
  ///
  /// Throws on a native-stop failure (-> stopFailed) or a persistence failure
  /// (-> cleanupFailed) so an awaiting explicit-stop / reset caller sees the
  /// error; the natural-terminal and rollback spawns swallow it (the truthful
  /// state is already published).
  Future<void> _driveFinalization(RunFinalization f) async {
    void secondary(String step, Object e) => _logger.warning(
      'Finalization: $step failed: $e',
      source: 'SequenceExecutor',
    );

    // 1. Hardware termination.
    if (f.nativeStopRequired && !f.nativeStopConfirmed) {
      final confirmation = f.nativeStopConfirmation ??= Completer<void>();
      try {
        await _backend.sequencerStop(origin: f.stopOrigin);
        // BOUNDED wait for the authoritative terminal. The stop command
        // returning only means it was accepted; tearing down while the camera
        // may still be exposing is what this gate prevents. The bound is
        // required because the terminal can legitimately never arrive: the
        // native event channel is a `tokio::sync::broadcast` whose receiver
        // handles `RecvError::Lagged` by SKIPPING events
        // (bridge/src/api/sequencer.rs), and the headless
        // `POST /api/sequencer/load` -> `/api/sequencer/start` path starts on
        // the native executor without ever calling [start], so this executor
        // installs no `_nativeEventSubscription` at all.
        //
        // Confirmation therefore accepts EITHER authoritative source: the
        // pushed terminal event, or the native executor's own reported state.
        // The status poll is the same executor answering "are you still
        // running?", pulled instead of pushed — not a weaker guess.
        //
        // On expiry, fall through to the same handling as a stop command that
        // failed: settle to the controllable `stopFailed` (Stop re-enabled for
        // a retry, Start blocked, checkpoint kept) with the native
        // subscription still live, so a late terminal resumes THIS
        // finalization through `_onTerminalEvent`. Nothing is torn down on a
        // guess.
        await _awaitNativeStopConfirmation(f, confirmation);
      } catch (e, st) {
        // The authoritative terminal may race a transport-level error from the
        // command call. Once native has confirmed termination, cleanup is safe
        // and the command-path error is secondary.
        if (f.nativeStopConfirmed) {
          secondary('stop command after native confirmation', e);
        } else {
          // NATIVE STOP FAILED. The hardware was NOT confirmed stopped and may
          // still be imaging. Do NOT tear down / finalize / clear / release. Keep
          // the native subscription ALIVE so a later authoritative native terminal
          // event can confirm termination and resume THIS finalization. Expose a
          // controllable stopFailed (Stop re-enabled for a retry, Start blocked);
          // the checkpoint is deliberately NOT discarded.
          _logger.error(
            'Finalization: sequencerStop() could not confirm the native executor '
            'stopped; retaining a controllable stopFailed state: $e\n$st',
            source: 'SequenceExecutor',
          );
          _setExecutionState(SequenceExecutionState.stopFailed);
          Error.throwWithStackTrace(e, st);
        }
      }
    }

    // 2. Release per-run resources (once, idempotent).
    if (!f.resourcesReleased) {
      await _releaseRunResources(secondary);
      f.resourcesReleased = true;
    }

    // 3. Persistence: drain live-stat writes + finishRun + hooks.
    // _finalizeRun seals the stats, drains in-flight incremental writes, does
    // the final finishRun write and fires the once-only session-end hooks. It
    // early-returns once _runFinalized is set, so a retry never repeats the
    // finish or the hooks; the session-end hooks read SessionState.dbSessionId,
    // so it runs BEFORE endSession clears it.
    try {
      await _finalizeRun(f.runStatus);
    } catch (e, st) {
      // finishRun FAILED. Do NOT endSession, clear ids, release ownership,
      // discard the checkpoint, or claim terminal. Retain a retryable
      // cleanupFailed with enough context (the retained _finalization) to
      // re-run.
      secondary('finalize run', e);
      _setExecutionState(SequenceExecutionState.cleanupFailed);
      Error.throwWithStackTrace(e, st);
    }

    // 4. End the durable session (only after finishRun succeeded).
    try {
      await _ref
          .read(sessionStateProvider.notifier)
          .endSession(status: f.runStatus);
    } catch (e, st) {
      // endSession FAILED after a successful finishRun. Retain a retryable
      // cleanupFailed; a Stop retry re-runs ONLY endSession + the later steps
      // (finishRun and the hooks are already latched by _runFinalized, and the
      // native stop is already confirmed).
      secondary('end session', e);
      _setExecutionState(SequenceExecutionState.cleanupFailed);
      Error.throwWithStackTrace(e, st);
    }

    // 5. Clear identity, release ownership, handle the checkpoint.
    try {
      _ref.read(currentRunIdProvider.notifier).state = null;
    } catch (e) {
      secondary('clear run id', e);
    }
    if (f.isRollback) {
      // A rejected launch clears its transient live stats (there is no run to
      // keep vitals for). A natural terminal / explicit stop deliberately KEEPS
      // the live stats so the post-run notes prompt can pre-fill from them.
      try {
        _ref.read(liveSequenceStatsProvider.notifier).state = null;
      } catch (e) {
        secondary('clear live stats', e);
      }
    }
    // Release a Smart Night / mosaic editor handoff (never autopilot — see
    // [_releaseAutomatedEditorOwnership]).
    _releaseAutomatedEditorOwnership();
    if (f.discardCheckpointOnSuccess) {
      // Discard the checkpoint ONLY on a clean, fully-successful stop; discarding
      // after a failed stop / failed cleanup would destroy a live run's resume
      // point.
      try {
        await _backend.discardCheckpoint();
      } catch (e) {
        secondary('discard checkpoint', e);
      }
    } else if (f.preserveCheckpoint) {
      _logger.info(
        'Stop with preserveCheckpoint=true: leaving checkpoint on disk so the '
        'user can resume later',
        source: 'SequenceExecutor',
      );
    }

    // Remember HOW this run ended, for the autopilot's reconcile: an
    // explicit stop carries its commander's origin ('operator' when the
    // stop() caller passed none); a natural 'stopped' terminal that no
    // stop() commanded is a native-side safety abort. The distinction is
    // what keeps a weather abort from pausing the autopilot as if a human
    // had asked it to stand down.
    if (f.nativeStopRequired) {
      _lastRunEndOrigin = f.stopOrigin ?? 'operator';
    } else if (f.runStatus == 'stopped' ||
        f.runStatus == 'paused-stopped' ||
        f.runStatus == 'aborted') {
      _lastRunEndOrigin = 'safety';
    } else {
      _lastRunEndOrigin = null;
    }

    // The run is over: clear the native run-id stamp so a decision emitted
    // BETWEEN runs (an idle Pause press, a runtime-config change) is not
    // written into the finished run's replay timeline. Cleared BEFORE the
    // terminal UI state publishes: once the state reads idle a new start is
    // legal, and this clear must not race the new run's own stamp.
    try {
      await _backend.sequencerSetActiveSequenceRunId(null);
    } catch (e) {
      secondary('clear active run id', e);
    }

    // 6. Publish one terminal result, THEN the settled UI state.
    if (f.publishTerminalResult) {
      _publishTerminalResult(f);
    }
    _setExecutionState(f.finalUiState);
    // This run now HAS a verdict. Any terminal that arrives from here on is a
    // second event for a run that is over, not a new outcome (see
    // [_settledRunStatus]).
    _settledRunStatus = f.runStatus;

    // Transaction complete — drop the context so the next run starts clean and a
    // stray late event cannot resume a finished finalization.
    if (identical(_finalization, f)) _finalization = null;
  }

  /// Release every per-run resource: timers, disk watchdog, settings watchers,
  /// the native event subscription, ETA state, and live-stacking. Each step is
  /// guarded so one failure never blocks a later one; all are idempotent, so a
  /// retry that re-enters before [RunFinalization.resourcesReleased] is set is
  /// safe.
  Future<void> _releaseRunResources(
    void Function(String, Object) secondary,
  ) async {
    try {
      _resetRunTimers();
    } catch (e) {
      secondary('reset run timers', e);
    }
    try {
      _stopDiskSpaceWatchdog();
    } catch (e) {
      secondary('stop disk watchdog', e);
    }
    try {
      _stopSettingsWatchers();
    } catch (e) {
      secondary('stop settings watchers', e);
    }
    try {
      _eta.reset();
    } catch (e) {
      secondary('reset eta state', e);
    }
    // Detach the reference BEFORE cancelling so no further event dispatches;
    // when called from inside the native event callback (a natural terminal),
    // Dart allows cancelling the subscription from within its own handler.
    final subscription = _nativeEventSubscription;
    _nativeEventSubscription = null;
    if (subscription != null) {
      try {
        await subscription.cancel();
      } catch (e) {
        secondary('cancel native subscription', e);
      }
    }
    try {
      await _teardownLiveStacking();
    } catch (e) {
      secondary('teardown live stacking', e);
    }
  }

  /// Publish the one-shot immutable terminal-run result carrying the finished
  /// run's snapshot ids, so the sequencer screen opens the Session Report and
  /// its run-scoped Journal against the completed run rather than racing the
  /// live providers finalization has just cleared.
  void _publishTerminalResult(RunFinalization f) {
    try {
      _ref
          .read(sequenceTerminalRunResultProvider.notifier)
          .state = SequenceTerminalRunResult(
        generation: f.generation,
        outcome: f.finalUiState,
        runStatus: f.runStatus,
        runId: f.runId,
        dbSessionId: f.dbSessionId,
      );
    } catch (e) {
      _logger.warning(
        'Failed to publish terminal run result: $e',
        source: 'SequenceExecutor',
      );
    }
  }

  /// Wait for [sequenceExecutionStateProvider] to reach [expectedState],
  /// resolving the instant the matching event pump updates the provider
  /// rather than on a 100 ms polling tick.
  ///
  /// Registers a one-shot `ref.listen` on the state provider and completes the
  /// moment the provider transitions into [expectedState], racing [timeout].
  /// Returns `true` if the state was observed, `false` on timeout. Resolving on
  /// the event rather than a poll tick is what keeps a pause from feeling dead
  /// and keeps a fallback status query off the fast path.
  Future<bool> _awaitStateChange(
    SequenceExecutionState expectedState, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // Already there — no need to wait.
    if (_ref.read(sequenceExecutionStateProvider) == expectedState) {
      return true;
    }

    final completer = Completer<bool>();
    final subscription = _ref.listen<SequenceExecutionState>(
      sequenceExecutionStateProvider,
      (_, next) {
        if (next == expectedState && !completer.isCompleted) {
          completer.complete(true);
        }
      },
    );
    Timer? timeoutTimer;
    timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    });

    try {
      return await completer.future;
    } finally {
      timeoutTimer.cancel();
      subscription.close();
    }
  }

  Future<void> pause() async {
    _ensureBackendAuthority();
    if (_pauseResumeInProgress) {
      throw Exception('Pause/Resume operation already in progress');
    }

    final currentState = _ref.read(sequenceExecutionStateProvider);
    if (currentState != SequenceExecutionState.running) {
      throw Exception('Cannot pause: sequence is not running');
    }

    _pauseResumeInProgress = true;

    try {
      final backend = _backend;
      await backend.sequencerPause();

      final confirmed = await _awaitStateChange(SequenceExecutionState.paused);
      if (!confirmed) {
        final status = await backend.sequencerGetStatus();
        if (status.state.toLowerCase() != 'paused') {
          throw Exception('Pause operation timed out - state not confirmed');
        }
        _ref
            .read(sequenceProgressProvider.notifier)
            .updateState(SequenceExecutionState.paused);
        _ref.read(sequenceExecutionStateProvider.notifier).state =
            SequenceExecutionState.paused;
      }

      _isPaused = true;
      await _persistLiveRunStatus('paused');
    } finally {
      _pauseResumeInProgress = false;
    }
  }

  Future<void> resume() async {
    _ensureBackendAuthority();
    if (_pauseResumeInProgress) {
      throw Exception('Pause/Resume operation already in progress');
    }

    final currentState = _ref.read(sequenceExecutionStateProvider);
    if (currentState != SequenceExecutionState.paused) {
      throw Exception('Cannot resume: sequence is not paused');
    }

    _pauseResumeInProgress = true;

    try {
      final backend = _backend;
      await backend.sequencerResume();

      final confirmed = await _awaitStateChange(SequenceExecutionState.running);
      if (!confirmed) {
        final status = await backend.sequencerGetStatus();
        if (status.state.toLowerCase() != 'running') {
          throw Exception('Resume operation timed out - state not confirmed');
        }
        _ref
            .read(sequenceProgressProvider.notifier)
            .updateState(SequenceExecutionState.running);
        _ref.read(sequenceExecutionStateProvider.notifier).state =
            SequenceExecutionState.running;
      }

      _isPaused = false;
      await _persistLiveRunStatus('running');
    } finally {
      _pauseResumeInProgress = false;
    }
  }

  /// Publish the run's live state onto its `sequence_runs` row.
  ///
  /// The GUI knew the run was paused; the database did not, and the headless
  /// API, the web dashboard and the phone all read the database. Failure is
  /// logged and swallowed: a pause that succeeded on the hardware must not be
  /// reported as failed because a row could not be updated.
  Future<void> _persistLiveRunStatus(String status) async {
    final runId = _ref.read(currentRunIdProvider);
    if (runId == null) return;
    try {
      await _ref.read(sequenceRunsDaoProvider).setLiveStatus(runId, status);
    } catch (e) {
      _logger.warning(
        'Could not persist run $runId status "$status": $e',
        source: 'SequenceExecutor',
      );
    }
  }

  /// Stop the sequencer.
  ///
  /// The caller declares checkpoint intent via [preserveCheckpoint]:
  ///   * `true` for an operator Stop (`SequenceActionService.stop`) — the
  ///     resume point survives and the session row is finalised as
  ///     `paused-stopped`;
  ///   * `false` (the default) for the internal completion / error /
  ///     cancellation finalisers, so a naturally-ended run leaves no stale
  ///     checkpoint for the next "resume?" prompt to mistake for an
  ///     interrupted session.
  ///
  /// The default is destructive, so a bare `stop()` is a deliberate hard stop
  /// (e.g. [reset]).

  /// How the most recently settled run ended: 'operator' / 'scheduler' /
  /// 'rollback' / 'safety' (native-side abort with no stop() commander) /
  /// null (completed, failed, or nothing settled yet).
  String? get lastRunEndOrigin => _lastRunEndOrigin;
  String? _lastRunEndOrigin;

  Future<void> stop({bool preserveCheckpoint = false, String? origin}) {
    _ensureBackendAuthority();
    // Join an in-flight finalization — a natural terminal, another stop(), or a
    // rollback: the caller observes the SAME outcome, and native stop + cleanup
    // happen exactly once. The first caller's terminal intent wins (a stop that
    // lands on an already-completing natural terminal does NOT override it).
    final inFlight = _finalizationFuture;
    if (inFlight != null) return inFlight;

    final state = _ref.read(sequenceExecutionStateProvider);
    // Idle-stop guard: nothing to stop from a settled, non-active state (idle /
    // completed / failed / finalizing). Returning a completed future keeps
    // stop() a safe no-op instead of flashing a state and commanding a native
    // stop against an executor that is not running.
    if (!state.canStop) return Future<void>.value();

    // Retry path: a retained finalization is awaiting a Stop retry. Re-drive it
    // WITHOUT rebuilding intent (its first-claimed terminal status/UI wins).
    // From `cleanupFailed` the native stop is already confirmed so the drive
    // skips it (pure persistence retry -> show `finalizing`); from `stopFailed`
    // the drive retries the native stop (-> show `stopping`).
    if (_finalization != null &&
        (state == SequenceExecutionState.stopFailed ||
            state == SequenceExecutionState.cleanupFailed)) {
      final f = _finalization!;
      // The retry keeps the retained intent — EXCEPT the origin, which
      // upgrades toward the operator: a human re-driving an autopilot's
      // failed stop has genuinely commanded a stop, and that press must be
      // recorded ("only a stop you command yourself is always recorded").
      // The reverse never downgrades: once an operator pressed, the episode
      // stays theirs whoever retries it. Scope: the upgrade reaches the
      // native record only on the stopFailed half (the drive re-issues the
      // native stop there); a cleanupFailed retry is a pure persistence
      // re-drive — no native stop is sent, so the press advances the
      // recovery but adds no decision row.
      if (origin == null || origin == 'operator') {
        f.stopOrigin = origin;
      }
      _setExecutionState(
        f.nativeStopConfirmed
            ? SequenceExecutionState.finalizing
            : SequenceExecutionState.stopping,
      );
      return _launchDrive(f);
    }

    // Fresh explicit stop from a live state (running / paused / recovering).
    // Command the native executor to stop FIRST (inside the drive), before any
    // teardown or persistence.
    final f = RunFinalization(
      generation: ++_finalizationGeneration,
      runStatus: preserveCheckpoint ? 'paused-stopped' : 'stopped',
      finalUiState: SequenceExecutionState.idle,
      runId: _ref.read(currentRunIdProvider),
      dbSessionId: _ref.read(sessionStateProvider).dbSessionId,
      preserveCheckpoint: preserveCheckpoint,
      nativeStopRequired: true,
      nativeStopConfirmed: false,
      publishTerminalResult: true,
      discardCheckpointOnSuccess: !preserveCheckpoint,
      isRollback: false,
      stopOrigin: origin,
    );
    _finalization = f;
    // Enter `stopping` synchronously (before the first await) so the UI is
    // truthful the instant Stop is pressed: not idle until the hardware has
    // actually been commanded to stop.
    _setExecutionState(SequenceExecutionState.stopping);
    return _launchDrive(f);
  }

  /// Publish [state] to both the progress notifier and the execution-state
  /// provider in lockstep. Every lifecycle transition must move the two
  /// together; a surface that reads one and not the other must never observe a
  /// split state.
  void _setExecutionState(SequenceExecutionState state) {
    _ref.read(sequenceProgressProvider.notifier).updateState(state);
    _ref.read(sequenceExecutionStateProvider.notifier).state = state;
  }

  Future<void> skip() async {
    _ensureBackendAuthority();
    final backend = _backend;
    await backend.sequencerSkip();
  }

  /// Jump to a specific node by id. Use from the sequence
  /// tree right-click context menu ("Skip to here"). Only meaningful while
  /// the sequence is running — the UI must gate the action on
  /// [SequenceExecutionState.running].
  Future<void> skipToNode(String nodeId) async {
    _ensureBackendAuthority();
    final backend = _backend;
    await backend.sequencerSkipToNode(nodeId);
  }

  /// Abandon the rest of the current target and advance to the next one.
  ///
  /// "Skip target" on the run dashboard: stop spending the night on the
  /// target currently imaging (it clouded over, drifted behind a tree, the
  /// user changed their mind) and jump straight to the next
  /// [TargetHeaderNode] in the sequence. Any remaining nodes inside the
  /// current target's subtree — further exposures, dithers, autofocus, the
  /// post-target waits — are skipped; execution resumes at the top of the
  /// next target.
  ///
  /// Only meaningful while [SequenceExecutionState.running] or
  /// [SequenceExecutionState.paused]; the UI must gate the action on those
  /// states. Throws [StateError] otherwise so the caller can surface a
  /// snackbar, matching the contract the native skip-to-node primitive
  /// already enforces.
  ///
  /// Implementation: the native executor has no dedicated skip-to-target
  /// primitive, so this is built on top of [sequencerSkipToNode]. We resolve
  /// the next target header in canonical (`orderIndex`) order from the
  /// in-memory sequence, then issue a single jump to that header's node id.
  /// The Rust side's `next_jump_target` walk fast-forwards through every
  /// instruction between here and the target header — i.e. the whole
  /// remainder of the current target's subtree — exactly as a manual
  /// "skip to here" on the next target would, so no per-node skip storm is
  /// needed. When there is no next target the run is finished cleanly via
  /// [stop] (graceful, checkpoint discarded), which drives the dashboard to
  /// idle the same way a natural end-of-sequence does.
  ///
  /// Returns the [TargetHeaderNode.id] we jumped to, or `null` when there was
  /// no next target and the run was finished instead.
  Future<String?> skipToTarget() async {
    _ensureBackendAuthority();
    final state = _ref.read(sequenceExecutionStateProvider);
    if (state != SequenceExecutionState.running &&
        state != SequenceExecutionState.paused) {
      throw StateError(
        'skipToTarget requires the sequence to be running or paused '
        '(current state: ${state.name})',
      );
    }

    final sequence = _ref.read(currentSequenceProvider);
    if (sequence == null) {
      throw StateError('skipToTarget called with no sequence loaded');
    }

    // Canonical target order — the same `orderIndex`-sorted view the run
    // dashboard renders, so "next" means what the operator sees.
    final targets = sequence.targetHeaders;
    if (targets.isEmpty) {
      throw StateError('skipToTarget called on a sequence with no targets');
    }

    // Identify which target is executing. The progress feed reports the
    // active leaf node; walk up to its owning header. If we can't pin the
    // current node to a header (e.g. the run hasn't reached any target's
    // subtree yet, or it's sitting on a pre-target setup node), treat the
    // first target as current so "skip" advances to the second.
    final currentNodeId = _ref.read(sequenceProgressProvider).currentNodeId;
    final currentTargetId = currentNodeId == null
        ? targets.first.id
        : (_owningTargetHeaderId(sequence, currentNodeId) ?? targets.first.id);

    final currentIndex = targets.indexWhere((t) => t.id == currentTargetId);
    final nextIndex = currentIndex < 0 ? 0 : currentIndex + 1;

    if (nextIndex >= targets.length) {
      // Last target — nothing left to advance to. Finish the run cleanly so
      // the dashboard returns to idle exactly as it would at a natural end.
      _logger.info(
        'skipToTarget: no target after "$currentTargetId"; finishing run',
        source: 'SequenceExecutor',
      );
      await stop();
      return null;
    }

    final nextTarget = targets[nextIndex];
    _logger.info(
      'skipToTarget: advancing from "$currentTargetId" to '
      '"${nextTarget.id}" (${nextTarget.targetName})',
      source: 'SequenceExecutor',
    );
    final backend = _backend;
    await backend.sequencerSkipToNode(nextTarget.id);
    return nextTarget.id;
  }

  /// Walk up the tree from [nodeId] to the [TargetHeaderNode] that owns it,
  /// returning that header's id (or [nodeId] itself when it *is* a header).
  /// Returns `null` when [nodeId] has no target-header ancestor — e.g. a
  /// pre-target setup node living at the sequence root.
  ///
  /// Bounded by `nodes.length` so a corrupted (cyclic) import can't loop
  /// forever; the [Sequence] invariants guarantee acyclicity in practice.
  String? _owningTargetHeaderId(Sequence sequence, String nodeId) {
    var cursor = sequence.getNode(nodeId);
    var hops = 0;
    while (cursor != null) {
      if (cursor is TargetHeaderNode) return cursor.id;
      if (++hops > sequence.nodes.length) break;
      final parentId = sequence.parentOf(cursor.id);
      cursor = parentId == null ? null : sequence.getNode(parentId);
    }
    return null;
  }

  /// Reset the sequence execution state without modifying the sequence
  /// configuration. Clears all execution progress (completed exposures, node
  /// statuses) while preserving the sequence structure.
  Future<void> reset() async {
    _ensureBackendAuthority();
    // If a finalization is mid-flight (`finalizing` after a natural terminal, or
    // an explicit stop still tearing down), let it settle first so reset() never
    // clobbers run/session identity or races the teardown. A cleanup that
    // settles to stopFailed / cleanupFailed is handled by the canStop retry
    // below; its thrown error was already surfaced via the state, so we swallow
    // it here.
    final inFlight = _finalizationFuture;
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (e) {
        _logger.debug(
          'Reset observed the already-surfaced finalization failure: $e',
          source: 'SequenceExecutor',
        );
      }
    }
    final currentState = _ref.read(sequenceExecutionStateProvider);

    // A live run — or one whose stop / persistence cleanup has not finished
    // (stopFailed / cleanupFailed) — must be genuinely stopped before we reset.
    // Await the canonical stop(): if the native stop or its cleanup fails it
    // throws (leaving the truthful stopFailed / cleanupFailed state) and we do
    // NOT continue to force idle — the hardware may still be imaging or the
    // session record is incomplete, so a resettable idle would be a lie.
    if (currentState.canStop) {
      await stop();
    }

    _ref.read(sequenceProgressProvider.notifier).reset();
    _ref.read(nodeExposureTallyProvider.notifier).reset();

    final backend = _backend;
    try {
      await backend.sequencerReset();
    } catch (e) {
      _logger.warning(
        'Error resetting native sequencer: $e',
        source: 'SequenceExecutor',
      );
      // The Dart-side reset above is the authoritative source of truth.
    }

    try {
      await backend.discardCheckpoint();
    } catch (e) {
      _logger.warning(
        'Error clearing checkpoint on reset: $e',
        source: 'SequenceExecutor',
      );
    }

    _setExecutionState(SequenceExecutionState.idle);

    _logger.info(
      'Sequence reset - ready to run from beginning',
      source: 'SequenceExecutor',
    );
  }

  // Checkpoint / crash recovery.

  /// Initialize checkpoint system with app's documents directory
  Future<void> initializeCheckpoints(String documentsPath) async {
    _ensureBackendAuthority();
    final backend = _backend;
    await backend.sequencerSetCheckpointDir(documentsPath);
  }

  /// Check if there's a checkpoint available to resume
  Future<bool> hasCheckpoint() async {
    _ensureBackendAuthority();
    final backend = _backend;
    return await backend.hasCheckpoint();
  }

  /// Get information about the current checkpoint
  Future<CheckpointInfo?> getCheckpointInfo() async {
    _ensureBackendAuthority();
    final backend = _backend;
    return await backend.getCheckpointInfo();
  }

  /// Resume sequence from checkpoint
  ///
  /// The native `resumeFromCheckpoint()` only PREPARES the executor: it
  /// loads the checkpointed sequence, marks already-completed nodes, and
  /// restores trigger state / devices / save path / location from the
  /// snapshot. Execution only begins on the subsequent `sequencerStart()`,
  /// which walks the restored tree and short-circuits the marked nodes.
  /// Skipping that start call leaves the executor Idle while the UI says
  /// "running" — a resumed night that silently never images.
  Future<void> resumeFromCheckpoint() async {
    _ensureBackendAuthority();
    // Same start serialization + admissible-state gate as [start]: a resume is
    // a form of start, so it must not overlap an in-flight start/resume or a
    // running/paused/stopping/recovering executor.
    final admissionState = _ref.read(sequenceExecutionStateProvider);
    if (_startInFlight || !_isStartAdmissible(admissionState)) {
      throw StateError(
        'Cannot resume: a sequence start is already in flight or the executor '
        'is not in an admissible state (state: ${admissionState.name}).',
      );
    }
    _startInFlight = true;
    _ref.read(sequenceLaunchInFlightProvider.notifier).state = true;
    try {
      await _resumeFromCheckpointInner();
    } finally {
      _startInFlight = false;
      _ref.read(sequenceLaunchInFlightProvider.notifier).state = false;
    }
  }

  /// Rehydrate [currentSequenceProvider] for a resumed run from the snapshot
  /// the interrupted run stored, and return that snapshot so the resumed run
  /// records one too.
  ///
  /// Returns null — leaving the executor in the previous "no Dart sequence"
  /// behaviour — when nothing can be recovered: no matching run row (checkpoint
  /// older than the snapshot column, or the row was pruned) or a snapshot that
  /// no longer parses against the current node schema. A failure here must never
  /// block the resume: imaging with degraded attribution still beats refusing to
  /// resume the night.
  ///
  /// Leaves an already-loaded sequence alone. A resume triggered from a session
  /// where the operator still has the tree open must not have it swapped for a
  /// historical snapshot of itself.
  Future<String?> _recoverResumedSequence(String sequenceName) async {
    if (_ref.read(currentSequenceProvider) != null) {
      final loaded = _ref.read(currentSequenceProvider)!;
      try {
        return jsonEncode(
          _ref.read(sequenceFileServiceProvider).sequenceToMap(loaded),
        );
      } catch (e) {
        _logger.warning(
          'Could not snapshot the already-loaded sequence for the resumed '
          'run: $e',
          source: 'SequenceExecutor',
        );
        return null;
      }
    }

    try {
      final snapshotJson = await _ref
          .read(sequenceRunsDaoProvider)
          .latestSnapshotForSequenceName(sequenceName);
      if (snapshotJson == null || snapshotJson.trim().isEmpty) {
        _logger.warning(
          'Resuming "$sequenceName" with no recoverable sequence tree: no '
          'previous run stored a snapshot. Frames will register without '
          'exposure/gain/target attribution.',
          source: 'SequenceExecutor',
        );
        return null;
      }
      final decoded = jsonDecode(snapshotJson);
      if (decoded is! Map<String, dynamic>) {
        _logger.warning(
          'Stored snapshot for "$sequenceName" is not a JSON object; '
          'resuming without a sequence tree.',
          source: 'SequenceExecutor',
        );
        return null;
      }
      final sequence = _ref
          .read(sequenceFileServiceProvider)
          .parseFromMap(decoded);
      // `loadSequence` (not a raw state write) so the editor's own bookkeeping
      // — saved-state, undo stack, ownership — stays consistent.
      // `discardUnsaved` is safe here: this branch only runs when nothing is
      // loaded, so there is no unsaved work to lose.
      _ref
          .read(currentSequenceProvider.notifier)
          .loadSequence(sequence, discardUnsaved: true);
      _logger.info(
        'Recovered the sequence tree for resumed run "$sequenceName" from the '
        'interrupted run\'s snapshot (${sequence.nodes.length} nodes).',
        source: 'SequenceExecutor',
      );
      return snapshotJson;
    } catch (e, st) {
      _logger.warning(
        'Could not recover the sequence tree for resumed run "$sequenceName": '
        '$e\n$st',
        source: 'SequenceExecutor',
      );
      return null;
    }
  }

  Future<void> _resumeFromCheckpointInner() async {
    // Resolve launch-authoritative settings before restoring or mutating the
    // native checkpoint. A failed settings store must leave the checkpoint
    // untouched instead of resuming it with fabricated defaults.
    final settings = await _ref.read(appSettingsProvider.future);
    final backend = _backend;

    final info = await backend.getCheckpointInfo();
    if (info == null || !info.canResume) {
      throw Exception('No valid checkpoint to resume from');
    }

    // Prepare the native executor from the snapshot first, so the
    // re-seeding below overrides snapshot values rather than being
    // overwritten by the restore. This preparation phase acquires no Dart-side
    // run resource (no session/run row/timers), so a failure here needs no
    // rollback — it just propagates.
    await backend.resumeFromCheckpoint();

    // The same ordered launch push the start path makes, with the two
    // resume-specific differences expressed inside it (see [_pushLaunchConfig]).
    await _pushLaunchConfig(backend, settings, isResume: true);
    await seedRuntimeConfigForNativeStart();

    // Recover the sequence TREE from the interrupted run's stored snapshot,
    // BEFORE the running-state flip below. The editor refuses edits once the
    // executor reports running (`_ensureEditable` throws SequenceLockedException),
    // so recovering any later silently fails and leaves the resumed run with no
    // tree at all. This step touches no run resource, so it also belongs outside
    // the acquisition transaction: a failure here needs no rollback.
    //
    // Without the tree, everything that reads it degrades silently: frames
    // register with exposure_duration 0.0 and no gain/offset/binning/target
    // (see `resolveFrameAttribution`), the Dashboard reads "no sequence loaded"
    // while the run is imaging, and the run's history entry has no tree.
    final recoveredSnapshotJson = await _recoverResumedSequence(
      info.sequenceName,
    );

    // Acquisition transaction.
    // From the UI running-state flip onward every resource is part of one
    // lifecycle transaction, protected by the same [_rollbackStart] path as
    // start(). Every resource from the running-state flip onward is inside
    // that one rollback transaction, not just the native start — a failure
    // creating the session/run row must not leave a running UI with an active
    // session and no native run.
    _resetFinalizationForNewRun();
    try {
      final progressNotifier = _ref.read(sequenceProgressProvider.notifier);
      progressNotifier.updateState(SequenceExecutionState.running);
      _ref.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;

      progressNotifier.updateProgress(
        completedExposures: info.completedExposures,
        completedIntegrationSecs: info.completedIntegrationSecs,
        message: 'Resuming from checkpoint...',
      );

      // A resumed run still needs a session + run row so frame stats,
      // replay decisions and the morning report have something to attach
      // to. The checkpoint itself stores the Rust-side definition rather than
      // a Dart DB id, but by this point [_recoverResumedSequence] has put the
      // tree back into `currentSequenceProvider` and the active profile never
      // left memory — so a resumed session carries exactly the identity a
      // fresh run's does. Recording nulls here is what made the Continue
      // Session dialog offer "Unknown Profile" / "No Sequence" after the one
      // event that dialog exists for: an interrupted night.
      final loadedForResume = _ref.read(currentSequenceProvider);
      final resumedSequence = loadedForResume == null
          ? null
          // A tree rebuilt from the interrupted run's JSON snapshot has no row
          // of its own, and a resumed night must not be filed as "No Sequence"
          // either.
          : await _ensureSequencePersisted(loadedForResume);
      if (resumedSequence != null) {
        // Same binding a fresh start makes: without it every frame captured
        // after the resume registers with target_id NULL, so one night's
        // frames split between the target and "Untargeted".
        await _bindCatalogTargets(resumedSequence);
      }
      final sessionNotifier = _ref.read(sessionStateProvider.notifier);
      await sessionNotifier.startSession(
        targetName: info.sequenceName,
        profileId: _ref.read(activeEquipmentProfileProvider)?.id,
        sequenceId: resumedSequence?.databaseId,
      );
      await _openRunRecords(
        sequenceName: info.sequenceName,
        sequenceDatabaseId: resumedSequence?.databaseId,
        snapshotJson: recoveredSnapshotJson,
      );

      _startPerRunTimers();

      await attachHostListenersForNativeRun();

      _startSettingsWatchers(backend);

      // Actually begin execution: start() walks the restored tree and
      // short-circuits already-completed nodes — that is what makes the
      // checkpoint resume real instead of a state-only restore. Mark the
      // native-launch boundary so [_rollbackStart] best-effort stops a partial
      // launch instead of tearing down blind.
      _nativeLaunchAttempted = true;
      await backend.sequencerStart();
    } catch (e, st) {
      // Single rollback path shared with start(): cancels every acquired
      // resource, finalizes the run failed, ends the session, clears the
      // stale run id, releases a Smart Night / mosaic handoff, and leaves a
      // truthful failed state — so a resumed night never shows a permanently
      // "running" ghost sequence.
      await _rollbackStart(e, st);
      rethrow;
    }
  }

  /// Subscribe [_handleSequencerEvent] to the backend event stream.
  ///
  /// The ONE subscribe site. A Dart-orchestrated [start] and a checkpoint
  /// [resumeFromCheckpoint] both route through here as part of their launch,
  /// and the headless appliance calls it directly: its canonical flow is
  /// `POST /api/sequencer/load` -> `POST /api/sequencer/start`, which never
  /// calls [start].
  ///
  /// The listener is what turns a native `FrameCaptured` into a
  /// `captured_images` row, advances the session counters, feeds progress and
  /// the run vitals, and drives auto-grading. Without it a night's frames land
  /// on disk and the database never hears about them.
  ///
  /// Idempotent (it cancels any existing subscription first) and safe to call
  /// before every native start: a run that ended in `stopFailed` /
  /// `cleanupFailed` deliberately retains its subscription, and a previous
  /// run's normal teardown cancels it.
  ///
  /// Because it is the ONE site every native launch passes through, it is also
  /// where a launch that did not come from [start] gets the previous run's
  /// terminal latches released — see [_releaseSettledRunForNextNativeRun].
  Future<void> attachHostListenersForNativeRun() async {
    _ensureBackendAuthority();
    final backend = _backend;
    _releaseSettledRunForNextNativeRun();
    await _nativeEventSubscription?.cancel();
    _nativeEventSubscription = backend.eventStream.listen(
      _handleSequencerEvent,
      onError: (e) =>
          _logger.error('Event stream error: $e', source: 'SequenceExecutor'),
    );
  }

  /// Whether this executor is currently listening to the native event stream.
  /// The subscription is what turns native frame events into database rows, so
  /// "is it attached" is the assertable form of "will this run be recorded".
  @visibleForTesting
  bool get isListeningToNativeEventsForTest => _nativeEventSubscription != null;

  /// Discard the current checkpoint
  Future<void> discardCheckpoint() async {
    _ensureBackendAuthority();
    final backend = _backend;
    await backend.discardCheckpoint();
  }

  /// Start periodic checkpoint saves (every 30 seconds while running).
  void dispose() {
    _disposed = true;
    _progressTimer?.cancel();
    _progressTimer = null;
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    _nativeEventSubscription?.cancel();
    _nativeEventSubscription = null;
    // The sky-brightness poll is a per-run resource like the two timers above,
    // but it was only cancelled on the clean release path
    // (`_releaseRunResources`). A run that ends in `stopFailed` /
    // `cleanupFailed` deliberately does NOT release, so the 10-second timer
    // outlived the executor and kept firing against a torn-down Ref — reading
    // providers from a disposed container every tick, forever.
    _skyBrightnessPollTimer?.cancel();
    _skyBrightnessPollTimer = null;
    _stopDiskSpaceWatchdog();
  }
}
