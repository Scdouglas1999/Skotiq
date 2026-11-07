import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../provider_reader.dart';
import 'camera_state_provider.dart';
import 'device_type_registry.dart';
import 'dome_state_provider.dart';
import 'filter_wheel_state_provider.dart';
import 'rotator_state_provider.dart';
import 'switch_state_provider.dart';
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
bool applyDevicePropertyChange(Object reader, Map<String, dynamic> data) {
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

  T read<T>(ProviderListenable<T> provider) => readProvider(reader, provider);

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

List<String>? _decodeNames(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;
    return [for (final name in decoded) name.toString()];
  } on FormatException {
    return null;
  }
}
