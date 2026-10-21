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
import 'sequencer_run_event.dart';

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

/// The stop authorship a sequencer event carries, or null when the event names
/// nobody.
SequenceStopDecision? sequenceStopEvidenceOf(SkotiqEvent event) {
  final typed = SequencerRunEvent.fromSkotiqEvent(event);
  return typed == null ? null : runEventStopEvidence(typed);
}

/// [sequenceStopEvidenceOf] for an already-decoded event.
///
/// Both producers of the terminal message (the DeviceService pump and
/// [SequenceExecutor]) read this one vocabulary, the same one
/// `sequenceStopDecision` gives the bridge-typed surfaces.
SequenceStopDecision? runEventStopEvidence(SequencerRunEvent event) {
  switch (event) {
    case TriggerFired(:final triggerId, :final triggerName, :final action):
      return sequenceStopTriggerDecision(
        triggerId: triggerId,
        triggerName: triggerName,
        action: action,
      );
    // A decision row missing its category or summary names nobody, rather
    // than falling through as a blank category.
    case DecisionLogged(:final category?, :final summary?):
      return sequenceStopDecision(
        category: category,
        summary: summary,
        detailsJson: event.detailsJson,
      );
    default:
      return null;
  }
}

typedef SequenceProviderReader = T Function<T>(ProviderListenable<T> provider);

/// Fold one event's authorship into [sequenceStopEvidenceProvider].
///
/// An event that names nobody leaves the last named author standing: the
/// cancel notice arrives after the row that named the cause.
void recordSequenceStopEvidence(
  SequenceProviderReader read,
  SkotiqEvent event,
) {
  final typed = SequencerRunEvent.fromSkotiqEvent(event);
  if (typed != null) recordRunEventStopEvidence(read, typed);
}

/// [recordSequenceStopEvidence] for an already-decoded event.
void recordRunEventStopEvidence(
  SequenceProviderReader read,
  SequencerRunEvent event,
) {
  final decision = runEventStopEvidence(event);
  if (decision == null) return;
  read(sequenceStopEvidenceProvider.notifier).state = decision;
}

/// True when a local [SequenceExecutor] owns the running sequence, and is
/// therefore the sole authority on run lifecycle state.
///
/// The executor opens the `sequence_runs` row before the native run starts, so
/// a run id means a Dart-side run transaction is live. The executor publishes
/// `finalizing` on a terminal and settles only after durable cleanup, so this
/// pump (which sees every event first) must not publish a settled terminal
/// state for such a run. With no local run (the headless `load -> start` path)
/// this pump is the only writer of lifecycle state.
bool _localExecutorOwnsRun(SequenceProviderReader read) =>
    read(currentRunIdProvider) != null;

/// Apply a backend sequencer event to the sequence state providers.
///
/// This keeps sequencer-state ownership inside the sequence provider layer
/// instead of having hardware/device services write those providers directly.
void applySequencerEventToSequenceProviders(
  SequenceProviderReader read,
  SkotiqEvent raw,
) {
  final event = SequencerRunEvent.fromSkotiqEvent(raw);
  if (event == null) return;
  final progressNotifier = read(sequenceProgressProvider.notifier);
  final executorOwnsRun = _localExecutorOwnsRun(read);

  // This pump is the only tally writer on a headless host; the tally's writes
  // are monotonic per node, so the executor folding the same event is a no-op.
  applyRunEventToNodeExposureTally(
    read(nodeExposureTallyProvider.notifier),
    event,
  );
  recordRunEventStopEvidence(read, event);

  void setState(SequenceExecutionState state) {
    progressNotifier.updateState(state);
    read(sequenceExecutionStateProvider.notifier).state = state;
  }

  switch (event) {
    case RunStarted():
      final sequenceName = event.sequenceName ?? 'Unknown';
      // A new run answers for itself: the previous run's stop cause must not
      // be read as this one's.
      read(sequenceStopEvidenceProvider.notifier).state = null;
      if (executorOwnsRun) {
        progressNotifier.updateProgress(
          message: 'Started sequence: $sequenceName',
        );
        break;
      }
      // With no executor, nothing else clears the previous run's accounting;
      // integration seconds accumulate and would otherwise span every run.
      progressNotifier.reset();
      progressNotifier.updateState(SequenceExecutionState.running);
      progressNotifier.updateProgress(
        message: 'Started sequence: $sequenceName',
      );
      read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;

    case RunPaused():
      if (!executorOwnsRun) setState(SequenceExecutionState.paused);

    case RunResumed():
      if (!executorOwnsRun) setState(SequenceExecutionState.running);

    case RunStopped():
      if (!executorOwnsRun) setState(SequenceExecutionState.idle);

    case RunCompleted():
      if (!executorOwnsRun) setState(SequenceExecutionState.completed);

    case RunFailed():
      final error = event.error ?? 'Unknown error';
      progressNotifier.updateProgress(message: 'Sequence failed: $error');
      if (!executorOwnsRun) setState(SequenceExecutionState.failed);

    case NodeStarted():
      final nodeId = event.nodeId ?? '';
      progressNotifier.updateProgress(
        currentNodeId: nodeId,
        currentNodeName: event.nodeType ?? '',
        currentNodeStatus: NodeStatus.running,
      );
      progressNotifier.updateNodeStatus(nodeId, NodeStatus.running);

    case NodeCompleted(:final nodeId?, :final nodeStatus?)
        when nodeId.isNotEmpty:
      // A missing status leaves the node alone: claiming a step failed because
      // its verdict could not be read would be confidently wrong.
      progressNotifier.updateNodeStatus(nodeId, nodeStatus);

    case ExposureCountProgress():
      progressNotifier.updateProgress(completedExposures: event.current ?? 0);
      progressNotifier.setTotals(event.total ?? 0);

    case TargetChanged():
      progressNotifier.updateProgress(currentTarget: event.targetName ?? '');

    case TargetCompleted():
      progressNotifier.updateProgress(
        message: 'Completed target: ${event.targetName ?? ''}',
      );

    case ExposureStarted(:final filter):
      final frame = event.frame ?? 0;
      final total = event.total ?? 0;
      final durationSecs = event.durationSecs ?? 0.0;
      progressNotifier.updateProgress(
        currentFilter: filter,
        message:
            'Exposure $frame/$total - ${durationSecs}s'
            '${filter != null ? " ($filter)" : ""}',
      );
      // A sequence exposes in Rust and surfaces only through events, so the
      // camera card learns it is exposing here.
      read(cameraStateProvider.notifier).setExposing(true);

    case ExposureCompleted():
      final durationSecs = event.durationSecs ?? 0.0;
      // The ABSOLUTE frame index, as the executor writes it: both subscribers
      // can be live for one run, and only an absolute write is idempotent.
      final absoluteFrame =
          event.frame ?? read(sequenceProgressProvider).completedExposures + 1;
      progressNotifier.updateProgress(completedExposures: absoluteFrame);
      progressNotifier.recordCompletedFrameIntegration(
        eventKey: '${event.timestamp}:$absoluteFrame',
        durationSecs: durationSecs,
      );
      read(cameraStateProvider.notifier).setExposing(false);

    case SequencerError():
      final message = event.message ?? 'Unknown error';
      // The executor reads the same notice the same way; both are live for one
      // run on a desktop host. The cause comes from the authorship rows, never
      // from the cause-neutral cancel notice.
      if (isSequenceCancelledNotice(message)) {
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

    default:
      break;
  }

  // Leaving the exposing path by any terminal or error must clear the camera
  // card's exposing flag: an aborted exposure never sends ExposureCompleted.
  if (event is RunTerminalEvent || event is SequencerError) {
    read(cameraStateProvider.notifier).setExposing(false);
  }
}
