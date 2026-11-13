part of '../remote_sync_handler.dart';

/// Re-reads the sequence library when [event] says a sequence changed.
/// Returns whether it was that notice.
bool _applySequenceLibraryNotice(ProviderContainer container, SkotiqEvent event) {
  if (event.eventType != sequenceUpdatedEventType) return false;
  _invalidateSequenceLibrary(
    container,
    sequenceId: event.data['sequenceId'] as int?,
  );
  return true;
}

/// Fold one of the host's sequencer events into this client's run record.
void _mirrorHostRunEvent(
  ProviderContainer container,
  SkotiqBackend backend,
  SkotiqEvent event,
) {
  final typed = SequencerRunEvent.fromSkotiqEvent(event);
  if (typed != null) {
    foldRunEvent(container.read(runRecordProvider.notifier), typed);
  }
  switch (event.eventType) {
    case 'NodeStarted':
      // A new node or target usually changes what the host's autopilot would
      // pick next, which the banner here shows.
      container.invalidate(schedulerPreviewDecisionProvider);
    case 'ProgressUpdated':
    case 'InstructionProgress':
      unawaited(_refreshSequencerStatus(container, backend));
  }
}

/// Mirror a run-control change the host announced (started, paused, resumed,
/// stopped, or a state it names).
void _mirrorHostRunControl(
  ProviderContainer container,
  String action,
  Map<String, dynamic> data,
) {
  final String? rawState = switch (action) {
    HostMutationAction.started || HostMutationAction.resumed => 'running',
    HostMutationAction.paused => 'paused',
    HostMutationAction.stopped => 'idle',
    _ => data['state'] as String?,
  };
  if (rawState == null) return;
  container
      .read(runRecordProvider.notifier)
      .mirrorHostState(rawState, message: data['message'] as String?);
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

void _invalidateSequenceLibrary(ProviderContainer container, {int? sequenceId}) {
  container.invalidate(savedSequencesProvider);
  container.invalidate(savedSequenceSummariesProvider);
  if (sequenceId != null) {
    unawaited(reloadOpenSequenceIfIdle(container, sequenceId));
  }
}

Future<void> _refreshSequencerStatus(
  ProviderContainer container,
  SkotiqBackend backend,
) async {
  try {
    final status = await backend.sequencerGetStatus();
    _applySequencerStatus(container, status);
  } catch (_) {
    // Fail closed on the event path — hydration/polling will recover.
  }
}

void _applySequencerStatus(ProviderContainer container, SequencerStatus status) {
  container.read(runRecordProvider.notifier).mirrorHostState(
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
  container.read(runRecordProvider.notifier,
  ).setStats(vitals == null ? null : SequenceRunStats.fromRemoteVitals(vitals));

  // Why the host's guiding is stopped. Live StopReason events carry it too,
  // but only to a client that was listening when it was set: one that joined
  // during a tracking-limit hold read "Guider needs a look" with no reason.
  if (status.reportsGuidingStopReason) {
    container.read(guidingStopReasonProvider.notifier).state =
        status.guidingStopReason;
  }
}
