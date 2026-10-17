import '../../models/equipment/equipment_models.dart'
    show DeviceConnectionState;

/// The connection surface every equipment state notifier exposes.
///
/// The master→slave mirror and the local device-event router both drive all
/// eleven device notifiers through one device-type table
/// (`equipment/device_type_registry.dart`). Without a shared type that table
/// has to be `dynamic`, and a rename in any notifier becomes a runtime
/// `NoSuchMethodError` on the event pump instead of an analyzer error.
///
/// Deliberately narrow: only the members those two tables drive. Each device's
/// own telemetry setters, and `connect` (whose signature genuinely varies — the
/// guider carries a friendly name through its retry), stay off it.
abstract interface class DeviceConnectionNotifier {
  /// Live connection state, read straight off the notifier's own state.
  DeviceConnectionState get connectionState;

  /// Id of the device this notifier currently represents, or null.
  String? get deviceId;

  void setConnecting(String deviceId, [String? deviceName]);
  void setConnected();
  void setDisconnected();

  /// Record a driver-reported error on this device's card. Each notifier keeps
  /// its own extra bookkeeping (the safety monitor also drops `isSafe`), so the
  /// implementations are not identical — only the entry point is shared.
  void setError(Object error);
}
