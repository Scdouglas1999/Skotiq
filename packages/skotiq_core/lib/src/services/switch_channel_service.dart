import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_api;

import '../backend/ffi_backend.dart';
import '../backend/network_backend.dart';
import '../backend/skotiq_backend.dart';
import '../models/equipment/equipment_models.dart' show DeviceConnectionState;
import '../providers/backend_provider.dart';
import '../providers/equipment_provider.dart';
import 'device_exceptions.dart';
import 'error_service.dart';
import 'logging_service.dart';

/// Type alias for the switch-bridge `apiSwitchGetMax` shim used by
/// [SwitchChannelService.refreshChannels]. Tests override the static
/// hook below to avoid loading the native bridge.
typedef SwitchBridgeGetMaxFn = Future<int> Function(String deviceId);

/// Type alias for the switch-bridge name fetch.
typedef SwitchBridgeGetNameFn =
    Future<String> Function(String deviceId, int switchId);

/// Type alias for the switch-bridge boolean read.
typedef SwitchBridgeGetStateFn =
    Future<bool> Function(String deviceId, int switchId);

/// Type alias for the switch-bridge boolean write.
typedef SwitchBridgeSetStateFn =
    Future<void> Function(String deviceId, int switchId, bool state);

/// Type aliases for the complete channel-capability read and analog write.
typedef SwitchBridgeGetCapabilitiesFn =
    Future<bridge_api.SwitchCapabilities> Function(String deviceId);
typedef SwitchBridgeSetValueFn =
    Future<void> Function(String deviceId, int switchId, double value);

/// Owns the per-channel switch-device refresh + write paths, and the
/// switch-bridge testable seam (four static function pointers plus the
/// backend-bypass flag).
///
/// `DeviceService` instantiates one per instance and keeps thin public
/// delegators (`refreshSwitchChannels` / `setSwitchChannel`) for its call sites.
/// That delegator owns its `_trackInFlight` quiesce accounting; this service
/// does not touch that state.
///
/// ## Testable seam
///
/// The FFI branch is normally guarded by `_backend is FfiBackend`, which
/// `MockBackend` cannot satisfy. Tests set
/// [switchBridgeBypassBackendCheck] = true and override the four
/// function-pointer hooks so the bridge calls are intercepted without
/// changing the backend type-check used in production.
///
/// MUST call [resetHooks] in `tearDown` to avoid leaking state between
/// tests.
class SwitchChannelService {
  SwitchChannelService({required Ref ref, required SkotiqBackend backend})
    : _ref = ref,
      _backend = backend;

  final Ref _ref;
  final SkotiqBackend _backend;
  int _refreshGeneration = 0;

  bool _stillOwnsDevice(String deviceId) {
    try {
      final current = _ref.read(switchStateProvider);
      return identical(_ref.read(backendProvider), _backend) &&
          current.connectionState == DeviceConnectionState.connected &&
          current.deviceId == deviceId;
    } on Object {
      return false;
    }
  }

  bool _stillOwnsRefresh(int generation, String deviceId) =>
      generation == _refreshGeneration && _stillOwnsDevice(deviceId);

  // Switch bridge hooks (testable seam)
  // Follow-up: the per-channel switch UI needs to call FFI even
  // when the test rig swaps in a MockBackend. The MockBackend can't
  // satisfy `_backend is FfiBackend`, so the actual `apiSwitch*` calls
  // would otherwise be skipped. Static function-pointer hooks let
  // tests swap in fakes for the bridge calls without touching the
  // backend type check. Production code calls
  // `switchBridge{GetMax,GetName,GetState,SetState}` instead of
  // `bridge_api.apiSwitch*` directly so the override is centralized.
  @visibleForTesting
  static SwitchBridgeGetMaxFn switchBridgeGetMax = (deviceId) =>
      bridge_api.apiSwitchGetMax(deviceId: deviceId);
  @visibleForTesting
  static SwitchBridgeGetNameFn switchBridgeGetName = (deviceId, switchId) =>
      bridge_api.apiSwitchGetName(deviceId: deviceId, switchId: switchId);
  @visibleForTesting
  static SwitchBridgeGetStateFn switchBridgeGetState = (deviceId, switchId) =>
      bridge_api.apiSwitchGetState(deviceId: deviceId, switchId: switchId);
  @visibleForTesting
  static SwitchBridgeSetStateFn switchBridgeSetState =
      (deviceId, switchId, state) => bridge_api.apiSwitchSetState(
        deviceId: deviceId,
        switchId: switchId,
        state: state,
      );
  @visibleForTesting
  static SwitchBridgeGetCapabilitiesFn switchBridgeGetCapabilities =
      (deviceId) => bridge_api.apiGetSwitchCapabilities(deviceId: deviceId);
  @visibleForTesting
  static SwitchBridgeSetValueFn switchBridgeSetValue =
      (deviceId, switchId, value) => bridge_api.apiSwitchSetValue(
        deviceId: deviceId,
        switchId: switchId,
        value: value,
      );

  /// When true, [refreshChannels] and [setChannel] will call the bridge
  /// hooks above unconditionally instead of gating on
  /// `_backend is FfiBackend`. Tests set this to true so MockBackend
  /// can stand in for FfiBackend without satisfying its type.
  /// MUST remain false in production builds.
  @visibleForTesting
  static bool switchBridgeBypassBackendCheck = false;

  /// Reset switch bridge hooks to their production implementations.
  /// Call from `tearDown` in any test that overrode them.
  @visibleForTesting
  static void resetHooks() {
    switchBridgeBypassBackendCheck = false;
    switchBridgeGetMax = (deviceId) =>
        bridge_api.apiSwitchGetMax(deviceId: deviceId);
    switchBridgeGetName = (deviceId, switchId) =>
        bridge_api.apiSwitchGetName(deviceId: deviceId, switchId: switchId);
    switchBridgeGetState = (deviceId, switchId) =>
        bridge_api.apiSwitchGetState(deviceId: deviceId, switchId: switchId);
    switchBridgeSetState = (deviceId, switchId, state) =>
        bridge_api.apiSwitchSetState(
          deviceId: deviceId,
          switchId: switchId,
          state: state,
        );
    switchBridgeGetCapabilities = (deviceId) =>
        bridge_api.apiGetSwitchCapabilities(deviceId: deviceId);
    switchBridgeSetValue = (deviceId, switchId, value) =>
        bridge_api.apiSwitchSetValue(
          deviceId: deviceId,
          switchId: switchId,
          value: value,
        );
  }

  /// Refresh the cached channel snapshot for the currently-connected
  /// switch device.
  ///
  /// Polls `api_switch_get_max`, then `api_switch_get_name` +
  /// `api_switch_get_state` for each channel, and stores the result on
  /// the [switchStateProvider]. Per-channel name/state fetches that
  /// individually fail fall back to a generated "Channel N" label and
  /// `false` state so a single misbehaving channel never blocks the
  /// whole panel; the failure is logged via the LoggingService.
  ///
  /// No-op when there is no connected switch device. No-op (but logs a
  /// warning) when running against a non-Ffi backend, because there is
  /// no remote REST endpoint for per-channel switch reads yet.
  ///
  /// Errors at the top-level (e.g. `apiSwitchGetMax` throws) are
  /// surfaced through [ErrorService] and rethrown so an explicit refresh
  /// control can remain retryable instead of reporting a false success.
  Future<void> refreshChannels() async {
    final generation = ++_refreshGeneration;
    final notifier = _ref.read(switchStateProvider.notifier);
    final state = _ref.read(switchStateProvider);
    final deviceId = state.deviceId;
    if (deviceId == null || deviceId.isEmpty) return;
    if (state.connectionState != DeviceConnectionState.connected) return;
    if (!_stillOwnsRefresh(generation, deviceId)) return;

    final backend = _backend;
    if (backend is! FfiBackend && !switchBridgeBypassBackendCheck) {
      // Remote path: a tablet/desktop talking to the headless appliance reads
      // channels over REST (`GET /api/switch/status?deviceId=`) instead of the
      // FFI bridge. Without this branch the per-channel panel stays empty on a
      // remote client even though the rig has a switch device connected.
      if (backend is NetworkBackend) {
        await _refreshChannelsRemote(backend, deviceId, notifier, generation);
        return;
      }
      _safeLog(
        (logger) => logger.warning(
          'refreshSwitchChannels skipped: unsupported backend '
          '(device=$deviceId).',
          source: 'SwitchChannelService',
        ),
        'switch-refresh-unsupported-backend',
      );
      return;
    }

    try {
      // The capability snapshot is the only local API that distinguishes a
      // boolean relay from an analog/PWM channel and carries range, step,
      // description and writeability. Prefer it so the UI does not turn a dew
      // heater into a misleading on/off switch.
      try {
        final capabilities = await switchBridgeGetCapabilities(deviceId);
        if (!_stillOwnsRefresh(generation, deviceId)) return;
        final channels = capabilities.switches;
        notifier.setChannels(
          count: channels.length,
          names: [for (final channel in channels) channel.name],
          states: [
            for (final channel in channels)
              channel.isBoolean
                  ? channel.value > 0.5
                  : channel.value >
                        channel.minValue +
                            ((channel.maxValue - channel.minValue) / 2),
          ],
          descriptions: [for (final channel in channels) channel.description],
          isBoolean: [for (final channel in channels) channel.isBoolean],
          values: [for (final channel in channels) channel.value],
          minValues: [for (final channel in channels) channel.minValue],
          maxValues: [for (final channel in channels) channel.maxValue],
          steps: [for (final channel in channels) channel.step],
          canWrite: [for (final channel in channels) channel.canWrite],
          refreshedAt: DateTime.now(),
        );
        return;
      } catch (error) {
        if (!_stillOwnsRefresh(generation, deviceId)) return;
        // Some older drivers cannot produce a complete capabilities object.
        // Fall back to the boolean API so existing relay control remains
        // available, but log that the richer metadata was unavailable.
        _safeLog(
          (logger) => logger.warning(
            'Switch capability read failed for $deviceId; falling back to '
            'boolean channels: $error',
            source: 'SwitchChannelService',
          ),
          'switch-capabilities-fallback',
        );
      }

      final count = await switchBridgeGetMax(deviceId);
      if (!_stillOwnsRefresh(generation, deviceId)) return;
      final names = <String>[];
      final states = <bool>[];
      for (var i = 0; i < count; i++) {
        String name;
        try {
          name = await switchBridgeGetName(deviceId, i);
          if (!_stillOwnsRefresh(generation, deviceId)) return;
        } catch (e) {
          if (!_stillOwnsRefresh(generation, deviceId)) return;
          // Per-channel label fetch failed — fall back to a generated
          // label so the row still renders. The state below is the
          // load-bearing data; an opaque label is acceptable.
          _safeLog(
            (logger) => logger.warning(
              'Switch channel name fetch failed for $deviceId#$i: $e',
              source: 'SwitchChannelService',
            ),
            'switch-channel-name-fetch',
          );
          name = '';
        }
        bool on;
        try {
          on = await switchBridgeGetState(deviceId, i);
          if (!_stillOwnsRefresh(generation, deviceId)) return;
        } catch (e) {
          if (!_stillOwnsRefresh(generation, deviceId)) return;
          // Reading this channel failed — reuse the pre-refresh snapshot
          // rather than fabricating OFF for a channel that may be powered ON
          // (a dew heater or flat panel left on would otherwise render OFF and
          // invite the operator to toggle it the wrong way).
          _safeLog(
            (logger) => logger.warning(
              'Switch channel state fetch failed for $deviceId#$i: $e',
              source: 'SwitchChannelService',
            ),
            'switch-channel-state-fetch',
          );
          on = i < state.channelStates.length ? state.channelStates[i] : false;
        }
        names.add(name);
        states.add(on);
      }
      notifier.setChannels(
        count: count,
        names: names,
        states: states,
        descriptions: List.filled(count, ''),
        isBoolean: List.filled(count, true),
        values: [for (final on in states) on ? 1.0 : 0.0],
        minValues: List.filled(count, 0.0),
        maxValues: List.filled(count, 1.0),
        steps: List.filled(count, 1.0),
        canWrite: List.filled(count, true),
        refreshedAt: DateTime.now(),
      );
    } catch (e) {
      if (!_stillOwnsRefresh(generation, deviceId)) return;
      _safeLog(
        (logger) => logger.warning(
          'refreshSwitchChannels failed for $deviceId: $e',
          source: 'SwitchChannelService',
        ),
        'switch-refresh',
      );
      try {
        final errSvc = _ref.read(errorServiceProvider);
        errSvc.logDeviceError(
          operation: 'switch_refresh',
          message: 'Failed to refresh switch channels: $e',
          deviceType: 'Switch',
          deviceId: deviceId,
          severity: ErrorSeverity.warning,
        );
      } on Object catch (errSvcErr) {
        _safeLog(
          (logger) => logger.warning(
            'errorService emission for switch_refresh failed: $errSvcErr',
            source: 'SwitchChannelService',
          ),
          'switch-refresh-errsvc',
        );
      }
      rethrow;
    }
  }

  /// Remote (NetworkBackend) variant of [refreshChannels]: reads the
  /// single-device switch snapshot over REST and stores it on the provider.
  /// Mirrors the FFI path's error handling (log + ErrorService toast).
  Future<void> _refreshChannelsRemote(
    NetworkBackend backend,
    String deviceId,
    SwitchStateNotifier notifier,
    int generation,
  ) async {
    try {
      final status = await backend.getSwitchStatus(deviceId: deviceId);
      if (!_stillOwnsRefresh(generation, deviceId)) return;
      final raw = status['switches'];
      final switches = raw is List ? raw : const <dynamic>[];
      final names = <String>[];
      final states = <bool>[];
      final descriptions = <String>[];
      final isBoolean = <bool>[];
      final values = <double>[];
      final minValues = <double>[];
      final maxValues = <double>[];
      final steps = <double>[];
      final canWrite = <bool>[];
      for (final s in switches) {
        if (s is! Map) continue;
        final booleanChannel = s['type'] == 'boolean';
        final rawValue = s['value'];
        final value = rawValue is bool
            ? (rawValue ? 1.0 : 0.0)
            : (rawValue is num ? rawValue.toDouble() : 0.0);
        final min = booleanChannel
            ? 0.0
            : ((s['minValue'] as num?)?.toDouble() ?? 0.0);
        final max = booleanChannel
            ? 1.0
            : ((s['maxValue'] as num?)?.toDouble() ?? 1.0);
        names.add((s['name'] as String?) ?? '');
        descriptions.add((s['description'] as String?) ?? '');
        isBoolean.add(booleanChannel);
        values.add(value);
        minValues.add(min);
        maxValues.add(max);
        steps.add(
          booleanChannel ? 1.0 : ((s['step'] as num?)?.toDouble() ?? 0.0),
        );
        canWrite.add(s['canWrite'] != false);
        states.add(
          booleanChannel ? value > 0.5 : value > min + ((max - min) / 2),
        );
      }
      notifier.setChannels(
        count: names.length,
        names: names,
        states: states,
        descriptions: descriptions,
        isBoolean: isBoolean,
        values: values,
        minValues: minValues,
        maxValues: maxValues,
        steps: steps,
        canWrite: canWrite,
        refreshedAt: DateTime.now(),
      );
    } catch (e) {
      if (!_stillOwnsRefresh(generation, deviceId)) return;
      _safeLog(
        (logger) => logger.warning(
          'refreshSwitchChannels (remote) failed for $deviceId: $e',
          source: 'SwitchChannelService',
        ),
        'switch-refresh-remote',
      );
      _emitDeviceError(
        'switch_refresh',
        'Failed to refresh switch channels: $e',
        deviceId,
        ErrorSeverity.warning,
      );
      rethrow;
    }
  }

  /// Emit a device error through [ErrorService] without letting an
  /// error-service failure mask the originating device fault.
  void _emitDeviceError(
    String operation,
    String message,
    String deviceId,
    ErrorSeverity severity,
  ) {
    try {
      _ref
          .read(errorServiceProvider)
          .logDeviceError(
            operation: operation,
            message: message,
            deviceType: 'Switch',
            deviceId: deviceId,
            severity: severity,
          );
    } on Object catch (errSvcErr) {
      _safeLog(
        (logger) => logger.warning(
          'errorService emission for $operation failed: $errSvcErr',
          source: 'SwitchChannelService',
        ),
        'switch-errsvc',
      );
    }
  }

  /// Toggle a single switch channel on or off.
  ///
  /// Calls the bridge synchronously and only updates the cached state
  /// after the bridge confirms success — optimistic updates would lie
  /// to the user about hardware state when a relay fails to engage.
  ///
  /// Throws [DeviceNotConnectedException] when no switch is connected.
  /// Bridge errors are routed through [ErrorService] (toast + history)
  /// and then rethrown so callers can react (e.g. a UI that wants to
  /// revert a switch widget's visual state).
  ///
  /// Note: this method does NOT participate in `DeviceService._trackInFlight`
  /// accounting; the public `DeviceService.setSwitchChannel` delegator wraps
  /// it in the facade's quiesce-tracking helper.
  Future<void> setChannel(int channelIndex, bool on) async {
    final notifier = _ref.read(switchStateProvider.notifier);
    final state = _ref.read(switchStateProvider);
    final deviceId = state.deviceId;
    if (deviceId == null ||
        deviceId.isEmpty ||
        state.connectionState != DeviceConnectionState.connected) {
      throw const DeviceNotConnectedException('switch');
    }
    if (channelIndex < 0 || channelIndex >= state.channelCount) {
      throw ArgumentError.value(
        channelIndex,
        'channelIndex',
        'Out of range for channelCount=${state.channelCount}',
      );
    }
    if (channelIndex < state.channelCanWrite.length &&
        !state.channelCanWrite[channelIndex]) {
      throw UnsupportedError('Switch channel $channelIndex is read-only.');
    }
    if (channelIndex < state.channelIsBoolean.length &&
        !state.channelIsBoolean[channelIndex]) {
      throw UnsupportedError(
        'Switch channel $channelIndex is analog; use setChannelValue.',
      );
    }
    if (!_stillOwnsDevice(deviceId)) {
      throw StateError('The active switch connection changed.');
    }

    final backend = _backend;
    if (backend is! FfiBackend && !switchBridgeBypassBackendCheck) {
      // Remote path: write the channel over REST (`POST /api/switch/set`).
      if (backend is NetworkBackend) {
        try {
          await backend.setSwitch(
            deviceId: deviceId,
            switchId: channelIndex,
            value: on,
          );
          if (_stillOwnsDevice(deviceId)) {
            notifier.setChannelState(channelIndex, on);
          }
        } catch (e) {
          _safeLog(
            (logger) => logger.warning(
              'setSwitchChannel (remote) failed for $deviceId#$channelIndex '
              'on=$on: $e',
              source: 'SwitchChannelService',
            ),
            'switch-set-channel-remote',
          );
          _emitDeviceError(
            'switch_set_state',
            'Failed to set switch channel $channelIndex to '
                '${on ? "on" : "off"}: $e',
            deviceId,
            ErrorSeverity.error,
          );
          rethrow;
        }
        return;
      }
      throw UnsupportedError(
        'setSwitchChannel is not supported on the current backend.',
      );
    }

    try {
      await switchBridgeSetState(deviceId, channelIndex, on);
      if (_stillOwnsDevice(deviceId)) {
        notifier.setChannelState(channelIndex, on);
      }
    } catch (e) {
      _safeLog(
        (logger) => logger.warning(
          'setSwitchChannel failed for $deviceId#$channelIndex on=$on: $e',
          source: 'SwitchChannelService',
        ),
        'switch-set-channel',
      );
      try {
        final errSvc = _ref.read(errorServiceProvider);
        errSvc.logDeviceError(
          operation: 'switch_set_state',
          message:
              'Failed to set switch channel $channelIndex to '
              '${on ? "on" : "off"}: $e',
          deviceType: 'Switch',
          deviceId: deviceId,
          severity: ErrorSeverity.error,
        );
      } on Object catch (errSvcErr) {
        _safeLog(
          (logger) => logger.warning(
            'errorService emission for switch_set_state failed: '
            '$errSvcErr',
            source: 'SwitchChannelService',
          ),
          'switch-set-channel-errsvc',
        );
      }
      rethrow;
    }
  }

  /// Set an analog/PWM switch channel to a numeric value.
  ///
  /// Values are validated against the driver-advertised range before any
  /// hardware write. As with boolean channels, cached state changes only after
  /// the local bridge or remote host confirms success.
  Future<void> setChannelValue(int channelIndex, double value) async {
    final notifier = _ref.read(switchStateProvider.notifier);
    final state = _ref.read(switchStateProvider);
    final deviceId = state.deviceId;
    if (deviceId == null ||
        deviceId.isEmpty ||
        state.connectionState != DeviceConnectionState.connected) {
      throw const DeviceNotConnectedException('switch');
    }
    if (channelIndex < 0 || channelIndex >= state.channelCount) {
      throw ArgumentError.value(
        channelIndex,
        'channelIndex',
        'Out of range for channelCount=${state.channelCount}',
      );
    }
    if (!value.isFinite) {
      throw ArgumentError.value(value, 'value', 'Must be finite');
    }
    if (channelIndex < state.channelCanWrite.length &&
        !state.channelCanWrite[channelIndex]) {
      throw UnsupportedError('Switch channel $channelIndex is read-only.');
    }
    if (channelIndex < state.channelIsBoolean.length &&
        state.channelIsBoolean[channelIndex]) {
      throw UnsupportedError(
        'Switch channel $channelIndex is boolean; use setChannel.',
      );
    }
    final min = channelIndex < state.channelMinValues.length
        ? state.channelMinValues[channelIndex]
        : 0.0;
    final max = channelIndex < state.channelMaxValues.length
        ? state.channelMaxValues[channelIndex]
        : 1.0;
    if (value < min || value > max) {
      throw ArgumentError.value(
        value,
        'value',
        'Must be between $min and $max',
      );
    }
    if (!_stillOwnsDevice(deviceId)) {
      throw StateError('The active switch connection changed.');
    }

    final backend = _backend;
    try {
      if (backend is NetworkBackend && !switchBridgeBypassBackendCheck) {
        await backend.setSwitch(
          deviceId: deviceId,
          switchId: channelIndex,
          value: value,
        );
      } else if (backend is FfiBackend || switchBridgeBypassBackendCheck) {
        await switchBridgeSetValue(deviceId, channelIndex, value);
      } else {
        throw UnsupportedError(
          'setSwitchChannelValue is not supported on the current backend.',
        );
      }
      if (_stillOwnsDevice(deviceId)) {
        notifier.setChannelValue(channelIndex, value);
      }
    } catch (error) {
      _safeLog(
        (logger) => logger.warning(
          'setSwitchChannelValue failed for $deviceId#$channelIndex '
          'value=$value: $error',
          source: 'SwitchChannelService',
        ),
        'switch-set-channel-value',
      );
      _emitDeviceError(
        'switch_set_value',
        'Failed to set switch channel $channelIndex to $value: $error',
        deviceId,
        ErrorSeverity.error,
      );
      rethrow;
    }
  }

  /// Mirror of `DeviceService._safeLog` — emits a diagnostic line through
  /// the logging service, but never lets a logger-emission failure mask
  /// a higher-priority device fault. We deliberately catch every kind of
  /// error from the logger lookup (e.g. provider mid-disposal during
  /// shutdown) and demote to a stderr line — fail-closed for the calling
  /// device operation, soft for the diagnostics emission itself.
  void _safeLog(void Function(LoggingService logger) emit, String contextTag) {
    try {
      final logger = _ref.read(loggingServiceProvider);
      emit(logger);
    } on Object catch (loggerErr) {
      // ignore: avoid_print
      print(
        'SwitchChannelService[$contextTag]: logger emission failed: $loggerErr',
      );
    }
  }
}
