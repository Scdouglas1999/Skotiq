import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/remote_host.dart';
import '../../models/backend/event_types.dart';
import '../../models/sequence/sequence_models.dart';
import '../backend_provider.dart';
import '../equipment/camera_state_provider.dart';
import 'node_exposure_tally.dart';
import 'run_record.dart';
import 'run_stop_classification.dart';
import 'sequencer_run_event.dart';

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

/// The always-on pump's entry for a backend sequencer event.
///
/// The event is folded onto the run record here unless the executor attached
/// to the run is folding its events itself (it adds what only it knows: stats,
/// frames, the finalization). The camera card learns of a sequence exposure
/// here either way.
void applySequencerEventToSequenceProviders(
  SequenceProviderReader read,
  SkotiqEvent raw,
) {
  final event = SequencerRunEvent.fromSkotiqEvent(raw);
  if (event == null) return;
  final run = read(runRecordProvider.notifier);
  // On a linked client the mirror folds the host's events.
  final mirrored = read(backendProvider).remoteHost != null;
  if (!mirrored && !run.eventFoldClaimed) foldRunEvent(run, event);

  // A sequence exposes in Rust and surfaces only through events. Leaving the
  // exposing path by any terminal or run-ending error must clear the flag: an
  // aborted exposure never sends ExposureCompleted. A problem the run carries
  // on through leaves the exposure running.
  switch (event) {
    case ExposureStarted():
      read(cameraStateProvider.notifier).setExposing(true);
    case ExposureCompleted() || RunTerminalEvent():
      read(cameraStateProvider.notifier).setExposing(false);
    case SequencerError(isAdvisory: false):
      read(cameraStateProvider.notifier).setExposing(false);
    default:
      break;
  }
}

/// Fold one sequencer event onto the run record: progress, per-step status and
/// tally, stop authorship, and the lifecycle when no local executor owns it.
///
/// Called once per event: by `RunEventHandler` for a run the executor is
/// attached to ([executorDecidesLifecycle]), by
/// [applySequencerEventToSequenceProviders] for any other event on a host, and
/// by the remote-sync mirror on a linked client.
///
/// A local executor is the authority on the lifecycle of a run it is attached
/// to or still finalizing (it opened the `sequence_runs` row, so the record
/// has a run id): it publishes `finalizing` on a terminal, settles only after
/// durable cleanup, and ignores a late terminal for a run that already has its
/// verdict. The lifecycle is not written from here for such a run.
void foldRunEvent(
  RunRecordNotifier run,
  SequencerRunEvent event, {
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
    case RunStarted():
      final sequenceName = event.sequenceName ?? 'Unknown';
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

    case RunPaused():
      if (!executorOwnsRun) run.setLifecycle(SequenceExecutionState.paused);

    case RunResumed():
      if (!executorOwnsRun) run.setLifecycle(SequenceExecutionState.running);

    case RunStopped():
      if (!executorOwnsRun) run.setLifecycle(SequenceExecutionState.idle);

    case RunCompleted():
      if (!executorOwnsRun) run.setLifecycle(SequenceExecutionState.completed);

    case RunFailed():
      final error = event.error ?? 'Unknown error';
      run.updateProgress(message: 'Sequence failed: $error');
      if (!executorOwnsRun) run.setLifecycle(SequenceExecutionState.failed);

    case NodeStarted():
      final nodeId = event.nodeId ?? '';
      run.updateProgress(
        currentNodeId: nodeId,
        currentNodeName: event.nodeType ?? '',
        currentNodeStatus: NodeStatus.running,
      );
      run.updateNodeStatus(nodeId, NodeStatus.running);

    case NodeCompleted(:final nodeId?, :final nodeStatus?)
        when nodeId.isNotEmpty:
      // A missing status leaves the node alone: claiming a step failed because
      // its verdict could not be read would be confidently wrong.
      run.updateNodeStatus(nodeId, nodeStatus);

    case ExposureCountProgress():
      run.updateProgress(completedExposures: event.current ?? 0);
      run.setTotals(event.total ?? 0);

    case TargetChanged():
      run.updateProgress(currentTarget: event.targetName ?? '');

    case TargetCompleted():
      run.updateProgress(
        message: 'Completed target: ${event.targetName ?? ''}',
      );

    case ExposureStarted(:final filter):
      final frame = event.frame ?? 0;
      final total = event.total ?? 0;
      final durationSecs = event.durationSecs ?? 0.0;
      run.updateProgress(
        currentFilter: filter,
        message:
            'Exposure $frame/$total - ${durationSecs}s'
            '${filter != null ? " ($filter)" : ""}',
      );

    case ExposureCompleted():
      run.updateProgress(
        completedExposures:
            event.frame ?? run.record.progress.completedExposures + 1,
      );
      run.addCompletedIntegration(event.durationSecs ?? 0.0);

    case SequencerError():
      final message = event.message ?? 'Unknown error';
      // Every cancellation path emits the same notice, so it is a stop whose
      // cause comes from the authorship rows, never an error.
      if (isSequenceCancelledNotice(message)) {
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
        message: event.isAdvisory ? message : 'Error: $message',
      );

    default:
      break;
  }
}
