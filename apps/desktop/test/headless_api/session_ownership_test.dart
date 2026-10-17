import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/session_ownership.dart';

class _EventRecorder {
  final events = <SkotiqEvent>[];
  void record(SkotiqEvent event) => events.add(event);
  List<SkotiqEvent> ofType(String type) =>
      events.where((e) => e.eventType == type).toList();
}

class _MutableClock {
  DateTime _now;
  _MutableClock(this._now);
  DateTime call() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

/// Identity-style digest function for tests: the digest is a stable
/// prefix on the raw token so test code can reason about which "owner"
/// is which without dragging SHA-256 into every assertion.
String _testDigest(String token) => 'digest:$token';

SessionOwnershipManager _build({
  void Function(SkotiqEvent)? onEvent,
  DateTime Function()? now,
  Duration heartbeatTimeout = const Duration(minutes: 5),
}) {
  return SessionOwnershipManager(
    emitEvent: onEvent ?? (_) {},
    digestToken: _testDigest,
    heartbeatTimeout: heartbeatTimeout,
    now: now,
  );
}

void main() {
  group('SessionOwnershipManager.claim()', () {
    test('claim on a free slot succeeds and broadcasts OwnershipClaimed', () {
      final recorder = _EventRecorder();
      final manager = _build(onEvent: recorder.record);
      addTearDown(manager.dispose);

      final owner = manager.claim(
        token: 'token-a',
        clientId: 'phone',
        clientName: 'Pixel 7',
      );
      expect(owner, isNotNull);
      expect(owner!.tokenDigest, 'digest:token-a');
      expect(owner.clientName, 'Pixel 7');
      expect(manager.current, isNotNull);
      expect(recorder.ofType(ownerEventClaimed), hasLength(1));
      expect(
        recorder.ofType(ownerEventClaimed).single.category,
        EventCategory.session,
      );
    });

    test('claim when slot already taken returns null and emits no event', () {
      final recorder = _EventRecorder();
      final manager = _build(onEvent: recorder.record);
      addTearDown(manager.dispose);

      manager.claim(token: 'token-a', clientName: 'A');
      recorder.events.clear();

      final result = manager.claim(token: 'token-b', clientName: 'B');
      expect(result, isNull);
      expect(recorder.events, isEmpty);
      // Original owner is still the operator.
      expect(manager.current!.clientName, 'A');
    });

    test('claim by same token is idempotent and refreshes identity', () {
      final manager = _build();
      addTearDown(manager.dispose);

      final first = manager.claim(token: 'token-a', clientName: 'Old');
      expect(first, isNotNull);
      final second = manager.claim(token: 'token-a', clientName: 'New');
      expect(second, isNotNull);
      expect(second!.clientName, 'New');
      expect(second.claimedAt, first!.claimedAt); // claimedAt stable
    });
  });

  group('SessionOwnershipManager.takeOver()', () {
    test('takeOver displaces the current owner', () {
      final recorder = _EventRecorder();
      final manager = _build(onEvent: recorder.record);
      addTearDown(manager.dispose);

      manager.claim(token: 'token-a', clientName: 'A');
      final newOwner = manager.takeOver(
        token: 'token-b',
        reason: 'taking over for B',
        clientName: 'B',
      );
      expect(newOwner.clientName, 'B');
      expect(manager.current!.clientName, 'B');
      final takenOver = recorder.ofType(ownerEventTakenOver);
      expect(takenOver, hasLength(1));
      expect(takenOver.single.data['reason'], 'taking over for B');
      expect(takenOver.single.data['previousOwner'], isA<Map>());
      expect(
        (takenOver.single.data['previousOwner'] as Map)['clientName'],
        'A',
      );
    });

    test('takeOver succeeds when the slot was empty', () {
      final recorder = _EventRecorder();
      final manager = _build(onEvent: recorder.record);
      addTearDown(manager.dispose);

      final owner = manager.takeOver(
        token: 'token-x',
        reason: 'no previous owner',
        clientName: 'X',
      );
      expect(owner.clientName, 'X');
      expect(manager.current!.clientName, 'X');
    });
  });

  group('SessionOwnershipManager.release()', () {
    test('release by the current owner clears the slot', () {
      final recorder = _EventRecorder();
      final manager = _build(onEvent: recorder.record);
      addTearDown(manager.dispose);

      manager.claim(token: 'token-a', clientName: 'A');
      final ok = manager.release('token-a');
      expect(ok, isTrue);
      expect(manager.current, isNull);
      expect(recorder.ofType(ownerEventReleased), hasLength(1));
    });

    test(
      'release by a non-owner returns false and does not touch the slot',
      () {
        final manager = _build();
        addTearDown(manager.dispose);

        manager.claim(token: 'token-a', clientName: 'A');
        final ok = manager.release('token-b');
        expect(ok, isFalse);
        expect(manager.current!.tokenDigest, 'digest:token-a');
      },
    );

    test('release on an empty slot is a no-op success', () {
      final manager = _build();
      addTearDown(manager.dispose);
      expect(manager.release('any-token'), isTrue);
    });
  });

  group('SessionOwnershipManager (auto-release)', () {
    test('auto-release fires after the heartbeat timeout', () {
      final clock = _MutableClock(DateTime.utc(2026, 5, 24, 22, 0, 0));
      final recorder = _EventRecorder();
      final manager = _build(
        onEvent: recorder.record,
        now: clock.call,
        heartbeatTimeout: const Duration(minutes: 5),
      );
      addTearDown(manager.dispose);

      manager.claim(token: 'token-a', clientName: 'A');
      // Sanity-check: sweep before the timeout does nothing.
      manager.sweepIdle();
      expect(manager.current, isNotNull);

      clock.advance(const Duration(minutes: 6));
      manager.sweepIdle();
      expect(manager.current, isNull);
      final autoEvents = recorder.ofType(ownerEventAutoReleased);
      expect(autoEvents, hasLength(1));
      expect(autoEvents.single.data['reason'], 'heartbeat_timeout');
    });

    test('touchHeartbeat resets the idle timer for the current owner', () {
      final clock = _MutableClock(DateTime.utc(2026, 5, 24, 22, 0, 0));
      final manager = _build(
        now: clock.call,
        heartbeatTimeout: const Duration(minutes: 5),
      );
      addTearDown(manager.dispose);

      manager.claim(token: 'token-a', clientName: 'A');
      clock.advance(const Duration(minutes: 4));
      manager.touchHeartbeat('token-a');
      clock.advance(const Duration(minutes: 4));
      manager.sweepIdle();
      expect(
        manager.current,
        isNotNull,
        reason: 'heartbeat refresh should have prevented auto-release',
      );
    });

    test('touchHeartbeat with a non-owner token is silently ignored', () {
      final clock = _MutableClock(DateTime.utc(2026, 5, 24, 22, 0, 0));
      final manager = _build(
        now: clock.call,
        heartbeatTimeout: const Duration(minutes: 5),
      );
      addTearDown(manager.dispose);

      manager.claim(token: 'token-a', clientName: 'A');
      manager.touchHeartbeat('token-b'); // non-owner, no-op
      clock.advance(const Duration(minutes: 6));
      manager.sweepIdle();
      expect(
        manager.current,
        isNull,
        reason: 'idle timeout should still fire when a non-owner touches',
      );
    });
  });

  group('SessionOwnershipManager.isOwner()', () {
    test('returns true for the owning token, false for any other', () {
      final manager = _build();
      addTearDown(manager.dispose);

      manager.claim(token: 'token-a', clientName: 'A');
      expect(manager.isOwner('token-a'), isTrue);
      expect(manager.isOwner('token-b'), isFalse);
      expect(manager.isOwner(''), isFalse);
    });

    test('returns false when the slot is empty', () {
      final manager = _build();
      addTearDown(manager.dispose);
      expect(manager.isOwner('whatever'), isFalse);
    });
  });

  group('isOwnershipRequired()', () {
    test('mutating destructive endpoints require ownership', () {
      const samples = [
        '/api/sequencer/start',
        '/api/sequencer/stop',
        '/api/mount/slew',
        '/api/mount/park',
        '/api/dome/open',
        '/api/camera/expose',
        '/api/focuser/autofocus/start',
        '/api/plate-solve',
        '/api/framing/center-on-target',
        '/api/polar-alignment/start',
      ];
      for (final path in samples) {
        expect(
          isOwnershipRequired(method: 'POST', path: path),
          isTrue,
          reason: 'expected POST $path to require ownership',
        );
      }
    });

    test('status / read-only endpoints do not require ownership', () {
      const samples = [
        '/api/equipment/camera/status',
        '/api/sequencer/status',
        '/api/mount/status',
        '/api/dome/status',
        '/api/devices',
        '/api/info',
        '/api/jobs',
      ];
      for (final path in samples) {
        expect(
          isOwnershipRequired(method: 'GET', path: path),
          isFalse,
          reason: 'expected GET $path to NOT require ownership',
        );
        expect(
          isOwnershipRequired(method: 'POST', path: path),
          isFalse,
          reason: 'expected POST $path to NOT require ownership',
        );
      }
    });

    test('non-POST methods never require ownership', () {
      expect(
        isOwnershipRequired(method: 'GET', path: '/api/mount/slew'),
        isFalse,
      );
      expect(
        isOwnershipRequired(method: 'DELETE', path: '/api/mount/slew'),
        isFalse,
      );
    });
  });

  group('SessionOwnershipManager (changes stream)', () {
    test('emits a snapshot per transition', () async {
      final recorder = _EventRecorder();
      final manager = _build(onEvent: recorder.record);
      addTearDown(manager.dispose);
      final snapshots = <SessionOwner?>[];
      final sub = manager.changes.listen(snapshots.add);
      addTearDown(sub.cancel);

      manager.claim(token: 'token-a', clientName: 'A');
      manager.takeOver(token: 'token-b', reason: 'switch', clientName: 'B');
      manager.release('token-b');

      expect(snapshots, hasLength(3));
      expect(snapshots[0]!.clientName, 'A');
      expect(snapshots[1]!.clientName, 'B');
      expect(snapshots[2], isNull);
    });
  });
}
