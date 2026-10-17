import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/backend/autofocus_result.dart';
import '../../models/equipment/equipment_models.dart';
import 'device_connection_notifier.dart';
import '../../services/device_service.dart';
import 'equipment_retry_defaults.dart';

// Note: All async callbacks and stream listeners check `mounted`
// before updating state to prevent updates after disposal.

/// Focuser state provider
final focuserStateProvider =
    StateNotifierProvider<FocuserStateNotifier, FocuserState>((ref) {
      return FocuserStateNotifier(ref);
    });

class FocuserStateNotifier extends StateNotifier<FocuserState>
    implements DeviceConnectionNotifier {
  @override
  DeviceConnectionState get connectionState => state.connectionState;

  @override
  String? get deviceId => state.deviceId;

  final Ref _ref;
  int _retryAttempts = 0;
  int _connectionRevision = 0;

  FocuserStateNotifier(this._ref) : super(const FocuserState());

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
      await deviceService.connectFocuser(deviceId);
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
    await deviceService.disconnectFocuser();
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
  void setConnected({
    int? maxPosition,
    double? stepSize,
    bool? isAbsolute,
    bool? hasTemperature,
  }) {
    state = state.copyWith(
      connectionState: DeviceConnectionState.connected,
      maxPosition: maxPosition,
      stepSize: stepSize,
      isAbsolute: isAbsolute,
      hasTemperature: hasTemperature,
      clearError: true,
    );
  }

  @override
  void setDisconnected() {
    final preservedAutoReconnect = state.autoReconnectEnabled;
    state = FocuserState(autoReconnectEnabled: preservedAutoReconnect);
  }

  bool _isCurrentConnection(String deviceId, int revision) =>
      mounted && revision == _connectionRevision && state.deviceId == deviceId;

  bool _isCurrentAttempt(String deviceId, int revision) =>
      mounted &&
      revision == _connectionRevision &&
      (state.deviceId == null || state.deviceId == deviceId);

  /// Enable or disable auto-reconnection for the focuser.
  void setAutoReconnect(bool enabled) {
    state = state.copyWith(autoReconnectEnabled: enabled);
  }

  void updatePosition(int position) {
    state = state.copyWith(position: position);
  }

  void updateTemperature(double temp) {
    state = state.copyWith(temperature: temp);
  }

  void setMoving(bool moving) {
    state = state.copyWith(isMoving: moving);
  }

  @override
  void setError(Object error) {
    state = state.copyWith(
      connectionState: DeviceConnectionState.error,
      lastError: DeviceError.fromException(error, deviceId: state.deviceId),
    );
  }
}

/// Focus position history provider - tracks the last N focus positions for sparkline display.
/// This allows the dashboard to show a visual history of focus position changes.
final focusPositionHistoryProvider =
    StateNotifierProvider<FocusPositionHistoryNotifier, List<int>>((ref) {
      return FocusPositionHistoryNotifier(ref);
    });

/// Notifier that maintains a rolling history of focus positions.
class FocusPositionHistoryNotifier extends StateNotifier<List<int>> {
  final Ref _ref;
  static const int _maxHistoryLength = 10;
  int? _lastRecordedPosition;

  FocusPositionHistoryNotifier(this._ref) : super([]) {
    // Listen to focuser state changes and record position updates
    _ref.listen<FocuserState>(focuserStateProvider, (previous, next) {
      if (next.position != null && next.position != _lastRecordedPosition) {
        _lastRecordedPosition = next.position;
        _addPosition(next.position!);
      }
    });
  }

  void _addPosition(int position) {
    final newHistory = [...state, position];
    if (newHistory.length > _maxHistoryLength) {
      state = newHistory.sublist(newHistory.length - _maxHistoryLength);
    } else {
      state = newHistory;
    }
  }

  /// Manually add a position to the history (e.g., after autofocus)
  void recordPosition(int position) {
    _lastRecordedPosition = position;
    _addPosition(position);
  }

  /// Clear the history (e.g., when switching focusers)
  void clear() {
    _lastRecordedPosition = null;
    state = [];
  }
}

// Autofocus result provider

/// Provider for the last autofocus result
/// This stores the most recent autofocus run result for display in the UI
final autofocusResultProvider = StateProvider<AutofocusResult?>((ref) => null);
