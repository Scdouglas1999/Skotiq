// Whether the values a connected device's slot shows are still being read.
//
// On the reference rig (Nov 8 2026) the mount and camera dropped and every
// read failed, yet Tonight kept showing "Mount · tracking · pier E · alt 2.5°"
// as if it were current. The pollers logged each failure and kept the last
// values; nothing marked them. This records, per device slot, when a read last
// succeeded and whether reads are failing now, so every surface that shows a
// device's values can say how old they are and why.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../errors/error_text.dart';
import '../../models/backend/device_types.dart';
import '../device_heartbeat_health_provider.dart';

/// Failed reads in a row after which a slot's values count as stale.
const int kStaleAfterFailedReads = 2;

/// How one device slot's reads are going.
class DeviceReadHealth {
  /// The device the readings belong to.
  final String deviceId;

  /// When a read last succeeded.
  final DateTime? lastReadAt;

  /// Failed reads since the last success.
  final int failures;

  /// The last read's error, while reads are failing.
  final String? lastError;

  const DeviceReadHealth({
    required this.deviceId,
    this.lastReadAt,
    this.failures = 0,
    this.lastError,
  });

  @override
  bool operator ==(Object other) =>
      other is DeviceReadHealth &&
      other.deviceId == deviceId &&
      other.lastReadAt == lastReadAt &&
      other.failures == failures &&
      other.lastError == lastError;

  @override
  int get hashCode => Object.hash(deviceId, lastReadAt, failures, lastError);
}

class DeviceReadHealthNotifier
    extends StateNotifier<Map<DeviceType, DeviceReadHealth>> {
  DeviceReadHealthNotifier({DateTime Function()? now})
    : _now = now ?? DateTime.now,
      super(const {});

  final DateTime Function() _now;

  /// A read of [deviceId] in the [type] slot succeeded.
  void recordSuccess(DeviceType type, String deviceId) {
    state = {
      ...state,
      type: DeviceReadHealth(deviceId: deviceId, lastReadAt: _now()),
    };
  }

  /// A read of [deviceId] in the [type] slot failed with [error].
  void recordFailure(DeviceType type, String deviceId, Object error) {
    final previous = state[type];
    final sameDevice = previous != null && previous.deviceId == deviceId;
    state = {
      ...state,
      type: DeviceReadHealth(
        deviceId: deviceId,
        lastReadAt: sameDevice ? previous.lastReadAt : null,
        failures: (sameDevice ? previous.failures : 0) + 1,
        lastError: readErrorText(error),
      ),
    };
  }

  /// Forget the [type] slot (its device disconnected).
  void clear(DeviceType type) {
    if (!state.containsKey(type)) return;
    state = {...state}..remove(type);
  }
}

/// A read error as one line for the operator: the driver's own sentence,
/// without the exception wrappers it arrives in.
String readErrorText(Object error) =>
    userFacingError(error).split('\n').first.trim();

final deviceReadHealthProvider =
    StateNotifierProvider<
      DeviceReadHealthNotifier,
      Map<DeviceType, DeviceReadHealth>
    >((ref) => DeviceReadHealthNotifier());

/// Why a connected device's shown values are not current, and since when.
class StaleReadings {
  /// When the values shown were last read; null when no read of this
  /// connection has succeeded.
  final DateTime? since;

  /// The driver's reason, or the heartbeat's.
  final String? reason;

  const StaleReadings({this.since, this.reason});

  /// The age of the values at [now], or null when unknown.
  Duration? ageAt(DateTime now) => since == null ? null : now.difference(since!);
}

/// Whether the values the [type] slot shows for [deviceId] are stale: its
/// reads are failing, or its heartbeat reports it degraded or reconnecting.
/// Null when they are current or nothing is known.
StaleReadings? staleReadingsFor(
  Map<DeviceType, DeviceReadHealth> reads,
  Map<String, DeviceHeartbeatHealthState> heartbeats,
  DeviceType type,
  String? deviceId,
) {
  if (deviceId == null || deviceId.isEmpty) return null;
  final read = reads[type];
  if (read != null &&
      read.deviceId == deviceId &&
      read.failures >= kStaleAfterFailedReads) {
    return StaleReadings(since: read.lastReadAt, reason: read.lastError);
  }
  final heartbeat = heartbeats[deviceId];
  if (heartbeat != null &&
      (heartbeat.health == HeartbeatHealth.degraded ||
          heartbeat.health == HeartbeatHealth.reconnecting)) {
    final lastRead = read != null && read.deviceId == deviceId
        ? read.lastReadAt
        : null;
    return StaleReadings(
      since: lastRead ?? heartbeat.lastChange,
      reason: heartbeat.reason,
    );
  }
  return null;
}

/// [staleReadingsFor] for the [type] slot's device, watched.
final staleReadingsProvider =
    Provider.family<StaleReadings?, (DeviceType, String?)>((ref, key) {
      return staleReadingsFor(
        ref.watch(deviceReadHealthProvider),
        ref.watch(deviceHeartbeatHealthProvider),
        key.$1,
        key.$2,
      );
    });

/// Ticks every 15 s so an age shown beside stale values keeps counting
/// while nothing else changes.
final staleAgeTickerProvider = StreamProvider.autoDispose<int>((ref) {
  return Stream<int>.periodic(const Duration(seconds: 15), (i) => i);
});

/// "45 s", "3 min", "2 h 10 min": how old stale values are.
String staleAgeText(Duration age) {
  if (age.isNegative) return '0 s';
  if (age.inSeconds < 60) return '${age.inSeconds} s';
  if (age.inMinutes < 60) return '${age.inMinutes} min';
  final minutes = age.inMinutes % 60;
  return minutes == 0
      ? '${age.inHours} h'
      : '${age.inHours} h $minutes min';
}
