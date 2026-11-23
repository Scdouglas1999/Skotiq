// The app keeps its own label and analytics key for each recovery cause
// kind, because the session report shows recovery history saved by earlier
// releases with the kind only. test_fixtures/recovery_causes.json is written
// by a Rust test from the sequencer's policy table, so a label or key changed
// on one side fails here.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

void main() {
  final rows =
      (jsonDecode(
                File(
                  '../../test_fixtures/recovery_causes.json',
                ).readAsStringSync(),
              )
              as List)
          .cast<Map<String, dynamic>>();

  test('every cause the sequencer has is in the sample', () {
    expect(rows, hasLength(9));
    expect(rows.map((r) => r['kind']).toSet(), hasLength(9));
  });

  for (final row in rows) {
    test('${row['kind']} has the policy table label and key', () {
      final cause = RecoveryCause.fromJson(row['cause']);
      expect(cause.kind, row['kind']);
      expect(cause.displayLabel, row['label']);
      expect(cause.wireKey, row['wireKey']);
      expect(cause.toJson(), row['cause']);
      // The live typed event carries the kind and the custom label apart.
      expect(RecoveryCause.fromKind(row['kind'], cause.customLabel), cause);
    });
  }

  // A cause the sequencer gains before this app has a label for it: the
  // banner names it as unknown, and the event is not dropped.
  test('a cause kind this app does not know still decodes', () {
    final cause = RecoveryCause.fromKind('DomeShutterStuck', null);
    expect(cause.kind, 'DomeShutterStuck');
    expect(cause.displayLabel, 'Unknown (DomeShutterStuck)');
    expect(cause, RecoveryCause.fromJson('DomeShutterStuck'));
  });

  test('a live recovery event with an unknown cause kind is applied', () {
    final envelope = recoveryEnvelopeFromBridgeForTest(
      bridge.SkotiqEvent(
        eventId: BigInt.one,
        timestamp: 0,
        severity: bridge.EventSeverity.critical,
        category: bridge.EventCategory.sequencer,
        payload: const bridge.EventPayload.sequencer(
          bridge.SequencerEvent.recoveryStarted(
            startedAtIso: '2026-11-22T03:14:15.000Z',
            causeKind: 'DomeShutterStuck',
            attemptCount: 1,
            maxAttempts: 5,
            retryIntervalSecs: 60,
            maxDurationSecs: 1800,
            phase: 'Waiting',
          ),
        ),
      ),
    );
    expect(envelope!.context.cause.displayLabel, 'Unknown (DomeShutterStuck)');
  });

  test('a saved entry with the kind only reads with the label', () {
    for (final row in rows) {
      final entry = RecoveryHistoryEntry.fromJson({
        'started_at': '2026-11-21T03:14:15.000Z',
        'ended_at': '2026-11-21T03:20:00.000Z',
        'cause': row['cause'],
        'attempts': 2,
        'recovered': true,
        'aborted_by_user': false,
        'last_error': null,
      });
      expect(entry.cause.displayLabel, row['label'], reason: '${row['kind']}');
    }
  });
}
