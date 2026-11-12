part of '../remote_sync_handler.dart';

/// Fill a linked client from its host: on connect, on reconnect and with the
/// periodic re-read.
///
/// The host's runtime channels carry its devices, guider, open plan and the
/// results only its process computes; what follows them here is data the
/// host stores (profiles, settings, plans, history), which is fetched again.
///
/// [refreshCurrentFrame] is false for the periodic re-read. The host's last
/// frame is a full-resolution JPEG plus its raw pixels (tens of MB), and new
/// frames arrive through ImageReady events, so only first connect and
/// BackendReconnected, after which frames may have been missed, fetch it.
Future<void> hydrateRemoteSessionState(
  Object reader,
  SkotiqBackend backend, {
  bool refreshCurrentFrame = true,
}) async {
  if (!_isCurrentRemoteBackend(reader, backend)) return;
  final host = backend.remoteHost;
  if (host == null) return;
  final status = await backend.sequencerGetStatus();
  if (!_isCurrentRemoteBackend(reader, backend)) return;
  _applySequencerStatus(reader, status);

  // The host's plate solver can be set up or changed while this client is
  // linked (or across a host restart); read it again rather than keep what it
  // reported when the client connected.
  refreshHostPlateSolverState(reader);

  // Live changes arrive as HostRuntimeState events; this fills a client that
  // connected or reconnected after them.
  try {
    await hydrateHostRuntimeState(reader, backend);
    await mirrorDevicesOfOlderHost(
      reader,
      backend,
      isCurrent: () => _isCurrentRemoteBackend(reader, backend),
    );
  } catch (e) {
    // An unreachable endpoint leaves the values the events already applied.
    developer.log(
      'Runtime state hydration failed: $e',
      name: 'RemoteSessionSync',
      level: 900,
    );
  }
  if (!_isCurrentRemoteBackend(reader, backend)) return;

  // The host's last frame, for a client whose camera slot is now filled. The
  // capture publisher runs only on the host, so without this the current
  // frame stays blank until the next ImageReady event.
  final cameraState = _read(reader, cameraStateProvider);
  if (refreshCurrentFrame &&
      cameraState.connectionState == DeviceConnectionState.connected) {
    unawaited(_publishRemoteCurrentFrame(reader, backend));
  }

  // The night so far: a client that connects mid-session opens on the host's
  // event log rather than an empty one. Not on the periodic re-hydrate; a
  // reconnect's missed events come from the WebSocket replay.
  if (refreshCurrentFrame) {
    await seedEventLogFromHost(reader, backend);
  }

  // Active-profile + populated cards parity at first connect: refetch the
  // profile providers from the (now SQLite-backed) host /api/profiles so the
  // slave's equipment screen reflects the master's real active profile
  // immediately, not only after the next 10s poll / profile mutation.
  _invalidateHostProfiles(reader);

  // Settings parity at first connect must not wait for the 10s poll: force a
  // re-pull of appSettingsProvider (its build() re-fetches backend.getSettings
  // on a linked client). No-op cost on the host (settings are local there;
  // hydration only runs on the slave / on BackendReconnected).
  _invalidate(reader, appSettingsProvider);

  // The host's key/value settings (sequencer defaults, presets, scheduler
  // config and the rest): re-fetch on connect and on every periodic
  // re-hydrate, so a change the host did not announce still arrives within
  // one cycle. Providers re-read only when a value actually changed.
  _read(reader, hostSettingsStoreProvider)?.refresh();

  _invalidateEquipmentSyncProviders(reader);
  host.runtimeMirror.invalidateDeviceCache();
  _invalidate(reader, savedSequencesProvider);
  _invalidate(reader, savedSequenceSummariesProvider);

  // Mirror the host's autopilot pick on connect (and each 30s re-hydrate): in
  // linked mode schedulerPreviewDecisionProvider re-fetches GET
  // /api/scheduler/preview, so the slave's autopilot banner shows the host's
  // real "what the rig would slew to next" instead of recomputing "nothing
  // eligible" against the slave's empty local catalog.
  _invalidate(reader, schedulerPreviewDecisionProvider);

  // Refresh the host-mirrored planner/scheduler DATA streams on connect (and
  // each 30s re-hydrate) so the slave's Projects tab, integration-goal editor,
  // and target-constraint editor show the host's rows immediately rather than
  // waiting out their first poll tick. On a linked client these providers
  // re-fetch GET /api/projects, /api/integration-goals, /api/target-constraints.
  _invalidate(reader, projectListProvider);
  _invalidate(reader, integrationGoalsStreamProvider);
  _invalidate(reader, targetConstraintsStreamProvider);

  // Run-history parity on connect: on a linked client sequenceRunsProvider
  // polls GET /api/sequence-runs. Invalidating restarts that poll so the
  // dashboard "Last night" recap, cockpit Morning Report, and the sequencer
  // History tab show the master's real run history immediately instead of
  // waiting out the first poll tick (or, before this branch, rendering empty).
  _invalidate(reader, sequenceRunsProvider);

  // Observing-lists parity on connect: on a linked client these providers
  // re-poll GET /api/observing-lists (and the listed-catalog-ids markers), so
  // the slave's planetarium Lists tab, the "add to list" pickers, and the
  // star-chart list markers show the master's curated lists immediately rather
  // than waiting out the first poll tick. (observingListItemsProvider is a
  // family keyed by the open list, so it re-polls when first watched.)
  _invalidate(reader, observingListsProvider);
  _invalidate(reader, listedCatalogIdsProvider);
}

/// Fill an empty event log with the host's recent events. Only into an empty
/// history, so nothing is added twice.
Future<void> seedEventLogFromHost(Object reader, SkotiqBackend backend) async {
  if (_read(reader, eventHistoryProvider).isNotEmpty) return;
  final runState = backend.remoteHost?.runState;
  if (runState == null) return;
  try {
    final events = await runState.getHostRecentEvents();
    if (!_isCurrentRemoteBackend(reader, backend)) return;
    final typed = [
      for (final event in events.reversed) ?tryBridgeEventFromCoreEvent(event),
    ];
    _read(reader, eventHistoryProvider.notifier).seedEarlier(typed);
  } catch (e) {
    // The log then starts with the first live event, as before.
    developer.log(
      'Event log seeding failed: $e',
      name: 'RemoteSessionSync',
      level: 900,
    );
  }
}

/// Read the host's plate solver (what it detects and how it is set up) again.
/// A linked client kept what the host reported when it connected, so a solver
/// set up on the host afterwards still read "No plate solver" here.
void refreshHostPlateSolverState(Object reader) {
  _invalidate(reader, plateSolverDetectionProvider);
  _invalidate(reader, plateSolverPreferenceProvider);
}
