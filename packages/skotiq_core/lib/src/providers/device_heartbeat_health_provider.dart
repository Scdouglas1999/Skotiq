/// Per-device heartbeat health state.
///
/// Rust's heartbeat monitor publishes [HeartbeatStatusChanged] events for
/// every device that has `apiStartDeviceHeartbeat` running. This provider
/// stores the latest reported health per device id so the equipment cards can
/// render a colored indicator (green / amber / gray) with a tooltip carrying
/// the actual failure reason.
///
/// The state is deliberately *separate* from the `*StateProvider` connection
/// state: heartbeat reports a richer signal (degraded != disconnected), and
/// the heartbeat dispatch path must not step on the established disconnect /
/// error handlers. The connection-state notifiers own
/// connecting/connected/disconnected/error; this provider only surfaces the
/// health gradient on top.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Heartbeat health classification for a single device.
enum HeartbeatHealth {
  /// No heartbeat data has been seen for this device yet (or the
  /// device disconnected and the entry was cleared).
  unknown,

  /// The Rust heartbeat monitor is reporting healthy: latest poll
  /// succeeded, consecutive failure counter is below the threshold.
  healthy,

  /// One or more polls have failed but the device has not yet crossed
  /// the disconnect threshold. The card should pulse amber and surface
  /// the reason on hover.
  degraded,

  /// The Rust heartbeat monitor is actively re-establishing the
  /// connection (mirrors `HeartbeatReconnecting`). Distinct from
  /// `degraded` so the card copy can read "Reconnecting…" rather than
  /// "Degraded".
  reconnecting,
}

/// Immutable snapshot of a single device's heartbeat health.
class DeviceHeartbeatHealthState {
  /// The current health classification.
  final HeartbeatHealth health;

  /// Human-readable reason for non-healthy states. Populated from the
  /// heartbeat event payload (consecutive failures, reconnect attempt
  /// counter, etc.). Always non-null for non-healthy states; nullable
  /// for `healthy` and `unknown` because there's nothing to report.
  final String? reason;

  /// Wall-clock timestamp of the last state transition. Used by the
  /// card widget to trigger the pulse animation when this value
  /// changes between rebuilds.
  final DateTime lastChange;

  /// Most recent device-reported round-trip-time in milliseconds, if
  /// the heartbeat event carried one. Useful diagnostic on the
  /// tooltip; not required.
  final int? lastRttMs;

  /// Consecutive heartbeat failure count from the latest event.
  /// Zero for `healthy`. Always defined so callers don't have to do
  /// null-checks when building the tooltip.
  final int consecutiveFailures;

  const DeviceHeartbeatHealthState({
    required this.health,
    required this.lastChange,
    this.reason,
    this.lastRttMs,
    this.consecutiveFailures = 0,
  });

  /// Convenience: known-empty state. Used as the default when a card
  /// asks for a device that hasn't reported in.
  factory DeviceHeartbeatHealthState.unknown() => DeviceHeartbeatHealthState(
    health: HeartbeatHealth.unknown,
    lastChange: DateTime.fromMillisecondsSinceEpoch(0),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceHeartbeatHealthState &&
          runtimeType == other.runtimeType &&
          health == other.health &&
          reason == other.reason &&
          lastChange == other.lastChange &&
          lastRttMs == other.lastRttMs &&
          consecutiveFailures == other.consecutiveFailures;

  @override
  int get hashCode =>
      health.hashCode ^
      reason.hashCode ^
      lastChange.hashCode ^
      lastRttMs.hashCode ^
      consecutiveFailures.hashCode;
}

/// StateNotifier holding heartbeat health for every device id we have
/// seen an event for.
///
/// Keys are device ids (the same opaque strings Rust uses — e.g.
/// `native:zwo:0`, `ascom:ASCOM.iOptronZEQ25.Telescope`); values are
/// the latest [DeviceHeartbeatHealthState]. Devices that have not
/// reported simply don't appear in the map; consumers should call
/// [DeviceHeartbeatHealthNotifier.forDevice] which falls back to
/// `unknown` for missing entries so the UI renders a stable gray dot.
class DeviceHeartbeatHealthNotifier
    extends StateNotifier<Map<String, DeviceHeartbeatHealthState>> {
  /// Optional clock so unit tests can pin `lastChange` deterministically.
  /// In production this defaults to `DateTime.now`.
  final DateTime Function() _now;

  DeviceHeartbeatHealthNotifier({DateTime Function()? now})
    : _now = now ?? DateTime.now,
      super(const <String, DeviceHeartbeatHealthState>{});

  /// Lookup helper. Returns a stable `unknown` state when the device
  /// id is missing so the UI never has to handle null.
  DeviceHeartbeatHealthState forDevice(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) {
      return DeviceHeartbeatHealthState.unknown();
    }
    return state[deviceId] ?? DeviceHeartbeatHealthState.unknown();
  }

  /// Apply a fresh heartbeat status event for [deviceId]. The status
  /// string is the snake_case name of the Rust `HeartbeatStatus` enum
  /// (`healthy`, `degraded`, `disconnected`, `reconnecting`,
  /// `reconnected`) — see `bridge::event::HeartbeatStatus`. Unknown
  /// strings are mapped to `unknown` rather than thrown so a future
  /// Rust addition cannot crash the card; the diagnostics path is
  /// elsewhere.
  void applyStatusEvent({
    required String deviceId,
    required String status,
    int consecutiveFailures = 0,
    int? lastRttMs,
  }) {
    if (deviceId.isEmpty) return;
    final (health, reason) = _mapStatus(
      status: status,
      consecutiveFailures: consecutiveFailures,
      lastRttMs: lastRttMs,
    );
    _update(
      deviceId: deviceId,
      health: health,
      reason: reason,
      consecutiveFailures: consecutiveFailures,
      lastRttMs: lastRttMs,
    );
  }

  /// Apply a `HeartbeatReconnecting` event. We distinguish this from
  /// `degraded` because the card copy reads differently to the user.
  void applyReconnecting({
    required String deviceId,
    required int attempt,
    required int maxAttempts,
  }) {
    if (deviceId.isEmpty) return;
    final reason = maxAttempts > 0
        ? 'Reconnecting (attempt $attempt of $maxAttempts)'
        : 'Reconnecting (attempt $attempt)';
    _update(
      deviceId: deviceId,
      health: HeartbeatHealth.reconnecting,
      reason: reason,
      // Reconnect attempts imply the consecutive-failure counter has
      // already hit the threshold, so surface that to the tooltip via
      // attempt count rather than failure count.
      consecutiveFailures: 0,
    );
  }

  /// Apply a `HeartbeatReconnected` event. The device is healthy again
  /// after [afterAttempts] tries — we surface that on the tooltip for
  /// one transition so the user knows recovery happened.
  void applyReconnected({
    required String deviceId,
    required int afterAttempts,
  }) {
    if (deviceId.isEmpty) return;
    _update(
      deviceId: deviceId,
      health: HeartbeatHealth.healthy,
      reason: afterAttempts > 0
          ? 'Recovered after $afterAttempts attempt${afterAttempts == 1 ? '' : 's'}'
          : null,
      consecutiveFailures: 0,
    );
  }

  /// Apply a `HeartbeatStarted` event — register the device with a
  /// healthy entry so the indicator turns green as soon as monitoring
  /// begins (rather than waiting for the first periodic event).
  void applyHeartbeatStarted({required String deviceId}) {
    if (deviceId.isEmpty) return;
    _update(
      deviceId: deviceId,
      health: HeartbeatHealth.healthy,
      reason: null,
      consecutiveFailures: 0,
    );
  }

  /// Clear the entry for [deviceId]. Called from the device service
  /// when the device emits a `Disconnected` event so the
  /// indicator returns to gray "unknown" rather than getting stuck on
  /// the last-known health value.
  void clearDevice(String deviceId) {
    if (deviceId.isEmpty) return;
    if (!state.containsKey(deviceId)) return;
    final next = Map<String, DeviceHeartbeatHealthState>.from(state)
      ..remove(deviceId);
    state = next;
  }

  /// Reset every entry. Used by tests and by the backend swap path
  /// (e.g. when toggling between FFI and Network backends).
  void clearAll() {
    if (state.isEmpty) return;
    state = const <String, DeviceHeartbeatHealthState>{};
  }

  void _update({
    required String deviceId,
    required HeartbeatHealth health,
    required String? reason,
    required int consecutiveFailures,
    int? lastRttMs,
  }) {
    final existing = state[deviceId];
    // Preserve lastChange when the meaningful fields are unchanged so
    // the widget doesn't pulse on every redundant healthy event.
    final isChanged =
        existing == null ||
        existing.health != health ||
        existing.reason != reason ||
        existing.consecutiveFailures != consecutiveFailures ||
        existing.lastRttMs != lastRttMs;
    if (!isChanged) return;

    final next = Map<String, DeviceHeartbeatHealthState>.from(state);
    next[deviceId] = DeviceHeartbeatHealthState(
      health: health,
      reason: reason,
      lastChange: _now(),
      consecutiveFailures: consecutiveFailures,
      lastRttMs: lastRttMs,
    );
    state = next;
  }

  (HeartbeatHealth, String?) _mapStatus({
    required String status,
    required int consecutiveFailures,
    int? lastRttMs,
  }) {
    switch (status.toLowerCase()) {
      case 'healthy':
        return (HeartbeatHealth.healthy, null);
      case 'degraded':
        final buf = StringBuffer();
        if (consecutiveFailures > 0) {
          buf.write(
            '$consecutiveFailures consecutive heartbeat '
            'failure${consecutiveFailures == 1 ? '' : 's'}',
          );
        } else {
          buf.write('Heartbeat degraded');
        }
        if (lastRttMs != null) {
          buf.write(' (last RTT ${lastRttMs}ms)');
        }
        return (HeartbeatHealth.degraded, buf.toString());
      case 'disconnected':
        // The Rust monitor marks the device disconnected after the failure
        // threshold is crossed. The heartbeat-lost path emits no standalone
        // equipment `Disconnected` event, which would raise a second
        // disconnect toast; DeviceService's `HeartbeatStatusChanged` handler
        // routes the `disconnected` status through `_handleDeviceDisconnected`,
        // which calls `clearDevice` to drop this entry back to gray "unknown".
        // The transient degraded state is still recorded here so a listener
        // that observes this status event before the clear runs sees a
        // sensible value.
        return (
          HeartbeatHealth.degraded,
          consecutiveFailures > 0
              ? 'Device unresponsive after $consecutiveFailures failure${consecutiveFailures == 1 ? '' : 's'}'
              : 'Device unresponsive',
        );
      case 'reconnecting':
        return (HeartbeatHealth.reconnecting, 'Heartbeat reconnecting');
      case 'reconnected':
        return (HeartbeatHealth.healthy, null);
      default:
        // Unknown status string — surface the raw value on the tooltip
        // so a future Rust enum addition still tells the user something
        // useful rather than silently swallowing it.
        return (HeartbeatHealth.degraded, 'Unknown heartbeat status "$status"');
    }
  }
}

/// Riverpod provider for the per-device heartbeat health map.
///
/// Watch this provider directly and call [DeviceHeartbeatHealthNotifier.forDevice]
/// with a device id to retrieve a single device's state; consumers that
/// only care about a specific device should use a `select` to avoid
/// rebuilding on unrelated changes.
final deviceHeartbeatHealthProvider =
    StateNotifierProvider<
      DeviceHeartbeatHealthNotifier,
      Map<String, DeviceHeartbeatHealthState>
    >((ref) => DeviceHeartbeatHealthNotifier());
