import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/backend/device_types.dart';
import '../../models/equipment/discovery_state.dart';
import '../../services/device_service/profile_device_resolution.dart';
import '../../utils/device_id.dart';
import '../backend_provider.dart';
import '../profiles_provider.dart';
import '../unified_discovery_provider.dart';
import 'device_slots.dart';
import 'profile_connection_status_provider.dart';

/// A device a profile assigns that the last device scan did not list.
class ProfileDeviceNotFound {
  const ProfileDeviceNotFound({
    required this.slot,
    required this.deviceId,
    this.deviceName,
  });

  /// The slot in a sentence: `camera`, `guide camera`, `filter wheel`.
  final String slot;

  final String deviceId;

  /// The name the profile saved for the device, when it saved one.
  final String? deviceName;

  /// The device as the operator knows it.
  String get name {
    final saved = deviceName?.trim();
    if (saved != null && saved.isNotEmpty) return saved;
    return friendlyNameFromDeviceId(deviceId);
  }
}

/// How a profile's devices compare with the last device scan.
class ProfileScanCheck {
  const ProfileScanCheck({required this.scannedAt, required this.notFound});

  /// No scan has finished yet, so nothing can be said.
  static const ProfileScanCheck notScanned = ProfileScanCheck(
    scannedAt: null,
    notFound: [],
  );

  /// When the last scan finished.
  final DateTime? scannedAt;

  /// The profile's devices, in slot order, that the scan did not list.
  final List<ProfileDeviceNotFound> notFound;
}

/// Which discovery bucket lists devices of [kind], or null when discovery
/// cannot speak for it: PHD2 is a socket service, not a device on a bus.
DriverType? _bucketFor(DeviceDriverKind kind) => switch (kind) {
  DeviceDriverKind.ascom => DriverType.ascom,
  DeviceDriverKind.alpaca => DriverType.alpaca,
  DeviceDriverKind.indi => DriverType.indi,
  DeviceDriverKind.native ||
  DeviceDriverKind.builtinGuider => DriverType.native,
  DeviceDriverKind.simulator => DriverType.simulator,
  DeviceDriverKind.phd2 || DeviceDriverKind.unknown => null,
};

/// The devices [profile] assigns that [scan] did not list.
///
/// A device is judged only when the scan of its driver finished without an
/// error: a driver that was not scanned, is still scanning or failed says
/// nothing about the device. Slots in [connected] are skipped, since a device
/// in use is plainly there and some SDKs do not list a camera they have open.
/// On a linked client ([linkedHost]) the host answers for every driver in one
/// sweep.
ProfileScanCheck checkProfileAgainstScan(
  EquipmentProfileModel profile,
  UnifiedDiscoveryState scan, {
  required bool linkedHost,
  Set<DeviceType> connected = const {},
}) {
  final scannedAt = scan.lastDiscoveryCompletedAt;
  if (scannedAt == null) return ProfileScanCheck.notScanned;

  // Slot order, with the guide camera before the guider as the connect
  // sweep lists it.
  final slots = <({String slot, DeviceType type, String id, String? name})>[
    for (final deviceSlot in deviceSlots) ...[
      if (deviceSlot.type == DeviceType.guider)
        if (profile.guideCameraId case final id? when id.isNotEmpty)
          (
            slot: 'guide camera',
            type: DeviceType.camera,
            id: id,
            name: profile.guideCameraName,
          ),
      if (profile.deviceIdFor(deviceSlot.type) case final id?
          when id.isNotEmpty && !connected.contains(deviceSlot.type))
        (
          slot: deviceSlot.noun,
          type: deviceSlot.type,
          id: id,
          name: profile.deviceNameFor(deviceSlot.type),
        ),
    ],
  ];

  final notFound = <ProfileDeviceNotFound>[];
  for (final slot in slots) {
    final bucket = linkedHost
        ? linkedHostScanBucket
        : _bucketFor(DeviceId.parse(slot.id).kind);
    if (bucket == null) continue;
    final backend = scan.backendStates[bucket];
    if (backend == null || !backend.isSuccess) continue;
    final found = discoveryHoldsProfileDevice(
      savedId: slot.id,
      savedName: slot.name,
      discovered: backend.devices.where((d) => d.deviceType == slot.type),
    );
    if (!found) {
      notFound.add(
        ProfileDeviceNotFound(
          slot: slot.slot,
          deviceId: slot.id,
          deviceName: slot.name,
        ),
      );
    }
  }
  return ProfileScanCheck(scannedAt: scannedAt, notFound: notFound);
}

/// [checkProfileAgainstScan] for [profile] against the current device scan,
/// skipping the slots where the profile's own device is connected.
final profileScanCheckProvider =
    Provider.family<ProfileScanCheck, EquipmentProfileModel>((ref, profile) {
      final status = ref.watch(profileConnectionStatusProvider(profile));
      return checkProfileAgainstScan(
        profile,
        ref.watch(unifiedDiscoveryProvider),
        linkedHost: ref.watch(isRemoteModeProvider),
        connected: {
          for (final connection in status.connections)
            if (connection.matchesProfile) connection.type,
        },
      );
    });
