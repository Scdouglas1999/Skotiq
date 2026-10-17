// USB / device disconnect log.
//
// Captures every device disconnect (or transient device-error severity
// event) emitted on the backend event stream with a wall-clock timestamp,
// then prunes anything older than 24 hours. The pre-flight USB-stability
// rule and the post-session diagnostics summary read from this log to
// answer "did this device flake out recently?".
//
// Storage is in-memory only by design:
//   * The 24 h sliding window is short enough that an app restart on a
//     normal imaging cadence (one session per night) loses at most a
//     night of history — and the pre-flight rule's user-visible action
//     ("warn me about flaky USB") only cares about disconnects in the
//     current run anyway.
//   * Persisting through Drift would mean a new table, a schema bump,
//     and migration code for a metric that's already cheap to recompute
// from in-memory state. flags over-engineering as a
//     failure mode; matching the codebase's existing
//     `recoveryHistoryProvider` pattern (also in-memory per-run) is the
//     simpler shape.
//   * If a user files a "my disconnect history is missing across
//     restarts" issue we can add SQL persistence later — the public API
//     surface stays the same.
//
// Pruning runs on every read AND on a 5-minute periodic timer so a
// long-running session that never reads the count doesn't accumulate
// unbounded entries (the timer is owned by the Riverpod provider, not
// the service, so unit tests can construct a service without a clock
// background task).

/// A single recorded disconnect / device-error event.
///
/// `reason` is optional because not every backend event carries a
/// human-readable explanation (e.g. an INDI driver crash surfaces as a
/// bare `Disconnected` with no message). The post-session summary still
/// counts these — the absence of a reason is itself useful information.
class UsbDisconnectEntry {
  final String deviceId;
  final String? deviceType;
  final DateTime timestamp;
  final String? reason;

  const UsbDisconnectEntry({
    required this.deviceId,
    required this.timestamp,
    this.deviceType,
    this.reason,
  });

  @override
  String toString() =>
      'UsbDisconnectEntry($deviceId, ${timestamp.toIso8601String()}, '
      'type=$deviceType, reason=$reason)';

  @override
  bool operator ==(Object other) {
    return other is UsbDisconnectEntry &&
        other.deviceId == deviceId &&
        other.timestamp == timestamp &&
        other.deviceType == deviceType &&
        other.reason == reason;
  }

  @override
  int get hashCode => Object.hash(deviceId, timestamp, deviceType, reason);
}

/// The 24-hour rolling window backing
/// [DeviceHealthSnapshot.disconnectCountLast24h].
///
/// All public methods accept an optional `now` parameter so tests can
/// inject deterministic timestamps without monkey-patching
/// `DateTime.now`.
class UsbDisconnectLog {
  /// Maximum window age. Disconnects older than this are pruned.
  static const Duration windowDuration = Duration(hours: 24);

  /// Hard cap on retained entries. Even a degenerate flapping device
  /// (one disconnect per second for 24 h) caps at 86 400 entries which
  /// is fine, but we cap defensively to keep the structure bounded if
  /// the clock jumps backward or the same event is replayed.
  final int maxEntries;

  final List<UsbDisconnectEntry> _entries = <UsbDisconnectEntry>[];

  /// Clock injection point. Tests pass a fixed `() => fakeTime`; the
  /// production wiring leaves it at [DateTime.now].
  final DateTime Function() _now;

  UsbDisconnectLog({DateTime Function()? now, this.maxEntries = 100000})
    : _now = now ?? DateTime.now;

  /// Record a disconnect.
  ///
  /// The `timestamp` argument is optional — passing it lets the bridge
  /// provider stamp the event with the backend's wall-clock when the
  /// raw event carried one (so cross-platform NTP-corrected timestamps
  /// survive into the log). When omitted we sample the clock here.
  void recordDisconnect({
    required String deviceId,
    String? deviceType,
    String? reason,
    DateTime? timestamp,
  }) {
    if (deviceId.isEmpty) {
      // Empty deviceId means the event carried no device identifier —
      // count it under a synthetic key so the total still reflects the
      // disconnect, but per-device queries don't surface it as the same
      // device. Matches the existing notification-router behaviour
      // (`equipment.device_id` defaults to '').
      deviceId = '<unknown>';
    }
    final entry = UsbDisconnectEntry(
      deviceId: deviceId,
      timestamp: timestamp ?? _now(),
      deviceType: deviceType,
      reason: reason,
    );
    _entries.add(entry);
    if (_entries.length > maxEntries) {
      // Drop oldest first.
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }

  /// Drop entries older than [windowDuration].
  ///
  /// Returns the number of entries pruned, primarily for testability.
  /// Called automatically on every read; the periodic timer in the
  /// provider only matters for very long sessions that never query
  /// the snapshot.
  int prune({DateTime? now}) {
    final cutoff = (now ?? _now()).subtract(windowDuration);
    final before = _entries.length;
    _entries.removeWhere((entry) => entry.timestamp.isBefore(cutoff));
    return before - _entries.length;
  }

  /// Total disconnects (across all devices) in the last 24 hours.
  int totalLast24h({DateTime? now}) {
    prune(now: now);
    return _entries.length;
  }

  /// Per-device disconnect count in the last 24 hours. Pass `<unknown>`
  /// to query disconnects that carried no device id.
  int countForDevice(String deviceId, {DateTime? now}) {
    prune(now: now);
    return _entries.where((entry) => entry.deviceId == deviceId).length;
  }

  /// All recorded entries (sorted oldest first). Cheap copy — used by
  /// the post-session diagnostics builder and by tests.
  List<UsbDisconnectEntry> recentEntries({DateTime? now}) {
    prune(now: now);
    return List<UsbDisconnectEntry>.unmodifiable(_entries);
  }

  /// Snapshot per-device counts as a `{deviceId: count}` map. Used by
  /// the equipment-health aggregation helper.
  Map<String, int> perDeviceCounts({DateTime? now}) {
    prune(now: now);
    final counts = <String, int>{};
    for (final entry in _entries) {
      counts[entry.deviceId] = (counts[entry.deviceId] ?? 0) + 1;
    }
    return counts;
  }

  /// Filter to entries that occurred at or after [since]. Used by the
  /// post-session diagnostics summary which only cares about
  /// disconnects that happened during the current session, not the
  /// rolling 24h window.
  int countSince(DateTime since, {DateTime? now}) {
    prune(now: now);
    return _entries.where((entry) => !entry.timestamp.isBefore(since)).length;
  }

  /// Per-device disconnect count since [since]. Used by the
  /// post-session diagnostics summary to drive the "USB flake during
  /// this run" line items.
  Map<String, int> perDeviceCountsSince(DateTime since, {DateTime? now}) {
    prune(now: now);
    final counts = <String, int>{};
    for (final entry in _entries) {
      if (entry.timestamp.isBefore(since)) continue;
      counts[entry.deviceId] = (counts[entry.deviceId] ?? 0) + 1;
    }
    return counts;
  }

  /// Clear all entries. Test helper; production code should never need
  /// this because pruning handles the natural lifecycle.
  void clear() => _entries.clear();
}
