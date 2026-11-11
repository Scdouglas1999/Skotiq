import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/backend/device_types.dart';
import '../../models/equipment/equipment_models.dart';
import '../../services/device_service.dart';

const int kDefaultMaxRetries = 3;
const Duration kDefaultRetryDelay = Duration(seconds: 1);

/// The connection surface of a device slot, as the device table
/// (`equipment/device_slots.dart`) hands it out.
///
/// An interface separate from [DeviceSlotNotifier] because widget suites
/// replace a slot's notifier with a fake that `implements` it.
abstract interface class DeviceConnectionNotifier {
  DeviceConnectionState get connectionState;
  String? get deviceId;

  /// Connect [deviceId], retrying a recoverable failure up to [maxRetries]
  /// attempts in total. A failure is left on the slot as `lastError`; this
  /// does not throw.
  Future<void> connect(String deviceId, {String? deviceName, int maxRetries});

  Future<void> retryConnection();
  Future<void> disconnect();
  void clearError();
  void setAutoReconnect(bool enabled);

  void setConnecting(String deviceId, [String? deviceName]);
  void setConnected();
  void setDisconnected();
  void setError(Object error);

  /// A connect attempt on this slot failed with [error]; the slot goes back
  /// to empty unless the device has a reason to keep showing the failure.
  void connectFailed(Object error);
}

/// The connection half of every device notifier: connect with retry,
/// disconnect, and the connecting / connected / disconnected / error
/// transitions. A device's own notifier adds its telemetry on top.
abstract class DeviceSlotNotifier<S extends DeviceSlotState<S>>
    extends StateNotifier<S>
    implements DeviceConnectionNotifier {
  DeviceSlotNotifier(this.ref, this.deviceType, S initial)
    : _baseline = initial,
      super(initial);

  final Ref ref;
  final DeviceType deviceType;
  final S _baseline;
  int _connectionRevision = 0;

  @override
  DeviceConnectionState get connectionState => state.connectionState;

  @override
  String? get deviceId => state.deviceId;

  @override
  Future<void> connect(
    String deviceId, {
    String? deviceName,
    int maxRetries = kDefaultMaxRetries,
  }) async {
    final revision = ++_connectionRevision;
    for (var attempt = 1; ; attempt++) {
      setConnecting(deviceId, deviceName ?? deviceId);
      try {
        await ref.read(deviceServiceProvider).connect(deviceType, deviceId);
        if (_isCurrent(revision) && state.deviceId == deviceId) setConnected();
        return;
      } catch (e) {
        if (!_isCurrentAttempt(deviceId, revision)) return;
        final error = DeviceError.fromException(
          e,
          deviceId: deviceId,
          retryAttempts: attempt,
        );
        if (!error.recoverable || attempt >= maxRetries) {
          state = state.copyWith(
            connectionState: DeviceConnectionState.error,
            lastError: error,
          );
          return;
        }
        state = state.copyWith(lastError: error);
        await Future<void>.delayed(kDefaultRetryDelay * attempt);
        if (!_isCurrentAttempt(deviceId, revision)) return;
      }
    }
  }

  @override
  Future<void> retryConnection() async {
    final deviceId = state.deviceId;
    if (deviceId != null) await connect(deviceId);
  }

  @override
  Future<void> disconnect() async {
    if (state.deviceId == null) return;
    final revision = ++_connectionRevision;
    await ref.read(deviceServiceProvider).disconnect(deviceType);
    if (_isCurrent(revision)) setDisconnected();
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
      lastError: DeviceError.fromException(error, deviceId: state.deviceId),
    );
  }

  @override
  void connectFailed(Object error) => setDisconnected();

  bool _isCurrent(int revision) => mounted && revision == _connectionRevision;

  bool _isCurrentAttempt(String deviceId, int revision) =>
      _isCurrent(revision) &&
      (state.deviceId == null || state.deviceId == deviceId);
}
