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
    // Camera temperature / cooling
    case 'CameraTemperatureChanged':
      final temp = (data['temperature'] as num?)?.toDouble();
      // Null-aware on purpose: `updateTemperature` clears the cached power when
      // this is null, so a frame without `coolerPower` leaves the cards saying
      // "unknown" rather than claiming a real 0 % reading.
      final power = (data['coolerPower'] as num?)?.toDouble();
      if (temp != null) {
        _read(
          reader,
          cameraStateProvider.notifier,
        ).updateTemperature(temp, power);
      }
      break;
    case 'CameraCoolingStarted':
      final targetTemp = (data['target_temp'] as num?)?.toDouble();
      _read(reader, cameraStateProvider.notifier).setCooling(true);
      if (targetTemp != null) {
        _read(reader, cameraStateProvider.notifier).setTargetTemp(targetTemp);
      }
      break;
    case 'CameraCoolingReached':
      final temp = (data['temperature'] as num?)?.toDouble();
      if (temp != null) {
        _read(
          reader,
          cameraStateProvider.notifier,
        ).updateTemperature(temp, 0.0);
      }
      break;
    case 'CameraWarmingStarted':
      _read(reader, cameraStateProvider.notifier).setCooling(false);
      break;
    case 'CameraWarmingCompleted':
      // No additional state change (matches event_handling.dart).
      break;

    // Mount position / motion
    case 'MountPositionChanged':
      final ra = (data['ra'] as num?)?.toDouble();
      final dec = (data['dec'] as num?)?.toDouble();
      final alt = (data['altitude'] as num?)?.toDouble() ?? 0.0;
      final az = (data['azimuth'] as num?)?.toDouble() ?? 0.0;
      if (ra != null && dec != null) {
        _read(
          reader,
          mountStateProvider.notifier,
        ).updatePosition(ra, dec, alt, az);
      }
      if (data['isSlewing'] is bool) {
        _read(
          reader,
          mountStateProvider.notifier,
        ).setSlewing(data['isSlewing'] as bool);
      }
      if (data['isTracking'] is bool) {
        _read(
          reader,
          mountStateProvider.notifier,
        ).setTracking(data['isTracking'] as bool);
      }
      if (data['isParked'] is bool) {
        _read(
          reader,
          mountStateProvider.notifier,
        ).setParked(data['isParked'] as bool);
      }
      break;
    case 'MountSlewStarted':
      _read(reader, mountStateProvider.notifier).setSlewing(true);
      break;
    case 'MountSlewCompleted':
      _read(reader, mountStateProvider.notifier).setSlewing(false);
      final ra = (data['ra'] as num?)?.toDouble();
      final dec = (data['dec'] as num?)?.toDouble();
      if (ra != null && dec != null) {
        _read(
          reader,
          mountStateProvider.notifier,
        ).updatePosition(ra, dec, 0.0, 0.0);
      }
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
    case 'FocuserMoveStarted':
      _read(reader, focuserStateProvider.notifier).setMoving(true);
      break;
    case 'FocuserMoveCompleted':
      _read(reader, focuserStateProvider.notifier).setMoving(false);
      final position = data['position'] as int?;
      if (position != null) {
        _read(reader, focuserStateProvider.notifier).updatePosition(position);
      }
      break;
    case 'FocuserTemperatureChanged':
      final temperature = (data['temperature'] as num?)?.toDouble();
      if (temperature != null) {
        _read(
          reader,
          focuserStateProvider.notifier,
        ).updateTemperature(temperature);
      }
      break;
    case 'FocuserPositionChanged':
      final focuserPosition = data['position'] as int?;
      if (focuserPosition != null) {
        _read(
          reader,
          focuserStateProvider.notifier,
        ).updatePosition(focuserPosition);
      }
      final focuserMoving = data['isMoving'] as bool?;
      if (focuserMoving != null) {
        _read(reader, focuserStateProvider.notifier).setMoving(focuserMoving);
      }
      final focuserTemp = (data['temperature'] as num?)?.toDouble();
      if (focuserTemp != null) {
        _read(
          reader,
          focuserStateProvider.notifier,
        ).updateTemperature(focuserTemp);
      }
      break;

    // Filter wheel
    case 'FilterChanging':
      _read(reader, filterWheelStateProvider.notifier).setMoving(true);
      break;
    case 'FilterChanged':
      _read(reader, filterWheelStateProvider.notifier).setMoving(false);
      final position = data['position'] as int?;
      if (position != null) {
        _read(
          reader,
          filterWheelStateProvider.notifier,
        ).updatePosition(position);
      }
      break;
    case 'FilterWheelPositionChanged':
      final filterPosition = data['position'] as int?;
      if (filterPosition != null) {
        _read(
          reader,
          filterWheelStateProvider.notifier,
        ).updatePosition(filterPosition);
      }
      final filterMoving = data['isMoving'] as bool?;
      if (filterMoving != null) {
        _read(
          reader,
          filterWheelStateProvider.notifier,
        ).setMoving(filterMoving);
      }
      break;

    // Rotator
    case 'RotatorMoveStarted':
      _read(reader, rotatorStateProvider.notifier).setMoving(true);
      break;
    case 'RotatorMoveCompleted':
      _read(reader, rotatorStateProvider.notifier).setMoving(false);
      final angle = (data['angle'] as num?)?.toDouble();
      if (angle != null) {
        _read(reader, rotatorStateProvider.notifier).updatePosition(angle);
      }
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
