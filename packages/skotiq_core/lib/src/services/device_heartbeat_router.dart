import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/device_heartbeat_health_provider.dart';
import '../providers/logging_service_provider.dart';

/// Routes native heartbeat events to [deviceHeartbeatHealthProvider].
///
/// The native device manager starts a device's heartbeat when it connects,
/// at the per-type policy (`bridge/src/device_manager/policy.rs`), and stops
/// it when it disconnects; nothing here starts or stops one.
///
/// Every dispatch is wrapped in a fail-soft try/catch: the heartbeat
/// indicator is strictly cosmetic relative to the connection and error
/// events that share the same EventBus, and a mid-disposal provider read
/// must not propagate up the device-event router.
class DeviceHeartbeatRouter {
  DeviceHeartbeatRouter({required Ref ref}) : _ref = ref;

  final Ref _ref;

  /// `last_rtt_ms` arrives as a `BigInt` over FRB. Squeeze it down to a
  /// Dart `int` for the heartbeat provider, which only cares about
  /// display. Returns null when the input is null or not coercible.
  static int? coerceIntFromBigInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is BigInt) {
      // Anything above 2^31 is meaningless for a millisecond RTT
      // display tooltip. `isValidInt` guards the (theoretical) JS-int
      // overflow; on native Dart ints are 64-bit so this is a no-op.
      return value.isValidInt ? value.toInt() : null;
    }
    if (value is num) return value.toInt();
    return null;
  }

  /// Apply a `HeartbeatStarted` event to the provider.
  void onHeartbeatStarted(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) return;
    _safeApply(
      contextTag: 'heartbeat-started',
      apply: (notifier) => notifier.applyHeartbeatStarted(deviceId: deviceId),
    );
  }

  /// Apply a `HeartbeatStatusChanged` event to the provider.
  void onStatusChanged({
    required String? deviceId,
    required String? status,
    required int? consecutiveFailures,
    required int? lastRttMs,
  }) {
    if (deviceId == null || deviceId.isEmpty) return;
    if (status == null || status.isEmpty) {
      logSafely(
        _ref,
        (l) => l.warning(
          'HeartbeatStatusChanged for $deviceId missing status field; '
          'dropping. Payload may be malformed.',
        ),
      );
      return;
    }
    _safeApply(
      contextTag: 'heartbeat-status',
      apply: (notifier) => notifier.applyStatusEvent(
        deviceId: deviceId,
        status: status,
        consecutiveFailures: consecutiveFailures ?? 0,
        lastRttMs: lastRttMs,
      ),
    );
  }

  /// Apply a `HeartbeatReconnecting` event to the provider.
  void onReconnecting({
    required String? deviceId,
    required int? attempt,
    required int? maxAttempts,
  }) {
    if (deviceId == null || deviceId.isEmpty) return;
    _safeApply(
      contextTag: 'heartbeat-reconnecting',
      apply: (notifier) => notifier.applyReconnecting(
        deviceId: deviceId,
        attempt: attempt ?? 0,
        maxAttempts: maxAttempts ?? 0,
      ),
    );
  }

  /// Apply a `HeartbeatReconnected` event to the provider.
  void onReconnected({required String? deviceId, required int? afterAttempts}) {
    if (deviceId == null || deviceId.isEmpty) return;
    _safeApply(
      contextTag: 'heartbeat-reconnected',
      apply: (notifier) => notifier.applyReconnected(
        deviceId: deviceId,
        afterAttempts: afterAttempts ?? 0,
      ),
    );
  }

  /// Show [deviceId] as reconnecting while the native reconnection loop
  /// works on it. The native side defines `HeartbeatReconnecting` but never
  /// publishes it, so the app lights the indicator from the
  /// heartbeat-loss disconnect it does see. No attempt count is known, so the
  /// tooltip shows none.
  void surfaceReconnecting({required String deviceId}) {
    if (deviceId.isEmpty) return;
    _safeApply(
      contextTag: 'heartbeat-surface-reconnecting',
      apply: (notifier) => notifier.applyReconnecting(
        deviceId: deviceId,
        attempt: 0,
        maxAttempts: 0,
      ),
    );
  }

  /// Clear the heartbeat-health entry for [deviceId] so its per-card
  /// indicator falls back to the gray "unknown" baseline. Called from
  /// `HeartbeatStopped` and from the Disconnected event handler.
  void clearDevice(String deviceId) {
    if (deviceId.isEmpty) return;
    try {
      _ref.read(deviceHeartbeatHealthProvider.notifier).clearDevice(deviceId);
    } on Object catch (e) {
      logSafely(
        _ref,
        (l) => l.warning('Heartbeat provider clear failed for $deviceId: $e'),
      );
    }
  }

  void _safeApply({
    required String contextTag,
    required void Function(DeviceHeartbeatHealthNotifier notifier) apply,
  }) {
    try {
      final notifier = _ref.read(deviceHeartbeatHealthProvider.notifier);
      apply(notifier);
    } on Object catch (e) {
      logSafely(
        _ref,
        (l) =>
            l.warning('Heartbeat provider dispatch failed ($contextTag): $e'),
      );
    }
  }
}
