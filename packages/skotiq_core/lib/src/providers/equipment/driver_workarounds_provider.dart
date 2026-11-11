import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/roles/device_backend.dart';
import '../backend_provider.dart';

/// The workarounds the drivers apply to the connected device [deviceId], read
/// from the backend that owns it: the host, on a linked client.
final deviceQuirksProvider = FutureProvider.autoDispose
    .family<List<DeviceQuirk>, String>((ref, deviceId) async {
      final backend = ref.watch(backendProvider);
      if (backend is! DeviceQuirksBackend) return const [];
      return (backend as DeviceQuirksBackend).deviceQuirks(deviceId);
    });

/// Whether the QHY SDK loaded on this computer; null when this app does not
/// run the vendor SDKs itself (a linked client, or no backend yet).
final qhySdkAvailableProvider = Provider<bool?>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is! VendorSdkBackend) return null;
  return (backend as VendorSdkBackend).qhySdkAvailable;
});
