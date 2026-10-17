// monotonic event sequencing + ring-buffer replay for the headless
// API server.
//
// Every SkotiqEvent broadcast by HeadlessApiServer is stamped with a
// monotonically-increasing `seq` and the server-instance UUID, then
// appended to this ring buffer. WebSocket clients reconnecting with
// `?since=<seq>&instance=<uuid>` can be replayed everything they missed,
// or told `resync_required` if the gap is too large.
//
// The buffer is in-memory only — a server restart issues a new
// `serverInstanceId` so clients know their cached `seq` is stale.

import 'package:skotiq_core/skotiq_core.dart';

/// Fixed-capacity FIFO ring buffer of stamped [SkotiqEvent]s.
///
/// Operations are O(1) amortised. Eviction is implicit: once [capacity]
/// is reached, every [append] silently drops the oldest entry.
///
/// Thread safety: this class assumes single-threaded access (the shelf
/// request loop). HeadlessApiServer.broadcastEvent runs on the Dart
/// event loop without yielding between append + sink.add.
class EventReplayBuffer {
  /// Maximum entries retained. Default 5000 chosen as a balance between
  /// memory cost (~5 MB at 1 KB/event) and gap-tolerance for phones
  /// backgrounded for several minutes during a guiding-heavy run.
  final int capacity;

  /// Stamped events ordered by ascending seq.
  final List<SkotiqEvent> _entries;

  EventReplayBuffer({this.capacity = 5000})
    : _entries = <SkotiqEvent>[],
      assert(capacity > 0, 'capacity must be positive');

  /// Append [event] to the buffer. The caller must have already stamped
  /// `seq` on the event; passing an unstamped event is a programmer error.
  void append(SkotiqEvent event) {
    if (event.seq == null) {
      // Why throw not silently accept: a pre-stamped event is the only
      // legitimate input here. Storing seq=null would break the since-query
      // replay path at read time, far from the caller that caused it.
      throw ArgumentError(
        'EventReplayBuffer.append requires a stamped event (seq != null)',
      );
    }
    _entries.add(event);
    if (_entries.length > capacity) {
      // Trim the oldest entries to enforce capacity. removeRange is O(N)
      // on the trimmed prefix; since we only ever overflow by 1 per
      // append, this stays O(1) per call.
      _entries.removeRange(0, _entries.length - capacity);
    }
  }

  /// Return all events with `seq > since`, ordered ascending. When
  /// [since] is older than the buffer's oldest retained seq, returns
  /// `null` to signal the caller must send `resync_required`.
  ///
  /// `since == oldestSeq - 1` is the edge case where the next event IS
  /// the oldest retained one — we treat that as a successful replay.
  List<SkotiqEvent>? eventsSince(int since) {
    if (_entries.isEmpty) {
      return const <SkotiqEvent>[];
    }
    final oldest = _entries.first.seq!;
    // The client's last-seen seq is `since`. If `since + 1` is older than
    // our oldest retained event, we cannot guarantee no gap.
    if (since + 1 < oldest) {
      return null; // out of range — caller must resync
    }
    final result = <SkotiqEvent>[];
    for (final entry in _entries) {
      if (entry.seq! > since) {
        result.add(entry);
      }
    }
    return result;
  }

  /// Lowest retained seq, or null when empty.
  int? get oldestSeq => _entries.isEmpty ? null : _entries.first.seq;

  /// Highest retained seq, or null when empty.
  int? get newestSeq => _entries.isEmpty ? null : _entries.last.seq;

  /// Current number of retained events (0..capacity).
  int get length => _entries.length;

  /// Drop every retained entry. Used by tests and by HeadlessApiServer.stop
  /// to release references.
  void clear() {
    _entries.clear();
  }
}
