import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/equipment/equipment_models.dart';
import '../../services/device_service.dart';

/// The connection surface of a device slot, as the device table
/// (`equipment/device_slots.dart`) hands it out.
///
/// An interface separate from [DeviceSlotNotifier] because widget suites
/// replace a slot's notifier with a fake that `implements` it.
abstract interface class DeviceConnectionNotifier {
  DeviceConnectionState get connectionState;
  String? get deviceId;

  Future<void> disconnect();
  void clearError();
  void setAutoReconnect(bool enabled);

  void setConnecting(String deviceId, [String? deviceName]);
  void setConnected();
  void setDisconnected();
  void setError(Object error);

  /// A connect attempt on this slot failed with [error]. The slot holds no
  /// device afterwards but shows the failure, naming the device that failed
  /// so it can be tried again.
  void connectFailed(Object error);
}

/// The connection half of every device notifier: disconnect, and the
/// connecting / connected / disconnected / error transitions that
/// [DeviceService] writes while it connects a device. A device's own notifier adds its telemetry on top.
abstract class DeviceSlotNotifier<S extends DeviceSlotState<S>>
    extends StateNotifier<S>
    implements DeviceConnectionNotifier {
  DeviceSlotNotifier(this.ref, this.deviceType, S initial)
    : _baseline = initial,
      super(initial);

  final Ref ref;
  final DeviceType deviceType;
  final S _baseline;

  @override
  DeviceConnectionState get connectionState => state.connectionState;

  @override
  String? get deviceId => state.deviceId;

  @override
  Future<void> disconnect() async {
    final released = state.deviceId;
    if (released == null) return;
    await ref.read(deviceServiceProvider).disconnect(deviceType);
    // A device connected in its place meanwhile keeps the slot.
    if (mounted && state.deviceId == released) setDisconnected();
  }

  @override
  void clearError() {
    state = state.copyWith(clearError: true);
  }

  @override
  void setAutoReconnect(bool enabled) {
    state = state.copyWith(autoReconnectEnabled: enabled);
  }

  /// `lastError` survives this transition so the card keeps showing why the
  /// device dropped while a reconnect is in flight; [setConnected] and
  /// [clearError] are what clear it.
  @override
  void setConnecting(String deviceId, [String? deviceName]) {
    state = state.copyWith(
      connectionState: DeviceConnectionState.connecting,
      deviceId: deviceId,
      deviceName: deviceName ?? state.deviceName ?? deviceId,
    );
  }

  @override
  void setConnected() {
    state = state.copyWith(
      connectionState: DeviceConnectionState.connected,
      clearError: true,
    );
  }

  /// Back to the empty slot. The auto-reconnect choice is the user's, not the
  /// device's, so it survives.
  @override
  void setDisconnected() {
    state = _baseline.copyWith(
      autoReconnectEnabled: state.autoReconnectEnabled,
    );
  }

  @override
  void setError(Object error) {
    state = state.copyWith(
      connectionState: DeviceConnectionState.error,
      lastError: DeviceError.fromException(
        error,
        deviceId: state.retryDeviceId,
      ),
    );
  }

  @override
  void connectFailed(Object error) {
    state = _baseline.copyWith(
      connectionState: DeviceConnectionState.error,
      deviceName: state.deviceName,
      autoReconnectEnabled: state.autoReconnectEnabled,
      lastError: DeviceError.fromException(error, deviceId: state.deviceId),
    );
  }
}
