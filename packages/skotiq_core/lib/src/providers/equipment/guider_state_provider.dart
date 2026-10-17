import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/equipment/equipment_models.dart';
import 'device_connection_notifier.dart';
import '../../services/device_service.dart';
import 'equipment_retry_defaults.dart';

// Note: All async callbacks and stream listeners check `mounted`
// before updating state to prevent updates after disposal.

/// Guider state provider
final guiderStateProvider =
    StateNotifierProvider<GuiderStateNotifier, GuiderState>((ref) {
      return GuiderStateNotifier(ref);
    });

class GuiderStateNotifier extends StateNotifier<GuiderState>
    implements DeviceConnectionNotifier {
  @override
  DeviceConnectionState get connectionState => state.connectionState;

  @override
  String? get deviceId => state.deviceId;

  final Ref _ref;
  int _retryAttempts = 0;
  int _connectionRevision = 0;

  GuiderStateNotifier(this._ref) : super(const GuiderState());

  /// Connect [deviceId], showing [deviceName] while the attempt is in flight.
  ///
  /// Nothing later overwrites the name, so a caller that knows the friendly
  /// one should pass it: omitting [deviceName] falls back to the raw id
  /// (`native:builtin_guider:multi_star`) and the device and guide-health
  /// cards read that for the rest of the session.
  Future<void> connect(
    String deviceId, {
    String? deviceName,
    int maxRetries = kDefaultMaxRetries,
  }) async {
    final revision = ++_connectionRevision;
    _retryAttempts = 0;
    _setConnectingState(deviceId, deviceName ?? deviceId);
    await _connectWithRetry(
      deviceId,
      maxRetries,
      revision,
      deviceName: deviceName,
    );
  }

  Future<void> _connectWithRetry(
    String deviceId,
    int maxRetries,
    int revision, {
    String? deviceName,
  }) async {
    try {
      final deviceService = _ref.read(deviceServiceProvider);
      await deviceService.connectGuider(deviceId);
      if (!_isCurrentConnection(deviceId, revision)) return;
      _retryAttempts = 0;
      setConnected();
    } catch (e) {
      if (!_isCurrentAttempt(deviceId, revision)) return;
      _retryAttempts++;
      final error = DeviceError.fromException(
        e,
        deviceId: deviceId,
        retryAttempts: _retryAttempts,
      );

      if (error.recoverable && _retryAttempts < maxRetries) {
        state = state.copyWith(lastError: error);
        await Future.delayed(kDefaultRetryDelay * _retryAttempts);
        if (!_isCurrentAttempt(deviceId, revision)) return;
        _setConnectingState(deviceId, deviceName ?? deviceId);
        await _connectWithRetry(
          deviceId,
          maxRetries,
          revision,
          deviceName: deviceName,
        );
      } else {
        state = state.copyWith(
          connectionState: DeviceConnectionState.error,
          lastError: error,
        );
      }
    }
  }

  Future<void> retryConnection() async {
    if (state.deviceId != null) {
      await connect(state.deviceId!);
    }
  }

  Future<void> disconnect() async {
    if (state.deviceId == null) return;
    final revision = ++_connectionRevision;
    final deviceService = _ref.read(deviceServiceProvider);
    await deviceService.disconnectGuider();
    if (mounted && revision == _connectionRevision) setDisconnected();
  }

  void clearError() {
    state = state.clearError();
  }

  @override
  void setConnecting(String deviceId, [String? deviceName]) {
    _setConnectingState(deviceId, deviceName);
  }

  void _setConnectingState(String deviceId, [String? deviceName]) {
    // Preserve `lastError` across Connecting; see camera
    // provider for the full rationale.
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

  @override
  void setDisconnected() {
    // Preserve `lastError` across the disconnect, exactly as
    // [_setConnectingState] already does.
    //
    // A guider that DIED still owes the operator a reason. The built-in guider's
    // task can fail asynchronously ("Calibration star match failed"), and that
    // path emits a guiding `Disconnected` event which lands here — wiping the
    // error that the accompanying device-error event had just set. The imaging
    // Guiding panel was then left with nothing and fell back to "No guider
    // connected", sending the operator to check cables for a calibration
    // problem. Reproduced end-to-end with the built-in guider on the simulator
    // camera; the error is now retained so the panel can name the failure.
    //
    // `setConnected()` clears it explicitly, so a successful reconnect still
    // wipes the stale error.
    final preservedAutoReconnect = state.autoReconnectEnabled;
    final preservedError = state.lastError;
    state = GuiderState(
      autoReconnectEnabled: preservedAutoReconnect,
      lastError: preservedError,
    );
  }

  bool _isCurrentConnection(String deviceId, int revision) =>
      mounted && revision == _connectionRevision && state.deviceId == deviceId;

  bool _isCurrentAttempt(String deviceId, int revision) =>
      mounted &&
      revision == _connectionRevision &&
      (state.deviceId == null || state.deviceId == deviceId);

  /// Enable or disable auto-reconnection for the guider.
  void setAutoReconnect(bool enabled) {
    state = state.copyWith(autoReconnectEnabled: enabled);
  }

  void setGuiding(bool guiding) {
    state = state.copyWith(isGuiding: guiding);
  }

  void updateRms(double ra, double dec, double total) {
    state = state.copyWith(rmsRa: ra, rmsDec: dec, rmsTotal: total);
  }

  @override
  void setError(Object error) {
    state = state.copyWith(
      connectionState: DeviceConnectionState.error,
      lastError: DeviceError.fromException(error, deviceId: state.deviceId),
    );
  }
}
