part of '../remote_sync_handler.dart';

void _applySequencerEvent(
  Object reader,
  SkotiqEvent event, {
  NetworkBackend? networkBackend,
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

/// SLAVE apply: mirror the master's OPEN sequence-editor canvas.
///
/// The master broadcasts its working/dirty open sequence via the
/// [HostMutationEntity.sequenceEditor] host-mutation (see
/// `masterSequenceEditorMirrorProvider`). Here the slave reflects it onto its
/// own [currentSequenceProvider] so the sequencer screen follows the master's
/// live canvas — not just re-saved library rows.
///
/// Guards (single-hardware-owner invariant; master is authoritative but never
/// silently clobbers a slave operator mid-edit):
///   * If the slave editor has unsaved edits ([CurrentSequenceNotifier.isDirty])
///     we SKIP the apply — same guard as [reloadOpenSequenceIfIdle].
///   * `cleared` empties the slave canvas to match the master closing its
///     editor.
/// Applies use `discardUnsaved: true` only after the isDirty guard has already
/// passed (the editor is clean), so no confirmed-clean work is lost.
void _applySequenceEditorMirror(
  Object reader,
  String action,
  Map<String, dynamic> data,
) {
  final editor = _read(reader, currentSequenceProvider.notifier);

  // While a run is active the executor owns the tree and every mutating call
  // below would throw SequenceLockedException — which used to escape and
  // abort the rest of hydration. Skip instead: the running run's tree is
  // shown by the run dashboard, and the canvas re-syncs on the next
  // hydration after the run ends.
  if (!editor.isEditableNow) {
    return;
  }

  if (action == HostMutationAction.cleared) {
    // Don't wipe a slave operator's unsaved canvas just because the master
    // closed its editor.
    if (editor.isDirty) {
      return;
    }
    editor.clearSequence(discardUnsaved: true);
    // Editor closed host-side -> back to manual ownership on the slave.
    editor.adoptOwner(ActivePlanOwner.manual);
    return;
  }

  // Never clobber the slave operator's in-progress edits. The slave diverges
  // until it returns to a clean state, which is the documented master-
  // authoritative behavior.
  if (editor.isDirty) {
    return;
  }

  final rawSequence = data['sequence'];
  if (rawSequence is! Map) {
    return;
  }

  final Sequence parsed;
  try {
    final map = Map<String, dynamic>.from(rawSequence);
    var seq = _read(reader, sequenceFileServiceProvider).parseFromMap(map);
    final dbId = data['databaseId'];
    if (dbId is int) {
      seq = seq.copyWith(databaseId: dbId);
    }
    parsed = seq;
  } catch (_) {
    // Best-effort: a malformed mirror frame must not crash the slave's sync
    // loop. The next frame (or a library reload) will recover.
    return;
  }

  editor.loadSequence(parsed, discardUnsaved: true);
  // Reflect the host's active-plan owner so the slave's UI shows WHO owns the
  // plan (host autopilot -> slave shows autopilot-owned, not stale manual).
  // Applied AFTER loadSequence: loadSequence resets the owner to manual (it is a
  // manual-load primitive), so adopting here lands the correct owner last.
  // Backward-compatible: an older host omits the field and fromWire -> manual.
  editor.adoptOwner(ActivePlanOwnerWire.fromWire(data['activePlanOwner']));
}

/// G2: seed the slave's sequencer canvas with the master's currently-open
/// editor sequence on connect.
///
/// The live master->slave editor mirror ([masterSequenceEditorMirrorProvider])
/// only emits on edit, so a slave connecting mid-session sees a blank canvas
/// until the next master edit. This fetches the master's open editor sequence
/// in the SAME payload shape that mirror broadcasts (`HostStateChanged` /
/// [HostMutationEntity.sequenceEditor]) and feeds it through the identical
/// [_applySequenceEditorMirror] apply path, so seed and live update share one
/// code path. Returns silently when no sequence is open host-side (the endpoint
/// reports `open: false`) or the endpoint is unavailable on an older host.
Future<void> _hydrateOpenEditorSequence(
  Object reader,
  NetworkBackend backend,
) async {
  final Map<String, dynamic>? payload;
  try {
    payload = await backend.getOpenEditorSequence();
  } catch (_) {
    // Older headless host without the endpoint, or a transient fetch error:
    // the live mirror still seeds the canvas on the master's next edit.
    return;
  }
  if (!_isCurrentRemoteBackend(reader, backend)) return;
  if (payload == null) {
    // No sequence open in the master's editor — leave the slave's canvas as-is
    // (don't clear, mirroring _applySequenceEditorMirror's dirty-safe behavior).
    return;
  }
  try {
    _applySequenceEditorMirror(reader, HostMutationAction.updated, payload);
  } catch (e) {
    // A throw from the editor must never abort the rest of hydration (PHD2
    // state, profile/settings invalidations, planner refreshes).
    _read(reader, loggingServiceProvider).debug(
      'Skipping open-editor mirror apply: $e',
      source: 'RemoteSessionSync',
    );
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
  NetworkBackend backend,
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
