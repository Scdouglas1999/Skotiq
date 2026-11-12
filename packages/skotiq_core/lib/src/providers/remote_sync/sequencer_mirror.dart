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

/// SLAVE apply: mirror the master's OPEN sequence-editor canvas.
///
/// The master broadcasts its open plan via the
/// [HostMutationEntity.sequenceEditor] host-mutation (see
/// `masterSequenceEditorMirrorProvider`), and hydration fetches it. Here the
/// slave reflects it onto its own [currentSequenceProvider].
///
/// The slave writes its own changes into the host's editor
/// (`remoteSequenceEditorSyncProvider`), so the two edit one plan and the
/// last writer wins:
///   * an edit made here that has not reached the host yet is kept; the
///     write lands after this frame and replaces it on the host;
///   * the host closing its editor closes the plan here too;
///   * otherwise the host's plan replaces the one shown here, with a note
///     when it replaces a plan this client wrote;
///   * a plan that is already the one shown is not reloaded, so selection
///     and undo survive the periodic re-hydrate;
///   * while a run holds the editor, the host's running plan is shown so a
///     client that joined mid-run sees what is running.
void _applySequenceEditorMirror(
  Object reader,
  String action,
  Map<String, dynamic> data,
) {
  final editor = _read(reader, currentSequenceProvider.notifier);
  final sync = _read(reader, remoteEditorSyncStateProvider);
  final files = _read(reader, sequenceFileServiceProvider);
  final current = _read(reader, currentSequenceProvider);

  Sequence? parsed;
  if (action != HostMutationAction.cleared) {
    final rawSequence = data['sequence'];
    if (rawSequence is! Map) return;
    try {
      var seq = files.parseFromMap(Map<String, dynamic>.from(rawSequence));
      final dbId = data['databaseId'];
      if (dbId is int) seq = seq.copyWith(databaseId: dbId);
      parsed = seq;
    } catch (_) {
      // A malformed mirror frame must not crash the slave's sync loop. The
      // next frame (or a library reload) will recover.
      return;
    }
  }
  final incomingFingerprint = sequenceFingerprint(files, parsed);
  final currentFingerprint = sequenceFingerprint(files, current);

  if (!editor.isEditableNow) {
    if (parsed == null || incomingFingerprint == currentFingerprint) return;
    sync.appliedFromHost = parsed;
    sync.hostFingerprint = incomingFingerprint;
    editor.showHostRunningSequence(parsed);
    editor.adoptOwner(ActivePlanOwnerWire.fromWire(data['activePlanOwner']));
    return;
  }

  // Unsaved edits the host has not seen yet are on their way to it.
  final holdsUnsentEdits =
      editor.isDirty &&
      currentFingerprint != sync.lastWrittenFingerprint &&
      currentFingerprint != sync.hostFingerprint;
  if (sync.writePending || holdsUnsentEdits) return;

  final owner = parsed == null
      ? ActivePlanOwner.manual
      : ActivePlanOwnerWire.fromWire(data['activePlanOwner']);
  sync.hostFingerprint = incomingFingerprint;
  if (incomingFingerprint == currentFingerprint) {
    editor.adoptOwner(owner);
    return;
  }

  final replacesOwnWrite =
      current != null && currentFingerprint == sync.lastWrittenFingerprint;
  sync.appliedFromHost = parsed;
  // Clean here: the host's unsaved flag is the host's to act on, and a
  // dirty plan here would be saved to the library by this client.
  editor.applyPeerEdit(parsed, dirty: false);
  editor.adoptOwner(owner);
  if (replacesOwnWrite && parsed != null) {
    final backend = _read(reader, backendProvider);
    final host = backend.remoteHost?.link.serverHost ?? 'the host';
    _read(reader, uiNotificationProvider.notifier).showInfo(
      'The plan was changed on $host after your last edit; showing its '
      'version.',
      title: 'Plan updated',
    );
  }
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
/// code path. When no sequence is open host-side (the endpoint reports
/// `open: false`, as after a host restart) the plan shown here is closed the
/// same way a live "editor cleared" frame closes it. Returns silently when the
/// endpoint is unavailable on an older host.
Future<void> _hydrateOpenEditorSequence(
  Object reader,
  SkotiqBackend backend,
) async {
  final runState = backend.remoteHost?.runState;
  if (runState == null) return;
  final Map<String, dynamic>? payload;
  try {
    payload = await runState.getOpenEditorSequence();
  } catch (_) {
    // Older headless host without the endpoint, or a transient fetch error:
    // the live mirror still seeds the canvas on the master's next edit.
    return;
  }
  if (!_isCurrentRemoteBackend(reader, backend)) return;
  try {
    // No plan open on the host: close the one shown here, keeping an edit
    // made here that has not reached the host yet.
    _applySequenceEditorMirror(
      reader,
      payload == null ? HostMutationAction.cleared : HostMutationAction.updated,
      payload ?? const <String, dynamic>{},
    );
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
