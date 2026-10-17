import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Per-device heartbeat-health dot.
///
/// Rendered inline in the device-card header (and reusable anywhere a
/// caller has a device id and wants the same visual). Subscribes to
/// [deviceHeartbeatHealthProvider] using a `select` keyed by
/// [deviceId] so it only rebuilds when *this* device's state changes.
/// Three colors:
///   * Green: heartbeat is healthy (or the device just recovered).
///   * Amber: heartbeat reported degraded / reconnecting — tooltip
///            carries the actual reason.
///   * Gray:  no heartbeat data for this device (e.g. heartbeat was
///            never started, or the device just disconnected and the
///            entry was cleared).
///
/// On every state change the dot briefly pulses (scale 1.4 → 1.0 over
/// 700ms via `TweenAnimationBuilder`) so the user's eye is drawn to
/// it. The pulse is keyed by the `lastChange` timestamp so rebuilds
/// without an actual state change don't replay the animation.
class HeartbeatHealthIndicator extends ConsumerWidget {
  /// Device id this indicator represents. Pulled from the matching
  /// `*StateProvider`'s `deviceId` field by the owning card.
  final String deviceId;

  /// Skotiq theme colors. Passed in (rather than read off the
  /// `Theme.of(context)`) so callers inside an already-resolved
  /// `SkotiqColors` scope can share a single instance.
  final SkotiqColors colors;

  const HeartbeatHealthIndicator({
    super.key,
    required this.deviceId,
    required this.colors,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Use `select` so we only rebuild when *this device's* entry
    // changes. The provider holds a map keyed by device id so any
    // other device updating would otherwise rebuild every dot in the
    // equipment tab.
    final state = ref.watch(
      deviceHeartbeatHealthProvider.select(
        (map) => map[deviceId] ?? DeviceHeartbeatHealthState.unknown(),
      ),
    );

    final (color, label) = _styleFor(state.health);
    final tooltip = _buildTooltip(state, label);

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 250),
      child: TweenAnimationBuilder<double>(
        // Keyed by lastChange so each transition replays the
        // animation from scratch even when the next state lands on the
        // same color. Without the key Flutter would otherwise reuse
        // the running tween's end value and skip the pulse.
        key: ValueKey(state.lastChange),
        tween: Tween<double>(begin: 1.4, end: 1.0),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOut,
        builder: (context, scale, child) {
          return Transform.scale(scale: scale, child: child);
        },
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: state.health == HeartbeatHealth.unknown
                ? null
                : [
                    BoxShadow(
                      color: color.withValues(alpha: 0.45),
                      blurRadius: 4,
                      spreadRadius: 0.5,
                    ),
                  ],
          ),
        ),
      ),
    );
  }

  (Color, String) _styleFor(HeartbeatHealth health) {
    switch (health) {
      case HeartbeatHealth.healthy:
        return (colors.success, 'Healthy');
      case HeartbeatHealth.degraded:
        return (colors.warning, 'Degraded');
      case HeartbeatHealth.reconnecting:
        return (colors.warning, 'Reconnecting');
      case HeartbeatHealth.unknown:
        return (colors.textMuted, 'No heartbeat data');
    }
  }

  String _buildTooltip(DeviceHeartbeatHealthState state, String label) {
    // Surface the actual reason verbatim — never replace it
    // with a generic "something went wrong" string.
    final buf = StringBuffer('Heartbeat: $label');
    if (state.reason != null && state.reason!.isNotEmpty) {
      buf.write('\n${state.reason}');
    }
    if (state.lastRttMs != null) {
      buf.write('\nLast RTT: ${state.lastRttMs}ms');
    }
    return buf.toString();
  }
}
