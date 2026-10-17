import '../backend/skotiq_backend.dart';
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

  /// Whether a live [DeviceService] is listening to [backend]'s events, and
  /// so surfaces its equipment errors itself.
  ///
  /// The service is created by the first thing that reads it, so a client
  /// that only watches a remote host may have none, and after a backend swap
  /// the one that exists may still be listening to the old backend.
  static bool surfacesDeviceErrorsFrom(SkotiqBackend backend) {
    final active = _active;
    return active != null && identical(active.eventSource, backend);
  }

  static Future<void> prepareForBackendSwap() async {
    final active = _active;
    if (active == null) {
      return;
    }
    await active.prepareForBackendSwap();
  }
}
