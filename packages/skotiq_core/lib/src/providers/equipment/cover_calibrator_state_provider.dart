import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/equipment/equipment_models.dart';
import 'device_connection_notifier.dart';
import '../../services/device_service.dart';
import 'equipment_retry_defaults.dart';

// Note: All async callbacks and stream listeners check `mounted`
// before updating state to prevent updates after disposal.

/// Cover calibrator state provider
final coverCalibratorStateProvider =
    StateNotifierProvider<CoverCalibratorStateNotifier, CoverCalibratorState>((
      ref,
    ) {
      return CoverCalibratorStateNotifier(ref);
    });

class CoverCalibratorStateNotifier extends StateNotifier<CoverCalibratorState>
    implements DeviceConnectionNotifier {
  @override
  DeviceConnectionState get connectionState => state.connectionState;

  @override
  String? get deviceId => state.deviceId;

  final Ref _ref;
  int _retryAttempts = 0;
  int _connectionRevision = 0;

  CoverCalibratorStateNotifier(this._ref) : super(const CoverCalibratorState());

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
      await deviceService.connectCoverCalibrator(deviceId);
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

  Future<void> retryConnection() async {
    if (state.deviceId != null) {
      await connect(state.deviceId!);
    }
  }

  void clearError() {
    state = state.clearError();
  }

  Future<void> disconnect() async {
    if (state.deviceId == null) return;
    final revision = ++_connectionRevision;
    final deviceService = _ref.read(deviceServiceProvider);
    await deviceService.disconnectCoverCalibrator();
    if (mounted && revision == _connectionRevision) setDisconnected();
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
    final preservedAutoReconnect = state.autoReconnectEnabled;
    state = CoverCalibratorState(autoReconnectEnabled: preservedAutoReconnect);
  }

  bool _isCurrentConnection(String deviceId, int revision) =>
      mounted && revision == _connectionRevision && state.deviceId == deviceId;

  bool _isCurrentAttempt(String deviceId, int revision) =>
      mounted &&
      revision == _connectionRevision &&
      (state.deviceId == null || state.deviceId == deviceId);

  /// Enable or disable auto-reconnection for the cover calibrator.
  void setAutoReconnect(bool enabled) {
    state = state.copyWith(autoReconnectEnabled: enabled);
  }

  void updateCoverStatus(CoverStatus status) {
    state = state.copyWith(coverStatus: status);
  }

  void updateCalibratorStatus(CalibratorStatus status) {
    state = state.copyWith(calibratorStatus: status);
  }

  void updateBrightness(int brightness) {
    state = state.copyWith(brightness: brightness);
  }

  void updateMaxBrightness(int maxBrightness) {
    state = state.copyWith(maxBrightness: maxBrightness);
  }

  @override
  void setError(Object error) {
    state = state.copyWith(
      connectionState: DeviceConnectionState.error,
      lastError: DeviceError.fromException(error, deviceId: state.deviceId),
    );
  }
}
