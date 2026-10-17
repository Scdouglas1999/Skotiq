import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/equipment/equipment_models.dart';
import 'device_connection_notifier.dart';
import '../../services/device_service.dart';
import 'equipment_retry_defaults.dart';

// Note: All async callbacks and stream listeners check `mounted`
// before updating state to prevent updates after disposal.

/// Dome state provider
final domeStateProvider = StateNotifierProvider<DomeStateNotifier, DomeState>((
  ref,
) {
  return DomeStateNotifier(ref);
});

class DomeStateNotifier extends StateNotifier<DomeState>
    implements DeviceConnectionNotifier {
  @override
  DeviceConnectionState get connectionState => state.connectionState;

  @override
  String? get deviceId => state.deviceId;

  final Ref _ref;
  int _retryAttempts = 0;
  int _connectionRevision = 0;

  DomeStateNotifier(this._ref) : super(const DomeState());

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
      await deviceService.connectDome(deviceId);
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
    await deviceService.disconnectDome();
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
    state = DomeState(autoReconnectEnabled: preservedAutoReconnect);
  }

  bool _isCurrentConnection(String deviceId, int revision) =>
      mounted && revision == _connectionRevision && state.deviceId == deviceId;

  bool _isCurrentAttempt(String deviceId, int revision) =>
      mounted &&
      revision == _connectionRevision &&
      (state.deviceId == null || state.deviceId == deviceId);

  /// Enable or disable auto-reconnection for the dome.
  void setAutoReconnect(bool enabled) {
    state = state.copyWith(autoReconnectEnabled: enabled);
  }

  void updateAzimuth(double azimuth) {
    state = state.copyWith(azimuth: azimuth);
  }

  void updateShutterStatus(ShutterStatus status) {
    state = state.copyWith(shutterStatus: status);
  }

  /// Apply one live telemetry read from the driver.
  ///
  /// Single state write so the card cannot render a half-updated dome (e.g. a
  /// new azimuth against the previous shutter state).
  ///
  /// Nothing here is *defaulted*: callers pass [ShutterStatus.unknown]
  /// explicitly when the driver exposes no shutter, so an unreadable shutter
  /// renders as `Unknown` rather than the fabricated `Closed` an operator would
  /// act on. A null argument means "this read carried no value for that field",
  /// which leaves the previous reading in place. Position telemetry alone never
  /// flips the connection state.
  void applyStatus({
    double? azimuth,
    ShutterStatus? shutterStatus,
    bool? isSlewing,
    bool? isAtHome,
    bool? isParked,
    bool? isSlaved,
  }) {
    state = state.copyWith(
      azimuth: azimuth,
      shutterStatus: shutterStatus,
      isSlewing: isSlewing,
      isAtHome: isAtHome,
      isParked: isParked,
      isSlaved: isSlaved,
    );
  }

  void setSlewing(bool slewing) {
    state = state.copyWith(isSlewing: slewing);
  }

  void setParked(bool parked) {
    state = state.copyWith(isParked: parked);
  }

  void setSlaved(bool slaved) {
    state = state.copyWith(isSlaved: slaved);
  }

  @override
  void setError(Object error) {
    state = state.copyWith(
      connectionState: DeviceConnectionState.error,
      lastError: DeviceError.fromException(error, deviceId: state.deviceId),
    );
  }
}
