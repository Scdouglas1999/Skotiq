import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Persists the devices that are connected but NOT assigned to [profileId].
///
/// This is the write behind the side panel's "Save N devices to profile"
/// button and the per-card "Add to profile" link. It is the same
/// `ProfileService.updateProfileDevices` call the Discovery panel's Assign menu
/// makes — one slot per call, so a single failing slot cannot silently drop the
/// others — and nothing else about the profile is touched.
///
/// Returns the slots that were written. Throws whatever the service throws so
/// the caller can report it; a partial write is reported through the returned
/// list.
Future<List<ProfileDeviceSlot>> saveSessionDevicesToProfile(
  WidgetRef ref, {
  required int profileId,
  required Set<ProfileDeviceSlot> slots,
}) async {
  final service = ref.read(profileServiceProvider);
  final saved = <ProfileDeviceSlot>[];
  for (final slot in slots) {
    final deviceId = connectedDeviceIdForSlot(ref, slot);
    if (deviceId == null || deviceId.isEmpty) continue;
    await _writeSlot(service, profileId, slot, deviceId);
    saved.add(slot);
  }
  return saved;
}

/// The id of the device currently occupying [slot], or null when nothing is
/// connected there.
String? connectedDeviceIdForSlot(WidgetRef ref, ProfileDeviceSlot slot) {
  return switch (slot) {
    ProfileDeviceSlot.camera => ref.read(cameraStateProvider).deviceId,
    ProfileDeviceSlot.mount => ref.read(mountStateProvider).deviceId,
    ProfileDeviceSlot.focuser => ref.read(focuserStateProvider).deviceId,
    ProfileDeviceSlot.filterWheel =>
      ref.read(filterWheelStateProvider).deviceId,
    ProfileDeviceSlot.guider => ref.read(guiderStateProvider).deviceId,
    ProfileDeviceSlot.rotator => ref.read(rotatorStateProvider).deviceId,
    ProfileDeviceSlot.dome => ref.read(domeStateProvider).deviceId,
    ProfileDeviceSlot.weather => ref.read(weatherStateProvider).deviceId,
    ProfileDeviceSlot.safetyMonitor =>
      ref.read(safetyMonitorStateProvider).deviceId,
    ProfileDeviceSlot.switchDevice => ref.read(switchStateProvider).deviceId,
    ProfileDeviceSlot.coverCalibrator =>
      ref.read(coverCalibratorStateProvider).deviceId,
  };
}

Future<void> _writeSlot(
  ProfileService service,
  int profileId,
  ProfileDeviceSlot slot,
  String deviceId,
) {
  return switch (slot) {
    ProfileDeviceSlot.camera =>
      service.updateProfileDevices(profileId, cameraId: deviceId),
    ProfileDeviceSlot.mount =>
      service.updateProfileDevices(profileId, mountId: deviceId),
    ProfileDeviceSlot.focuser =>
      service.updateProfileDevices(profileId, focuserId: deviceId),
    ProfileDeviceSlot.filterWheel =>
      service.updateProfileDevices(profileId, filterWheelId: deviceId),
    ProfileDeviceSlot.guider =>
      service.updateProfileDevices(profileId, guiderId: deviceId),
    ProfileDeviceSlot.rotator =>
      service.updateProfileDevices(profileId, rotatorId: deviceId),
    ProfileDeviceSlot.dome =>
      service.updateProfileDevices(profileId, domeId: deviceId),
    ProfileDeviceSlot.weather =>
      service.updateProfileDevices(profileId, weatherId: deviceId),
    ProfileDeviceSlot.safetyMonitor =>
      service.updateProfileDevices(profileId, safetyMonitorId: deviceId),
    ProfileDeviceSlot.switchDevice =>
      service.updateProfileDevices(profileId, switchId: deviceId),
    ProfileDeviceSlot.coverCalibrator =>
      service.updateProfileDevices(profileId, coverCalibratorId: deviceId),
  };
}
