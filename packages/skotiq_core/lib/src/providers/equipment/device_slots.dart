/// The device table: one entry per device type.
///
/// Everything that is the same question asked of every device type (its wire
/// spellings, where its state lives, who reconnects it) is answered here; its
/// name is on [DeviceType] itself. Adding a device type means adding the enum
/// value, one [DeviceSlot] below, its state notifier, and whatever is unique
/// to it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/backend/device_types.dart';
import '../../models/equipment/equipment_models.dart';
import '../device_heartbeat_health_provider.dart';
import '../provider_reader.dart';
import 'camera_state_provider.dart';
import 'cover_calibrator_state_provider.dart';
import 'device_connection_notifier.dart';
import 'dome_state_provider.dart';
import 'filter_wheel_state_provider.dart';
import 'focuser_state_provider.dart';
import 'guider_state_provider.dart';
import 'mount_state_provider.dart';
import 'rotator_state_provider.dart';
import 'safety_monitor_state_provider.dart';
import 'switch_state_provider.dart';
import 'weather_state_provider.dart';

class DeviceSlot {
  const DeviceSlot({
    required this.type,
    required this.wireNames,
    required this.state,
    required this.notifier,
    this.isCore = false,
    this.nativeOwnsReconnect = false,
    this.heartbeat = false,
    this.checksModel = false,
  });

  final DeviceType type;

  String get label => type.displayName;
  String get noun => type.noun;

  /// Lower-case spellings of this type on the wire (bridge events, the host
  /// API, remote-sync payloads). The first is the canonical one.
  final List<String> wireNames;

  final ProviderBase<DeviceSlotState<Object?>> state;
  final ProviderListenable<DeviceConnectionNotifier> notifier;

  /// Part of the imaging chain that the profile list summarizes as
  /// connection dots and a connected/total count.
  final bool isCore;

  /// The native heartbeat reconnects this type itself
  /// (`HeartbeatConfig::for_*().auto_reconnect`), so Dart must not schedule a
  /// second reconnect that would race it.
  final bool nativeOwnsReconnect;

  /// Dart starts and stops the native heartbeat around connect / disconnect.
  final bool heartbeat;

  /// Connect passes the profile's saved model so a positional id that now
  /// points at different hardware is refused.
  final bool checksModel;
}

/// Every device slot, in the order the app lists devices.
final List<DeviceSlot> deviceSlots = List.unmodifiable([
  DeviceSlot(
    type: DeviceType.camera,
    wireNames: const ['camera'],
    state: cameraStateProvider,
    notifier: cameraStateProvider.notifier,
    isCore: true,
    heartbeat: true,
    checksModel: true,
  ),
  DeviceSlot(
    type: DeviceType.mount,
    wireNames: const ['mount'],
    state: mountStateProvider,
    notifier: mountStateProvider.notifier,
    isCore: true,
    nativeOwnsReconnect: true,
    heartbeat: true,
    checksModel: true,
  ),
  DeviceSlot(
    type: DeviceType.focuser,
    wireNames: const ['focuser'],
    state: focuserStateProvider,
    notifier: focuserStateProvider.notifier,
    isCore: true,
    heartbeat: true,
    checksModel: true,
  ),
  DeviceSlot(
    type: DeviceType.filterWheel,
    wireNames: const ['filterwheel', 'filter wheel'],
    state: filterWheelStateProvider,
    notifier: filterWheelStateProvider.notifier,
    isCore: true,
    heartbeat: true,
    checksModel: true,
  ),
  DeviceSlot(
    type: DeviceType.guider,
    wireNames: const ['guider'],
    state: guiderStateProvider,
    notifier: guiderStateProvider.notifier,
    isCore: true,
    nativeOwnsReconnect: true,
  ),
  DeviceSlot(
    type: DeviceType.rotator,
    wireNames: const ['rotator'],
    state: rotatorStateProvider,
    notifier: rotatorStateProvider.notifier,
    isCore: true,
    heartbeat: true,
    checksModel: true,
  ),
  DeviceSlot(
    type: DeviceType.dome,
    wireNames: const ['dome'],
    state: domeStateProvider,
    notifier: domeStateProvider.notifier,
    nativeOwnsReconnect: true,
  ),
  DeviceSlot(
    type: DeviceType.weather,
    wireNames: const ['weather'],
    state: weatherStateProvider,
    notifier: weatherStateProvider.notifier,
    nativeOwnsReconnect: true,
  ),
  DeviceSlot(
    type: DeviceType.safetyMonitor,
    wireNames: const ['safetymonitor', 'safety monitor'],
    state: safetyMonitorStateProvider,
    notifier: safetyMonitorStateProvider.notifier,
  ),
  DeviceSlot(
    type: DeviceType.switch_,
    wireNames: const ['switch', 'switch_'],
    state: switchStateProvider,
    notifier: switchStateProvider.notifier,
  ),
  DeviceSlot(
    type: DeviceType.coverCalibrator,
    wireNames: const ['covercalibrator', 'cover calibrator'],
    state: coverCalibratorStateProvider,
    notifier: coverCalibratorStateProvider.notifier,
    nativeOwnsReconnect: true,
  ),
]);

final Map<DeviceType, DeviceSlot> _slotByType = {
  for (final slot in deviceSlots) slot.type: slot,
};

final Map<String, DeviceType> _typeByWireName = {
  for (final slot in deviceSlots)
    for (final name in slot.wireNames) name: slot.type,
};

extension DeviceTypeSlot on DeviceType {
  DeviceSlot get slot => _slotByType[this]!;
}

/// Parse a device type as it arrives on the wire. Case-insensitive; anything
/// that is not a [DeviceSlot.wireNames] spelling is null, which callers treat
/// as "not one of ours".
DeviceType? deviceTypeFromWireName(String raw) =>
    _typeByWireName[raw.toLowerCase()];

/// The live state of [deviceType]'s slot.
///
/// [reader] is a `Ref`, a `WidgetRef` or a `ProviderContainer`; see
/// [readProvider].
DeviceSlotState<Object?> readDeviceSlot(Object reader, DeviceType deviceType) =>
    readProvider(reader, deviceType.slot.state);

/// The name [deviceType]'s card shows, or null when the slot has none.
String? readDeviceSlotName(Object reader, DeviceType deviceType) =>
    readDeviceSlot(reader, deviceType).deviceName;

/// The notifier that drives [deviceType]'s slot.
DeviceConnectionNotifier readDeviceConnectionNotifier(
  Object reader,
  DeviceType deviceType,
) => readProvider(reader, deviceType.slot.notifier);

/// Put every slot back to disconnected.
///
/// Called when the active backend is swapped, and on a linked client before
/// it re-reads the host's device list, so no card keeps showing a device as
/// connected against a backend that never opened it. Pass
/// `includeGuider: false` when the guider is re-read from its own source
/// (PHD2 is not always in the host's device list).
void resetAllEquipmentStateNotifiers(
  Object reader, {
  bool includeGuider = true,
  bool clearHeartbeatHealth = true,
}) {
  for (final slot in deviceSlots) {
    if (slot.type == DeviceType.guider && !includeGuider) continue;
    readProvider(reader, slot.notifier).setDisconnected();
  }
  if (!clearHeartbeatHealth) return;
  try {
    readProvider(reader, deviceHeartbeatHealthProvider.notifier).clearAll();
  } on Object {
    // The heartbeat provider can be mid-disposal during shutdown.
  }
}
