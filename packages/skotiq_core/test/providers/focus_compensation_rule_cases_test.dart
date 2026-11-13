// The app's idle temperature compensation and a run's are one rule written
// twice: `FocusCompensationRule` here and `FocusCompensation` in
// native/skotiq_native/sequencer/src/temperature_compensation.rs. Both run
// every case in the file below (the Rust test is
// `the_rule_gives_what_the_shared_cases_say`), so the two cannot come apart
// without a test failing on one side.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/equipment/focus_compensation_rule.dart';

const _casesPath =
    '../../native/skotiq_native/sequencer/src/temperature_compensation_cases.json';

Map<String, Object?> _wire(CompensationStep step) => switch (step) {
  TakeReference(movedFrom: final movedFrom) => {
    'kind': 'take_reference',
    'moved_from': movedFrom,
  },
  Hold() => {'kind': 'hold'},
  Move(target: final target, owed: final owed) => {
    'kind': 'move',
    'target': target,
    'owed': owed,
  },
  Refuse(target: final target) => {'kind': 'refuse', 'target': target},
};

void main() {
  final cases =
      (jsonDecode(File(_casesPath).readAsStringSync()) as List)
          .cast<Map<String, dynamic>>();

  test('the case file is the one the Rust rule runs', () {
    expect(cases.length, greaterThanOrEqualTo(12));
    expect(
      cases.map((c) => c['name']),
      contains('a filter offset keeps the correction owed'),
    );
  });

  for (final c in cases) {
    test('rule case: ${c['name']}', () {
      final rule = FocusCompensationRule();
      final ops = (c['ops'] as List).cast<Map<String, dynamic>>();
      for (var i = 0; i < ops.length; i++) {
        final op = ops[i];
        switch (op['op'] as String) {
          case 'shifted_by':
            rule.shiftedBy(op['steps'] as int);
          case 'moved_to':
            rule.movedTo(op['target'] as int);
          case 'forget_reference':
            rule.forgetReference();
          case 'step':
            final step = rule.step(
              stepsPerDegree: (c['steps_per_degree'] as num).toDouble(),
              minSteps: c['min_steps'] as int,
              temperature: (op['temperature'] as num).toDouble(),
              position: op['position'] as int,
            );
            expect(_wire(step), op['expect'], reason: 'op $i');
          default:
            fail('unknown op ${op['op']}');
        }
      }
    });
  }
}
