// The app keeps its own label and analytics key for each recovery cause
// kind, because the session report shows recovery history saved by earlier
// releases with the kind only. test_fixtures/recovery_causes.json is written
// by a Rust test from the sequencer's policy table, so a label or key changed
// on one side fails here.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

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
    });
  }

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
