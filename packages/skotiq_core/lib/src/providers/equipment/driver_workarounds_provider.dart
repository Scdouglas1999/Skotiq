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
