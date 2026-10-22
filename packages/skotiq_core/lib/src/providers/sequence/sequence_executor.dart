import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/skotiq_backend.dart';
import '../../models/sequence/active_plan_owner.dart';
import '../../models/sequence/sequence_models.dart';
import '../../services/sequence_file_service.dart';
import '../../services/sequence_repository.dart'
    show sequenceRepositoryProvider;
import '../../services/live_stacking_broadcast_service.dart';
import '../../services/safe_rig_service.dart';
import '../../services/logging_service.dart';
import '../backend_provider.dart';
import '../database_provider.dart' show targetsDaoProvider;
import '../disk_space_provider.dart';
import '../focuser_backlash_provider.dart' show savedFocuserBacklashProvider;
// Sky-brightness poll reads the tracker via this
// provider (defined in flat_wizard_provider since the tracker is
// shared between flat-wizard and adaptive-exposure paths).
import '../live_stacking_provider.dart';
import '../meridian_flip_provider.dart';
// Plugin-node dispatcher abstraction.
import '../profiles_provider.dart';
import '../sequence_provider.dart'
    show
        currentSequenceProvider,
        restoredCheckpointProvider,
        sequenceExecutionStateProvider,
        sequenceLaunchInFlightProvider,
        sequenceProgressProvider;
import '../sequence_stats_provider.dart';
import '../session_provider.dart';
import '../settings_provider.dart';
// Session-lifecycle hooks: optical-train baseline capture,
// post-session diagnostics summary, NotificationRouter active-sequence
// tracking, USB disconnect aggregation.
import 'node_exposure_tally.dart';
import 'run_stop_classification.dart';
import 'sequence_validation.dart' as validation;
import 'sequence_executor/eta_smoothing.dart';
import 'sequence_executor/run_finalization.dart';
import 'sequence_executor/run_lifecycle.dart';
import 'sequence_executor/run_stats_ledger.dart';
import 'sequence_executor/live_stacking_feed.dart';
import 'sequence_executor/run_timers.dart';
import 'sequence_executor/runtime_config_sync.dart';
import 'sequence_executor/session_diagnostics.dart';
import 'sequence_executor/run_target_binding.dart';
import 'sequence_executor/run_frame_recorder.dart';
import 'sequence_executor/run_event_handler.dart';
import 'sequence_executor/sequence_serializer.dart';
import 'sequence_executor/stop_confirmation.dart';

export 'sequence_executor/eta_smoothing.dart'
    show EtaSmoother, kEtaEmaAlpha, kEtaWindowSize;
export 'sequence_executor/run_finalization.dart' show RunFinalization;
export 'sequence_executor/run_lifecycle.dart';
export 'sequence_executor/session_diagnostics.dart'
    show kCoolerSetpointBandDegC;
export 'sequence_executor/sequence_serializer.dart' show SequenceSerializer;
export 'sequence_executor/stop_confirmation.dart'
    show
        NativeStopConfirmer,
        kNativeStopConfirmationPollInterval,
        kNativeStopConfirmationTimeout,
        kNativeTerminalStates;

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
  final SkotiqBackend _backend;

  /// Translates the loaded [Sequence] into the JSON the native executor runs.
  /// Its lookup warnings go into the run record through [_surfaceRunWarning].
  late final SequenceSerializer _serializer = SequenceSerializer(
    ref: _ref,
    warn: _surfaceRunWarning,
  );

  /// Log an operator-facing warning and put it on the run record, so it
  /// reaches `sequence_runs.stats_json` and the post-session report.
  /// [persist] as in [RunStatsLedger.update].
  void _surfaceRunWarning(String message, {bool persist = true}) {
    _logger.warning(message, source: 'SequenceExecutor');
    _stats.update((stats) => stats.recordWarning(message), persist: persist);
  }

  StreamSubscription? _nativeEventSubscription;

  /// The run's elapsed-time ticker, checkpoint saver and disk watchdog.
  late final RunTimers _timers = RunTimers(
    isPaused: () => _lifecycle.isPausedByExecutor,
    onElapsed: _publishElapsed,
    isRunning: () =>
        _ref.read(sequenceExecutionStateProvider) ==
        SequenceExecutionState.running,
    saveCheckpoint: () => _backend.saveCheckpoint(),
    capturePath: () =>
        _ref.read(appSettingsProvider).valueOrNull?.imageOutputPath ?? '',
    diskGuard: () => _ref.read(diskSpaceGuardProvider),
    safeTheRig: (reason) async {
      await _ref
          .read(safeRigServiceProvider)
          .safeTheRig(reason: reason, park: true);
    },
    logger: () => _logger,
  );

  /// The checkpoint prepared for the next start.
  _RestoredCheckpoint? _restored;

  /// Owns the run phases and operation latches.
  final RunLifecycle _lifecycle = RunLifecycle();

  /// The finalization drive the most recent natural terminal event spawned,
  /// for [terminalCleanupSettledForTest].
  Future<void>? _lastTerminalDrive;

  /// The live run stats and their persistence.
  late final RunStatsLedger _stats = RunStatsLedger(
    readStats: () => _ref.read(liveSequenceStatsProvider),
    publishStats: (stats) =>
        _ref.read(liveSequenceStatsProvider.notifier).state = stats,
    readRunId: () => _ref.read(currentRunIdProvider),
    runsDao: () => _ref.read(sequenceRunsDaoProvider),
    logger: () => _logger,
  );

  /// Feeds accepted frames to the live stacker when the sequence asks for it.
  late final LiveStackingFeed _liveStacking = LiveStackingFeed(
    sequence: () => _ref.read(currentSequenceProvider),
    progress: () => _ref.read(sequenceProgressProvider),
    broadcast: () => _ref.read(liveStackingBroadcastServiceProvider),
    stacker: () => _ref.read(liveStackingProvider.notifier),
    stackState: () => _ref.read(liveStackingProvider),
    logger: () => _logger,
  );

  /// The run's frame counters, `captured_images` rows and live preview.
  late final RunFrameRecorder _frames = RunFrameRecorder(
    ref: _ref,
    backend: _backend,
    stats: _stats,
    targets: _targets,
    logger: () => _logger,
    isDisposed: () => _disposed,
  );

  /// Applies native sequencer events to the run; terminal events come back
  /// to [_onTerminalEvent].
  late final RunEventHandler _events = RunEventHandler(
    ref: _ref,
    backend: _backend,
    stats: _stats,
    frames: _frames,
    liveStacking: _liveStacking,
    eta: _eta,
    logger: () => _logger,
    warn: _surfaceRunWarning,
    setExecutionState: _setExecutionState,
    onTerminal: _onTerminalEvent,
  );

  /// True once [dispose] has run. Late completions of fire-and-forget
  /// work (frame persistence, campaign credit) must not read providers
  /// through [_ref] afterwards — the container may be gone, and the read
  /// throws "Tried to read a provider from a ProviderContainer that was
  /// already disposed" out of an unhandled async error.
  // NOT final: set to true in [dispose].
  bool _disposed = false;

  /// Per-frame cadence smoother backing the run's ETA.
  final EtaSmoother _eta = EtaSmoother();

  /// Pushes the operator's settings into the native runtime config, before
  /// launch and while the run is live.
  late final RuntimeConfigSync _runtimeConfig = RuntimeConfigSync(
    ref: _ref,
    backend: _backend,
    serializer: _serializer,
    logger: () => _logger,
    warn: _surfaceRunWarning,
    isDisposed: () => _disposed,
  );

  /// Session-start and session-end diagnostics.
  late final SessionDiagnostics _diagnostics = SessionDiagnostics(
    ref: _ref,
    logger: () => _logger,
  );

  LoggingService get _logger => _ref.read(loggingServiceProvider);

  SequenceExecutor(this._ref, {SkotiqBackend? backend})
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

  /// Test entry point for the session-start hooks, without a whole start.
  @visibleForTesting
  void captureSessionStartHooksForTest(String sequenceId) =>
      _diagnostics.captureStart(sequenceId);

  /// Test entry point for the session-end hooks.
  @visibleForTesting
  void captureSessionEndHooksForTest() => _diagnostics.captureEnd();

  /// Test entry point that pumps a synthesised
  /// `SkotiqEvent` through the same handler the live native event
  /// subscription uses. Lets unit tests exercise the FrameAccepted /
  /// FrameRejected / PluginNodeRequested handlers without spinning up
  /// the full Rust backend.
  @visibleForTesting
  void handleSequencerEventForTest(SkotiqEvent event) => _events.handle(event);

  /// Runs the start-time catalog binding on its own, so a test can assert what
  /// the `targets` rows hold afterwards without driving a whole run.
  @visibleForTesting
  Future<void> bindCatalogTargetsForTest(Sequence sequence) =>
      _targets.bind(sequence);

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
      final tail = _liveStacking.pending;
      final registrations = _frames.inFlightRegistrations;
      if (tail == null && registrations.isEmpty) return;
      try {
        await Future.wait<void>([if (tail != null) tail, ...registrations]);
      } catch (_) {
        // Feed errors are logged and surfaced by the feed itself; this
        // waiter only cares about quiescence.
      }
      if (identical(tail, _liveStacking.pending) &&
          _frames.inFlightRegistrations.isEmpty) {
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
      await _lastTerminalDrive;
    } catch (_) {
      // The truthful state (cleanupFailed) is already published; tests assert
      // on it directly.
    }
  }

  /// Test entry point for the session-handoff carry-over seed, without
  /// driving a whole start.
  @visibleForTesting
  Future<void> seedIntegrationCarryOverFromHandoffForTest(Sequence sequence) =>
      _runtimeConfig.seedIntegrationCarryOver(sequence);

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
    if (_lifecycle.launch.isHeld || !_isStartAdmissible(admissionState)) {
      throw StateError(
        'Cannot start: a sequence start is already in flight or the executor '
        'is not in an admissible state (state: ${admissionState.name}).',
      );
    }
    _acquireLaunchLatch();
    try {
      final sequence = _ref.read(currentSequenceProvider);
      final restored = _restored;
      if (restored != null) {
        if (restored.matches(sequence)) {
          await _continueRestoredRun(restored);
          return;
        }
        _logger.info(
          'The loaded sequence is no longer the one restored from the '
          'checkpoint of "${restored.info.sequenceName}"; starting it fresh.',
          source: 'SequenceExecutor',
        );
        _clearRestored();
      }
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
      _beginLaunch();
      try {
        await _acquireAndStartRun(sequence, runSettings);
      } catch (e, st) {
        await _rollbackStart(e, st);
        rethrow;
      }
      _lifecycle.launchSucceeded();
    } finally {
      _releaseLaunchLatch();
    }
  }

  void _acquireLaunchLatch() {
    _lifecycle.launch.acquire();
    _ref.read(sequenceLaunchInFlightProvider.notifier).state = true;
  }

  void _releaseLaunchLatch() {
    _lifecycle.launch.release();
    _ref.read(sequenceLaunchInFlightProvider.notifier).state = false;
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
  /// An unsaved tree would file its run and session with `sequence_id` NULL,
  /// which the Continue Session dialog, run history grouping and run diff all
  /// key on. It is saved once; the editor adopts the id, so the next run
  /// updates the same row. A failure is logged and the run proceeds: a night
  /// filed without a sequence id beats refusing to image.
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

  /// The running sequence's Target nodes bound to their `targets` rows.
  late final RunTargetBinding _targets = RunTargetBinding(
    targetsDao: () => _ref.read(targetsDaoProvider),
    logger: () => _logger,
  );

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
    _liveStacking.resetForRun();
    _frames.clearVerdicts();

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
  /// Without the row the run has no history entry and finalization has
  /// nowhere to write its status and stats.
  ///
  /// No snapshot: the column holds the editor's sequence map, and the native
  /// wire JSON is a different document the run diff cannot compare.
  ///
  /// A run id already set means a run is under way; it is kept rather than
  /// orphaned in `running`. Returns the run id in force.
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
    // Clear the previous run's progress, as [_acquireAndStartRun] does: the
    // integration total and the per-node badges accumulate otherwise.
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
  /// The one seed site every launch path shares ([_startNativeExecution]
  /// calls it too), so no path can run on the Rust defaults.
  ///
  /// Throws on a failed push, as [start] does: a start that refuses and says
  /// why beats a night with the operator's grading silently inert.
  Future<void> seedRuntimeConfigForNativeStart() async {
    _ensureBackendAuthority();
    await _runtimeConfig.seedFromSettings();
  }

  /// Start the periodic work a run owns. The ETA smoother restarts with it:
  /// a resumed run's cadence must not be biased by the interrupted run's.
  void _startPerRunTimers() {
    _eta.reset();
    _timers.start();
  }

  /// Publish the elapsed time and the ETA. The ETA is projected from
  /// [EtaSmoother]'s per-frame average, not the wall clock, so one slow
  /// download or a fast calibration frame does not yank it around.
  void _publishElapsed(double elapsedSecs) {
    final progress = _ref.read(sequenceProgressProvider);
    _ref
        .read(sequenceProgressProvider.notifier)
        .updateProgress(
          elapsedSecs: elapsedSecs,
          estimatedRemainingSecs: _eta.remainingSeconds(
            completedFrames: progress.completedExposures,
            totalFrames: progress.totalExposures,
          ),
        );
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
    // Clear the previous run's progress before seeding this one's: the
    // integration total and the per-node maps accumulate otherwise.
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

    await _targets.bind(sequence);
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
    _diagnostics.captureStart(sequence.id);

    _startPerRunTimers();

    // Always use backend/native sequencer engine to avoid divergent semantics.
    // This is the last acquisition step; it sets up the native event
    // subscription + settings watchers and issues sequencerStart(). A throw
    // anywhere in the transaction (including here) is rolled back by [start].
    await _startNativeExecution(sequence, runSettings);
  }

  /// Configure the native executor, load the run's tree and start it: the
  /// last acquisition step of [start]. From the native launch boundary on, a
  /// failure may have left a partial launch, so [_rollbackStart] stops the
  /// native executor before tearing down.
  Future<void> _startNativeExecution(
    Sequence sequence,
    AppSettingsState settings,
  ) async {
    await _runtimeConfig.pushLaunchConfig(settings, isResume: false);

    // Both values below are serialized into the tree from providers that
    // hold defaults until their loads finish; a start that outran the loads
    // would bake factory values into the run.
    await _ref.read(globalMeridianFlipSettingsProvider.notifier).ensureLoaded();
    await _ref.read(savedFocuserBacklashProvider.future);

    await _backend.sequencerLoadJson(_serializer.sequenceToJson(sequence));

    // The runtime config is seeded before start, so the trigger monitor's
    // first poll already runs on the operator's values; the settings watchers
    // only fire on a later change. Through the public entry point the headless
    // `load -> start` path shares.
    await seedRuntimeConfigForNativeStart();

    // After the runtime seed, so the carry-over overrides any default it
    // re-stamps, and before start, so the executor consumes it.
    await _runtimeConfig.seedIntegrationCarryOver(sequence);

    _ensureStillLaunching();
    await attachHostListenersForNativeRun();
    _runtimeConfig.startWatchers();

    _lifecycle.markNativeLaunchAttempted();
    await _backend.sequencerStart();
  }

  /// Admissible starting states: idle, completed, failed (see
  /// [SequenceExecutionStateCapabilities.canStart]). A run may only start from
  /// a settled state — running / paused / stopping / recovering are rejected so
  /// a start can never overlap an in-flight or tearing-down run, and the
  /// retryable stopFailed / cleanupFailed states are rejected so a fresh run
  /// can never collide with live hardware or a dangling session.
  bool _isStartAdmissible(SequenceExecutionState state) => state.canStart;

  /// Throws when a stop (or a native terminal) claimed the run while it was
  /// still launching. The launch must then never reach the native start: the
  /// stop has already torn the run down and published it as stopped.
  void _ensureStillLaunching() {
    final phase = _lifecycle.phase;
    if (phase is! RunLaunching) {
      throw StateError(
        'The run was stopped before it started (${phase.name}); the native '
        'executor was not started.',
      );
    }
  }

  /// Enter [RunLaunching] at the top of a start / resume acquisition.
  void _beginLaunch() {
    _lifecycle.beginLaunch();
    _resetPerRunState();
  }

  /// Clear what a previous run left behind so a new run starts clean.
  void _resetPerRunState() {
    _lastTerminalDrive = null;
    _stats.reopen();
    // The sequencer screen must see a clean null -> result transition when
    // this run ends, never the previous run's report.
    _ref.read(sequenceTerminalRunResultProvider.notifier).state = null;
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
      _events.recordRunError('Failed to start sequence execution: $startError');
    } catch (_) {
      // Absent live stats (failure before the run row existed) — nothing to
      // record; the drive's finalizeRun is a no-op in that case anyway.
    }

    final phase = _lifecycle.phase;
    if (phase is! RunLaunching) {
      await _yieldToClaimedFinalization(phase);
      return;
    }
    final f = RunFinalization(
      generation: _lifecycle.nextGeneration(),
      runStatus: 'failed',
      finalUiState: SequenceExecutionState.failed,
      runId: _ref.read(currentRunIdProvider),
      dbSessionId: _ref.read(sessionStateProvider).dbSessionId,
      preserveCheckpoint: false,
      // A throw at/after sequencerStart() may mean a partial native launch; a
      // throw before it (validation / session-row / loadJson) leaves the flag
      // false so the drive skips the native stop entirely and settles cleanly.
      nativeStopRequired: phase.nativeLaunchAttempted,
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
    _lifecycle.claim(f);
    try {
      await _launchDrive(f);
    } catch (_) {
      // The truthful stopFailed / cleanupFailed / failed state is already
      // published inside the drive. Swallow so [start] rethrows the ORIGINAL
      // launch error, not the secondary cleanup error.
    }
  }

  /// A launch failed after a stop or a native terminal had already claimed the
  /// run. That finalization owns the teardown, so the rollback opens no second
  /// one; once it settles, whatever the launch acquired after its resource
  /// release ran is released too. A retained (stopFailed / cleanupFailed)
  /// finalization keeps everything, its native subscription included.
  Future<void> _yieldToClaimedFinalization(RunPhase phase) async {
    _logger.warning(
      'Sequence start failed after the run was already claimed '
      '(${phase.name}); its finalization owns the teardown',
      source: 'SequenceExecutor',
    );
    try {
      await _lifecycle.drive;
    } catch (_) {
      // Already surfaced through the published state.
    }
    if (_lifecycle.phase is RunSettled) {
      await _releaseRunResources(
        (step, e) => _logger.warning(
          'Rollback: $step failed: $e',
          source: 'SequenceExecutor',
        ),
      );
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
    final pending = _lifecycle.finalization;

    // Confirmation path: an explicit stop (or a retry after stopFailed) holds
    // its resources until an authoritative terminal proves the native abort
    // finished. The stop API returning only means the command was accepted.
    if (pending != null &&
        pending.nativeStopRequired &&
        !pending.nativeStopConfirmed) {
      pending.nativeStopConfirmed = true;
      final confirmation = pending.nativeStopConfirmation;
      if (confirmation != null && !confirmation.isCompleted) {
        confirmation.complete();
      }
      if (error != null) _recordTerminalRunError(error);
      // A drive waiting on the confirmation wakes above. If the stop command
      // had already failed, resume the retained transaction without a second
      // native stop.
      if (state == SequenceExecutionState.stopFailed &&
          _lifecycle.drive == null) {
        _respawnFinalization(pending);
      }
      return;
    }

    // A retained stop whose command failed before the confirmation gate
    // existed.
    if (state == SequenceExecutionState.stopFailed && pending != null) {
      pending.nativeStopConfirmed = true;
      if (error != null) _recordTerminalRunError(error);
      if (_lifecycle.drive == null) _respawnFinalization(pending);
      return;
    }

    // Exactly once: a claimed finalization swallows duplicate, aliased and
    // echo terminals, including the Stopped echo of a successful stop().
    if (pending != null) return;

    // Exactly once, part two: the run already has a verdict, and this is a
    // second wire event for it (a stop-cancelled Slew sends both Stopped and
    // SequenceFailed). Re-finalizing would republish a Stop as a failure.
    if (_lifecycle.phase case RunSettled(runStatus: final settled)) {
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
      _stats.update((stats) => stats.recordWarning(warning));
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
      generation: _lifecycle.nextGeneration(),
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
    _lifecycle.claim(f);
    _spawnTerminalDrive(f);
  }

  /// Re-enter `finalizing` and resume the retained [f] after a late terminal
  /// confirmed the native stop.
  void _respawnFinalization(RunFinalization f) {
    _setExecutionState(SequenceExecutionState.finalizing);
    _spawnTerminalDrive(f);
  }

  /// Launch [f]'s drive from an event handler, which cannot await it.
  void _spawnTerminalDrive(RunFinalization f) {
    final drive = _launchDrive(f);
    _lastTerminalDrive = drive;
    _swallowSpawnedFinalizationError(drive);
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

  /// Launch (or relaunch, for a Stop retry) the drive of the claimed [f]. The
  /// lifecycle holds it as the drive racing callers join; a drive that ends
  /// without settling leaves [f] retained for a Stop retry.
  Future<void> _launchDrive(RunFinalization f) {
    late final Future<void> wrapped;
    wrapped = _driveFinalization(
      f,
    ).whenComplete(() => _lifecycle.driveEnded(f, wrapped));
    _lifecycle.driveStarted(f, wrapped);
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
        // A BOUNDED wait for the authoritative terminal: the command returning
        // only means it was accepted, and the camera may still be exposing.
        // The terminal can legitimately never arrive (the broadcast receiver
        // skips events when it lags, and a headless run may have no
        // subscription), so either the pushed terminal or the native
        // executor's own reported state confirms it. On expiry this is
        // handled like a failed stop command: a controllable stopFailed with
        // the subscription still live, so a late terminal resumes THIS
        // finalization. Nothing is torn down on a guess.
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

    // 3. Persistence: seal and drain the live stats, finishRun, then the
    // once-only session-end hooks ([RunFinalization.runRecordFinished] keeps a
    // retry from repeating them). The hooks read SessionState.dbSessionId, so
    // this runs BEFORE endSession clears it.
    try {
      await _finalizeRun(f);
    } catch (e, st) {
      // finishRun FAILED. Do NOT endSession, clear ids, release ownership,
      // discard the checkpoint, or settle. The retained finalization is the
      // retry's context.
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
      // (finishRun and the hooks are already latched by
      // [RunFinalization.runRecordFinished], and the native stop is already
      // confirmed).
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

    // How the run ended, for the autopilot's reconcile: an explicit stop
    // carries its commander's origin; a natural 'stopped' terminal nobody
    // commanded is a native safety abort, which must not pause the autopilot
    // as if a human had asked it to stand down.
    final String? endOrigin;
    if (f.nativeStopRequired) {
      endOrigin = f.stopOrigin ?? 'operator';
    } else if (f.runStatus == 'stopped' ||
        f.runStatus == 'paused-stopped' ||
        f.runStatus == 'aborted') {
      endOrigin = 'safety';
    } else {
      endOrigin = null;
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

    // 6. The run has its verdict; publish one terminal result, THEN the
    // settled UI state. Settled before publishing, so a listener reacting to
    // the published state already sees the verdict and the end origin.
    _lifecycle.settle(f, endOrigin: endOrigin);
    if (f.publishTerminalResult) {
      _publishTerminalResult(f);
    }
    _setExecutionState(f.finalUiState);
  }

  /// Finalize the run row and fire the once-per-run session-end hooks.
  ///
  /// Awaited by the drive, so the run id is cleared only after `finishRun` has
  /// persisted and a failed finish surfaces as `cleanupFailed`.
  /// [RunFinalization.runRecordFinished] is set only after `finishRun`
  /// succeeds: it makes the success path exactly-once without swallowing a
  /// retry after a failed finish.
  Future<void> _finalizeRun(RunFinalization f) async {
    if (f.runRecordFinished) return;
    final runId = _ref.read(currentRunIdProvider);
    final stats = _ref.read(liveSequenceStatsProvider);
    if (runId == null || stats == null) return;
    await _stats.sealAndDrain();
    stats.endTime = DateTime.now();
    await _ref
        .read(sequenceRunsDaoProvider)
        .finishRun(runId, f.runStatus, stats.toJson());
    f.runRecordFinished = true;
    _diagnostics.captureEnd();
  }

  /// Record a terminal event's reason. Not a run error: it restates the
  /// mid-run `Error` the run already recorded (see
  /// [SequenceRunStats.recordTerminalError]).
  void _recordTerminalRunError(String message) {
    _stats.update((stats) => stats.recordTerminalError(message));
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
      _timers.stopTimers();
    } catch (e) {
      secondary('reset run timers', e);
    }
    try {
      _timers.stopDiskWatchdog();
    } catch (e) {
      secondary('stop disk watchdog', e);
    }
    try {
      _runtimeConfig.stopWatchers();
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
      await _liveStacking.teardown();
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
    if (_lifecycle.pauseResume.isHeld) {
      throw Exception('Pause/Resume operation already in progress');
    }

    final currentState = _ref.read(sequenceExecutionStateProvider);
    if (currentState != SequenceExecutionState.running) {
      throw Exception('Cannot pause: sequence is not running');
    }

    _lifecycle.pauseResume.acquire();

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

      _notePausedByExecutor(true);
      await _persistLiveRunStatus('paused');
    } finally {
      _lifecycle.pauseResume.release();
    }
  }

  Future<void> resume() async {
    _ensureBackendAuthority();
    if (_lifecycle.pauseResume.isHeld) {
      throw Exception('Pause/Resume operation already in progress');
    }

    final currentState = _ref.read(sequenceExecutionStateProvider);
    if (currentState != SequenceExecutionState.paused) {
      throw Exception('Cannot resume: sequence is not paused');
    }

    _lifecycle.pauseResume.acquire();

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

      _notePausedByExecutor(false);
      await _persistLiveRunStatus('running');
    } finally {
      _lifecycle.pauseResume.release();
    }
  }

  /// Record a confirmed pause or resume on a live run. A run in any other
  /// phase (still launching, already finalizing, or a native run this executor
  /// never attached to) has no elapsed-time ticker to hold.
  void _notePausedByExecutor(bool paused) {
    if (_lifecycle.phase is RunLive) _lifecycle.setPaused(paused);
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

  /// How the most recently settled run ended: 'operator' / 'scheduler' /
  /// 'rollback' / 'safety' (native-side abort with no stop() commander) /
  /// null (completed, failed, or nothing settled yet).
  String? get lastRunEndOrigin => _lifecycle.lastRunEndOrigin;

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
  Future<void> stop({bool preserveCheckpoint = false, String? origin}) {
    _ensureBackendAuthority();
    // Join an in-flight finalization — a natural terminal, another stop(), or a
    // rollback: the caller observes the SAME outcome, and native stop + cleanup
    // happen exactly once. The first caller's terminal intent wins (a stop that
    // lands on an already-completing natural terminal does NOT override it).
    final inFlight = _lifecycle.drive;
    if (inFlight != null) return inFlight;

    final state = _ref.read(sequenceExecutionStateProvider);
    // Idle-stop guard: nothing to stop from a settled, non-active state (idle /
    // completed / failed / finalizing). Returning a completed future keeps
    // stop() a safe no-op instead of flashing a state and commanding a native
    // stop against an executor that is not running.
    if (!state.canStop) return Future<void>.value();

    // Retry path: a retained finalization (stopFailed / cleanupFailed) is
    // re-driven WITHOUT rebuilding intent; its first-claimed status wins. With
    // the native stop already confirmed the drive is a pure persistence retry
    // (`finalizing`); otherwise it retries the native stop (`stopping`).
    final retained = _lifecycle.finalization;
    if (retained != null) {
      final f = retained;
      // The retry keeps the retained intent except the origin, which only
      // upgrades toward the operator: a human retrying a system stop has
      // commanded one, and an operator's episode stays theirs. Only the
      // stopFailed half re-sends the native stop and so records the press.
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
    // teardown or persistence. A settled phase here means the live state
    // belongs to a native run this executor did not launch; it gets its own
    // finalization.
    _lifecycle.releaseSettled();
    final f = RunFinalization(
      generation: _lifecycle.nextGeneration(),
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
    _lifecycle.claim(f);
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
  /// The rest of the current target's subtree is skipped and execution resumes
  /// at the next [TargetHeaderNode] in canonical order, through one native
  /// skip-to-node jump. With no next target the run is finished with [stop],
  /// as a natural end would. Throws [StateError] unless the run is running or
  /// paused.
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
    final inFlight = _lifecycle.drive;
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

  /// Restore the interrupted run from its checkpoint WITHOUT starting it.
  ///
  /// Prepares the native executor from the checkpoint (sequence, completed
  /// nodes, loop counts, trigger state, devices, save path, location), puts the
  /// sequence tree back into the editor and the checkpoint's frame counts into
  /// the progress, and leaves the run ready: nothing executes (no slew, no
  /// cooler command, no exposure, no end steps) until [start] is called, which
  /// then continues from the checkpoint. A restore can happen at any hour; only
  /// the operator decides when the run goes on.
  Future<void> restoreFromCheckpoint() async {
    _ensureBackendAuthority();
    final admissionState = _ref.read(sequenceExecutionStateProvider);
    if (_lifecycle.launch.isHeld || !_isStartAdmissible(admissionState)) {
      throw StateError(
        'Cannot restore: a sequence start is already in flight or the '
        'executor is not in an admissible state '
        '(state: ${admissionState.name}).',
      );
    }
    _acquireLaunchLatch();
    try {
      await _restoreFromCheckpointInner();
    } finally {
      _releaseLaunchLatch();
    }
  }

  /// Restore the interrupted run from its checkpoint and start it at once.
  ///
  /// [restoreFromCheckpoint] followed by [start]. Only for a caller that has
  /// explicitly asked for the run to go on now (the headless API's
  /// `checkpoint/resume` with `start: true`); every operator-facing Resume
  /// restores and waits for Start.
  Future<void> resumeFromCheckpoint() async {
    await restoreFromCheckpoint();
    await start();
  }

  /// Whether a checkpoint restore is waiting for [start].
  bool get hasRestoredCheckpoint => _restored != null;

  void _clearRestored() {
    _restored = null;
    _ref.read(restoredCheckpointProvider.notifier).state = null;
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

  Future<void> _restoreFromCheckpointInner() async {
    final backend = _backend;

    final info = await backend.getCheckpointInfo();
    if (info == null || !info.canResume) {
      throw Exception('No valid checkpoint to resume from');
    }

    // Prepare the native executor from the snapshot. This only rebuilds and
    // marks the tree; nothing runs until `sequencerStart()`. The launch
    // re-seeding that must override snapshot values happens at [start].
    await backend.resumeFromCheckpoint();

    // Recover the sequence TREE from the interrupted run's stored snapshot so
    // the editor shows what will run, and so the run, once started, has the
    // tree its frames are attributed from.
    final recoveredSnapshotJson = await _recoverResumedSequence(
      info.sequenceName,
    );

    final progressNotifier = _ref.read(sequenceProgressProvider.notifier);
    progressNotifier.updateProgress(
      completedExposures: info.completedExposures,
      completedIntegrationSecs: info.completedIntegrationSecs,
      message:
          'Restored from checkpoint: ${info.completedExposures} frames done. '
          'Nothing moves until you press Start.',
    );

    _restored = _RestoredCheckpoint(
      info: info,
      snapshotJson: recoveredSnapshotJson,
      sequence: _ref.read(currentSequenceProvider),
    );
    _ref.read(restoredCheckpointProvider.notifier).state = info;
    _logger.info(
      'Restored "${info.sequenceName}" from its checkpoint '
      '(${info.completedExposures} frames, '
      '${(info.completedIntegrationSecs / 60).toStringAsFixed(1)} min); '
      'the run waits for Start.',
      source: 'SequenceExecutor',
    );
  }

  /// Start the run [restoreFromCheckpoint] prepared, continuing from its
  /// checkpoint. Called by [start] under its latch.
  Future<void> _continueRestoredRun(_RestoredCheckpoint restored) async {
    // Resolve launch-authoritative settings before touching the prepared
    // executor. A failed settings store must leave the restore in place
    // instead of continuing it with fabricated defaults.
    final settings = await _ref.read(appSettingsProvider.future);
    final backend = _backend;
    final info = restored.info;

    // The same ordered launch push the start path makes, with the two
    // resume-specific differences expressed inside it (see [RuntimeConfigSync.pushLaunchConfig]).
    await _runtimeConfig.pushLaunchConfig(settings, isResume: true);
    await seedRuntimeConfigForNativeStart();

    final recoveredSnapshotJson = restored.snapshotJson;

    // Acquisition transaction.
    // From the UI running-state flip onward every resource is part of one
    // lifecycle transaction, protected by the same [_rollbackStart] path as
    // start(). Every resource from the running-state flip onward is inside
    // that one rollback transaction, not just the native start — a failure
    // creating the session/run row must not leave a running UI with an active
    // session and no native run.
    _beginLaunch();
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
        await _targets.bind(resumedSequence);
      }
      // The interrupted night's session may already be open again (the
      // operator recovered it from the incomplete-sessions prompt); the
      // continued run belongs to it rather than to a second session.
      if (_ref.read(sessionStateProvider).isActive) {
        _logger.info(
          'Continuing "${info.sequenceName}" in the session that is already '
          'open',
          source: 'SequenceExecutor',
        );
      } else {
        await _ref
            .read(sessionStateProvider.notifier)
            .startSession(
              targetName: info.sequenceName,
              profileId: _ref.read(activeEquipmentProfileProvider)?.id,
              sequenceId: resumedSequence?.databaseId,
            );
      }
      await _openRunRecords(
        sequenceName: info.sequenceName,
        sequenceDatabaseId: resumedSequence?.databaseId,
        snapshotJson: recoveredSnapshotJson,
      );

      _startPerRunTimers();

      _ensureStillLaunching();
      await attachHostListenersForNativeRun();

      _runtimeConfig.startWatchers();

      // Actually begin execution: start() walks the restored tree and
      // short-circuits already-completed nodes — that is what makes the
      // checkpoint resume real instead of a state-only restore. Mark the
      // native-launch boundary so [_rollbackStart] best-effort stops a partial
      // launch instead of tearing down blind.
      _lifecycle.markNativeLaunchAttempted();
      _clearRestored();
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
    _lifecycle.launchSucceeded();
  }

  /// Subscribe the event handler to the backend event stream.
  ///
  /// The ONE subscribe site. A Dart-orchestrated [start] and a checkpoint
  /// [resumeFromCheckpoint] both route through here as part of their launch,
  /// and the headless appliance calls it directly: its canonical flow is
  /// `POST /api/sequencer/load` -> `POST /api/sequencer/start`, which never
  /// calls [start].
  ///
  /// Without the subscription a night's frames land on disk and the database
  /// never hears about them.
  ///
  /// Idempotent (it cancels any existing subscription first) and safe to call
  /// before every native start: a run that ended in `stopFailed` /
  /// `cleanupFailed` deliberately retains its subscription, and a previous
  /// run's normal teardown cancels it.
  ///
  /// Because it is the ONE site every native launch passes through, it is also
  /// where a native run that did not come through [start] becomes this
  /// executor's live run ([RunLifecycle.attachNativeRun]). A settled previous
  /// run is released first, or its verdict would swallow this run's terminal
  /// and the second night would never finalize. A retained (stopFailed /
  /// cleanupFailed) finalization is kept: a retry or a late terminal resumes
  /// exactly that transaction.
  Future<void> attachHostListenersForNativeRun() async {
    _ensureBackendAuthority();
    final backend = _backend;
    final settled = _lifecycle.phase;
    if (!_lifecycle.launch.isHeld && _lifecycle.attachNativeRun()) {
      _logger.info(
        'A new native run is starting on an executor whose previous run '
        'settled as "${(settled as RunSettled).runStatus}"; releasing that '
        'run\'s terminal state so this one can finalize',
        source: 'SequenceExecutor',
      );
      _resetPerRunState();
    }
    await _nativeEventSubscription?.cancel();
    _nativeEventSubscription = backend.eventStream.listen(
      _events.handle,
      onError: (e) =>
          _logger.error('Event stream error: $e', source: 'SequenceExecutor'),
    );
  }

  /// The run's current [RunPhase].
  @visibleForTesting
  RunPhase get runPhaseForTest => _lifecycle.phase;

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

  /// Tear down everything the executor owns. A run retained in stopFailed /
  /// cleanupFailed never released its per-run resources, so dispose must
  /// cancel each of them itself.
  void dispose() {
    _disposed = true;
    _timers.dispose();
    _nativeEventSubscription?.cancel();
    _nativeEventSubscription = null;
    _runtimeConfig.dispose();
  }
}

/// A checkpoint restored by [SequenceExecutor.restoreFromCheckpoint] and not
/// yet started.
class _RestoredCheckpoint {
  _RestoredCheckpoint({
    required this.info,
    required this.snapshotJson,
    required this.sequence,
  });

  final CheckpointInfo info;
  final String? snapshotJson;

  /// The editor's sequence as the restore left it; null when none could be
  /// recovered.
  final Sequence? sequence;

  /// Whether [current] is still the restored tree. A save that only gives the
  /// sequence a database row keeps it the same tree; any edit to its nodes, or
  /// loading another sequence, does not.
  bool matches(Sequence? current) {
    final restored = sequence;
    if (restored == null || current == null) {
      return identical(restored, current);
    }
    return restored.id == current.id &&
        restored.rootNodeId == current.rootNodeId &&
        mapEquals(restored.nodes, current.nodes);
  }
}
