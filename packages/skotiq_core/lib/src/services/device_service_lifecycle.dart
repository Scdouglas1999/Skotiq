import '../services/device_service.dart';

/// Tracks the live [DeviceService] without creating a Riverpod cycle between
/// [backendProvider] and [deviceServiceProvider].
class DeviceServiceLifecycle {
  DeviceServiceLifecycle._();

  static DeviceService? _active;

  static void register(DeviceService service) {
    _active = service;
  }

  static void unregister(DeviceService service) {
    if (identical(_active, service)) {
      _active = null;
    }
  }

  static Future<void> prepareForBackendSwap() async {
    final active = _active;
    if (active == null) {
      return;
    }
    await active.prepareForBackendSwap();
  }
}
