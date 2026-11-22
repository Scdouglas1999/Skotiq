import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'camera_state_provider.dart';
import 'device_slots.dart';
import 'dome_state_provider.dart';
import 'filter_wheel_state_provider.dart';
import 'focuser_state_provider.dart';
import 'mount_state_provider.dart';
import 'rotator_state_provider.dart';
import 'switch_state_provider.dart';
import '../../backend/bridge_events.dart' as ev;
import '../../models/backend/device_types.dart';

/// Apply a device setting change the host published as an Equipment
/// `PropertyChanged` event.
///
/// The host's `DeviceManager` publishes one of these for every setting that
/// has no event of its own (`state_events.rs` names them), whoever changed it:
/// the host UI, a slave or phone through the API, a script or the sequencer.
/// The host's `DeviceService` and a slave's equipment mirror both apply them
/// here, so both show the same value. A change for a device other than the one
/// in the slot (a guide camera, a second switch) is ignored.
///
/// Returns whether the event was one of these settings.
bool applyDevicePropertyChange(
  ProviderContainer container,
  Map<String, dynamic> data,
) {
  final wireType = data['device_type'];
  final deviceId = data['device_id'];
  final property = data['property'];
  final value = data['value'];
  if (wireType is! String ||
      deviceId is! String ||
      property is! String ||
      value is! String) {
    return false;
  }
  final deviceType = deviceTypeFromWireName(wireType);
  if (deviceType == null) return false;

  T read<T>(ProviderListenable<T> provider) => container.read(provider);

  switch (deviceType) {
    case DeviceType.camera:
      final camera = read(cameraStateProvider.notifier);
      if (camera.deviceId != deviceId) return false;
      switch (property) {
        case 'Gain':
          final gain = int.tryParse(value);
          if (gain == null) return false;
          camera.applySetting(gain: gain);
          return true;
        case 'Offset':
          final offset = int.tryParse(value);
          if (offset == null) return false;
          camera.applySetting(offset: offset);
          return true;
        case 'Binning':
          camera.applySetting(binning: value);
          return true;
      }
      return false;

    case DeviceType.filterWheel:
      final wheel = read(filterWheelStateProvider.notifier);
      if (wheel.deviceId != deviceId || property != 'FilterNames') {
        return false;
      }
      final decoded = _decodeNames(value);
      if (decoded == null) return false;
      wheel.setFilterNames(decoded);
      return true;

    case DeviceType.rotator:
      final rotator = read(rotatorStateProvider.notifier);
      if (read(rotatorStateProvider).deviceId != deviceId) return false;
      switch (property) {
        case 'Position':
          final angle = double.tryParse(value);
          if (angle == null) return false;
          rotator.updatePosition(angle);
          return true;
        case 'Reverse':
          rotator.setReversed(value == 'true');
          return true;
      }
      return false;

    case DeviceType.switch_:
      if (read(switchStateProvider).deviceId != deviceId) return false;
      final parts = value.split(' ');
      if (parts.length != 2) return false;
      final index = int.tryParse(parts[0]);
      if (index == null) return false;
      final notifier = read(switchStateProvider.notifier);
      switch (property) {
        case 'SwitchState':
          notifier.setChannelState(index, parts[1] == 'true');
          return true;
        case 'SwitchValue':
          final number = double.tryParse(parts[1]);
          if (number == null) return false;
          notifier.setChannelValue(index, number);
          return true;
      }
      return false;

    case DeviceType.mount:
      // A sync, an abort or an alt/az slew: no event carries the mount's new
      // state, so read it now rather than at the next poll tick.
      if (read(mountStateProvider).deviceId != deviceId) return false;
      final mount = read(mountStateProvider.notifier);
      switch (property) {
        case 'SlewToAltAz':
          mount.setSlewing(true);
        case 'AbortSlew':
          mount.setSlewing(false);
        case 'Synced':
          break;
        default:
          return false;
      }
      mount.refreshNow();
      return true;

    case DeviceType.dome:
      if (read(domeStateProvider).deviceId != deviceId ||
          property != 'Slaved') {
        return false;
      }
      read(domeStateProvider.notifier).setSlaved(value == 'true');
      return true;

    default:
      return false;
  }
}

/// Apply a focuser, filter wheel, rotator or camera-cooler event the host
/// published (`FocuserMove*`, `FilterChang*`, `RotatorMove*`,
/// `CameraCooling*`, `CameraWarming*`, `CameraTemperatureChanged`).
///
/// The host's `DeviceService` and a slave's equipment mirror both apply them
/// here. Each event names its device; one for a device other than the one in
/// the slot (a guide camera, a second focuser) is ignored, so a guide
/// camera's cooler never shows as the imaging camera's. An event with no
/// device id comes from a host older than the id and is applied as before.
///
/// Returns whether the event was one of these and was applied.
bool applyDeviceStateEvent(
  ProviderContainer container,
  ev.EquipmentEvent event,
) {
  T read<T>(ProviderListenable<T> provider) => container.read(provider);
  bool inSlot(DeviceType type, String id) =>
      id.isEmpty || readDeviceSlot(container, type).deviceId == id;

  switch (event) {
    case ev.EquipmentEvent_FocuserMoveStarted(:final deviceId):
      if (!inSlot(DeviceType.focuser, deviceId)) return false;
      read(focuserStateProvider.notifier).setMoving(true);
      return true;
    case ev.EquipmentEvent_FocuserMoveCompleted(
      :final deviceId,
      :final position,
    ):
      if (!inSlot(DeviceType.focuser, deviceId)) return false;
      read(focuserStateProvider.notifier)
        ..setMoving(false)
        ..updatePosition(position);
      return true;

    case ev.EquipmentEvent_FilterChanging(:final deviceId):
      if (!inSlot(DeviceType.filterWheel, deviceId)) return false;
      read(filterWheelStateProvider.notifier).setMoving(true);
      return true;
    case ev.EquipmentEvent_FilterChanged(:final deviceId, :final position):
      if (!inSlot(DeviceType.filterWheel, deviceId)) return false;
      read(filterWheelStateProvider.notifier)
        ..setMoving(false)
        ..updatePosition(position);
      return true;

    case ev.EquipmentEvent_RotatorMoveStarted(:final deviceId):
      if (!inSlot(DeviceType.rotator, deviceId)) return false;
      read(rotatorStateProvider.notifier).setMoving(true);
      return true;
    case ev.EquipmentEvent_RotatorMoveCompleted(:final deviceId, :final angle):
      if (!inSlot(DeviceType.rotator, deviceId)) return false;
      read(rotatorStateProvider.notifier)
        ..setMoving(false)
        ..updatePosition(angle);
      return true;

    case ev.EquipmentEvent_CameraCoolingStarted(
      :final deviceId,
      :final targetTemp,
    ):
      if (!inSlot(DeviceType.camera, deviceId)) return false;
      read(cameraStateProvider.notifier)
        ..setCooling(true)
        ..setTargetTemp(targetTemp);
      return true;
    case ev.EquipmentEvent_CameraCoolingReached(
      :final deviceId,
      :final temperature,
    ):
      if (!inSlot(DeviceType.camera, deviceId)) return false;
      read(cameraStateProvider.notifier).updateTemperature(temperature, 0.0);
      return true;
    case ev.EquipmentEvent_CameraWarmingStarted(:final deviceId):
      if (!inSlot(DeviceType.camera, deviceId)) return false;
      read(cameraStateProvider.notifier).setCooling(false);
      return true;
    case ev.EquipmentEvent_CameraWarmingCompleted(:final deviceId):
      return inSlot(DeviceType.camera, deviceId);
    case ev.EquipmentEvent_CameraTemperatureChanged(
      :final deviceId,
      :final temperature,
      :final coolerPower,
    ):
      if (!inSlot(DeviceType.camera, deviceId)) return false;
      // `updateTemperature` clears the cached power when this is null, so a
      // reading without power leaves the cards saying "unknown" rather than
      // claiming a real 0 %.
      read(
        cameraStateProvider.notifier,
      ).updateTemperature(temperature, coolerPower);
      return true;
    default:
      return false;
  }
}

/// Apply a `CameraSettingsChanged` event: the camera's full gain, offset
/// and binning as it reports them after a change or on connect. Returns
/// whether it was for the camera in the slot.
bool applyCameraSettings(
  ProviderContainer container,
  Map<String, dynamic> data,
) {
  final deviceId = data['device_id'];
  final gain = data['gain'];
  final offset = data['offset'];
  final binX = data['bin_x'];
  final binY = data['bin_y'];
  // A null gain or offset is a value the camera would not report.
  if (deviceId is! String ||
      gain is! num? ||
      offset is! num? ||
      binX is! num ||
      binY is! num) {
    return false;
  }
  final camera = container.read(cameraStateProvider.notifier);
  if (camera.deviceId != deviceId) return false;
  camera.updateReadout(
    gain: gain?.toInt(),
    offset: offset?.toInt(),
    binX: binX.toInt(),
    binY: binY.toInt(),
  );
  return true;
}

List<String>? _decodeNames(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;
    return [for (final name in decoded) name.toString()];
  } on FormatException {
    return null;
  }
}
