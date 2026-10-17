import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/equipment/equipment_models.dart';
import 'device_connection_notifier.dart';
import '../../services/device_service.dart';
import 'equipment_retry_defaults.dart';

// Note: All async callbacks and stream listeners check `mounted`
// before updating state to prevent updates after disposal.

/// Camera state provider
final cameraStateProvider =
    StateNotifierProvider<CameraStateNotifier, CameraStateSnapshot>((ref) {
      return CameraStateNotifier(ref);
    });

class CameraStateNotifier extends StateNotifier<CameraStateSnapshot>
    implements DeviceConnectionNotifier {
  @override
  DeviceConnectionState get connectionState => state.connectionState;

  @override
  String? get deviceId => state.deviceId;

  final Ref _ref;
  int _retryAttempts = 0;
  int _connectionRevision = 0;

  CameraStateNotifier(this._ref) : super(const CameraStateSnapshot());

  Future<void> connect(
    String deviceId, {
    int maxRetries = kDefaultMaxRetries,
  }) async {
    final revision = ++_connectionRevision;
    _retryAttempts = 0;
    _setConnectingState(deviceId, deviceId);
    await _connectWithRetry(deviceId, maxRetries, revision);
  }

  Future<void> _connectWithRetry(
    String deviceId,
    int maxRetries,
    int revision,
  ) async {
    try {
      final deviceService = _ref.read(deviceServiceProvider);
      await deviceService.connectCamera(deviceId);
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
        _setConnectingState(deviceId, deviceId);
        await _connectWithRetry(deviceId, maxRetries, revision);
      } else {
        state = state.copyWith(
          connectionState: DeviceConnectionState.error,
          lastError: error,
        );
      }
    }
  }

  /// Retry the last failed connection
  Future<void> retryConnection() async {
    if (state.deviceId != null) {
      await connect(state.deviceId!);
    }
  }

  /// Clear the current error state
  void clearError() {
    state = state.clearError();
  }

  Future<void> disconnect() async {
    if (state.deviceId == null && state.deviceName == null) return;
    final revision = ++_connectionRevision;
    final deviceService = _ref.read(deviceServiceProvider);
    await deviceService.disconnectCamera();
    if (mounted && revision == _connectionRevision) setDisconnected();
  }

  @override
  void setConnecting(String deviceId, [String? deviceName]) {
    _setConnectingState(deviceId, deviceName);
  }

  void _setConnectingState(String deviceId, [String? deviceName]) {
    // Preserve `lastError` across the Connecting transition so
    // the equipment card can keep showing the most recent driver error
    // while the reconnect is in flight. It is cleared only when the
    // device actually reaches Connected (see [setConnected]), or when
    // the user explicitly calls [clearError].
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
    // Preserve the user's auto-reconnect preference across disconnects.
    // Resetting to a fresh CameraStateSnapshot would flip it back to the
    // `true` default, which would silently undo the user's choice the
    // moment the device disconnected.
    final preservedAutoReconnect = state.autoReconnectEnabled;
    state = CameraStateSnapshot(autoReconnectEnabled: preservedAutoReconnect);
  }

  bool _isCurrentConnection(String deviceId, int revision) {
    return mounted &&
        revision == _connectionRevision &&
        state.deviceId == deviceId;
  }

  bool _isCurrentAttempt(String deviceId, int revision) {
    return mounted &&
        revision == _connectionRevision &&
        (state.deviceId == null || state.deviceId == deviceId);
  }

  void updateTemperature(double temp, [double? power]) {
    state = state.copyWith(
      temperature: temp,
      coolerPower: power,
      clearCoolerPower: power == null,
      lastSuccessfulCommunication: DateTime.now(),
    );
  }

  /// Update target temperature setting (persists across navigation)
  void setTargetTemp(double temp) {
    state = state.copyWith(targetTemp: temp);
  }

  /// Update cooling state (on/off)
  void setCooling(bool isCooling) {
    state = state.copyWith(isCooling: isCooling);
  }

  /// Update warming state (gradual warm-up in progress)
  void setWarming(bool isWarming) {
    state = state.copyWith(isWarming: isWarming);
  }

  /// Apply an acknowledged cooler-off command without leaving stale telemetry
  /// that makes shutdown/risk UI believe the TEC is still energized. A future
  /// device status event may repopulate cooler power if the driver reports it.
  void markCoolingDisabled() {
    state = state.copyWith(
      isCooling: false,
      isWarming: false,
      clearCoolerPower: true,
      lastSuccessfulCommunication: DateTime.now(),
    );
  }

  void setExposing(bool isExposing, {double? progress}) {
    state = state.copyWith(
      isExposing: isExposing,
      exposureProgress: progress,
      lastSuccessfulCommunication: DateTime.now(),
    );
  }

  @override
  void setError(Object error) {
    state = state.copyWith(
      connectionState: DeviceConnectionState.error,
      lastError: DeviceError.fromException(error, deviceId: state.deviceId),
    );
  }

  /// Update last successful communication timestamp
  void updateCommunication() {
    state = state.copyWith(lastSuccessfulCommunication: DateTime.now());
  }

  /// Enable or disable auto-reconnection
  void setAutoReconnect(bool enabled) {
    state = state.copyWith(autoReconnectEnabled: enabled);
  }
}
