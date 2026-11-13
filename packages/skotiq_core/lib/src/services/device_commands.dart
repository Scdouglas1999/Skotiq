import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/roles/device_backend.dart';
import '../models/backend/device_types.dart';
import '../models/equipment/equipment_models.dart';
import '../models/equipment/filter_names.dart';
import '../providers/backend_provider.dart';
import '../providers/equipment/device_slots.dart';
import '../providers/equipment/switch_state_provider.dart';
import 'device_service.dart';
import '../providers/device_service_providers.dart';

/// One path for a device command that names its device, whoever sends it.
///
/// The host's own UI commands the device in each slot through
/// [DeviceService], and that is where a command's side effects live: the
/// filter's focus offset, the checks that refuse a manual move while
/// autofocus runs or a target outside the driver's range, the operations
/// bar, the cooling goal the "Cool to" action offers, the position verify
/// and the log. The embedded API that slaves, phones and scripts use sends
/// the same commands by device id, and it reached the backend directly, so a
/// command from a slave skipped all of that: a slave's filter change by name
/// never applied the focus offset, and a 400° rotator move the host UI
/// refuses went to the driver.
///
/// Through here a command for the device in the host's slot takes the same
/// [DeviceService] path the host UI does, and a command for any other device
/// (a second focuser, the guide camera) goes to the backend as before. The
/// host UI's own dome commands come through here too, so the status re-read
/// after a dome command is the same for both.
///
/// [DeviceService] reports a refused command as a [StateError] (busy: a move
/// in progress, autofocus running), an [ArgumentError] or [RangeError] (a bad
/// target) or an [UnsupportedError] (the driver cannot); callers map those.
class DeviceCommands {
  DeviceCommands(this._ref);

  final Ref _ref;

  DeviceService get _service => _ref.read(deviceServiceProvider);
  DeviceBackend get _backend => _ref.read(deviceBackendProvider);

  /// Whether [deviceId] is the connected device in the host's [type] slot.
  ///
  /// A slot nobody has used is not created here: creating it would only
  /// start its profile listener, and no device can be in it.
  bool isSlotDevice(DeviceType type, String deviceId) {
    if (!_ref.exists(type.slot.state)) return false;
    final slot = readDeviceSlot(_ref, type);
    return slot.connectionState == DeviceConnectionState.connected &&
        slot.deviceId == deviceId;
  }

  Future<void> filterWheelSetPosition(String deviceId, int position) {
    if (isSlotDevice(DeviceType.filterWheel, deviceId)) {
      return _service.setFilterWheelPosition(position);
    }
    return _backend.filterWheelSetPosition(deviceId, position);
  }

  /// Move to the slot named [name]. The slot wheel resolves the name against
  /// the names the wheel reports by the filter-name rule ("Ha" is "Ha 7nm")
  /// and moves as [filterWheelSetPosition] does, so the focus offset follows
  /// the filter whichever way it was asked for.
  Future<void> filterWheelSetByName(String deviceId, String name) async {
    if (isSlotDevice(DeviceType.filterWheel, deviceId)) {
      final names = (await _backend.getFilterWheelStatus(deviceId)).filterNames;
      final slot = matchingFilterIndex(name, names);
      if (slot != null) return _service.setFilterWheelPosition(slot);
    }
    return _backend.filterWheelSetByName(deviceId, name);
  }

  Future<void> filterWheelSetNames(String deviceId, List<String> names) {
    if (isSlotDevice(DeviceType.filterWheel, deviceId)) {
      return _service.setFilterWheelNames(names);
    }
    return _backend.filterWheelSetNames(deviceId, names);
  }

  Future<void> focuserMoveTo(String deviceId, int position) {
    if (isSlotDevice(DeviceType.focuser, deviceId)) {
      return _service.moveFocuserTo(position);
    }
    return _backend.focuserMoveTo(deviceId, position);
  }

  Future<void> focuserMoveRelative(String deviceId, int delta) {
    if (isSlotDevice(DeviceType.focuser, deviceId)) {
      return _service.moveFocuserRelative(delta);
    }
    return _backend.focuserMoveRelative(deviceId, delta);
  }

  Future<void> focuserHalt(String deviceId) {
    if (isSlotDevice(DeviceType.focuser, deviceId)) {
      return _service.haltFocuser();
    }
    return _backend.focuserHalt(deviceId);
  }

  Future<void> rotatorMoveTo(String deviceId, double angle) {
    if (isSlotDevice(DeviceType.rotator, deviceId)) {
      return _service.moveRotatorTo(angle);
    }
    return _backend.rotatorMoveTo(deviceId, angle);
  }

  Future<void> rotatorMoveRelative(String deviceId, double delta) {
    if (isSlotDevice(DeviceType.rotator, deviceId)) {
      return _service.moveRotatorRelative(delta);
    }
    return _backend.rotatorMoveRelative(deviceId, delta);
  }

  Future<void> rotatorHalt(String deviceId) {
    if (isSlotDevice(DeviceType.rotator, deviceId)) {
      return _service.haltRotator();
    }
    return _backend.rotatorHalt(deviceId);
  }

  Future<void> rotatorSetReverse(String deviceId, bool reverse) {
    if (isSlotDevice(DeviceType.rotator, deviceId)) {
      return _service.setRotatorReversed(reverse);
    }
    return _backend.rotatorSetReverse(deviceId, reverse);
  }

  Future<void> rotatorSyncToPa(String deviceId, double positionAngle) {
    if (isSlotDevice(DeviceType.rotator, deviceId)) {
      return _service.syncRotatorToPa(positionAngle);
    }
    return _backend.rotatorSyncToPa(deviceId, positionAngle);
  }

  /// Switch the cooler. A cooler command from anyone replaces a warm-up in
  /// progress, as the host's own cooler controls do; otherwise the ramp's
  /// next step would overwrite the set-point just sent.
  Future<void> cameraSetCooling(
    String deviceId, {
    required bool enabled,
    double? targetTemp,
  }) {
    if (isSlotDevice(DeviceType.camera, deviceId)) {
      _service.cancelWarmCamera(restorePriorSetting: false);
      return _service.setCameraCooling(
        enabled: enabled,
        targetTemp: targetTemp,
      );
    }
    return _backend.cameraSetCooling(
      deviceId: deviceId,
      enabled: enabled,
      targetTemp: targetTemp,
    );
  }

  // Gain, offset and readout mode have no DeviceService step: the host UI
  // sends them to the backend too, and the native event that follows updates
  // every UI. They come through here so a side effect added later applies to
  // both.

  Future<void> cameraSetGain(String deviceId, int gain) =>
      _backend.cameraSetGain(deviceId, gain);

  Future<void> cameraSetOffset(String deviceId, int offset) =>
      _backend.cameraSetOffset(deviceId, offset);

  Future<void> cameraSetReadoutMode(String deviceId, int modeIndex) =>
      _backend.cameraSetReadoutMode(deviceId, modeIndex);

  // Dome: the backend command, then a status re-read so the dome card shows
  // the command at once instead of after the next 5 s poll.

  Future<void> domeOpenShutter(String deviceId) =>
      _dome(deviceId, () => _backend.domeOpenShutter(deviceId));

  Future<void> domeCloseShutter(String deviceId) =>
      _dome(deviceId, () => _backend.domeCloseShutter(deviceId));

  Future<void> domeSlewToAzimuth(String deviceId, double azimuth) =>
      _dome(deviceId, () => _backend.domeSlewToAzimuth(deviceId, azimuth));

  Future<void> domeSetSlaved(String deviceId, bool slaved) =>
      _dome(deviceId, () => _backend.domeSetSlaved(deviceId, slaved));

  Future<void> domePark(String deviceId) =>
      _dome(deviceId, () => _backend.domePark(deviceId));

  Future<void> domeFindHome(String deviceId) =>
      _dome(deviceId, () => _backend.domeFindHome(deviceId));

  Future<void> domeAbortSlew(String deviceId) =>
      _dome(deviceId, () => _backend.domeAbortSlew(deviceId));

  Future<void> _dome(String deviceId, Future<void> Function() command) async {
    await command();
    if (isSlotDevice(DeviceType.dome, deviceId)) {
      await _service.refreshDomeStatus();
    }
  }

  // Cover calibrator: the backend command the host UI sends.

  Future<void> coverOpen(String deviceId) => _backend.coverOpen(deviceId);

  Future<void> coverClose(String deviceId) => _backend.coverClose(deviceId);

  Future<void> calibratorOn(String deviceId, int brightness) =>
      _backend.calibratorOn(deviceId, brightness);

  Future<void> calibratorOff(String deviceId) =>
      _backend.calibratorOff(deviceId);

  /// Set a channel of the switch in the host's slot through [DeviceService]
  /// (the read-only and analog checks, the channel state, the error log), as
  /// the host's switch card does. Returns false, sending nothing, for another
  /// switch or before the slot has read the channel list; the caller then
  /// writes the channel itself.
  Future<bool> setSlotSwitchChannel(
    String deviceId,
    int switchId,
    Object value,
  ) async {
    if (!isSlotDevice(DeviceType.switch_, deviceId)) return false;
    if (switchId >= _ref.read(switchStateProvider).channelCount) return false;
    if (value is bool) {
      await _service.setSwitchChannel(switchId, value);
    } else if (value is num) {
      await _service.setSwitchChannelValue(switchId, value.toDouble());
    } else {
      return false;
    }
    return true;
  }
}
