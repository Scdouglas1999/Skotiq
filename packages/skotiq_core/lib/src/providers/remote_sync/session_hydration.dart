part of '../remote_sync_handler.dart';

/// Full session hydration for remote companions (and reconnect recovery).
///
/// Makes the slave correct IMMEDIATELY on first connect and TELEMETRY-STABLE
/// across the 30s repoll: it never blanks a populated card. Per-device live
/// status is fetched into a LOCAL BUFFER first (each fetch wrapped in its own
/// try/catch, all run in parallel via [Future.wait]), then applied in a single
/// pass. On a per-device failure the prior telemetry for that device is left
/// intact — one slow device on a high-latency link can neither stall nor wipe
/// the others. Connection state is applied first so cards exist before live
/// values land.
///
/// [refreshCurrentFrame] is false for the periodic re-hydrate. The host's last
/// frame is a full-resolution JPEG plus its raw pixels (tens of MB), and new
/// frames arrive through ImageReady events, so only first connect and
/// BackendReconnected, after which frames may have been missed, fetch it.
Future<void> hydrateRemoteSessionState(
  Object reader,
  NetworkBackend backend, {
  bool refreshCurrentFrame = true,
}) async {
  if (!_isCurrentRemoteBackend(reader, backend)) return;
  final status = await backend.sequencerGetStatus();
  if (!_isCurrentRemoteBackend(reader, backend)) return;
  _applySequencerStatus(reader, status);

  final devices = await backend.getConnectedDevices();
  if (!_isCurrentRemoteBackend(reader, backend)) return;
  _dropDevicesTheHostNoLongerReports(reader, devices);
  for (final device in devices) {
    _applyConnectedDevice(reader, device);
  }

  // Buffer-then-apply per-device live telemetry. Only camera/mount/focuser/
  // filterwheel/rotator expose a status GET; dome/weather/safetyMonitor/
  // coverCalibrator/switch mirror connection state only (no status endpoint).
  await _hydrateDeviceTelemetry(reader, backend, devices);
  if (!_isCurrentRemoteBackend(reader, backend)) return;

  // G3 (current-frame hero tile): seed the master's last cached frame on
  // connect. The host-local capture publisher never runs on a slave, so without
  // this the dashboard's "current frame" tile stays blank until the next
  // ImageReady event. _publishRemoteCurrentFrame resolves the connected camera
  // from the (now-hydrated) camera state and no-ops if none is connected or no
  // frame is cached host-side, so the guard mirrors the live-event path.
  final cameraState = _read(reader, cameraStateProvider);
  if (refreshCurrentFrame &&
      cameraState.connectionState == DeviceConnectionState.connected) {
    unawaited(_publishRemoteCurrentFrame(reader, backend));
  }

  // G2 (open sequence-editor canvas): seed the master's live/dirty editor
  // canvas. It otherwise mirrors only via edit-triggered WS frames, so a slave
  // connecting mid-edit shows a blank sequencer screen until the next master
  // edit. Fetch the master's currently-open editor sequence in the same payload
  // shape the live mirror emits and feed it through the existing apply path.
  await _hydrateOpenEditorSequence(reader, backend);
  if (!_isCurrentRemoteBackend(reader, backend)) return;

  await _hydratePhd2GuiderState(reader, backend);
  if (!_isCurrentRemoteBackend(reader, backend)) return;

  // Runtime results only the host's GUI computes (plate solve, centering,
  // autofocus, the frame on screen). Live changes arrive as HostRuntimeState
  // events; this fills a client that connected or reconnected after them.
  try {
    await hydrateHostRuntimeState(reader, backend);
  } catch (_) {
    // An unreachable endpoint leaves the values the events already applied.
  }
  if (!_isCurrentRemoteBackend(reader, backend)) return;

  // Active-profile + populated cards parity at first connect: refetch the
  // profile providers from the (now SQLite-backed) host /api/profiles so the
  // slave's equipment screen reflects the master's real active profile
  // immediately, not only after the next 10s poll / profile mutation.
  _invalidateHostProfiles(reader);

  // Settings parity at first connect must not wait for the 10s poll: force a
  // re-pull of appSettingsProvider (its build() re-fetches backend.getSettings
  // in NetworkBackend mode). No-op cost on the host (settings are local there;
  // hydration only runs on the slave / on BackendReconnected).
  _invalidate(reader, appSettingsProvider);

  // Framing target is NOT seeded from framing/current-position here: that GET
  // returns the mount's current pointing (already mirrored via getMountStatus),
  // not a chosen framing target, and FramingNotifier.setTargetCoordinates would
  // clobber the real target + trigger a survey-image load + push back to the
  // host. Framing target parity flows through the framingTargetChanged event +
  // HostMutationEntity.framing path instead.

  _invalidateEquipmentSyncProviders(reader);
  backend.invalidateDeviceCache();
  _invalidate(reader, savedSequencesProvider);
  _invalidate(reader, savedSequenceSummariesProvider);

  // Mirror the host's autopilot pick on connect (and each 30s re-hydrate): in
  // NetworkBackend mode schedulerPreviewDecisionProvider re-fetches GET
  // /api/scheduler/preview, so the slave's autopilot banner shows the host's
  // real "what the rig would slew to next" instead of recomputing "nothing
  // eligible" against the slave's empty local catalog.
  _invalidate(reader, schedulerPreviewDecisionProvider);

  // Refresh the host-mirrored planner/scheduler DATA streams on connect (and
  // each 30s re-hydrate) so the slave's Projects tab, integration-goal editor,
  // and target-constraint editor show the host's rows immediately rather than
  // waiting out their first poll tick. In NetworkBackend mode these providers
  // re-fetch GET /api/projects, /api/integration-goals, /api/target-constraints.
  _invalidate(reader, projectListProvider);
  _invalidate(reader, integrationGoalsStreamProvider);
  _invalidate(reader, targetConstraintsStreamProvider);

  // Run-history parity on connect: in NetworkBackend mode sequenceRunsProvider
  // polls GET /api/sequence-runs. Invalidating restarts that poll so the
  // dashboard "Last night" recap, cockpit Morning Report, and the sequencer
  // History tab show the master's real run history immediately instead of
  // waiting out the first poll tick (or, before this branch, rendering empty).
  _invalidate(reader, sequenceRunsProvider);

  // Observing-lists parity on connect: in NetworkBackend mode these providers
  // re-poll GET /api/observing-lists (and the listed-catalog-ids markers), so
  // the slave's planetarium Lists tab, the "add to list" pickers, and the
  // star-chart list markers show the master's curated lists immediately rather
  // than waiting out the first poll tick. (observingListItemsProvider is a
  // family keyed by the open list, so it re-polls when first watched.)
  _invalidate(reader, observingListsProvider);
  _invalidate(reader, listedCatalogIdsProvider);
}

/// Device types whose cards mirror the host's connected-device list. The
/// guider is left out: PHD2 is not always listed by getConnectedDevices, and its
/// card is hydrated from phd2/status instead.
const _hostListedDeviceTypes = <DeviceType>[
  DeviceType.camera,
  DeviceType.mount,
  DeviceType.focuser,
  DeviceType.filterWheel,
  DeviceType.rotator,
  DeviceType.dome,
  DeviceType.weather,
  DeviceType.safetyMonitor,
  DeviceType.switch_,
  DeviceType.coverCalibrator,
];

/// Disconnect only the cards whose device the host no longer reports. A card
/// whose device is still connected keeps its state and telemetry; resetting
/// every card on each re-hydrate blanked readouts until the status fetches
/// landed.
void _dropDevicesTheHostNoLongerReports(
  Object reader,
  List<DeviceInfo> devices,
) {
  for (final type in _hostListedDeviceTypes) {
    final notifier = readDeviceConnectionNotifier(reader, type);
    final deviceId = notifier.deviceId;
    if (deviceId == null &&
        notifier.connectionState == DeviceConnectionState.disconnected) {
      continue;
    }
    final stillReported = devices.any(
      (d) => d.deviceType == type && d.id == deviceId,
    );
    if (stillReported) continue;
    notifier.setDisconnected();
    if (deviceId != null) {
      try {
        _read(
          reader,
          deviceHeartbeatHealthProvider.notifier,
        ).clearDevice(deviceId);
      } on Object {
        // The heartbeat provider may be mid-disposal during shutdown.
      }
    }
  }
}

/// Buffer-then-apply per-device live status for the connected equipment that
/// exposes a status GET. Each fetch is isolated in its own try/catch and run in
/// parallel; results are applied only after ALL fetches settle, so a failed or
/// slow device never blanks a card.
Future<void> _hydrateDeviceTelemetry(
  Object reader,
  NetworkBackend backend,
  List<DeviceInfo> devices,
) async {
  String? idFor(DeviceType type) =>
      devices.where((d) => d.deviceType == type).map((d) => d.id).firstOrNull;

  final cameraId = idFor(DeviceType.camera);
  final mountId = idFor(DeviceType.mount);
  final focuserId = idFor(DeviceType.focuser);
  final filterWheelId = idFor(DeviceType.filterWheel);
  final rotatorId = idFor(DeviceType.rotator);

  CameraStatus? cameraStatus;
  MountStatus? mountStatus;
  FocuserStatus? focuserStatus;
  FilterWheelStatus? filterWheelStatus;
  RotatorStatus? rotatorStatus;

  Future<void> fetchCamera() async {
    if (cameraId == null) return;
    try {
      cameraStatus = await backend.getCameraStatus(cameraId);
    } catch (_) {
      // Leave prior camera telemetry intact.
    }
  }

  Future<void> fetchMount() async {
    if (mountId == null) return;
    try {
      mountStatus = await backend.getMountStatus(mountId);
    } catch (_) {
      // Leave prior mount telemetry intact.
    }
  }

  Future<void> fetchFocuser() async {
    if (focuserId == null) return;
    try {
      focuserStatus = await backend.getFocuserStatus(focuserId);
    } catch (_) {
      // Leave prior focuser telemetry intact.
    }
  }

  Future<void> fetchFilterWheel() async {
    if (filterWheelId == null) return;
    try {
      filterWheelStatus = await backend.getFilterWheelStatus(filterWheelId);
    } catch (_) {
      // Leave prior filter-wheel telemetry intact.
    }
  }

  Future<void> fetchRotator() async {
    if (rotatorId == null) return;
    try {
      rotatorStatus = await backend.getRotatorStatus(rotatorId);
    } catch (_) {
      // Leave prior rotator telemetry intact.
    }
  }

  await Future.wait([
    fetchCamera(),
    fetchMount(),
    fetchFocuser(),
    fetchFilterWheel(),
    fetchRotator(),
  ]);
  if (!_isCurrentRemoteBackend(reader, backend)) return;

  // Single apply pass — no intervening clear, so cards never blank.
  //
  // The status fetches ran in parallel with the live event mirror. A device
  // the host disconnected meanwhile has had its notifier reset (deviceId
  // cleared), and a status read before that is no evidence of its state now,
  // so each device's apply is skipped when its card no longer holds the id it
  // was fetched for. Without that a camera disconnected mid-exposure came
  // back as a disconnected card still exposing and cooling, and a focuser as
  // connected.
  final camera = cameraStatus;
  final cameraNotifier = _read(reader, cameraStateProvider.notifier);
  if (camera != null && cameraNotifier.deviceId == cameraId) {
    final notifier = cameraNotifier;
    final temp = camera.sensorTemp;
    if (temp != null) {
      // `updateTemperature`'s power argument is null-aware
      // (`clearCoolerPower: power == null`), and `CameraStatus.coolerPower` is
      // null exactly when the host's driver reports no cooler power. Pass it
      // through: the cards branch on `coolerPower != null` to show "unknown",
      // so coercing to 0.0 here would claim a real 0 % reading.
      notifier.updateTemperature(temp, camera.coolerPower);
    }
    notifier.setCooling(camera.coolerOn);
    final target = camera.targetTemp;
    if (target != null) {
      notifier.setTargetTemp(target);
    }
    // G4 (in-flight exposure): the fetched status already reports whether the
    // master is mid-exposure. Seed the Exposing flag the same way the live
    // ExposureStarted handler does so the card/status isn't stuck Idle on a
    // mid-session connect. Precise remaining-time legitimately waits for the
    // first live ExposureProgress tick; here we only flip the flag.
    if (camera.state == CameraState.exposing) {
      notifier.setExposing(true);
    }
  }

  final mount = mountStatus;
  final mountNotifier = _read(reader, mountStateProvider.notifier);
  if (mount != null && mountNotifier.deviceId == mountId) {
    final notifier = mountNotifier;
    notifier.updatePosition(
      mount.rightAscension,
      mount.declination,
      mount.altitude,
      mount.azimuth,
    );
    notifier.setTracking(mount.tracking);
    notifier.setSlewing(mount.slewing);
    notifier.setParked(mount.parked);
    notifier.setTrackingRate(mount.trackingRate);
  }

  final focuser = focuserStatus;
  final focuserNotifier = _read(reader, focuserStateProvider.notifier);
  if (focuser != null && focuserNotifier.deviceId == focuserId) {
    final notifier = focuserNotifier;
    // The status payload carries the capability flags the reset wiped;
    // without them the slave's focuser card claims absolute positioning is
    // unsupported and disables Go To Position (same shape as the
    // filter-wheel names below). setConnected preserves live values.
    notifier.setConnected(
      maxPosition: focuser.maxPosition,
      stepSize: focuser.stepSize,
      isAbsolute: focuser.isAbsolute,
      hasTemperature: focuser.hasTemperature,
    );
    notifier.updatePosition(focuser.position);
    notifier.setMoving(focuser.moving);
    final temp = focuser.temperature;
    if (temp != null) {
      notifier.updateTemperature(temp);
    }
  }

  final filterWheel = filterWheelStatus;
  final filterWheelNotifier = _read(reader, filterWheelStateProvider.notifier);
  if (filterWheel != null && filterWheelNotifier.deviceId == filterWheelId) {
    final notifier = filterWheelNotifier;
    notifier.updatePosition(filterWheel.position);
    notifier.setMoving(filterWheel.moving);
    // The fetched status already carries the wheel's filter names; apply them
    // so the slave shows the filter list (not just the position). Without this
    // the names were fetched and silently dropped, leaving filterNames empty on
    // the slave. setConnected preserves position/state and merges the names.
    if (filterWheel.filterNames.isNotEmpty) {
      notifier.setConnected(filterNames: filterWheel.filterNames);
    }
  }

  final rotator = rotatorStatus;
  final rotatorNotifier = _read(reader, rotatorStateProvider.notifier);
  if (rotator != null && rotatorNotifier.deviceId == rotatorId) {
    final notifier = rotatorNotifier;
    notifier.updatePosition(
      rotator.position,
      mechanicalPosition: rotator.mechanicalPosition,
    );
    notifier.setMoving(rotator.moving || rotator.isMoving);
  }
}
