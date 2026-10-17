import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/backend/event_types.dart';
import '../../models/sequence/instruction_progress_detail.dart';
import '../../models/sequence/sequence_models.dart';
import '../backend_provider.dart';
import '../equipment/camera_state_provider.dart';
import '../sequence_stats_provider.dart' show currentRunIdProvider;
import 'node_exposure_tally.dart';
import 'run_stop_classification.dart';

// Execution state.

/// Current sequence execution state
final sequenceExecutionStateProvider = StateProvider<SequenceExecutionState>((
  ref,
) {
  return SequenceExecutionState.idle;
});

/// Whether the executor is driving simulated device ops.
///
/// Reports what the executor holds rather than what anyone asked for — the
/// backend records simulation only once the call installing simulated ops has
/// returned — so a badge fed from here cannot claim simulated hardware while
/// real mounts and cameras are under the run. Recomputed on every execution
/// state transition, which is when a run installs or tears down its ops.
///
/// A backend with no reading of the flag (remote) answers `false`, and a
/// disconnected backend throws; both leave the value falsy for a consumer
/// reading `.valueOrNull ?? false`, so an unreadable flag makes no claim
/// rather than a wrong one.
final executorSimulationModeProvider = FutureProvider<bool>((ref) async {
  ref.watch(sequenceExecutionStateProvider);
  return ref.watch(backendProvider).sequencerIsSimulationMode();
});

/// True while a start or checkpoint-resume transaction is still being
/// admitted. During this window the execution state may legitimately remain
/// idle while settings and preflight validation are awaited, so backend swaps
/// must consult this latch as well as [sequenceExecutionStateProvider].
final sequenceLaunchInFlightProvider = StateProvider<bool>((ref) => false);

/// Current sequence progress
final sequenceProgressProvider =
    StateNotifierProvider<SequenceProgressNotifier, SequenceProgress>((ref) {
      return SequenceProgressNotifier();
    });

class SequenceProgressNotifier extends StateNotifier<SequenceProgress> {
  SequenceProgressNotifier() : super(const SequenceProgress());

  void updateState(SequenceExecutionState executionState) {
    state = state.copyWith(state: executionState);
  }

  // `updateProgress` means "a null argument leaves the field alone". The next
  // `SequenceProgress` is therefore rebuilt explicitly rather than through
  // `copyWith`: a generated copyWith treats `null` per field-nullability — a
  // compile error on non-null fields, "clear" on nullable ones — and neither
  // is the omit semantic every caller here relies on.
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
    final current = state;
    state = SequenceProgress(
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
    );
  }

  void updateNodeStatus(String nodeId, NodeStatus status) {
    final newStatuses = Map<String, NodeStatus>.from(state.nodeStatuses);
    newStatuses[nodeId] = status;
    state = state.copyWith(nodeStatuses: newStatuses);
  }

  void updateNodeProgress(
    String nodeId,
    double progressPercent,
    String detail,
  ) {
    final newProgressPercent = Map<String, double>.from(
      state.nodeProgressPercent,
    );
    final newProgressDetail = Map<String, String>.from(
      state.nodeProgressDetail,
    );

    newProgressPercent[nodeId] = progressPercent;
    newProgressDetail[nodeId] = detail;

    state = state.copyWith(
      nodeProgressPercent: newProgressPercent,
      nodeProgressDetail: newProgressDetail,
    );
  }

  void updateNodeStructuredProgress(
    String nodeId,
    double progressPercent,
    InstructionProgressDetail detail,
  ) {
    final newProgressPercent = Map<String, double>.from(
      state.nodeProgressPercent,
    );
    final newStructuredDetail = Map<String, InstructionProgressDetail>.from(
      state.nodeProgressStructuredDetail,
    );

    newProgressPercent[nodeId] = progressPercent;
    newStructuredDetail[nodeId] = detail;

    state = state.copyWith(
      nodeProgressPercent: newProgressPercent,
      nodeProgressStructuredDetail: newStructuredDetail,
    );
  }

  /// Set the run's denominators. [totalIntegrationSecs] is optional: pass it
  /// only when a real value is known, otherwise the existing one is kept.
  ///
  /// It is optional because the native `Progress` event carries a frame count
  /// but no integration total: passing its absent value as `0` would clobber,
  /// roughly once a second, the real total
  /// [SequenceExecutor._acquireAndStartRun] seeded from the sequence at start.
  void setTotals(int totalExposures, [double? totalIntegrationSecs]) {
    state = state.copyWith(
      totalExposures: totalExposures,
      totalIntegrationSecs: totalIntegrationSecs ?? state.totalIntegrationSecs,
    );
  }

  /// Signature of the last `ExposureCompleted` already folded into
  /// [SequenceProgress.completedIntegrationSecs]. See
  /// [recordCompletedFrameIntegration].
  String? _lastIntegrationEventKey;

  /// Add one completed frame's shutter time to the run's integration total,
  /// exactly once per event.
  ///
  /// Two independent subscribers handle `ExposureCompleted` on a desktop host —
  /// the DeviceService-driven pump in this file and [SequenceExecutor]'s own
  /// handler — so an unguarded read-modify-write counts every frame twice.
  ///
  /// [eventKey] must identify the originating EVENT, not the frame: both
  /// subscribers receive the SAME event object, so its timestamp plus the frame
  /// index distinguishes "the other subscriber already handled this" from "a
  /// genuinely new frame".
  void recordCompletedFrameIntegration({
    required String eventKey,
    required double durationSecs,
  }) {
    if (_lastIntegrationEventKey == eventKey) return;
    _lastIntegrationEventKey = eventKey;
    state = state.copyWith(
      completedIntegrationSecs: state.completedIntegrationSecs + durationSecs,
    );
  }

  void reset() {
    _lastIntegrationEventKey = null;
    state = const SequenceProgress();
  }
}

/// WHO ended the run in progress, as the last authorship evidence on the wire
/// named them — null while nothing has named anyone.
///
/// The cancel notice the executor emits ("Sequence cancelled") is emitted by
/// EVERY cancellation path, so it says only THAT a run ended. The rows that say
/// WHO all land BEFORE it: measured on the release bundle, `Trigger fired: Dawn
/// Approaching - action: ParkAndAbort` at 11:02:16.638243 and the cancel notice
/// 100 ms later. Reading the notice alone published "Stopped by request" on
/// run-watch for a weather/dawn park nobody was awake for.
///
/// Cleared when a run starts, so one night's cause can never be attached to the
/// next one's stop.
final sequenceStopEvidenceProvider = StateProvider<SequenceStopDecision?>(
  (ref) => null,
);

/// The stop authorship a core-typed sequencer event carries, or null when the
/// event names nobody.
///
/// Both producers of the terminal message fold every event through here, so
/// the DeviceService-driven pump and [SequenceExecutor]'s own handler read one
/// vocabulary — the same one `sequenceStopDecision` gives the bridge-typed
/// surfaces.
SequenceStopDecision? sequenceStopEvidenceOf(SkotiqEvent event) {
  switch (event.eventType) {
    case 'TriggerFired':
      return sequenceStopTriggerDecision(
        triggerId: event.data['trigger_id'] as String?,
        triggerName: event.data['trigger_name'] as String?,
        action: event.data['action'] as String?,
      );
    case 'DecisionLogged':
      final category = event.data['category'];
      final summary = event.data['summary'];
      // A row missing either half is a decision this build cannot read, and an
      // unreadable row names nobody rather than falling through as a blank
      // category that matches no author.
      if (category is! String || summary is! String) return null;
      return sequenceStopDecision(
        category: category,
        summary: summary,
        detailsJson: event.data['details_json'] as String?,
      );
    default:
      return null;
  }
}

typedef SequenceProviderReader = T Function<T>(ProviderListenable<T> provider);

/// Fold one event's authorship into [sequenceStopEvidenceProvider].
///
/// An event that names nobody leaves the last named author standing: the
/// cancel-notice lifecycle row arrives after the row that named the cause, and
/// erasing the cause with it would put the run straight back to claiming
/// nothing — or, worse, to whatever the reader assumed.
void recordSequenceStopEvidence(
  SequenceProviderReader read,
  SkotiqEvent event,
) {
  final decision = sequenceStopEvidenceOf(event);
  if (decision == null) return;
  read(sequenceStopEvidenceProvider.notifier).state = decision;
}

/// True when a local [SequenceExecutor] owns the running sequence, and is
/// therefore the sole authority on run lifecycle state.
///
/// The executor creates the `sequence_runs` row before it starts the native
/// run, so a non-null [currentRunIdProvider] means "a Dart-side run
/// transaction is live here". That matters because the executor deliberately
/// publishes `finalizing` on a terminal event and only settles to
/// completed/failed/idle AFTER durable cleanup succeeds (see
/// `SequenceExecutor._onTerminalEvent`). This pump runs FIRST — DeviceService
/// subscribes to the shared broadcast event stream at app start, the executor
/// only when a run begins — so writing a settled terminal state from here
/// would re-introduce the early terminal publish that contract exists to
/// prevent.
///
/// When no local run is owned, nothing else translates lifecycle events into
/// provider state. That is the real headless-appliance case: with no in-editor
/// sequence, `POST /api/sequencer/start` calls `backend.sequencerStart()`
/// directly (see `handleSequencerStart`), so the executor never subscribes and
/// this pump is the only writer.
bool _localExecutorOwnsRun(SequenceProviderReader read) =>
    read(currentRunIdProvider) != null;

/// Map a `NodeCompleted` wire status onto a [NodeStatus], or null when the
/// event carries no status at all.
///
/// The wire field is `status` — a STRING (`success` / `failed` / `cancelled` /
/// `skipped`), see `SequencerEvent.nodeCompleted`. A `success` BOOL is also
/// accepted so an older producer keeps working.
///
/// A missing status returns null rather than defaulting to failure: claiming a
/// step failed because we could not read its verdict is exactly the kind of
/// confident-and-wrong statement this pump is not allowed to make.
NodeStatus? _nodeStatusFromCompletedEvent(Map<String, dynamic> data) {
  final statusStr = data['status'] as String?;
  final legacySuccess = data['success'] as bool?;
  final resolved =
      statusStr ??
      (legacySuccess == null ? null : (legacySuccess ? 'success' : 'failed'));
  return switch (resolved) {
    null => null,
    'success' => NodeStatus.success,
    // Matches SequenceExecutor's own handler (event_operations.dart) so the
    // two writers can never disagree about the same event.
    'skipped' || 'cancelled' => NodeStatus.skipped,
    _ => NodeStatus.failure,
  };
}

/// Apply a backend sequencer event to the sequence state providers.
///
/// This keeps sequencer-state ownership inside the sequence provider layer
/// instead of having hardware/device services write those providers directly.
///
/// Event names: the FFI mapper emits the BARE lifecycle names — `Started`,
/// `Paused`, `Resumed`, `Stopped`, `Completed`, plus the terminal
/// `SequenceFailed` (see `ffi_backend/event_mapping.dart`). The
/// `Sequence`-prefixed spellings are accepted as well, so remote hosts using
/// either convention behave the same — but the bare names are the ones the FFI
/// mapper actually emits, and a case that lists only the prefixed spelling is
/// dead code.
void applySequencerEventToSequenceProviders(
  SequenceProviderReader read,
  SkotiqEvent event,
) {
  final progressNotifier = read(sequenceProgressProvider.notifier);
  final data = event.data;
  final executorOwnsRun = _localExecutorOwnsRun(read);

  // The per-node captured-frame tally. This pump is the ONLY writer on
  // a headless host (no executor subscribes there), so it has to feed the tally
  // as well as `SequenceExecutor`'s own handler; the tally's writes are
  // monotonic per node, so both firing for the same event is a no-op.
  applySequencerEventToNodeExposureTally(
    read(nodeExposureTallyProvider.notifier),
    event,
  );

  // WHO is ending this run, kept as it arrives — the cancel notice below is
  // cause-neutral and the rows that name a cause precede it.
  recordSequenceStopEvidence(read, event);

  switch (event.eventType) {
    case 'Started':
    case 'SequenceStarted':
      final sequenceName = data['sequence_name'] as String? ?? 'Unknown';
      // A new run answers for itself: the previous run's ParkAndAbort must not
      // be read as the cause of this one's stop.
      read(sequenceStopEvidenceProvider.notifier).state = null;
      if (executorOwnsRun) {
        progressNotifier.updateProgress(
          message: 'Started sequence: $sequenceName',
        );
        break;
      }
      // Clear the PREVIOUS run's accounting. The executor path does this
      // (SequenceExecutor seeds a fresh SequenceProgress at start); the
      // headless load->start path has no executor, so without this the second
      // sequence of the night inherited run 1's per-node badges and — because
      // integration seconds ACCUMULATE while the frame count is assigned from
      // the event's absolute index — reported a `completedIntegrationSecs`
      // covering every run so far next to a `completedExposures` covering only
      // the current one. Totals are re-seeded a moment later by the native
      // `Progress` event.
      progressNotifier.reset();
      progressNotifier.updateState(SequenceExecutionState.running);
      progressNotifier.updateProgress(
        message: 'Started sequence: $sequenceName',
      );
      read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;
      break;

    case 'Paused':
    case 'SequencePaused':
      if (executorOwnsRun) break;
      progressNotifier.updateState(SequenceExecutionState.paused);
      read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.paused;
      break;

    case 'Resumed':
    case 'SequenceResumed':
      if (executorOwnsRun) break;
      progressNotifier.updateState(SequenceExecutionState.running);
      read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;
      break;

    case 'Stopped':
    case 'SequenceStopped':
      if (executorOwnsRun) break;
      progressNotifier.updateState(SequenceExecutionState.idle);
      read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.idle;
      break;

    case 'Completed':
    case 'SequenceCompleted':
      if (executorOwnsRun) break;
      progressNotifier.updateState(SequenceExecutionState.completed);
      read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.completed;
      break;

    // Terminal FAILURE. Without this case a headless run that died keeps the
    // state it had before the failure, with no error text anywhere.
    case 'SequenceFailed':
      final error = data['error'] as String? ?? 'Unknown error';
      progressNotifier.updateProgress(message: 'Sequence failed: $error');
      if (executorOwnsRun) break;
      progressNotifier.updateState(SequenceExecutionState.failed);
      read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.failed;
      break;

    case 'NodeStarted':
      final nodeId = data['node_id'] as String? ?? '';
      final nodeType = data['node_type'] as String? ?? '';
      progressNotifier.updateProgress(
        currentNodeId: nodeId,
        currentNodeName: nodeType,
        currentNodeStatus: NodeStatus.running,
      );
      progressNotifier.updateNodeStatus(nodeId, NodeStatus.running);
      break;

    case 'NodeCompleted':
      final nodeId = data['node_id'] as String? ?? '';
      final nodeStatus = _nodeStatusFromCompletedEvent(data);
      if (nodeId.isNotEmpty && nodeStatus != null) {
        progressNotifier.updateNodeStatus(nodeId, nodeStatus);
      }
      break;

    case 'Progress':
      final current = (data['current'] as num?)?.toInt() ?? 0;
      final total = (data['total'] as num?)?.toInt() ?? 0;
      progressNotifier.updateProgress(completedExposures: current);
      progressNotifier.setTotals(total);
      break;

    case 'TargetChanged':
      final targetName = data['target_name'] as String? ?? '';
      progressNotifier.updateProgress(currentTarget: targetName);
      break;

    case 'TargetCompleted':
      final targetName = data['target_name'] as String? ?? '';
      progressNotifier.updateProgress(message: 'Completed target: $targetName');
      break;

    case 'ExposureStarted':
      final frame = (data['frame'] as num?)?.toInt() ?? 0;
      final total = (data['total'] as num?)?.toInt() ?? 0;
      final filter = data['filter'] as String?;
      final durationSecs = (data['duration_secs'] as num?)?.toDouble() ?? 0.0;
      progressNotifier.updateProgress(
        currentFilter: filter,
        message:
            'Exposure $frame/$total - ${durationSecs}s${filter != null ? " ($filter)" : ""}',
      );
      // Reflect sequencer-driven exposures on the camera card. The manual
      // imaging path sets this directly, but a sequence exposes in Rust and
      // only surfaces via events, so the Equipment card showed "Idle" all run.
      read(cameraStateProvider.notifier).setExposing(true);
      break;

    case 'ExposureCompleted':
      final durationSecs = (data['duration_secs'] as num?)?.toDouble() ?? 0.0;
      final currentProgress = read(sequenceProgressProvider);
      // Use the event's ABSOLUTE frame index, matching the SequenceExecutor
      // event handler, rather than incrementing the current count: this pump
      // and the executor's handler can both be live for the same run, and only
      // an absolute write is idempotent across the two. `frame` is 1-based
      // from the backend.
      final absoluteFrame =
          (data['frame'] as num?)?.toInt() ??
          currentProgress.completedExposures + 1;
      progressNotifier.updateProgress(completedExposures: absoluteFrame);
      progressNotifier.recordCompletedFrameIntegration(
        eventKey: '${event.timestamp}:$absoluteFrame',
        durationSecs: durationSecs,
      );
      // Exposure done — the camera is idle again during download/dither/slew.
      read(cameraStateProvider.notifier).setExposing(false);
      break;

    case 'Error':
      final message = data['message'] as String? ?? 'Unknown error';
      // PRODUCER 2b of the stop pipeline — the SECOND implementation of the
      // sequencer-Error handler. `SequenceExecutor._handleSequencerEvent` has
      // the same `case 'Error'`, and on a desktop host BOTH are live for the
      // same run (this pump is driven by DeviceService from app start, the
      // executor's only while a run it owns is alive). Fixing one and not the
      // other leaves the rollup still reading "Error: Sequence cancelled" —
      // the exact trap this batch was chartered on, so the pin
      // `run_stop_classification_producers_test.dart` asserts on both.
      if (isSequenceCancelledNotice(message)) {
        // WHOSE stop it was comes from the run's own authorship rows, never
        // from the notice: the notice is identical for an operator Stop and
        // for a dawn/weather ParkAndAbort, and reading it as the operator's
        // told a sleeping owner their trigger-parked rig was "Stopped by
        // request".
        final stopped = sequenceStoppedMessage(
          read(sequenceStopEvidenceProvider),
        );
        developer.log(
          '[$kStopClassificationLogTag] sequence_progress pump: cancellation '
          'notice treated as a stop, not an error ($stopped)',
          name: 'SequenceProgress',
        );
        progressNotifier.updateProgress(message: stopped);
        break;
      }
      progressNotifier.updateProgress(message: 'Error: $message');
      break;
  }

  // Whenever the run leaves the exposing path (completed, stopped, failed, or
  // an error), make sure the camera card doesn't get stuck showing "Exposing".
  //
  // This listed only `Sequence`-prefixed names, of which the backend emits
  // exactly one (`SequenceFailed`), so the reset never fired for the common
  // case: abort a run mid-exposure (Stop, or a trigger-driven abort) and no
  // `ExposureCompleted` ever arrives, leaving the Equipment camera card
  // claiming "Exposing" for the rest of the session. Both spellings are
  // matched now.
  switch (event.eventType) {
    case 'Completed':
    case 'SequenceCompleted':
    case 'Stopped':
    case 'SequenceStopped':
    case 'SequenceFailed':
    case 'Cancelled':
    case 'SequenceCancelled':
    case 'Error':
      read(cameraStateProvider.notifier).setExposing(false);
      break;
  }
}
