import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/equipment/equipment_models.dart';
import 'device_connection_notifier.dart';
import '../../services/device_service.dart';
import 'equipment_retry_defaults.dart';

// Switch device state provider, mirroring the safety-monitor
// shape (Audit C1). The notifier owns the connect-with-retry loop and the
// `autoReconnectEnabled` flag that `DeviceService._getAutoReconnectFor`
// consults when a Disconnected event arrives.
//
// Per-channel state mutation is driven by [DeviceService.setSwitchChannel],
// which calls the Rust bridge (`api_switch_set_state`) and then calls
// [setChannelState] here to reconcile the cached snapshot. The
// [setChannels] helper is used by [DeviceService.refreshSwitchChannels]
// to populate the channel snapshot on connect and on manual refresh.
//
// Note: All async callbacks and stream listeners check `mounted` before
// updating state to prevent updates after disposal.

/// Switch device state provider.
final switchStateProvider =
    StateNotifierProvider<SwitchStateNotifier, SwitchState>((ref) {
      return SwitchStateNotifier(ref);
    });

class SwitchStateNotifier extends StateNotifier<SwitchState>
    implements DeviceConnectionNotifier {
  @override
  DeviceConnectionState get connectionState => state.connectionState;

  @override
  String? get deviceId => state.deviceId;

  final Ref _ref;
  int _retryAttempts = 0;
  int _connectionRevision = 0;

  SwitchStateNotifier(this._ref) : super(const SwitchState());

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
      await deviceService.connectSwitch(deviceId);
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
    await deviceService.disconnectSwitch();
    if (mounted && revision == _connectionRevision) setDisconnected();
  }

  @override
  void setConnecting(String deviceId, [String? deviceName]) {
    _setConnectingState(deviceId, deviceName);
  }

  void _setConnectingState(String deviceId, [String? deviceName]) {
    state = state.copyWith(
      connectionState: DeviceConnectionState.connecting,
      deviceId: deviceId,
      deviceName: deviceName ?? state.deviceName ?? deviceId,
      clearError: true,
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
    state = SwitchState(autoReconnectEnabled: preservedAutoReconnect);
  }

  bool _isCurrentConnection(String deviceId, int revision) =>
      mounted && revision == _connectionRevision && state.deviceId == deviceId;

  bool _isCurrentAttempt(String deviceId, int revision) =>
      mounted &&
      revision == _connectionRevision &&
      (state.deviceId == null || state.deviceId == deviceId);

  /// Enable or disable auto-reconnection for the switch device.
  void setAutoReconnect(bool enabled) {
    state = state.copyWith(autoReconnectEnabled: enabled);
  }

  /// Update the cached channel snapshot. The Rust bridge does not push
  /// these on a stream yet; DeviceService polls explicitly on connect
  /// and after any `setSwitchChannel` write.
  ///
  /// When [refreshedAt] is provided it is recorded as the last-poll
  /// timestamp the UI uses for the "Refresh" affordance; pass null when
  /// only updating the count without re-polling labels/states.
  void setChannels({
    required int count,
    List<String>? names,
    List<bool>? states,
    List<String>? descriptions,
    List<bool>? isBoolean,
    List<double>? values,
    List<double>? minValues,
    List<double>? maxValues,
    List<double>? steps,
    List<bool>? canWrite,
    DateTime? refreshedAt,
  }) {
    state = state.copyWith(
      channelCount: count,
      channelNames: names ?? state.channelNames,
      channelStates: states ?? state.channelStates,
      channelDescriptions: descriptions ?? state.channelDescriptions,
      channelIsBoolean: isBoolean ?? state.channelIsBoolean,
      channelValues: values ?? state.channelValues,
      channelMinValues: minValues ?? state.channelMinValues,
      channelMaxValues: maxValues ?? state.channelMaxValues,
      channelSteps: steps ?? state.channelSteps,
      channelCanWrite: canWrite ?? state.channelCanWrite,
      lastChannelRefresh: refreshedAt,
    );
  }

  /// Update a single channel's boolean state after a successful bridge
  /// write. The index is bounds-checked against the cached
  /// [SwitchState.channelStates] list; out-of-range indices are
  /// silently ignored because the UI cannot have rendered a row for a
  /// channel that does not exist in the snapshot. This is the only
  /// mutation path the UI is allowed to use — direct optimistic writes
  /// would lie to the user about hardware state.
  void setChannelState(int index, bool on) {
    final current = state.channelStates;
    if (index < 0 || index >= current.length) return;
    final next = List<bool>.from(current);
    next[index] = on;
    final values = List<double>.from(state.channelValues);
    if (index < values.length) {
      final min = index < state.channelMinValues.length
          ? state.channelMinValues[index]
          : 0.0;
      final max = index < state.channelMaxValues.length
          ? state.channelMaxValues[index]
          : 1.0;
      values[index] = on ? max : min;
    }
    state = state.copyWith(channelStates: next, channelValues: values);
  }

  /// Reconcile a numeric/PWM channel after the hardware confirms a write.
  void setChannelValue(int index, double value) {
    final current = state.channelValues;
    if (index < 0 || index >= current.length) return;
    final values = List<double>.from(current);
    values[index] = value;

    final states = List<bool>.from(state.channelStates);
    if (index < states.length) {
      final min = index < state.channelMinValues.length
          ? state.channelMinValues[index]
          : 0.0;
      final max = index < state.channelMaxValues.length
          ? state.channelMaxValues[index]
          : 1.0;
      states[index] = value > min + ((max - min) / 2);
    }
    state = state.copyWith(channelValues: values, channelStates: states);
  }

  @override
  void setError(Object error) {
    state = state.copyWith(
      connectionState: DeviceConnectionState.error,
      lastError: DeviceError.fromException(error, deviceId: state.deviceId),
    );
  }
}
