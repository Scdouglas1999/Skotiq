part of '../remote_sync_handler.dart';

void _applySequencerEvent(
  Object reader,
  SkotiqEvent event, {
  SkotiqBackend? networkBackend,
}) {
  final progressNotifier = _read(reader, sequenceProgressProvider.notifier);
  final data = event.data;

  // A local [SequenceExecutor] that owns a run (it created the sequence_runs
  // row, hence a non-null currentRunId) is the authority on lifecycle state:
  // it publishes `finalizing` on a terminal event and only settles once
  // durable cleanup succeeds. Writing a settled state from here would race
  // that transaction, so mirrored lifecycle only drives state when no local
  // run is owned — i.e. we are watching someone else's run, which is the
  // whole point of this handler.
  final executorOwnsRun = _read(reader, currentRunIdProvider) != null;

  // The bare names are what a host actually emits (see
  // `ffi_backend/event_mapping.dart`); the `Sequence`-prefixed spellings were
  // the only ones matched here, so a mirrored run stayed `running` on the
  // phone after the host had finished, failed or been stopped, until the next
  // status poll or reconnect happened to correct it.
  switch (event.eventType) {
    case 'Started':
    case 'SequenceStarted':
      final sequenceName = data['sequence_name'] as String? ?? 'Unknown';
      progressNotifier.updateProgress(
        message: 'Started sequence: $sequenceName',
      );
      if (executorOwnsRun) break;
      progressNotifier.updateState(SequenceExecutionState.running);
      _read(reader, sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;
      break;
    case 'Paused':
    case 'SequencePaused':
      if (executorOwnsRun) break;
      progressNotifier.updateState(SequenceExecutionState.paused);
      _read(reader, sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.paused;
      break;
    case 'Resumed':
    case 'SequenceResumed':
      if (executorOwnsRun) break;
      progressNotifier.updateState(SequenceExecutionState.running);
      _read(reader, sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;
      break;
    case 'Stopped':
    case 'SequenceStopped':
      if (executorOwnsRun) break;
      progressNotifier.updateState(SequenceExecutionState.idle);
      _read(reader, sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.idle;
      break;
    case 'Completed':
    case 'SequenceCompleted':
      if (executorOwnsRun) break;
      progressNotifier.updateState(SequenceExecutionState.completed);
      _read(reader, sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.completed;
      break;
    // A terminal failure must mirror through with its reason, or the phone
    // keeps reporting the state the run held before it died.
    case 'SequenceFailed':
      final error = data['error'] as String? ?? 'Unknown error';
      progressNotifier.updateProgress(message: 'Sequence failed: $error');
      if (executorOwnsRun) break;
      progressNotifier.updateState(SequenceExecutionState.failed);
      _read(reader, sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.failed;
      break;
    case 'NodeStarted':
      progressNotifier.updateProgress(
        currentNodeId: data['node_id'] as String? ?? '',
        currentNodeName: data['node_type'] as String? ?? '',
        currentNodeStatus: NodeStatus.running,
      );
      // A new node/target means the host autopilot's live pick likely changed;
      // refresh the mirrored preview so the slave's banner tracks the switch
      // (no-op when the banner isn't mounted — it's autoDispose).
      if (networkBackend != null) {
        _invalidate(reader, schedulerPreviewDecisionProvider);
      }
      break;
    case 'ProgressUpdated':
    case 'InstructionProgress':
      if (networkBackend != null) {
        unawaited(_refreshSequencerStatus(reader, networkBackend));
      }
      break;
    case sequenceUpdatedEventType:
      _invalidateSequenceLibrary(
        reader,
        sequenceId: data['sequenceId'] as int?,
      );
      break;
  }
}

void _applySequencerMutationFromHost(
  Object reader,
  String action,
  Map<String, dynamic> data,
) {
  SequenceExecutionState mapped;
  switch (action) {
    case HostMutationAction.started:
      mapped = SequenceExecutionState.running;
    case HostMutationAction.paused:
      mapped = SequenceExecutionState.paused;
    case HostMutationAction.resumed:
      mapped = SequenceExecutionState.running;
    case HostMutationAction.stopped:
      mapped = SequenceExecutionState.idle;
    default:
      final rawState = data['state'] as String?;
      if (rawState == null) {
        return;
      }
      mapped = _mapSequencerState(rawState);
  }

  _read(reader, sequenceExecutionStateProvider.notifier).state = mapped;
  _read(reader, sequenceProgressProvider.notifier).updateState(mapped);

  final message = data['message'] as String?;
  if (message != null) {
    _read(
      reader,
      sequenceProgressProvider.notifier,
    ).updateProgress(message: message);
  }
}

int? _parseSequenceId(Map<String, dynamic> data) {
  final raw = data['entityId'] ?? data['sequenceId'];
  if (raw is int) {
    return raw;
  }
  if (raw is String) {
    return int.tryParse(raw);
  }
  return null;
}

void _invalidateSequenceLibrary(Object reader, {int? sequenceId}) {
  _invalidate(reader, savedSequencesProvider);
  _invalidate(reader, savedSequenceSummariesProvider);
  if (sequenceId != null && reader is Ref) {
    unawaited(reloadOpenSequenceIfIdle(reader, sequenceId));
  }
}

Future<void> _refreshSequencerStatus(
  Object reader,
  SkotiqBackend backend,
) async {
  try {
    final status = await backend.sequencerGetStatus();
    _applySequencerStatus(reader, status);
  } catch (_) {
    // Fail closed on the event path — hydration/polling will recover.
  }
}

void _applySequencerStatus(Object reader, SequencerStatus status) {
  final mapped = _mapSequencerState(status.state);
  _read(reader, sequenceExecutionStateProvider.notifier).state = mapped;
  _read(reader, sequenceProgressProvider.notifier).updateState(mapped);
  _read(reader, sequenceProgressProvider.notifier).updateProgress(
    message: status.message,
    currentNodeId: status.currentNodeId,
    currentNodeName: status.currentNodeName,
  );

  // Mirror the master's live run-vitals onto the slave's Session Vitals tile.
  // The local executor never writes liveSequenceStatsProvider on a slave, so
  // without this the Vitals tile reads idle next to a live progress bar. Null
  // vitals (idle host, or a host build that doesn't emit them) clears the tile.
  final vitals = status.runVitals;
  _read(reader, liveSequenceStatsProvider.notifier).state = vitals == null
      ? null
      : SequenceRunStats.fromRemoteVitals(vitals);

  // Why the host's guiding is stopped. Live StopReason events carry it too,
  // but only to a client that was listening when it was set: one that joined
  // during a tracking-limit hold read "Guider needs a look" with no reason.
  if (status.reportsGuidingStopReason) {
    _read(reader, guidingStopReasonProvider.notifier).state =
        status.guidingStopReason;
  }
}

SequenceExecutionState _mapSequencerState(String rawState) {
  switch (rawState.toLowerCase()) {
    case 'running':
      return SequenceExecutionState.running;
    case 'paused':
      return SequenceExecutionState.paused;
    case 'stopping':
      return SequenceExecutionState.stopping;
    case 'completed':
      return SequenceExecutionState.completed;
    case 'failed':
    case 'error':
      return SequenceExecutionState.failed;
    case 'recovering':
      return SequenceExecutionState.paused;
    case 'idle':
    case 'stopped':
    default:
      return SequenceExecutionState.idle;
  }
}
