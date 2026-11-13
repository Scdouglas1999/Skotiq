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

/// Follow one of the host's run events. The run's progress arrives on the
/// `sequenceRun` and `runRecord` channels, not from these.
void _followHostRunEvent(ProviderContainer container, SkotiqEvent event) {
  if (SequencerRunEvent.fromSkotiqEvent(event) is NodeStarted) {
    // A new node or target usually changes what the host's autopilot would
    // pick next, which the banner here shows.
    container.invalidate(schedulerPreviewDecisionProvider);
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

void _invalidateSequenceLibrary(ProviderContainer container, {int? sequenceId}) {
  container.invalidate(savedSequencesProvider);
  container.invalidate(savedSequenceSummariesProvider);
  if (sequenceId != null) {
    unawaited(reloadOpenSequenceIfIdle(container, sequenceId));
  }
}

/// Why the host's guiding is stopped, from its run status.
void _applySequencerStatus(ProviderContainer container, SequencerStatus status) {
  // Why the host's guiding is stopped. Live StopReason events carry it too,
  // but only to a client that was listening when it was set: one that joined
  // during a tracking-limit hold read "Guider needs a look" with no reason.
  if (status.reportsGuidingStopReason) {
    container.read(guidingStopReasonProvider.notifier).state =
        status.guidingStopReason;
  }
}
