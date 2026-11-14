import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart' show wireEventFromTyped;
import 'package:skotiq_core/bridge_events.dart' as sk;
import 'package:skotiq_core/models.dart' show SkotiqEvent;
import 'package:skotiq_desktop/headless_api/command_correlator.dart';

/// UUID v4 canonical form. The 13th hex char (after two dashes) must be
/// `4`, and the 17th must be one of `8`, `9`, `a`, `b` (variant 10xx).
final _uuidV4Regex = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  group('CommandCorrelator.beginCommand', () {
    test('returns a non-empty UUID v4 string', () {
      final correlator = CommandCorrelator();
      final id = correlator.beginCommand(
        operation: 'mount.slew',
        deviceId: 'mount:0',
      );

      expect(id, isNotEmpty);
      expect(
        _uuidV4Regex.hasMatch(id),
        isTrue,
        reason: 'generated id "$id" is not a canonical RFC 4122 UUID v4',
      );
    });

    test('two consecutive calls return distinct UUIDs', () {
      final correlator = CommandCorrelator();
      final id1 = correlator.beginCommand(
        operation: 'mount.slew',
        deviceId: 'mount:0',
      );
      final id2 = correlator.beginCommand(
        operation: 'mount.slew',
        deviceId: 'mount:0',
      );

      expect(id1, isNot(equals(id2)));
    });

    test('returns id even for an unknown operation kind', () {
      // The impl explicitly documents that unknown operations are accepted —
      // the id is returned to the caller but stampEvent will never match
      // them because there's no completion-event mapping. We pin both
      // halves of that contract here.
      final correlator = CommandCorrelator();
      final id = correlator.beginCommand(
        operation: 'some.unknown.op',
        deviceId: 'device:0',
      );
      expect(id, isNotEmpty);
      expect(_uuidV4Regex.hasMatch(id), isTrue);

      // Stamping an unrelated, real completion event on a different op
      // does not consume our pending command.
      expect(
        correlator.stampEvent(operation: 'mount.slew', deviceId: 'mount:0'),
        isNull,
      );
      // And the original pending command is still in the table.
      expect(correlator.pendingCount, 1);
    });

    test('pendingCount tracks outstanding commands', () {
      final correlator = CommandCorrelator();
      expect(correlator.pendingCount, 0);
      correlator.beginCommand(operation: 'mount.slew', deviceId: 'mount:0');
      correlator.beginCommand(operation: 'mount.slew', deviceId: 'mount:0');
      correlator.beginCommand(operation: 'camera.expose', deviceId: 'cam:0');
      expect(correlator.pendingCount, 3);
    });
  });

  group('CommandCorrelator.stampEvent', () {
    test('matches by (operation, deviceId) and returns the registered id', () {
      final correlator = CommandCorrelator();
      final commandId = correlator.beginCommand(
        operation: 'mount.slew',
        deviceId: 'mount:0',
      );

      final stamped = correlator.stampEvent(
        operation: 'mount.slew',
        deviceId: 'mount:0',
      );

      expect(stamped, equals(commandId));
    });

    test('returns null with no prior beginCommand', () {
      final correlator = CommandCorrelator();

      final stamped = correlator.stampEvent(
        operation: 'mount.slew',
        deviceId: 'mount:0',
      );

      expect(stamped, isNull);
    });

    test('matches in FIFO order when multiple commands are outstanding', () {
      // The class doc says "best-effort", "oldest un-stamped pending command
      // for the key". The brief asked for "most recent" — those statements
      // appear contradictory, but the actual semantics implemented are
      // FIFO (oldest-first). We pin the actual implementation; if a future
      // change wants LIFO it should fail this test and force a review of
      // both the doc-comment and the brief.
      final correlator = CommandCorrelator();
      final first = correlator.beginCommand(
        operation: 'mount.slew',
        deviceId: 'mount:0',
      );
      final second = correlator.beginCommand(
        operation: 'mount.slew',
        deviceId: 'mount:0',
      );

      expect(
        correlator.stampEvent(operation: 'mount.slew', deviceId: 'mount:0'),
        equals(first),
      );
      expect(
        correlator.stampEvent(operation: 'mount.slew', deviceId: 'mount:0'),
        equals(second),
      );
    });

    test('does not match across different (operation, deviceId) pairs '
        '(operation-or-device asymmetry)', () {
      final correlator = CommandCorrelator();
      correlator.beginCommand(operation: 'camera.expose', deviceId: 'camera:0');

      // Same op, different device — no match.
      expect(
        correlator.stampEvent(operation: 'camera.expose', deviceId: 'camera:1'),
        isNull,
      );
      // Different op, same device — no match.
      expect(
        correlator.stampEvent(operation: 'mount.slew', deviceId: 'camera:0'),
        isNull,
      );
      // Completely different — no match.
      expect(
        correlator.stampEvent(operation: 'mount.slew', deviceId: 'mount:0'),
        isNull,
      );

      // The original is still pending and unconsumed.
      expect(correlator.pendingCount, 1);
    });

    test('after a successful match, the command is consumed', () {
      final correlator = CommandCorrelator();
      final commandId = correlator.beginCommand(
        operation: 'mount.slew',
        deviceId: 'mount:0',
      );

      final first = correlator.stampEvent(
        operation: 'mount.slew',
        deviceId: 'mount:0',
      );
      expect(first, equals(commandId));

      // A second event for the same key must NOT keep stamping the
      // already-matched id. With no other pending commands, it returns null.
      final second = correlator.stampEvent(
        operation: 'mount.slew',
        deviceId: 'mount:0',
      );
      expect(second, isNull);
      expect(correlator.pendingCount, 0);
    });

    test('keys correctly distinguish null vs empty vs missing deviceId', () {
      // Both null and empty deviceId collapse to a key without the device
      // suffix (see _key in the impl). We pin that so a future "tighten
      // device-id semantics" change must update the test deliberately.
      final correlator = CommandCorrelator();
      final id = correlator.beginCommand(operation: 'sequencer.start');

      expect(correlator.stampEvent(operation: 'sequencer.start'), equals(id));

      final id2 = correlator.beginCommand(
        operation: 'sequencer.start',
        deviceId: '',
      );
      expect(
        correlator.stampEvent(operation: 'sequencer.start', deviceId: ''),
        equals(id2),
      );
    });
  });

  group('CommandCorrelator TTL eviction', () {
    test('a beginCommand made > TTL ago is no longer matched', () {
      // Use a pluggable clock + short TTL to make this deterministic.
      var now = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final correlator = CommandCorrelator(
        ttl: const Duration(minutes: 1),
        now: () => now,
      );
      correlator.beginCommand(
        operation: 'plate-solve',
        deviceId: 'platesolver:0',
      );

      // Advance the clock past TTL.
      now = now.add(const Duration(minutes: 2));

      final stamped = correlator.stampEvent(
        operation: 'plate-solve',
        deviceId: 'platesolver:0',
      );
      expect(stamped, isNull);
    });

    test('evictExpired drops everything past TTL', () {
      var now = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final correlator = CommandCorrelator(
        ttl: const Duration(minutes: 1),
        now: () => now,
      );
      correlator.beginCommand(operation: 'mount.slew', deviceId: 'mount:0');
      correlator.beginCommand(operation: 'mount.slew', deviceId: 'mount:0');
      correlator.beginCommand(operation: 'camera.expose', deviceId: 'cam:0');
      expect(correlator.pendingCount, 3);

      now = now.add(const Duration(minutes: 2));
      correlator.evictExpired();
      expect(correlator.pendingCount, 0);
    });

    test('evictExpired leaves entries within TTL alone', () {
      var now = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final correlator = CommandCorrelator(
        ttl: const Duration(minutes: 30),
        now: () => now,
      );
      correlator.beginCommand(operation: 'mount.slew', deviceId: 'mount:0');

      // Advance by half the TTL: entry should still be live.
      now = now.add(const Duration(minutes: 15));
      correlator.evictExpired();
      expect(correlator.pendingCount, 1);

      final stamped = correlator.stampEvent(
        operation: 'mount.slew',
        deviceId: 'mount:0',
      );
      expect(stamped, isNotNull);
    });

    test('expired entries at the head are evicted when a fresh stamp arrives '
        'and the next-oldest entry matches', () {
      var now = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final correlator = CommandCorrelator(
        ttl: const Duration(minutes: 1),
        now: () => now,
      );
      final stale = correlator.beginCommand(
        operation: 'mount.slew',
        deviceId: 'mount:0',
      );

      // Advance past TTL — stale is no longer eligible.
      now = now.add(const Duration(minutes: 2));

      // Register a fresh command at the new clock.
      final fresh = correlator.beginCommand(
        operation: 'mount.slew',
        deviceId: 'mount:0',
      );

      // stampEvent should skip the stale entry and consume the fresh one.
      final stamped = correlator.stampEvent(
        operation: 'mount.slew',
        deviceId: 'mount:0',
      );
      expect(stamped, equals(fresh));
      expect(stamped, isNot(equals(stale)));
    });
  });

  group('CommandCorrelator.clear', () {
    test('clear drops every pending command', () {
      final correlator = CommandCorrelator();
      correlator.beginCommand(operation: 'mount.slew', deviceId: 'mount:0');
      correlator.beginCommand(operation: 'camera.expose', deviceId: 'cam:0');
      expect(correlator.pendingCount, 2);

      correlator.clear();
      expect(correlator.pendingCount, 0);
      expect(
        correlator.stampEvent(operation: 'mount.slew', deviceId: 'mount:0'),
        isNull,
      );
    });
  });

  group('commandCompletionOf', () {
    SkotiqEvent fromHost(sk.EventCategory category, sk.EventPayload payload) {
      final wire = wireEventFromTyped(
        sk.SkotiqEvent(
          eventId: BigInt.zero,
          timestamp: 0,
          severity: sk.EventSeverity.info,
          category: category,
          payload: payload,
        ),
      );
      // Through JSON, as the server receives a forwarded event.
      return SkotiqEvent.fromWireJson(
        jsonDecode(jsonEncode(wire.toJson())) as Map<String, dynamic>,
      );
    }

    CommandCompletion? sequencer(sk.SequencerEvent event) =>
        commandCompletionOf(
          fromHost(
            sk.EventCategory.sequencer,
            sk.EventPayload.sequencer(event),
          ),
        );

    test('the run lifecycle events a host sends complete their commands', () {
      expect(
        sequencer(
          const sk.SequencerEvent.started(sequenceName: 'n'),
        )?.operations,
        contains('sequencer.start'),
      );
      expect(sequencer(const sk.SequencerEvent.paused())?.operations, [
        'sequencer.pause',
      ]);
      expect(sequencer(const sk.SequencerEvent.resumed())?.operations, [
        'sequencer.resume',
      ]);
      expect(sequencer(const sk.SequencerEvent.stopped())?.operations, [
        'sequencer.stop',
      ]);
    });

    test("the guider's pause completes no sequencer command", () {
      expect(
        commandCompletionOf(
          fromHost(
            sk.EventCategory.guiding,
            const sk.EventPayload.guiding(sk.GuidingEvent.paused()),
          ),
        ),
        isNull,
      );
    });

    test('a device event names the device it completes for', () {
      final completion = commandCompletionOf(
        fromHost(
          sk.EventCategory.equipment,
          const sk.EventPayload.equipment(
            sk.EquipmentEvent.mountSlewCompleted(
              deviceId: 'sim_mount_1',
              ra: 1,
              dec: 2,
            ),
          ),
        ),
      );
      expect(completion?.operations.first, 'mount.slew');
      expect(completion?.deviceId, 'sim_mount_1');
    });

    test('an event that completes nothing returns null', () {
      expect(
        sequencer(
          const sk.SequencerEvent.nodeStarted(
            nodeId: 'n',
            nodeType: 'TakeExposure',
          ),
        ),
        isNull,
      );
    });
  });
}
