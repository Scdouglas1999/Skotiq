part of '../remote_sync_handler.dart';

/// Fill a linked client from its host: on connect, on reconnect and with the
/// periodic re-read.
///
/// The host's runtime channels carry its devices, guider, open plan and the
/// results only its process computes; the data the host stores (profiles,
/// settings, plans, history) is the list [_rereadWithTheHost].
///
/// [refreshCurrentFrame] is false for the periodic re-read. The host's last
/// frame is a full-resolution JPEG plus its raw pixels (tens of MB), and new
/// frames arrive through ImageReady events, so only first connect and
/// BackendReconnected, after which frames may have been missed, fetch it.
Future<void> hydrateRemoteSessionState(
  ProviderContainer container,
  SkotiqBackend backend, {
  bool refreshCurrentFrame = true,
}) async {
  if (!_isCurrentRemoteBackend(container, backend)) return;
  final host = backend.remoteHost;
  if (host == null) return;
  final status = await backend.sequencerGetStatus();
  if (!_isCurrentRemoteBackend(container, backend)) return;
  _applySequencerStatus(container, status);

  // Live changes arrive as HostRuntimeState events; this fills a client that
  // connected or reconnected after them.
  try {
    await hydrateHostRuntimeState(container, backend);
    await mirrorDevicesOfOlderHost(
      container,
      backend,
      isCurrent: () => _isCurrentRemoteBackend(container, backend),
    );
  } catch (e) {
    // An unreachable endpoint leaves the values the events already applied.
    developer.log(
      'Runtime state hydration failed: $e',
      name: 'RemoteSessionSync',
      level: 900,
    );
  }
  if (!_isCurrentRemoteBackend(container, backend)) return;

  // The host's last frame, for a client whose camera slot is now filled. The
  // capture publisher runs only on the host, so without this the current
  // frame stays blank until the next ImageReady event.
  final cameraState = container.read(cameraStateProvider);
  if (refreshCurrentFrame &&
      cameraState.connectionState == DeviceConnectionState.connected) {
    unawaited(_publishRemoteCurrentFrame(container, backend));
  }

  // The night so far: a client that connects mid-session opens on the host's
  // event log rather than an empty one. Not on the periodic re-hydrate; a
  // reconnect's missed events come from the WebSocket replay.
  if (refreshCurrentFrame) {
    await seedEventLogFromHost(container, backend);
  }

  rereadStoredHostData(container);
  host.runtimeMirror.invalidateDeviceCache();
}

/// Read again everything in [_rereadWithTheHost] and the host's key/value
/// settings (sequencer defaults, presets, scheduler config and the rest),
/// whose readers are told only when a value changed.
void rereadStoredHostData(ProviderContainer container) {
  for (final provider in _rereadWithTheHost) {
    container.invalidate(provider);
  }
  container.read(hostSettingsStoreProvider)?.refresh();
}

/// What a linked client reads again from its host on connect, on reconnect
/// and with each periodic re-read: the stored data the host announces no
/// change of, or whose announcement a client that was not listening missed.
/// Each then shows the host's value at once instead of after its own poll.
///
/// Add a provider here when a linked client fetches it from the host and
/// nothing else refreshes it.
final _rereadWithTheHost = <ProviderOrFamily>[
  // Equipment profiles and the one that is active.
  equipmentProfilesProvider,
  allProfilesProvider,
  activeProfileProvider,
  appSettingsProvider,
  // The host's plate solver can be set up while this client is linked.
  plateSolverDetectionProvider,
  plateSolverPreferenceProvider,
  savedSequencesProvider,
  savedSequenceSummariesProvider,
  // What the host's autopilot would slew to next.
  schedulerPreviewDecisionProvider,
  projectListProvider,
  integrationGoalsStreamProvider,
  targetConstraintsStreamProvider,
  sequenceRunsProvider,
  observingListsProvider,
  listedCatalogIdsProvider,
];

/// Fill an empty event log with the host's recent events. Only into an empty
/// history, so nothing is added twice.
Future<void> seedEventLogFromHost(ProviderContainer container, SkotiqBackend backend) async {
  if (container.read(eventHistoryProvider).isNotEmpty) return;
  final runState = backend.remoteHost?.runState;
  if (runState == null) return;
  try {
    final events = await runState.getHostRecentEvents();
    if (!_isCurrentRemoteBackend(container, backend)) return;
    final typed = [
      for (final event in events.reversed) ?tryBridgeEventFromCoreEvent(event),
    ];
    container.read(eventHistoryProvider.notifier).seedEarlier(typed);
  } catch (e) {
    // The log then starts with the first live event, as before.
    developer.log(
      'Event log seeding failed: $e',
      name: 'RemoteSessionSync',
      level: 900,
    );
  }
}
