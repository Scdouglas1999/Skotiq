import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/skotiq_backend.dart';
import '../providers/device_heartbeat_health_provider.dart';
import 'logging_service.dart';

/// Routes native heartbeat events to [deviceHeartbeatHealthProvider]
/// and owns the per-device start/stop helpers DeviceService uses from
/// its connect/disconnect flows.
///
/// Pulled out of `DeviceService` so the heartbeat concern lives in one
/// file. Every dispatch is wrapped in a fail-soft try/catch: the
/// heartbeat indicator is strictly cosmetic relative to the connection
/// and error events that share the same EventBus, and a mid-disposal
/// provider read must not propagate up the device-event router.
class DeviceHeartbeatRouter {
  DeviceHeartbeatRouter({required Ref ref, required SkotiqBackend backend})
    : _ref = ref,
      _backend = backend;

  final Ref _ref;
  final SkotiqBackend _backend;

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

  /// Begin native heartbeat monitoring for [deviceType]/[deviceId] at
  /// [intervalMs]. Logs success at INFO and failure at WARNING — never
  /// throws. Heartbeat is an optional safety net; a failure here must
  /// not abort the connect flow that called it.
  Future<void> start({
    required DeviceType deviceType,
    required String deviceId,
    required int intervalMs,
  }) async {
    try {
      await _backend.startDeviceHeartbeat(
        deviceType: deviceType,
        deviceId: deviceId,
        intervalMs: intervalMs,
      );
      _log(
        (l) => l.info(
          'Started heartbeat monitoring for ${_label(deviceType)} '
          '($deviceId) with ${(intervalMs / 1000).toStringAsFixed(0)}s '
          'interval',
        ),
      );
    } catch (e) {
      _log(
        (l) => l.warning(
          'Failed to start heartbeat monitoring for ${_label(deviceType)} '
          '($deviceId): $e. Device will remain connected but automatic '
          'reconnection may not work if connection is lost.',
        ),
      );
    }
  }

  /// Stop native heartbeat monitoring for [deviceId]. Logs at INFO on
  /// success, WARNING on failure — never throws. Called from disconnect
  /// paths where the original disconnect MUST proceed even if the
  /// matching stop call fails (e.g. driver already gone).
  Future<void> stop({
    required DeviceType deviceType,
    required String deviceId,
  }) async {
    try {
      await _backend.stopDeviceHeartbeat(deviceId);
      _log(
        (l) => l.info(
          'Stopped heartbeat monitoring for ${_label(deviceType)} '
          '($deviceId)',
        ),
      );
    } catch (e) {
      _log(
        (l) => l.warning(
          'Error stopping heartbeat monitoring for ${_label(deviceType)} '
          '($deviceId): $e',
        ),
      );
    }
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
      _log(
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

  /// Surface a Dart-driven "reconnecting" health state for [deviceId].
  ///
  /// Why this exists (DEV-P1 reconnect-UI gap): the native heartbeat
  /// monitor defines `HeartbeatReconnecting` / `HeartbeatReconnected`
  /// events but never emits them (bridge `event.rs` ~220-226). So the
  /// `reconnecting` indicator was permanently dead during real
  /// reconnects — whether the native `reconnection_loop` or the Dart
  /// [DeviceReconnectCoordinator] is doing the reconnecting. This method
  /// lets the Dart side drive the indicator from the signals it DOES
  /// receive (a heartbeat-loss disconnect followed by a reconnect
  /// attempt owned by one of the two engines), so the card reads
  /// "Reconnecting…" instead of falling back to gray "unknown".
  ///
  /// [attempt]/[maxAttempts] are surfaced on the tooltip when known.
  /// `maxAttempts == 0` means "unknown / open-ended" (the native loop
  /// retries with no Dart-visible cap), which renders without the
  /// "of N" suffix.
  void surfaceReconnecting({
    required String deviceId,
    int attempt = 0,
    int maxAttempts = 0,
  }) {
    if (deviceId.isEmpty) return;
    _safeApply(
      contextTag: 'heartbeat-surface-reconnecting',
      apply: (notifier) => notifier.applyReconnecting(
        deviceId: deviceId,
        attempt: attempt,
        maxAttempts: maxAttempts,
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
      _log(
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
      _log(
        (l) =>
            l.warning('Heartbeat provider dispatch failed ($contextTag): $e'),
      );
    }
  }

  void _log(void Function(LoggingService logger) emit) {
    try {
      final logger = _ref.read(loggingServiceProvider);
      emit(logger);
    } on Object {
      // Diagnostic-only failure during logger lookup; swallow so the
      // heartbeat path stays fail-soft.
    }
  }

  String _label(DeviceType type) {
    switch (type) {
      case DeviceType.camera:
        return 'Camera';
      case DeviceType.mount:
        return 'Mount';
      case DeviceType.focuser:
        return 'Focuser';
      case DeviceType.filterWheel:
        return 'Filter Wheel';
      case DeviceType.guider:
        return 'Guider';
      case DeviceType.rotator:
        return 'Rotator';
      case DeviceType.dome:
        return 'Dome';
      case DeviceType.weather:
        return 'Weather';
      case DeviceType.safetyMonitor:
        return 'Safety Monitor';
      case DeviceType.switch_:
        return 'Switch';
      case DeviceType.coverCalibrator:
        return 'Cover Calibrator';
    }
  }
}
