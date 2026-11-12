part of '../remote_sync_handler.dart';

/// Mirror one of the host's sequencer events onto this client's run record.
///
/// A host folds its own run's events (the executor attached to the run, or
/// the always-on pump), so on a host only the library notice is acted on.
void _applySequencerEvent(
  Object reader,
  SkotiqEvent event, {
  SkotiqBackend? networkBackend,
}) {
  if (event.eventType == sequenceUpdatedEventType) {
    _invalidateSequenceLibrary(
      reader,
      sequenceId: event.data['sequenceId'] as int?,
    );
    return;
  }
  if (networkBackend == null) return;

  final typed = SequencerRunEvent.fromSkotiqEvent(event);
  if (typed != null) {
    foldRunEvent(_read(reader, runRecordProvider.notifier), typed);
  }
  switch (event.eventType) {
    case 'NodeStarted':
      // A new node/target means the host autopilot's live pick likely changed;
      // refresh the mirrored preview so the banner here tracks the switch
      // (no-op when the banner isn't mounted — it's autoDispose).
      _invalidate(reader, schedulerPreviewDecisionProvider);
    case 'ProgressUpdated':
    case 'InstructionProgress':
      unawaited(_refreshSequencerStatus(reader, networkBackend));
  }
}

/// Mirror a run-control change the host announced (started, paused, resumed,
/// stopped, or a state it names). A host's own run state comes from its
/// executor, so the announcement is acted on only by a linked client.
void _applySequencerMutationFromHost(
  Object reader,
  String action,
  Map<String, dynamic> data,
) {
  if (_read(reader, backendProvider).remoteHost == null) return;
  final String? rawState = switch (action) {
    HostMutationAction.started || HostMutationAction.resumed => 'running',
    HostMutationAction.paused => 'paused',
    HostMutationAction.stopped => 'idle',
    _ => data['state'] as String?,
  };
  if (rawState == null) return;
  _read(
    reader,
    runRecordProvider.notifier,
  ).mirrorHostState(rawState, message: data['message'] as String?);
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
  _read(reader, runRecordProvider.notifier).mirrorHostState(
    status.state,
    message: status.message,
    currentNodeId: status.currentNodeId,
    currentNodeName: status.currentNodeName,
  );

  // Mirror the master's live run-vitals onto the slave's Session Vitals tile.
  // The local executor never writes liveSequenceStatsProvider on a slave, so
  // without this the Vitals tile reads idle next to a live progress bar. Null
  // vitals (idle host, or a host build that doesn't emit them) clears the tile.
  final vitals = status.runVitals;
  _read(
    reader,
    runRecordProvider.notifier,
  ).setStats(vitals == null ? null : SequenceRunStats.fromRemoteVitals(vitals));

  // Why the host's guiding is stopped. Live StopReason events carry it too,
  // but only to a client that was listening when it was set: one that joined
  // during a tracking-limit hold read "Guider needs a look" with no reason.
  if (status.reportsGuidingStopReason) {
    _read(reader, guidingStopReasonProvider.notifier).state =
        status.guidingStopReason;
  }
}
