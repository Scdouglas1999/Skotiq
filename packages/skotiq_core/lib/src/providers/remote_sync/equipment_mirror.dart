part of '../remote_sync_handler.dart';

void _applyEquipmentEvent(
  Object reader,
  SkotiqEvent event, {
  NetworkBackend? networkBackend,
}) {
  final data = event.data;
  switch (event.eventType) {
    case 'Connecting':
      _applyConnectingDevice(
        reader,
        data['device_type'] as String?,
        data['device_id'] as String?,
        data['device_name'] as String?,
      );
      break;
    case 'Connected':
      _applyConnectedDeviceFromPayload(
        reader,
        data['device_type'] as String?,
        data['device_id'] as String?,
        data['device_name'] as String?,
      );
      if (networkBackend != null) {
        _fetchConnectedFocuserCaps(reader, networkBackend, data);
      }
      // Do NOT invalidate equipmentProfilesProvider here. A device
      // connecting/disconnecting does not change the profile LIST or the active
      // profile, but on a slave equipmentProfilesProvider is network-backed:
      // invalidating it round-trips to the host and cascades through
      // opticalConfigProvider -> tonightSuggestionsProvider, so doing it on
      // every mirrored Connected/Disconnected event made "Plan Tonight" thrash
      // (constant refresh). Connection STATE is already applied above via the
      // per-device state providers. Profile refreshes happen on actual profile
      // events (profileChanged / HostMutationEntity.profile) instead.
      break;
    case 'Disconnected':
      _applyDeviceDisconnectedFromSyncPayload(reader, data);
      break;
    default:
      // Live telemetry mirroring is SLAVE-ONLY: on the host both
      // DeviceService.event_handling AND host_local_sync run, so applying
      // these here when networkBackend == null (the host path) would
      // double-apply state DeviceService already wrote. The slave is a pure
      // observer with no DeviceService, so networkBackend != null cleanly
      // scopes this to the remote companion. Connection-state cases above
      // stay unconditional (they run on both host and slave).
      if (networkBackend != null) {
        _applyEquipmentTelemetry(reader, event.eventType, data);
      }
      break;
  }
}

/// Slave-only: mirror the master's live equipment telemetry into the same
/// per-device notifiers [DeviceService.event_handling] writes on the host, but
/// with NO reconnect / critical-device / heartbeat side effects (a remote
/// companion must never originate connect commands back to the host).
///
/// Event names + payload shapes are kept in lock-step with
/// `device_service/event_handling.dart`. Only camera/mount/focuser/filter-
/// wheel/rotator carry live values; dome/weather/safetyMonitor/coverCalibrator/
/// switch mirror CONNECTION STATE ONLY (no source telemetry events). The
/// per-frame exposure countdown is mirrored via the imaging-category
/// `ExposureStarted`/`ExposureProgress`/`ExposureComplete` events in
/// [_applyExposureMirror]; the current-frame hero tile is mirrored separately
/// via the imaging/current-frame path.
void _applyEquipmentTelemetry(
  Object reader,
  String eventType,
  Map<String, dynamic> data,
) {
  switch (eventType) {
    // Camera cooler and temperature, focuser, filter wheel and rotator: the
    // applier the host's DeviceService uses too, which ignores events for a
    // device not in the slot (a guide camera, a second focuser).
    case 'CameraTemperatureChanged':
    case 'CameraCoolingStarted':
    case 'CameraCoolingReached':
    case 'CameraWarmingStarted':
    case 'CameraWarmingCompleted':
    case 'FocuserMoveStarted':
    case 'FocuserMoveCompleted':
    case 'FilterChanging':
    case 'FilterChanged':
    case 'RotatorMoveStarted':
    case 'RotatorMoveCompleted':
      applyDeviceStateEvent(reader, eventType, data);
      break;

    // Mount position / motion
    case 'MountSlewStarted':
      _read(reader, mountStateProvider.notifier).setSlewing(true);
      break;
    case 'MountSlewCompleted':
      // Carries the commanded target, not a reading; see event_handling.
      _read(reader, mountStateProvider.notifier).setSlewing(false);
      break;
    case 'MountTrackingStarted':
      _read(reader, mountStateProvider.notifier).setTracking(true);
      break;
    case 'MountTrackingStopped':
      _read(reader, mountStateProvider.notifier).setTracking(false);
      break;
    case 'MountParkStarted':
      _read(reader, mountStateProvider.notifier).setSlewing(true);
      break;
    case 'MountParkCompleted':
      _read(reader, mountStateProvider.notifier).setSlewing(false);
      _read(reader, mountStateProvider.notifier).setParked(true);
      _read(reader, mountStateProvider.notifier).setTracking(false);
      break;
    case 'MountUnparked':
      _read(reader, mountStateProvider.notifier).setParked(false);
      break;

    // Focuser
    case 'FocuserTemperatureChanged':
      final temperature = (data['temperature'] as num?)?.toDouble();
      if (temperature != null) {
        _read(
          reader,
          focuserStateProvider.notifier,
        ).updateTemperature(temperature);
      }
      break;

    // Settings with no event of their own (gain, offset, binning, slot names,
    // rotator sync and reverse, switch writes, dome slaving).
    case 'PropertyChanged':
      applyDevicePropertyChange(reader, data);
      break;
    case 'CameraSettingsChanged':
      applyCameraSettings(reader, data);
      break;
  }
}

/// Slave-only: a `Connected` equipment event carries no focuser capability
/// flags, so a focuser that connects on the host between 30 s hydration ticks
/// leaves the slave's card claiming absolute positioning is unsupported.
/// Backfill the caps from one status fetch; telemetry-only, errors swallowed
/// (the next hydration repoll retries).
void _fetchConnectedFocuserCaps(
  Object reader,
  NetworkBackend backend,
  Map<String, dynamic> data,
) {
  final deviceType = data['device_type'] as String?;
  final deviceId = data['device_id'] as String?;
  if (deviceType == null ||
      deviceId == null ||
      deviceTypeFromWireName(deviceType) != DeviceType.focuser) {
    return;
  }
  unawaited(() async {
    try {
      final status = await backend.getFocuserStatus(deviceId);
      final notifier = _read(reader, focuserStateProvider.notifier);
      if (notifier.deviceId != deviceId) return;
      notifier.setConnected(
        maxPosition: status.maxPosition,
        stepSize: status.stepSize,
        isAbsolute: status.isAbsolute,
        hasTemperature: status.hasTemperature,
      );
    } catch (_) {}
  }());
}

void _invalidateEquipmentSyncProviders(Object reader) {
  _invalidate(reader, equipmentProfilesProvider);
  // Deliberately NOT invalidating unifiedDiscoveryProvider here. It is a
  // StateNotifier whose state resets to an EMPTY device list on invalidation
  // and does not auto-rediscover, so invalidating it on every remote
  // Connected/Disconnected event wipes the user's scanned "Available Devices"
  // list (the whole panel goes blank the instant they connect a device in
  // remote-client mode). Device connection *status* is tracked by the
  // per-class device state providers (updated above via the sync payload),
  // not by the discovery list, so the discovered set is stable across
  // connect/disconnect and must be left intact.
}
