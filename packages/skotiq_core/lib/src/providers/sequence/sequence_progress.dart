import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/bridge_events.dart';
import '../../backend/sequencer_error_kind.dart';
import '../../backend/sequencer_run_events.dart';
import '../../models/backend/event_types.dart';
import '../../models/sequence/sequence_models.dart';
import '../backend_provider.dart';
import '../equipment/camera_state_provider.dart';
import 'node_exposure_tally.dart';
import 'run_record.dart';
import '../../models/sequence/run_stop_classification.dart';

/// Where the run stands.
final sequenceExecutionStateProvider = runRecordProvider.select(
  (run) => run.lifecycle,
);

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
final sequenceLaunchInFlightProvider = runRecordProvider.select(
  (run) => run.launching,
);

/// The checkpoint `SequenceExecutor.restoreFromCheckpoint` restored and the
/// next Start will continue, or null. While set, the run is loaded and ready
/// but nothing has executed.
final restoredCheckpointProvider = runRecordProvider.select(
  (run) => run.restoredCheckpoint,
);

/// Frames each exposure step of the loaded plan already had before the run
/// that is ready or under way, by node id: the checkpoint's count when the run
/// continues one, empty for a fresh run, so the plan's progress counts what
/// was taken before it.
final framesDoneBeforeRunProvider = runRecordProvider.select(
  (run) => run.framesDoneBeforeRun,
);

/// The run's counters, current step and per-step status.
final sequenceProgressProvider = runRecordProvider.select(
  (run) => run.progress,
);

/// The run's progress as a step list draws it: the current step and filter
/// and each step's status, percent and detail. It changes only when one of
/// those does, so a tree of steps is not rebuilt by the run's clock, counters
/// and message, which change every second. Those fields are as of the last
/// step change here; read [sequenceProgressProvider] for them.
final sequenceStepProgressProvider = Provider<SequenceProgress>((ref) {
  ref.watch(
    sequenceProgressProvider.select(
      (p) => (
        p.currentNodeId,
        p.currentFilter,
        p.nodeStatuses,
        p.nodeProgressPercent,
        p.nodeProgressDetail,
        p.nodeProgressStructuredDetail,
      ),
    ),
  );
  return ref.read(sequenceProgressProvider);
});

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
final sequenceStopEvidenceProvider = runRecordProvider.select(
  (run) => run.stopEvidence,
);

/// The stop authorship a sequencer event carries, or null when the event names
/// nobody.
///
/// Both producers of the terminal message (the DeviceService pump and
/// [SequenceExecutor]) read this one vocabulary, the same one
/// `sequenceStopDecision` gives the bridge-typed surfaces.
SequenceStopDecision? runEventStopEvidence(SequencerEvent event) {
  switch (event) {
    case SequencerEvent_TriggerFired(
      :final triggerId,
      :final triggerName,
      :final action,
    ):
      return sequenceStopTriggerDecision(
        triggerId: triggerId,
        triggerName: triggerName,
        action: action,
      );
    // A decision row missing its category or summary names nobody, rather
    // than falling through as a blank category.
    case SequencerEvent_DecisionLogged(:final stop):
      return sequenceStopDecisionOf(stop);
    default:
      return null;
  }
}

typedef SequenceProviderReader = T Function<T>(ProviderListenable<T> provider);

/// The always-on pump's entry for a backend sequencer event.
///
/// The event is folded onto the run record here unless the executor attached
/// to the run is folding its events itself (it adds what only it knows: stats,
/// frames, the finalization). On a host the end of a run clears the camera's
/// exposing flag here either way.
void applySequencerEventToSequenceProviders(
  SequenceProviderReader read,
  SkotiqEvent raw,
) {
  final event = sequencerEventOf(raw);
  if (event == null) return;
  final run = read(runRecordProvider.notifier);
  // On a linked client the mirror folds the host's events.
  final mirrored = read(isRemoteModeProvider);
  if (!mirrored && !run.eventFoldClaimed) foldRunEvent(run, event);
  // A linked client's camera follows the host camera's own events.
  if (mirrored) return;

  // A run's frames show from the camera's own events
  // (`hostExposureFollowProvider`). A run that ends, or stops on an error,
  // leaves no exposure standing; a problem it carries on through does not
  // end the one in flight.
  final endsExposure = switch (event) {
    SequencerEvent_Error(:final kind) => !kind.runContinues,
    _ => event.endsRun,
  };
  if (endsExposure) read(cameraStateProvider.notifier).setExposing(false);
}

/// Fold one sequencer event onto the run record: progress, per-step status and
/// tally, stop authorship, and the lifecycle when no local executor owns it.
///
/// Called once per event on a host: by `RunEventHandler` for a run the executor
/// is attached to ([executorDecidesLifecycle]), and by
/// [applySequencerEventToSequenceProviders] for any other event. A linked
/// client takes the host's record from its runtime channels instead.
///
/// A local executor is the authority on the lifecycle of a run it is attached
/// to or still finalizing (it opened the `sequence_runs` row, so the record
/// has a run id): it publishes `finalizing` on a terminal, settles only after
/// durable cleanup, and ignores a late terminal for a run that already has its
/// verdict. The lifecycle is not written from here for such a run.
void foldRunEvent(
  RunRecordNotifier run,
  SequencerEvent event, {
  bool executorDecidesLifecycle = false,
}) {
  final executorOwnsRun = executorDecidesLifecycle || run.record.runId != null;

  applyRunEventToNodeExposureTally(run, event);
  // Authorship rows precede the cause-neutral cancel notice, so they are
  // folded as they arrive; an event that names nobody leaves the last named
  // author standing.
  final stopEvidence = runEventStopEvidence(event);
  if (stopEvidence != null) run.setStopEvidence(stopEvidence);

  switch (event) {
    case SequencerEvent_Started(:final sequenceName):
      // A new run answers for itself: the previous run's stop cause must not
      // be read as this one's.
      run.setStopEvidence(null);
      if (!executorOwnsRun) {
        // With no executor, nothing else clears the previous run's accounting;
        // integration seconds would otherwise span every run.
        run.resetProgress();
        run.setLifecycle(SequenceExecutionState.running);
      }
      run.updateProgress(message: 'Started sequence: $sequenceName');

    case SequencerEvent_Paused():
      if (!executorOwnsRun) run.setLifecycle(SequenceExecutionState.paused);

    case SequencerEvent_Resumed():
      if (!executorOwnsRun) run.setLifecycle(SequenceExecutionState.running);

    case SequencerEvent_Stopped():
      if (!executorOwnsRun) run.setLifecycle(SequenceExecutionState.idle);

    case SequencerEvent_Completed():
      if (!executorOwnsRun) run.setLifecycle(SequenceExecutionState.completed);

    case SequencerEvent_Failed(:final error):
      run.updateProgress(message: 'Sequence failed: $error');
      if (!executorOwnsRun) run.setLifecycle(SequenceExecutionState.failed);

    case SequencerEvent_NodeStarted(:final nodeId, :final nodeType):
      run.updateProgress(
        currentNodeId: nodeId,
        currentNodeName: nodeType,
        currentNodeStatus: NodeStatus.running,
      );
      run.updateNodeStatus(nodeId, NodeStatus.running);

    case SequencerEvent_NodeCompleted(:final nodeId) when nodeId.isNotEmpty:
      run.updateNodeStatus(nodeId, event.nodeStatus);

    case SequencerEvent_Progress(:final current, :final total):
      run.updateProgress(completedExposures: current);
      run.setTotals(total);

    case SequencerEvent_TargetChanged(:final targetName):
      run.updateProgress(currentTarget: targetName);

    case SequencerEvent_TargetCompleted(:final targetName):
      run.updateProgress(message: 'Completed target: $targetName');

    case SequencerEvent_ExposureStarted(
      :final frame,
      :final total,
      :final filter,
      :final durationSecs,
    ):
      run.updateProgress(
        currentFilter: filter,
        message:
            'Exposure $frame/$total - ${durationSecs}s'
            '${filter != null ? " ($filter)" : ""}',
      );

    case SequencerEvent_ExposureCompleted(:final frame, :final durationSecs):
      run.updateProgress(completedExposures: frame);
      run.addCompletedIntegration(durationSecs);

    case SequencerEvent_Error(:final message, :final kind):
      // A cancellation is a stop whose cause comes from the authorship rows,
      // never an error.
      if (kind == SequencerErrorKind.cancelled) {
        final stopped = sequenceStoppedMessage(run.record.stopEvidence);
        developer.log(
          '[$kStopClassificationLogTag] run event fold: cancellation notice '
          'treated as a stop, not an error ($stopped)',
          name: 'SequenceProgress',
        );
        run.updateProgress(message: stopped);
        break;
      }
      run.updateProgress(
        message: kind.runContinues ? message : 'Error: $message',
      );

    default:
      break;
  }
}
