import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/device_commands.dart';
import 'backend_provider.dart';
import 'device_service_providers.dart';
import 'equipment/device_slots.dart';
import 'equipment/switch_state_provider.dart';

/// The shared device command path; see [DeviceCommands].
final deviceCommandsProvider = Provider<DeviceCommands>(
  (ref) => DeviceCommands(
    service: () => ref.read(deviceServiceProvider),
    backend: () => ref.read(deviceBackendProvider),
    slotDevice: (type) {
      if (!ref.exists(type.slot.state)) return null;
      final slot = readDeviceSlot(ref.container, type);
      return (connectionState: slot.connectionState, deviceId: slot.deviceId);
    },
    switchChannelCount: () => ref.read(switchStateProvider).channelCount,
  ),
);
