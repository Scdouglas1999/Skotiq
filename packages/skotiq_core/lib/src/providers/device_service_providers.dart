import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backend_provider.dart';
import '../models/backend/backend_types.dart';
import '../services/device_service.dart';

final deviceServiceProvider = Provider<DeviceService>((ref) {
  final backend = ref.watch(backendProvider);
  final service = DeviceService(ref, backend);
  ref.onDispose(() => service.dispose());
  return service;
});

final availableCamerasProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref.watch(deviceServiceProvider).discoverDevices(DeviceType.camera);
});

final availableMountsProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref.watch(deviceServiceProvider).discoverDevices(DeviceType.mount);
});

final availableFocusersProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref.watch(deviceServiceProvider).discoverDevices(DeviceType.focuser);
});

final availableFilterWheelsProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref
      .watch(deviceServiceProvider)
      .discoverDevices(DeviceType.filterWheel);
});

final availableGuidersProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref.watch(deviceServiceProvider).discoverDevices(DeviceType.guider);
});

final availableRotatorsProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref.watch(deviceServiceProvider).discoverDevices(DeviceType.rotator);
});

final availableDomesProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref.watch(deviceServiceProvider).discoverDevices(DeviceType.dome);
});

final availableWeatherProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref.watch(deviceServiceProvider).discoverDevices(DeviceType.weather);
});

/// Provider for available safety monitors
final availableSafetyMonitorsProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref
      .watch(deviceServiceProvider)
      .discoverDevices(DeviceType.safetyMonitor);
});

final availableSwitchesProvider = FutureProvider<List<DeviceInfo>>((ref) {
  return ref.watch(deviceServiceProvider).discoverDevices(DeviceType.switch_);
});
