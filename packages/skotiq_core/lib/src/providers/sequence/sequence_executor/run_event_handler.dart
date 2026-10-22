import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../backend/bridge_events.dart' show depthGoalCompletedDetail;
import '../../../backend/skotiq_backend.dart';
import '../../../models/replay_decision.dart' show DecisionCategory;
import '../../../models/sequence/instruction_progress_detail.dart';
import '../../../models/sequence/sequence_models.dart';
import '../../../services/logging_service.dart';
import '../../../utils/remote_path.dart';
import '../../equipment_provider.dart';
import '../../focuser_backlash_provider.dart'
    show focuserBacklashOfferSessionProvider;
import '../../plugin_node_dispatcher.dart';
import '../../replay_debug_provider.dart';
import '../../sequence_provider.dart'
    show
        recordRunEventStopEvidence,
        sequenceExecutionStateProvider,
        sequenceProgressProvider,
        SequenceProgressNotifier,
        sequenceStopEvidenceProvider;
import '../../sequence_stats_provider.dart';
import '../../session_provider.dart';
import '../exposure_progress_vocabulary.dart';
import '../log_rate_limiter.dart';
import '../node_exposure_tally.dart';
import '../run_stop_classification.dart';
import '../sequencer_defaults.dart';
import '../sequencer_run_event.dart';
import '../target_end_when_notice.dart';
import 'eta_smoothing.dart';
import 'live_stacking_feed.dart';
import 'run_frame_recorder.dart';
import 'run_stats_ledger.dart';

/// Receives a terminal event's verdict; the executor's finalization claim.
typedef RunTerminalSink =
    void Function(
      SequenceExecutionState uiState,
      String runStatus, {
      String? error,
      String? warning,
    });

/// Applies each native sequencer event to the run: progress and node state,
/// run stats, frames, decisions, plugin dispatch. Events are decoded once
/// ([SequencerRunEvent]) and switched over by type. The run's lifecycle is not
/// decided here: lifecycle events go to [setExecutionState] and terminal
/// events to the executor's finalization through [onTerminal].
class RunEventHandler {
  RunEventHandler({
    required Ref ref,
    required SkotiqBackend backend,
    required RunStatsLedger stats,
    required RunFrameRecorder frames,
    required LiveStackingFeed liveStacking,
    required EtaSmoother eta,
    required LoggingService Function() logger,
    required void Function(String message, {bool persist}) warn,
    required void Function(SequenceExecutionState state) setExecutionState,
    required RunTerminalSink onTerminal,
  }) : _ref = ref,
       _backend = backend,
       _stats = stats,
       _frames = frames,
       _liveStacking = liveStacking,
       _eta = eta,
       _loggerFn = logger,
       _warn = warn,
       _setExecutionState = setExecutionState,
       _onTerminal = onTerminal;

  final Ref _ref;
  final SkotiqBackend _backend;
  final RunStatsLedger _stats;
  final RunFrameRecorder _frames;
  final LiveStackingFeed _liveStacking;
  final EtaSmoother _eta;
  final LoggingService Function() _loggerFn;
  final void Function(String message, {bool persist}) _warn;
  final void Function(SequenceExecutionState state) _setExecutionState;
  final RunTerminalSink _onTerminal;
  LoggingService get _logger => _loggerFn();

  /// Per-event-type rate limit on the debug trace, so a chatty type cannot
  /// fill the in-app log ring.
  final LogRateLimiter _eventTraceLimiter = LogRateLimiter(
    window: const Duration(seconds: 5),
  );

  void handle(SkotiqEvent raw) {
    // Rate-limited per event type, so a chatty type collapses while a rare one
    // is still traced the moment it arrives.
    final trace = _eventTraceLimiter.admit(
      '${raw.category.name}/${raw.eventType}',
      'Received event: type=${raw.eventType}, category=${raw.category}',
    );
    if (trace != null) {
      _logger.debug(trace, source: 'SequenceExecutor');
    }

    final event = SequencerRunEvent.fromSkotiqEvent(raw);
    if (event == null) return;

    // The one place a dither is counted: native reports each dither once,
    // whoever asked for it. It is a count, not node progress.
    if (event is DitherPerformed) {
      _stats.update((stats) => stats.recordDither());
      return;
    }

    applyRunEventToNodeExposureTally(
      _ref.read(nodeExposureTallyProvider.notifier),
      event,
    );
    // Authorship rows precede the cause-neutral cancel notice, so they are
    // folded as they arrive.
    recordRunEventStopEvidence(_ref.read, event);

    final progressNotifier = _ref.read(sequenceProgressProvider.notifier);
    switch (event) {
      case NodeStarted():
        _onNodeStarted(event, progressNotifier);
      case NodeCompleted():
        _onNodeCompleted(event, progressNotifier);
      case ExposureStarted():
        _onExposureStarted(event, progressNotifier);
      case ExposureCompleted():
        _onExposureCompleted(event, progressNotifier);
      case ExposureCountProgress(:final current, :final total):
        progressNotifier.updateProgress(
          completedExposures: current ?? 0,
          message: 'Progress: ${current ?? 0}/${total ?? 0} exposures',
        );
      case TargetChanged(:final targetName, :final ra, :final dec):
        progressNotifier.updateProgress(
          currentTarget: targetName,
          message: targetName != null ? 'Started target: $targetName' : null,
        );
        if (targetName != null && ra != null && dec != null) {
          _logger.debug(
            'Target changed: $targetName (RA=${ra.toStringAsFixed(4)}h, '
            'Dec=${dec.toStringAsFixed(4)}°)',
            source: 'SequenceExecutor',
          );
          _ref
              .read(sessionStateProvider.notifier)
              .updateTargetCoordinates(ra: ra, dec: dec);
        }
      case TargetCompleted(:final targetName):
        progressNotifier.updateProgress(
          message: 'Completed target: ${targetName ?? 'unknown'}',
        );
      case SequencerError():
        _onSequencerError(event, progressNotifier);
      case StructuredInstructionProgress():
        _onStructuredProgress(event, progressNotifier);
      case InstructionProgress():
        _onInstructionProgress(event, progressNotifier);
      case MeridianFlipOutcome():
        _handleMeridianFlipOutcome(event);
      case TriggerFired():
        _onTriggerFired(event, progressNotifier);
      case RunStarted():
        // A new run answers for itself: the previous run's stop cause must not
        // be read as this one's.
        _ref.read(sequenceStopEvidenceProvider.notifier).state = null;
        _setExecutionState(SequenceExecutionState.running);
      case RunPaused():
        _setExecutionState(SequenceExecutionState.paused);
      case RunResumed():
        _setExecutionState(SequenceExecutionState.running);
      case RunCompleted():
        _onTerminal(SequenceExecutionState.completed, 'completed');
      case RunFailed(:final error):
        _onTerminal(
          SequenceExecutionState.failed,
          'failed',
          error: error ?? 'Unknown error',
        );
      case RunStopped():
        _onNativeStopped();
      case FrameAccepted():
        _frames.recordGraded(event);
        _frames.register(event, grade: 'pass');
        _liveStacking.feed(event);
      case FrameRejected(:final rejectPath):
        _frames.recordGraded(event);
        // The folder rejects pile up in is what an operator opens after a
        // reject storm, so the run record names the grader's own directory.
        final rejectFolder = rejectPath == null
            ? null
            : parentDirectoryOf(rejectPath);
        if (rejectFolder != null) {
          _stats.update((stats) => stats.recordRejectFolder(rejectFolder));
        }
        _frames.register(event, grade: 'reject');
      case PluginNodeRequested():
        _dispatchPluginNode(event);
      case PluginNodeProgress(:final pluginId, :final nodeTypeId):
        _logger.debug(
          'PluginNodeProgress: ${pluginId ?? ''}/${nodeTypeId ?? ''} '
          '${event.detailJson ?? ''}',
          source: 'SequenceExecutor',
        );
      case DepthGoalCompleted():
        _persistDepthGoalDecision(event);
      case DecisionLogged():
        _persistReplayDecision(event);
      case DitherPerformed() || RunCancelled() || UnrecognizedSequencerEvent():
        break;
    }
  }

  void _onNodeStarted(
    NodeStarted event,
    SequenceProgressNotifier progressNotifier,
  ) {
    final nodeId = event.nodeId;
    if (nodeId != null) {
      progressNotifier.updateProgress(
        currentNodeId: nodeId,
        currentNodeName: event.nodeType,
        currentNodeStatus: NodeStatus.running,
      );
      progressNotifier.updateNodeStatus(nodeId, NodeStatus.running);
    }
    // Frame indices restart at 1 for every node, so a verdict an aborted burst
    // never completed must not survive into this node's frame 1.
    _frames.clearVerdicts();
  }

  void _onNodeCompleted(
    NodeCompleted event,
    SequenceProgressNotifier progressNotifier,
  ) {
    final nodeId = event.nodeId;
    if (nodeId == null) return;
    final status = event.status ?? 'failed';
    final nodeStatus = event.nodeStatus ?? NodeStatus.failure;
    progressNotifier.updateNodeStatus(nodeId, nodeStatus);
    // An autofocus is counted by what the node did (its structured progress
    // was an Autofocus detail), never by its operator-editable name.
    if (nodeStatus == NodeStatus.success && _nodeRanAutofocus(nodeId)) {
      _stats.update((stats) => stats.recordAutofocus());
      _noteAutofocusOutcomeForBacklashOffer();
    }
    // A status Dart has not learned yet reads as a failure; carry the raw
    // string so the red node explains itself.
    if (!NodeCompleted.knownStatuses.contains(status)) {
      _logger.warning(
        'NodeCompleted with unknown status "$status" for node '
        '$nodeId; treating as failure.',
        source: 'SequenceExecutor',
      );
      progressNotifier.updateNodeProgress(
        nodeId,
        0.0,
        'Unknown node status: "$status"',
      );
    }
  }

  void _onExposureStarted(
    ExposureStarted event,
    SequenceProgressNotifier progressNotifier,
  ) {
    final frame = event.frame ?? 0;
    final total = event.total ?? 0;
    final exposureDetail = formatExposureStartedDetail(
      frame,
      total,
      event.filter,
    );
    progressNotifier.updateProgress(
      message: 'Exposing $exposureDetail',
      currentFilter: event.filter,
    );
    final nodeId = _ref.read(sequenceProgressProvider).currentNodeId;
    if (nodeId != null && total > 0) {
      // frame - 1: this frame has only just started.
      progressNotifier.updateNodeProgress(
        nodeId,
        (frame - 1) / total * 100.0,
        exposureDetail,
      );
    }
  }

  void _onExposureCompleted(
    ExposureCompleted event,
    SequenceProgressNotifier progressNotifier,
  ) {
    final frame = event.frame ?? 0;
    final total = event.total ?? 1;
    final durationSecs = event.durationSecs ?? 0.0;
    // A graded frame was already counted and shown when its verdict arrived
    // (see [RunFrameRecorder]); an ungraded one (no save path, so no grader) is
    // counted here as accepted.
    final graded = _frames.takeVerdict(frame);
    if (!graded) {
      _frames.recordRunFrame(
        exposureSecs: durationSecs,
        filter: event.filter,
        accepted: true,
      );
    }
    // The ETA is fed shutter-open time plus a fixed download overhead, not the
    // wall clock between frames, so autofocus and slew stalls do not skew it.
    if (durationSecs > 0) {
      final defaults = _ref.read(sequencerDefaultsProvider);
      _eta.recordFrame(durationSecs + defaults.frameDownloadOverheadSecs);
    }
    progressNotifier.updateProgress(completedExposures: frame);
    // Keyed on the originating event: the DeviceService pump sees the same
    // event, and only one of the two may add its shutter time.
    progressNotifier.recordCompletedFrameIntegration(
      eventKey: '${event.timestamp}:$frame',
      durationSecs: durationSecs,
    );
    final nodeId = _ref.read(sequenceProgressProvider).currentNodeId;
    if (nodeId != null) {
      progressNotifier.updateNodeProgress(
        nodeId,
        total > 0 ? (frame / total * 100.0) : 100.0,
        formatExposureCompletedDetail(frame, total),
      );
    }
    if (!graded) {
      _frames.showPreview(_frames.previewSettingsFor(null, durationSecs));
    }
  }

  void _onSequencerError(
    SequencerError event,
    SequenceProgressNotifier progressNotifier,
  ) {
    final message = event.message ?? 'Unknown error';
    // An advisory shares the Error payload; it is a warning on the run, never
    // a fault on a node.
    if (event.isAdvisory) {
      _warn(message);
      progressNotifier.updateProgress(message: message);
      return;
    }
    // Older native executors acknowledged SkipToNode through Error. It is an
    // informational success.
    if (message.startsWith('SkipToNode request accepted:')) {
      progressNotifier.updateProgress(message: message);
      return;
    }
    // Every cancellation path emits the same notice, so it is a stop whose
    // cause comes from the run's authorship rows, not an error.
    if (isSequenceCancelledNotice(message)) {
      final stopped = sequenceStoppedMessage(
        _ref.read(sequenceStopEvidenceProvider),
      );
      _logger.info(
        '[$kStopClassificationLogTag] sequence_executor: cancellation '
        'notice treated as a stop, not an error ($stopped)',
        source: 'SequenceExecutor',
      );
      progressNotifier.updateProgress(message: stopped);
      return;
    }
    recordRunError(message);
    progressNotifier.updateProgress(message: 'Error: $message');
    final nodeId = _ref.read(sequenceProgressProvider).currentNodeId;
    if (nodeId != null) {
      progressNotifier.updateNodeProgress(nodeId, 0.0, 'Error: $message');
    }
    _escalateRunningToRecovering();
  }

  /// A mid-run fault is not terminal (recovery may still salvage the run), but
  /// a healthy `running` would be a lie, so `running` alone moves to
  /// `recovering`; the terminal event settles it later.
  void _escalateRunningToRecovering() {
    if (_ref.read(sequenceExecutionStateProvider) ==
        SequenceExecutionState.running) {
      _setExecutionState(SequenceExecutionState.recovering);
    }
  }

  void _onStructuredProgress(
    StructuredInstructionProgress event,
    SequenceProgressNotifier progressNotifier,
  ) {
    // A Change Filter instruction is the only place the running filter is
    // named when the exposure node itself has none.
    final filterName = event.changedFilterName;
    if (filterName != null) {
      progressNotifier.updateProgress(currentFilter: filterName);
    }
    final nodeId =
        event.nodeId ?? _ref.read(sequenceProgressProvider).currentNodeId;
    if (nodeId != null) {
      progressNotifier.updateNodeStructuredProgress(
        nodeId,
        event.progressPercent ?? 0.0,
        event.detail,
      );
      progressNotifier.updateProgress(
        message: '${event.instruction ?? ''}: ${event.detailKind}',
      );
    }
  }

  void _onInstructionProgress(
    InstructionProgress event,
    SequenceProgressNotifier progressNotifier,
  ) {
    final instruction = event.instruction ?? '';
    final percent = event.progressPercent ?? 0.0;
    final detail = event.detail ?? '';
    _logger.debug(
      'InstructionProgress: nodeId=${event.nodeId}, instruction=$instruction, '
      'progress=$percent%, detail=$detail',
      source: 'SequenceExecutor',
    );
    final nodeId =
        event.nodeId ?? _ref.read(sequenceProgressProvider).currentNodeId;
    _logger.debug(
      'Updating node progress for: $nodeId',
      source: 'SequenceExecutor',
    );
    if (nodeId != null) {
      progressNotifier.updateNodeProgress(nodeId, percent, detail);
      progressNotifier.updateProgress(message: '$instruction: $detail');
    }
  }

  void _onTriggerFired(
    TriggerFired event,
    SequenceProgressNotifier progressNotifier,
  ) {
    final triggerName = event.triggerName ?? 'Unknown trigger';
    final action = event.action ?? '';
    _stats.update((stats) => stats.recordTriggerFire());
    // A target dropped by its own end_when costs the operator a whole target,
    // so it goes on the run record, not only into the trigger feed.
    if (isTargetEndWhenSkip(event.triggerId ?? '')) {
      final warning = targetEndWhenSkipWarning(triggerName);
      _logger.warning(warning, source: 'SequenceExecutor');
      _stats.update((stats) => stats.recordWarning(warning));
      progressNotifier.updateProgress(message: warning);
      return;
    }
    _logger.info(
      'Trigger fired: $triggerName -> $action',
      source: 'SequenceExecutor',
    );
    progressNotifier.updateProgress(
      message: 'Trigger "$triggerName" fired: $action',
    );
  }

  /// A native `Stopped` this executor did not command came from the native
  /// side (a trigger's park, a watchdog, a safety abort) and is filed
  /// `aborted`; only a stop the wire attributes to the operator stays
  /// `stopped`. The echo of this executor's own stop() is swallowed by the
  /// finalization it already claimed.
  void _onNativeStopped() {
    final stopEvidence = _ref.read(sequenceStopEvidenceProvider);
    final operatorStopped =
        stopEvidence?.author == SequenceStopAuthor.operatorPress;
    _onTerminal(
      SequenceExecutionState.idle,
      operatorStopped ? 'stopped' : 'aborted',
      warning: operatorStopped || stopEvidence == null
          ? null
          : sequenceStoppedMessage(stopEvidence),
    );
  }

  /// Persist a `DepthGoalCompleted` payload as a `budget_met` decision row.
  ///
  /// `budget_met` rather than a category of its own: a depth goal IS the
  /// budget for a plan bound to one, and the replay feed already renders that
  /// bucket as "the plan stopped because it had enough". Fire-and-forget for
  /// the same reason as [_persistReplayDecision] — the executor's event loop
  /// must keep pumping.
  void _persistDepthGoalDecision(DepthGoalCompleted event) {
    final runId = _ref.read(currentRunIdProvider);
    if (runId == null) {
      _logger.debug(
        'DepthGoalCompleted dropped: no active sequence_run_id '
        '(goal ${event.goalId})',
        source: 'SequenceExecutor',
      );
      return;
    }
    final filterName = event.filterName ?? '';
    final score = event.score ?? 0;
    final threshold = event.threshold ?? 0;
    final evidenceFrames = event.evidenceFrames ?? 0;
    final confirmationFrames = event.confirmationFrames ?? 0;
    final summary = depthGoalCompletedDetail(
      filterName: filterName,
      score: score,
      threshold: threshold,
      evidenceFrames: evidenceFrames,
      confirmationFrames: confirmationFrames,
    );
    _logger.info(summary, source: 'SequenceExecutor');
    final service = _ref.read(replayDebugServiceProvider);
    unawaited(
      service
          .persistFromBridgeEvent(
            timestampIso: DateTime.fromMillisecondsSinceEpoch(
              event.timestamp,
            ).toUtc().toIso8601String(),
            categoryWireKey: DecisionCategory.budgetMet.wireKey,
            summary: summary,
            detailsJson: jsonEncode({
              'goal_id': event.goalId,
              'revision': event.revision,
              'filter_name': filterName,
              'score': score,
              'threshold': threshold,
              'evidence_frames': evidenceFrames,
              'confirmation_frames': confirmationFrames,
            }),
            nodeId: event.nodeId,
            sequenceRunId: runId,
          )
          .catchError((Object e, StackTrace st) {
            _logger.warning(
              'Failed to persist depth-goal decision ($summary): $e',
              source: 'SequenceExecutor',
            );
            return -1;
          }),
    );
  }

  /// Replay Debug — persist a `DecisionLogged` payload into
  /// the `sequence_decisions` table via the [ReplayDebugService].
  /// `unawaited` because the executor's event loop must keep pumping;
  /// the service handles its own change-notification, and a write
  /// failure is logged at warn-level (loud-fail policy without
  /// taking the executor down).
  void _persistReplayDecision(DecisionLogged event) {
    final timestampIso = event.timestampIso ?? '';
    final category = event.category ?? '';
    final summary = event.summary ?? '';
    final detailsJson = event.detailsJson ?? '{}';
    final nodeId = event.nodeId;
    final rustRunId = event.sequenceRunId;
    final effectiveRunId = rustRunId ?? _ref.read(currentRunIdProvider);
    if (effectiveRunId == null) {
      // No active run id — the very first lifecycle "Sequence started"
      // decision falls into this window before the Dart row insert
      // completes. We intentionally drop these so the replay log never
      // has dangling rows that can't be joined back to a run.
      _logger.debug(
        'DecisionLogged dropped: no active sequence_run_id '
        '($category: $summary)',
        source: 'SequenceExecutor',
      );
      return;
    }
    final service = _ref.read(replayDebugServiceProvider);
    unawaited(
      service
          .persistFromBridgeEvent(
            timestampIso: timestampIso,
            categoryWireKey: category,
            summary: summary,
            detailsJson: detailsJson,
            nodeId: nodeId,
            sequenceRunId: effectiveRunId,
          )
          .catchError((Object e, StackTrace st) {
            _logger.warning(
              'Failed to persist replay decision ($category: $summary): $e',
              source: 'SequenceExecutor',
            );
            return -1;
          }),
    );
  }

  /// Run a `PluginNodeRequested` through the configured dispatcher and post
  /// the verdict back. A dispatcher that throws still yields a failure
  /// verdict, so the native node unblocks instead of waiting out its timeout.
  /// Fire-and-forget, so other events keep flowing.
  void _dispatchPluginNode(PluginNodeRequested event) {
    final nodeId = event.nodeId ?? '';
    final pluginId = event.pluginId ?? '';
    final nodeTypeId = event.nodeTypeId ?? '';
    final configJson = event.configJson ?? '';
    final displayName = event.displayName;
    final timeoutSecs = event.timeoutSecs ?? 600;

    if (nodeId.isEmpty) {
      _logger.warning(
        'PluginNodeRequested event missing node_id; cannot dispatch '
        '(plugin=$pluginId, node_type=$nodeTypeId)',
        source: 'SequenceExecutor',
      );
      return;
    }

    final backend = _backend;
    if (!backend.dispatchPluginNodesLocally) {
      _logger.debug(
        'PluginNodeRequested ignored locally because the backend '
        'delegates plugin dispatch to the remote host '
        '(plugin=$pluginId, node_type=$nodeTypeId, node_id=$nodeId)',
        source: 'SequenceExecutor',
      );
      return;
    }

    final coordinator = _ref.read(pluginNodeDispatchCoordinatorProvider);
    if (!coordinator.claim(nodeId)) {
      _logger.debug(
        'PluginNodeRequested ignored because another local listener is '
        'already dispatching node_id=$nodeId',
        source: 'SequenceExecutor',
      );
      return;
    }
    final dispatcher = _ref.read(pluginNodeDispatcherProvider);

    unawaited(() async {
      late PluginNodeDispatchResult result;
      try {
        result = await dispatcher(
          PluginNodeDispatchRequest(
            nodeId: nodeId,
            pluginId: pluginId,
            nodeTypeId: nodeTypeId,
            configJson: configJson,
            displayName: displayName,
            timeoutSecs: timeoutSecs,
          ),
        );
      } catch (e, st) {
        _logger.error(
          'Plugin node dispatcher threw for $pluginId/$nodeTypeId '
          '(node_id=$nodeId): $e\n$st',
          source: 'SequenceExecutor',
        );
        result = PluginNodeDispatchResult(
          success: false,
          message: 'dispatcher threw: $e',
        );
      }

      try {
        await backend.sequencerPluginNodeFinished(
          nodeId: nodeId,
          success: result.success,
          message: result.message,
          structuredDetailJson: result.structuredDetailJson,
        );
      } catch (e, st) {
        // The reply itself failed. The Rust executor will time out
        // the node at the configured timeout and surface its own
        // error — but we log loudly here so the operator sees the
        // cause-of-cause.
        _logger.error(
          'Failed to deliver plugin node verdict for $pluginId/$nodeTypeId '
          '(node_id=$nodeId): $e\n$st',
          source: 'SequenceExecutor',
        );
      } finally {
        coordinator.release(nodeId);
      }
    }());
  }

  /// Whether the node identified by [nodeId] ran an autofocus sweep, judged by
  /// its most recent structured progress payload.
  ///
  /// `ProgressDetail::Autofocus` reaches Dart as an
  /// [UnknownInstructionProgressDetail] with `kind == 'Autofocus'` (only
  /// `Exposure` has a typed Dart counterpart today), and it is emitted by the
  /// autofocus instruction alone — both for a tree `Autofocus` node and for a
  /// trigger-fired refocus, which the executor publishes under the synthetic
  /// node id `trigger:<id>:autofocus`.
  bool _nodeRanAutofocus(String nodeId) {
    final detail = _ref
        .read(sequenceProgressProvider)
        .nodeProgressStructuredDetail[nodeId];
    return detail is UnknownInstructionProgressDetail &&
        detail.kind == 'Autofocus';
  }

  /// Put a mid-run fault on the run record and offer backlash calibration
  /// when it is an autofocus landing failure.
  void recordRunError(String message) {
    _stats.update((stats) => stats.recordError(message));
    _noteAutofocusOutcomeForBacklashOffer(failureMessage: message);
  }

  /// Feed an autofocus verdict to the backlash-calibration offer.
  ///
  /// This is the only place Dart sees a sequencer instruction's failure text,
  /// and the landing-verification failure — autofocus moved to the fitted
  /// position and the frame taken there disagreed — is the one that points at
  /// an uncalibrated gear train. The offer itself matches the message; every
  /// other error passes through it unchanged.
  void _noteAutofocusOutcomeForBacklashOffer({String? failureMessage}) {
    final focuserId = _ref.read(focuserStateProvider).deviceId;
    if (focuserId == null || focuserId.isEmpty) return;
    _ref
        .read(focuserBacklashOfferSessionProvider.notifier)
        .noteAutofocusOutcome(
          focuserId: focuserId,
          failureMessage: failureMessage,
        );
  }

  /// Record a meridian flip's verdict on the run record:
  ///  * clean success (one attempt, no failed steps) -> count it, nothing more;
  ///  * degraded success (the retry ladder ran but the flip eventually worked)
  ///    -> count it AND warn, because a recenter that needed retries means the
  ///    framing should be eyeballed before trusting the sub-frames;
  ///  * failed / aborted -> do NOT count it (no flip happened) and record an
  ///    error/warning so the session report cannot claim a clean night.
  void _handleMeridianFlipOutcome(MeridianFlipOutcome event) {
    final progressNotifier = _ref.read(sequenceProgressProvider.notifier);
    final outcome = event.outcome ?? 'unknown';
    final targetName = event.targetName ?? 'target';
    final attempts = event.attempts ?? 0;
    final durationSecs = event.durationSecs ?? 0;
    final error = event.error;
    final actionTaken = event.actionTaken;
    final failedSteps = event.failedSteps;

    switch (outcome) {
      case 'success':
        _stats.update((stats) => stats.recordMeridianFlip());
        if (failedSteps.isEmpty) {
          final message =
              'Meridian flip for "$targetName" completed in '
              '${durationSecs.toStringAsFixed(1)}s';
          _logger.info(message, source: 'SequenceExecutor');
          progressNotifier.updateProgress(message: message);
        } else {
          final message =
              'Meridian flip for "$targetName" succeeded only on attempt '
              '$attempts after ${failedSteps.length} failed '
              'attempt${failedSteps.length == 1 ? '' : 's'}: '
              '${failedSteps.join("; ")}. Verify framing — the post-flip '
              'recentre needed retries.';
          _logger.warning(message, source: 'SequenceExecutor');
          _stats.update((stats) => stats.recordWarning(message));
          progressNotifier.updateProgress(message: message);
        }
        break;

      case 'aborted':
        final message =
            'Meridian flip for "$targetName" was aborted after $attempts '
            'attempt${attempts == 1 ? "" : "s"}'
            '${error != null ? ": $error" : ""}. The mount was NOT '
            'flipped.';
        _logger.warning(message, source: 'SequenceExecutor');
        _stats.update((stats) => stats.recordWarning(message));
        progressNotifier.updateProgress(message: message);
        break;

      default:
        final message =
            'Meridian flip for "$targetName" FAILED after $attempts '
            'attempt${attempts == 1 ? "" : "s"}: ${error ?? "unknown error"}'
            '${actionTaken != null ? " (action: $actionTaken)" : ""}. '
            'Frames captured after this point may be mis-framed.';
        _logger.error(message, source: 'SequenceExecutor');
        recordRunError(message);
        progressNotifier.updateProgress(message: message);
        // Same escalation the generic Error handler performs: a failed flip
        // may have left the rig mis-framed or slewing, so the run must not go
        // on claiming a healthy `running` state — the dashboard shows
        // needs-attention until the authoritative terminal event lands.
        _escalateRunningToRecovering();
        break;
    }
  }
}
