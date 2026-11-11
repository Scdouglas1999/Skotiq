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
Future<List<DeviceType>> saveSessionDevicesToProfile(
  WidgetRef ref, {
  required int profileId,
  required Set<DeviceType> slots,
}) async {
  final service = ref.read(profileServiceProvider);
  final saved = <DeviceType>[];
  for (final slot in slots) {
    final deviceId = connectedDeviceIdForSlot(ref, slot);
    if (deviceId == null || deviceId.isEmpty) continue;
    await service.updateProfileDevices(profileId, {slot: deviceId});
    saved.add(slot);
  }
  return saved;
}

/// The id of the device currently occupying [slot], or null when nothing is
/// connected there.
String? connectedDeviceIdForSlot(WidgetRef ref, DeviceType slot) =>
    readDeviceSlot(ref, slot).deviceId;
