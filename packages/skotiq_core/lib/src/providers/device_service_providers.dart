import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backend_provider.dart';
import 'linked_host.dart';
import '../models/backend/backend_types.dart';
import '../services/device_service.dart';
import '../services/device_service/connect_attempts.dart';

/// Where each connect this app asked for stands, for the backend that is
/// current. The device service writes it; whatever else writes a device slot
/// (a linked client's mirror of the host) asks it first, so a connect in
/// flight or just failed keeps its slot.
final connectAttemptsProvider = Provider<ConnectAttempts>((ref) {
  ref.watch(backendProvider);
  final attempts = ConnectAttempts();
  ref.onDispose(attempts.dispose);
  return attempts;
});

final deviceServiceProvider = Provider<DeviceService>((ref) {
  final backend = ref.watch(backendProvider);
  final service = DeviceService(
    ref,
    backend,
    attempts: ref.watch(connectAttemptsProvider),
    hostDevices: ref.watch(linkedHostDevicesProvider),
    hostLink: ref.watch(linkedHostLinkProvider),
  );
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
