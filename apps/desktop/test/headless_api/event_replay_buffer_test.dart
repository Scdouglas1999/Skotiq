import 'package:flutter_test/flutter_test.dart';
// Import the event-types source directly rather than via the
// `package:skotiq_core/skotiq_core.dart` barrel. The barrel
// transitively pulls in providers/services whose switch statements over
// `EventCategory` are temporarily non-exhaustive (post-`job` /
// `session` enum additions); a direct import keeps these tests
// compilable even while that mismatch is being resolved elsewhere.
import 'package:skotiq_core/src/models/backend/event_types.dart';
import 'package:skotiq_desktop/headless_api/event_replay_buffer.dart';

/// Helper: build a stamped [SkotiqEvent] with the given seq. The
/// content of the event is irrelevant to ring-buffer behaviour — only the
/// seq matters for ordering / replay slicing.
SkotiqEvent _stamped(int seq, {String? instanceId}) {
  return SkotiqEvent(
    timestamp: 1700000000000 + seq,
    severity: EventSeverity.info,
    category: EventCategory.system,
    eventType: 'TestEvent',
    data: {'n': seq},
    seq: seq,
    serverInstanceId: instanceId ?? 'test-instance',
  );
}

void main() {
  group('EventReplayBuffer (empty)', () {
    test('oldestSeq and newestSeq are null when no events stored', () {
      final buffer = EventReplayBuffer(capacity: 10);

      expect(buffer.oldestSeq, isNull);
      expect(buffer.newestSeq, isNull);
      expect(buffer.length, 0);
    });

    test('eventsSince(0) on empty buffer returns empty list (not null)', () {
      final buffer = EventReplayBuffer(capacity: 10);

      // An empty buffer hasn't dropped anything, so eventsSince must NOT
      // return the resync sentinel — there's simply nothing newer than
      // the client's cursor yet.
      final result = buffer.eventsSince(0);
      expect(result, isNotNull);
      expect(result, isEmpty);
    });

    test('eventsSince(arbitrary large seq) on empty buffer returns empty', () {
      final buffer = EventReplayBuffer(capacity: 10);

      // Same contract: empty buffer means "no events known", not "resync".
      expect(buffer.eventsSince(9999), isEmpty);
    });
  });

  group('EventReplayBuffer (basic append + replay)', () {
    test('append stores events in insertion order', () {
      final buffer = EventReplayBuffer(capacity: 10);
      buffer.append(_stamped(1));
      buffer.append(_stamped(2));
      buffer.append(_stamped(3));

      expect(buffer.length, 3);
      expect(buffer.oldestSeq, 1);
      expect(buffer.newestSeq, 3);
    });

    test('eventsSince(0) returns every stored event in seq order', () {
      final buffer = EventReplayBuffer(capacity: 10);
      for (var i = 1; i <= 5; i++) {
        buffer.append(_stamped(i));
      }

      final replayed = buffer.eventsSince(0)!;
      expect(replayed.map((e) => e.seq).toList(), [1, 2, 3, 4, 5]);
    });

    test(
      'eventsSince(newestSeq) returns empty (nothing newer than itself)',
      () {
        final buffer = EventReplayBuffer(capacity: 10);
        for (var i = 1; i <= 5; i++) {
          buffer.append(_stamped(i));
        }

        expect(buffer.eventsSince(5), isEmpty);
      },
    );

    test('eventsSince(newestSeq - 1) returns only the latest event', () {
      final buffer = EventReplayBuffer(capacity: 10);
      for (var i = 1; i <= 5; i++) {
        buffer.append(_stamped(i));
      }

      final replayed = buffer.eventsSince(4)!;
      expect(replayed.length, 1);
      expect(replayed.first.seq, 5);
    });

    test('eventsSince in the middle returns the tail slice', () {
      final buffer = EventReplayBuffer(capacity: 10);
      for (var i = 1; i <= 5; i++) {
        buffer.append(_stamped(i));
      }

      final replayed = buffer.eventsSince(2)!;
      expect(replayed.map((e) => e.seq).toList(), [3, 4, 5]);
    });

    test('append throws ArgumentError when event has no seq', () {
      final buffer = EventReplayBuffer(capacity: 10);
      final unstamped = SkotiqEvent(
        timestamp: 1700000000000,
        severity: EventSeverity.info,
        category: EventCategory.system,
        eventType: 'TestEvent',
        data: const {},
        // seq is intentionally null
      );

      expect(() => buffer.append(unstamped), throwsArgumentError);
    });
  });

  group('EventReplayBuffer (capacity + eviction)', () {
    test('capacity must be positive (asserted)', () {
      expect(
        () => EventReplayBuffer(capacity: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => EventReplayBuffer(capacity: -1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('adding capacity + 1 events drops the oldest entry (FIFO)', () {
      final buffer = EventReplayBuffer(capacity: 3);
      buffer.append(_stamped(1));
      buffer.append(_stamped(2));
      buffer.append(_stamped(3));
      expect(buffer.length, 3);
      expect(buffer.oldestSeq, 1);

      buffer.append(_stamped(4));
      expect(buffer.length, 3);
      expect(buffer.oldestSeq, 2);
      expect(buffer.newestSeq, 4);
    });

    test('burst of 10x capacity retains only the most recent N entries', () {
      const cap = 5;
      final buffer = EventReplayBuffer(capacity: cap);
      for (var i = 1; i <= cap * 10; i++) {
        buffer.append(_stamped(i));
      }

      expect(buffer.length, cap);
      expect(buffer.oldestSeq, cap * 10 - cap + 1); // 46
      expect(buffer.newestSeq, cap * 10); // 50

      // Sanity: a full replay from before the burst returns the resync
      // sentinel because the gap is far larger than capacity.
      expect(buffer.eventsSince(0), isNull);
    });
  });

  group('EventReplayBuffer (stale since => resync sentinel)', () {
    test('eventsSince(since) older than oldestSeq - 1 returns null', () {
      // Buffer ends up holding 11..15 after 15 inserts with cap=5.
      const cap = 5;
      final buffer = EventReplayBuffer(capacity: cap);
      for (var i = 1; i <= 15; i++) {
        buffer.append(_stamped(i));
      }
      expect(buffer.oldestSeq, 11);

      // Client last saw seq=5; the next event it needs would be seq=6,
      // but the buffer no longer has it. Caller must resync.
      expect(buffer.eventsSince(5), isNull);
    });

    test('eventsSince(oldestSeq - 1) is the boundary that still replays', () {
      // The doc-string says: "since == oldestSeq - 1 is the edge case
      // where the next event IS the oldest retained one — we treat that
      // as a successful replay."
      const cap = 5;
      final buffer = EventReplayBuffer(capacity: cap);
      for (var i = 1; i <= 15; i++) {
        buffer.append(_stamped(i));
      }
      expect(buffer.oldestSeq, 11);

      final boundary = buffer.eventsSince(10);
      expect(boundary, isNotNull);
      expect(boundary!.map((e) => e.seq).toList(), [11, 12, 13, 14, 15]);
    });

    test('eventsSince(oldestSeq - 2) is just past the boundary => resync', () {
      const cap = 5;
      final buffer = EventReplayBuffer(capacity: cap);
      for (var i = 1; i <= 15; i++) {
        buffer.append(_stamped(i));
      }
      expect(buffer.oldestSeq, 11);

      // since=9 means the client expects 10 next, but we evicted 10.
      expect(buffer.eventsSince(9), isNull);
    });
  });

  group('EventReplayBuffer (clear + length)', () {
    test('clear removes all entries and resets oldest/newest', () {
      final buffer = EventReplayBuffer(capacity: 10);
      for (var i = 1; i <= 5; i++) {
        buffer.append(_stamped(i));
      }
      expect(buffer.length, 5);

      buffer.clear();
      expect(buffer.length, 0);
      expect(buffer.oldestSeq, isNull);
      expect(buffer.newestSeq, isNull);
      expect(buffer.eventsSince(0), isEmpty);
    });

    test('append after clear behaves like a fresh buffer', () {
      final buffer = EventReplayBuffer(capacity: 3);
      buffer.append(_stamped(1));
      buffer.append(_stamped(2));
      buffer.clear();
      buffer.append(_stamped(100));

      expect(buffer.length, 1);
      expect(buffer.oldestSeq, 100);
      expect(buffer.newestSeq, 100);
    });
  });

  group('EventReplayBuffer (single-threaded contract)', () {
    // The class doc explicitly states: "Thread safety: this class assumes
    // single-threaded access (the shelf request loop). HeadlessApiServer
    // .broadcastEvent runs on the Dart event loop without yielding between
    // append + sink.add."
    //
    // Dart isolates are single-threaded by design, and EventReplayBuffer
    // backs onto a plain List with no Future/Stream boundaries, so there
    // is no concurrency to exercise. We pin the contract here so a future
    // change that introduces async pauses inside append() will trip this
    // test (and force the author to revisit the thread-safety claim).
    test('rapid synchronous appends preserve order with no interleaving', () {
      final buffer = EventReplayBuffer(capacity: 1000);
      for (var i = 1; i <= 500; i++) {
        buffer.append(_stamped(i));
      }
      expect(buffer.length, 500);
      final replayed = buffer.eventsSince(0)!;
      for (var i = 0; i < replayed.length; i++) {
        expect(replayed[i].seq, i + 1);
      }
    });
  });
}
