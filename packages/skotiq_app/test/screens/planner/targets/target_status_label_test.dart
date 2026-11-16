import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';

/// A target's status in Plan > Targets is the scheduler's own reading of why
/// it was ruled out, shortened by the one ladder in skotiq_core.
void main() {
  test(
    'the chip and the engine record classify a reason identically',
    () {
      // One ladder, two renderings. If someone re-forks the matching, these
      // two disagree on at least one row below.
      const cases = <String, String>{
        'altitude 9.8° below site minimum 30.0°': 'Too low',
        'altitude -3.0° below site minimum 30.0°': 'Below horizon',
        'altitude 41.0° below horizon profile "Trees" (45.0° at az 130°)':
            'Behind horizon',
        'outside time window 22:00–02:00': 'Outside window',
        'required filter Ha not in wheel': 'Filter missing',
        'goals complete': 'Complete',
      };
      for (final entry in cases.entries) {
        expect(
          schedulerRejectionChipLabel(entry.key),
          entry.value,
          reason: 'chip label for "${entry.key}"',
        );
        expect(
          classifySchedulerRejection(entry.key),
          isNot(SchedulerRejectionKind.other),
          reason: 'the shared ladder must recognize "${entry.key}"',
        );
      }
      // The engine's long form for the counter-input keeps both numbers.
      expect(
        schedulerRejectionSummary(
          'altitude 9.8° below site minimum 30.0°',
          minAltitudeDegrees: 30.0,
        ),
        'too low (9.8° < site minimum 30.0°)',
      );
    },
  );

  test('the target list grows no second rejection ladder', () {
    // The guard that makes the two-implementations trap loud instead of
    // silent: the chip must come from skotiq_core, so this file may not
    // contain its own reason matching.
    final source = File(
      'lib/screens/planner/targets/target_list.dart',
    ).readAsStringSync();
    // Strip the doc comment that explains the rule (it names the words).
    final code = source
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    for (final forbidden in const [
      "contains('altitude'",
      "contains('moon",
      "contains('horizon",
      "contains('filter'",
      "contains('time window'",
    ]) {
      expect(
        code.contains(forbidden),
        isFalse,
        reason: 'target_list.dart must not classify rejection reasons itself; '
            'use schedulerRejectionChipLabel() from skotiq_core',
      );
    }
    expect(code, contains('schedulerRejectionChipLabel('));
  });
}
