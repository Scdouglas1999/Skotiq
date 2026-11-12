import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/remote_host.dart';
import '../../models/backend/sequencer_status.dart' show CheckpointInfo;
import '../../models/sequence/instruction_progress_detail.dart';
import '../../models/sequence/sequence_models.dart';
import '../backend_provider.dart';
import '../runtime_mirror/channels/run_record_channel.dart'
    show runRecordChannelKey;
import '../runtime_mirror/client_runtime_mirror.dart';
import '../sequence_stats_provider.dart'
    show CompletedImagingRun, SequenceRunStats, SequenceTerminalRunResult;
import 'last_ended_run.dart' show LastEndedRun;
import 'node_exposure_tally.dart' show NodeExposureTally;
import 'run_stop_classification.dart' show SequenceStopDecision;
import 'sequence_selection.dart' show currentSequenceProvider;

const Object _keep = Object();

/// Everything the app knows about the sequence run: the one under way, or the
/// last one, on the imaging host.
///
/// One value with one writer, [RunRecordNotifier]. On the host it is written
/// from the run's event stream and by the executor's own transaction steps; on
/// a linked client by the mirror of the host's record. Everything else reads a
/// narrow view of it (`sequenceExecutionStateProvider`,
/// `sequenceProgressProvider`, `nodeExposureTallyProvider` and the rest), each
/// a `select` of one field.
@immutable
class RunRecord {
  const RunRecord({
    this.lifecycle = SequenceExecutionState.idle,
    this.launching = false,
    this.progress = const SequenceProgress(),
    this.tally = const {},
    this.framesDoneBeforeRun = const {},
    this.restoredCheckpoint,
    this.runId,
    this.stats,
    this.stopEvidence,
    this.startedAt,
    this.lastEnded,
    this.terminal,
    this.terminalFromHost = false,
    this.completedImagingRun,
  });

  /// Where the run stands. The only lifecycle value; [progress] carries a copy
  /// in its `state` for the surfaces that show progress.
  final SequenceExecutionState lifecycle;

  /// A start or checkpoint restore is being admitted. The lifecycle can still
  /// read idle then, while settings and pre-flight are awaited.
  final bool launching;

  /// Counters, the current step and per-step status. `progress.state` is the
  /// phase the progress surfaces show: [lifecycle], except while a recovery is
  /// in flight, when it is the recovery's phase.
  final SequenceProgress progress;

  /// Frames captured and planned per exposure step, by node id.
  final Map<String, NodeExposureTally> tally;

  /// Frames each exposure step had before this run, by node id: the
  /// checkpoint's counts when the run continues one, empty for a fresh run.
  final Map<String, int> framesDoneBeforeRun;

  /// The checkpoint a restore prepared and the next Start will continue.
  final CheckpointInfo? restoredCheckpoint;

  /// The `sequence_runs` row of the run the local executor owns; null on a
  /// linked client and between runs.
  final int? runId;

  /// The run's live statistics; kept after the run ends for the report.
  final SequenceRunStats? stats;

  /// Who ended the run, as the last authorship row on the wire named them.
  final SequenceStopDecision? stopEvidence;

  /// When the current or last run started, as the host saw it.
  final DateTime? startedAt;

  /// The last run that ended this session; cleared when the next one starts.
  final LastEndedRun? lastEnded;

  /// The last fully finalized run: how it ended and the ids it owned. On a
  /// linked client it is the host's ([terminalFromHost]).
  final SequenceTerminalRunResult? terminal;

  /// [terminal] came from the host's record rather than from a run this app
  /// finalized, so nothing here must react to it as to its own run ending.
  final bool terminalFromHost;

  /// The last imaging run, kept when a calibration run replaces the live one.
  final CompletedImagingRun? completedImagingRun;

  RunRecord copyWith({
    SequenceExecutionState? lifecycle,
    bool? launching,
    SequenceProgress? progress,
    Map<String, NodeExposureTally>? tally,
    Map<String, int>? framesDoneBeforeRun,
    Object? restoredCheckpoint = _keep,
    Object? runId = _keep,
    Object? stats = _keep,
    Object? stopEvidence = _keep,
    Object? startedAt = _keep,
    Object? lastEnded = _keep,
    Object? terminal = _keep,
    bool? terminalFromHost,
    Object? completedImagingRun = _keep,
  }) {
    T? pick<T>(Object? value, T? current) =>
        identical(value, _keep) ? current : value as T?;
    return RunRecord(
      lifecycle: lifecycle ?? this.lifecycle,
      launching: launching ?? this.launching,
      progress: progress ?? this.progress,
      tally: tally ?? this.tally,
      framesDoneBeforeRun: framesDoneBeforeRun ?? this.framesDoneBeforeRun,
      restoredCheckpoint: pick(restoredCheckpoint, this.restoredCheckpoint),
      runId: pick(runId, this.runId),
      stats: pick(stats, this.stats),
      stopEvidence: pick(stopEvidence, this.stopEvidence),
      startedAt: pick(startedAt, this.startedAt),
      lastEnded: pick(lastEnded, this.lastEnded),
      terminal: pick(terminal, this.terminal),
      terminalFromHost: terminalFromHost ?? this.terminalFromHost,
      completedImagingRun: pick(completedImagingRun, this.completedImagingRun),
    );
  }
}

bool _isLive(SequenceExecutionState state) => switch (state) {
  SequenceExecutionState.running ||
  SequenceExecutionState.paused ||
  SequenceExecutionState.recovering ||
  SequenceExecutionState.stopping ||
  SequenceExecutionState.finalizing => true,
  _ => false,
};

final runRecordProvider = StateNotifierProvider<RunRecordNotifier, RunRecord>(
  RunRecordNotifier.new,
);

/// The writer of [RunRecord]. Callers: `SequenceExecutor` and the event fold
/// on the host; the remote-sync mirror and the runtime-mirror channels on a
/// linked client. Nothing else writes run state.
class RunRecordNotifier extends StateNotifier<RunRecord> {
  /// [_ref] is absent only for a notifier a test builds on its own.
  RunRecordNotifier([this._ref]) : super(const RunRecord());

  final Ref? _ref;

  /// Seed the record in a test.
  @visibleForTesting
  void seed(RunRecord Function(RunRecord record) change) =>
      state = change(state);

  // Lifecycle.

  /// Move the run to [next]. The progress phase moves with it, and a
  /// transition into or out of a live state stamps when the run started or
  /// which plan just ended.
  ///
  /// A stopped or dawn-ended run settles in the same `idle` as a plan that
  /// never ran; `lastEnded` is what tells them apart, so the night keeps its
  /// results until the next start.
  void setLifecycle(SequenceExecutionState next) {
    final previous = state.lifecycle;
    var record = state.copyWith(
      lifecycle: next,
      progress: state.progress.state == next
          ? null
          : state.progress.copyWith(state: next),
    );
    // A linked client that has the host's record follows it; the host saw
    // the run start and end, this client may not have.
    final ref = _ref;
    if (previous != next && ref != null && !_followsHostRecord(ref)) {
      if (_isLive(next) && !_isLive(previous)) {
        record = record.copyWith(lastEnded: null, startedAt: DateTime.now());
      } else if (_isLive(previous) && next.canStart) {
        final sequenceId = ref.read(currentSequenceProvider)?.id;
        if (sequenceId != null) {
          record = record.copyWith(
            lastEnded: LastEndedRun(
              sequenceId: sequenceId,
              endedAt: DateTime.now(),
            ),
          );
        }
      }
    }
    state = record;
  }

  bool _followsHostRecord(Ref ref) =>
      ref.read(backendProvider).remoteHost != null &&
      ref
          .read(clientRuntimeMirrorStateProvider)
          .hasApplied(runRecordChannelKey);

  /// Show [phase] on the progress surfaces without moving the lifecycle: a
  /// recovery in flight, whose start and end the executor does not decide.
  void showPhase(SequenceExecutionState phase) {
    if (state.progress.state == phase) return;
    state = state.copyWith(progress: state.progress.copyWith(state: phase));
  }

  void setLaunching(bool launching) {
    if (state.launching == launching) return;
    state = state.copyWith(launching: launching);
  }

  /// Forget the outgoing host's progress when the imaging host changes.
  void resetForHostChange() {
    resetProgress();
    setLifecycle(SequenceExecutionState.idle);
  }

  // Progress.

  // A null argument leaves the field alone, so the next `SequenceProgress` is
  // rebuilt explicitly: the generated copyWith reads null as "clear" on a
  // nullable field.
  void updateProgress({
    String? currentNodeId,
    String? currentNodeName,
    NodeStatus? currentNodeStatus,
    int? completedExposures,
    double? completedIntegrationSecs,
    double? elapsedSecs,
    double? estimatedRemainingSecs,
    String? currentTarget,
    String? currentFilter,
    String? message,
  }) {
    final current = state.progress;
    _setProgress(
      SequenceProgress(
        state: current.state,
        currentNodeId: currentNodeId ?? current.currentNodeId,
        currentNodeName: currentNodeName ?? current.currentNodeName,
        currentNodeStatus: currentNodeStatus ?? current.currentNodeStatus,
        totalExposures: current.totalExposures,
        completedExposures: completedExposures ?? current.completedExposures,
        totalIntegrationSecs: current.totalIntegrationSecs,
        completedIntegrationSecs:
            completedIntegrationSecs ?? current.completedIntegrationSecs,
        elapsedSecs: elapsedSecs ?? current.elapsedSecs,
        estimatedRemainingSecs:
            estimatedRemainingSecs ?? current.estimatedRemainingSecs,
        currentTarget: currentTarget ?? current.currentTarget,
        currentFilter: currentFilter ?? current.currentFilter,
        message: message ?? current.message,
        nodeStatuses: current.nodeStatuses,
        nodeProgressPercent: current.nodeProgressPercent,
        nodeProgressDetail: current.nodeProgressDetail,
        nodeProgressStructuredDetail: current.nodeProgressStructuredDetail,
      ),
    );
  }

  void updateNodeStatus(String nodeId, NodeStatus status) {
    _setProgress(
      state.progress.copyWith(
        nodeStatuses: {...state.progress.nodeStatuses, nodeId: status},
      ),
    );
  }

  void updateNodeProgress(
    String nodeId,
    double progressPercent,
    String detail,
  ) {
    final progress = state.progress;
    _setProgress(
      progress.copyWith(
        nodeProgressPercent: {
          ...progress.nodeProgressPercent,
          nodeId: progressPercent,
        },
        nodeProgressDetail: {...progress.nodeProgressDetail, nodeId: detail},
      ),
    );
  }

  void updateNodeStructuredProgress(
    String nodeId,
    double progressPercent,
    InstructionProgressDetail detail,
  ) {
    final progress = state.progress;
    _setProgress(
      progress.copyWith(
        nodeProgressPercent: {
          ...progress.nodeProgressPercent,
          nodeId: progressPercent,
        },
        nodeProgressStructuredDetail: {
          ...progress.nodeProgressStructuredDetail,
          nodeId: detail,
        },
      ),
    );
  }

  /// Set the run's denominators. [totalIntegrationSecs] is passed only when a
  /// real value is known: the native `Progress` event carries a frame count
  /// and no integration total, and its absent value must not replace the total
  /// the executor seeded from the sequence at start.
  void setTotals(int totalExposures, [double? totalIntegrationSecs]) {
    _setProgress(
      state.progress.copyWith(
        totalExposures: totalExposures,
        totalIntegrationSecs:
            totalIntegrationSecs ?? state.progress.totalIntegrationSecs,
      ),
    );
  }

  String? _lastIntegrationEventKey;

  /// Add one completed frame's shutter time to the run's integration total,
  /// once per event: [eventKey] names the event, so a second subscriber
  /// handling the same one adds nothing.
  void recordCompletedFrameIntegration({
    required String eventKey,
    required double durationSecs,
  }) {
    if (_lastIntegrationEventKey == eventKey) return;
    _lastIntegrationEventKey = eventKey;
    _setProgress(
      state.progress.copyWith(
        completedIntegrationSecs:
            state.progress.completedIntegrationSecs + durationSecs,
      ),
    );
  }

  /// Clear the run's progress. The lifecycle is left alone; `progress.state`
  /// reads idle until the next lifecycle write.
  void resetProgress() {
    _lastIntegrationEventKey = null;
    _setProgress(const SequenceProgress());
  }

  void _setProgress(SequenceProgress progress) =>
      state = state.copyWith(progress: progress);

  // Per-step frame tally.

  /// A fresh pass over [nodeId]: a loop's next iteration, or a new run. The
  /// previous pass's frames are no longer this step's.
  void startNode(String nodeId) {
    if (!state.tally.containsKey(nodeId)) return;
    state = state.copyWith(tally: {...state.tally}..remove(nodeId));
  }

  /// Record that [nodeId] has captured [captured] of [planned] frames.
  ///
  /// Monotonic within a pass: an out-of-order or repeated sighting must never
  /// walk the count backwards.
  ///
  /// [nodeId] must be the id the event named. `ExposureStarted` and
  /// `ExposureCompleted` carry no node id, and at a burst boundary the current
  /// node has already advanced to the next one, so crediting the current node
  /// would join by position with the right id sitting in the other event.
  void recordFrames(
    String nodeId, {
    required int captured,
    required int planned,
  }) {
    if (nodeId.isEmpty || captured < 0 || planned <= 0) return;
    final current = state.tally[nodeId];
    final nextCaptured = current == null || captured > current.captured
        ? captured
        : current.captured;
    if (current != null &&
        current.captured == nextCaptured &&
        current.planned == planned) {
      return;
    }
    state = state.copyWith(
      tally: {
        ...state.tally,
        nodeId: NodeExposureTally(captured: nextCaptured, planned: planned),
      },
    );
  }

  void resetTally() {
    if (state.tally.isEmpty) return;
    state = state.copyWith(tally: const {});
  }

  // The executor's run transaction.

  void setFramesDoneBeforeRun(Map<String, int> frames) =>
      state = state.copyWith(framesDoneBeforeRun: frames);

  void setRestoredCheckpoint(CheckpointInfo? info) =>
      state = state.copyWith(restoredCheckpoint: info);

  void setRunId(int? runId) => state = state.copyWith(runId: runId);

  void setStats(SequenceRunStats? stats) =>
      state = state.copyWith(stats: stats);

  /// Name who ended the run, or clear it (null) when a run starts, so one
  /// night's cause is never attached to the next one's stop.
  void setStopEvidence(SequenceStopDecision? decision) =>
      state = state.copyWith(stopEvidence: decision);

  /// Publish the result of a run this app finalized, or clear it (null) when
  /// the next run starts, so its end is seen as a change from nothing.
  void publishTerminal(SequenceTerminalRunResult? result) =>
      state = state.copyWith(terminal: result, terminalFromHost: false);

  void setCompletedImagingRun(CompletedImagingRun? run) =>
      state = state.copyWith(completedImagingRun: run);

  // The mirror of the host's record, on a linked client.

  /// Show the host's run progress. The lifecycle phase is kept: lifecycle
  /// events drive that. So is the structured per-step detail, which the wire
  /// does not carry.
  void mirrorHostProgress(SequenceProgress hostProgress) {
    _setProgress(
      hostProgress.copyWith(
        state: state.progress.state,
        nodeProgressStructuredDetail:
            state.progress.nodeProgressStructuredDetail,
      ),
    );
  }

  void mirrorHostTally(Map<String, NodeExposureTally> hostTally) =>
      state = state.copyWith(
        tally: Map<String, NodeExposureTally>.unmodifiable(hostTally),
      );

  /// Show what the host remembers of the run that ended.
  void mirrorHostRunRecord({
    required SequenceTerminalRunResult? terminal,
    required CompletedImagingRun? completedImagingRun,
    required LastEndedRun? lastEnded,
    required DateTime? startedAt,
  }) {
    state = state.copyWith(
      terminal: terminal,
      terminalFromHost: true,
      completedImagingRun: completedImagingRun,
      lastEnded: lastEnded,
      startedAt: startedAt,
    );
  }
}
