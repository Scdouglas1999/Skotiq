import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/backend/backend_types.dart';
import '../../models/equipment/equipment_models.dart';
import '../../models/equipment/known_devices.dart';
import '../../models/equipment/unified_device.dart';
import '../../models/equipment_profile_model.dart';
import '../../utils/device_id.dart';
import '../backend_provider.dart';
import '../host_role.dart';
import '../profiles_provider.dart';
import '../unified_discovery_provider.dart';
import 'device_slots.dart';

/// What one device slot holds, as far as the device list is concerned.
typedef SlotDevice = ({
  DeviceConnectionState state,
  String? id,
  String? name,
  String? error,
});

/// The devices the imaging host knows about: the device in each slot with
/// its state, every other device the device registry holds [connected] (a
/// built-in guider's guide camera), every device [profile] names, and every
/// device [scanned] (the last scan's groups, finished at [lastScanAt]).
///
/// A device appears once. Slot, registry and scan are joined on the device
/// id; the profile joins the slot by the rule the profile uses to recognize
/// its own connected device ([deviceIdsMatch]), and the rest by id.
KnownDevices buildKnownDevices({
  required Map<DeviceType, SlotDevice> slots,
  List<DeviceInfo> connected = const [],
  required EquipmentProfileModel? profile,
  required List<UnifiedDevice> scanned,
  required DateTime? lastScanAt,
}) {
  final entries = [
    for (final device in scanned) _Entry(device, foundByScan: true),
  ];

  _Entry entryFor(DeviceType type, String id, String? name) {
    final key = DeviceId.parse(id).canonical;
    for (final entry in entries) {
      if (entry.device.type != type) continue;
      for (final backend in entry.device.availableBackends.entries) {
        if (DeviceId.parse(backend.value.id).canonical == key) {
          entry.device = entry.device.withSelectedBackend(backend.key);
          return entry;
        }
      }
    }
    final driverType = _driverTypeOf(id);
    final displayName = name == null || name.trim().isEmpty || name == id
        ? friendlyNameFromDeviceId(id)
        : name;
    final entry = _Entry(
      UnifiedDevice(
        canonicalName: key,
        displayName: displayName,
        type: type,
        availableBackends: {
          driverType: DeviceInfo(
            id: id,
            name: displayName,
            deviceType: type,
            driverType: driverType,
            description: '',
            driverVersion: '',
          ),
        },
      ),
      foundByScan: false,
    );
    entries.add(entry);
    return entry;
  }

  for (final slot in deviceSlots) {
    final type = slot.type;
    final live = slots[type];
    final liveId = live?.id;
    final holdsDevice =
        live != null &&
        liveId != null &&
        liveId.isNotEmpty &&
        live.state != DeviceConnectionState.disconnected;
    if (holdsDevice) {
      entryFor(type, liveId, live.name)
        ..state = live.state
        ..error = live.error;
    }

    final assigned = profile?.deviceIdFor(type);
    if (assigned == null || assigned.isEmpty) continue;
    if (holdsDevice && deviceIdsMatch(assigned, liveId)) {
      entryFor(type, liveId, live.name).inProfile = true;
    } else {
      entryFor(type, assigned, profile!.deviceNameFor(type)).inProfile = true;
    }
  }

  for (final device in connected) {
    final entry = entryFor(device.deviceType, device.id, device.name);
    if (entry.state == DeviceConnectionState.disconnected) {
      entry.state = DeviceConnectionState.connected;
    }
  }

  // The guide camera is part of its guider, so the profile does not list it
  // on its own; it is marked when it is listed for another reason.
  final guideCameraId = profile?.guideCameraId;
  if (guideCameraId != null && guideCameraId.isNotEmpty) {
    final key = DeviceId.parse(guideCameraId).canonical;
    for (final entry in entries) {
      if (entry.device.type == DeviceType.camera &&
          entry.device.availableBackends.values.any(
            (d) => DeviceId.parse(d.id).canonical == key,
          )) {
        entry.inProfile = true;
      }
    }
  }

  final order = {
    for (final (index, slot) in deviceSlots.indexed) slot.type: index,
  };
  final devices =
      [
        for (final entry in entries)
          KnownDevice(
            device: entry.device,
            state: entry.state,
            error: entry.error,
            inProfile: entry.inProfile,
            foundByScan: entry.foundByScan,
          ),
      ]..sort((a, b) {
        final byType = order[a.type]!.compareTo(order[b.type]!);
        if (byType != 0) return byType;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  return KnownDevices(
    devices: List.unmodifiable(devices),
    lastScanAt: lastScanAt,
  );
}

class _Entry {
  _Entry(this.device, {required this.foundByScan});

  UnifiedDevice device;
  final bool foundByScan;
  DeviceConnectionState state = DeviceConnectionState.disconnected;
  String? error;
  bool inProfile = false;
}

DriverType _driverTypeOf(String id) => switch (DeviceId.parse(id).kind) {
  DeviceDriverKind.ascom => DriverType.ascom,
  DeviceDriverKind.alpaca => DriverType.alpaca,
  DeviceDriverKind.indi => DriverType.indi,
  DeviceDriverKind.simulator => DriverType.simulator,
  DeviceDriverKind.native ||
  DeviceDriverKind.phd2 ||
  DeviceDriverKind.builtinGuider ||
  DeviceDriverKind.unknown => DriverType.native,
};

/// The devices this process knows about as an imaging host. `GET
/// /api/devices` answers it; screens read [knownDevicesProvider].
final hostKnownDevicesProvider = FutureProvider<KnownDevices>((ref) async {
  final scan = ref.watch(
    unifiedDiscoveryProvider.select(
      (s) => (devices: s.groupedDevices, at: s.lastDiscoveryCompletedAt),
    ),
  );
  final slots = {
    for (final slot in deviceSlots)
      slot.type: ref.watch(
        slot.state.select(
          (s) => (
            state: s.connectionState,
            id: s.retryDeviceId,
            name: s.deviceName,
            error: s.lastError?.message,
          ),
        ),
      ),
  };
  final profile = ref.watch(activeEquipmentProfileProvider);
  // The registry changes when a slot does; the slots above are watched, so
  // this is read again then.
  final connected = await ref
      .watch(deviceBackendProvider)
      .getConnectedDevices();
  return buildKnownDevices(
    slots: slots,
    connected: connected,
    profile: profile,
    scanned: scan.devices,
    lastScanAt: scan.at,
  );
});

/// The devices the imaging host knows about: this process's own list, or
/// the linked host's answer to `GET /api/devices`.
final knownDevicesProvider = FutureProvider<KnownDevices>(
  (ref) => ref.watch(_knownDevicesSourceProvider)(ref),
);

final _knownDevicesSourceProvider =
    hostRoleProvider<Future<KnownDevices> Function(Ref ref)>(
      here: (_) =>
          (ref) => ref.watch(hostKnownDevicesProvider.future),
      // The host's list changes when one of its slots, its profile or its
      // scan does; this client sees each of those, and asks again.
      linked: (_, host) => (ref) {
        for (final slot in deviceSlots) {
          ref.watch(
            slot.state.select((s) => (s.connectionState, s.retryDeviceId)),
          );
        }
        ref.watch(activeEquipmentProfileProvider);
        ref.watch(
          unifiedDiscoveryProvider.select((s) => s.lastDiscoveryCompletedAt),
        );
        return host.devices.knownDevices();
      },
    );
