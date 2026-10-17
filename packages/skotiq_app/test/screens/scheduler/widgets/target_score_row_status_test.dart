// The rejection wording has ONE implementation. A private ladder inside the
// widget is a second one, and it is the one that runs: Plan Tonight > Schedule
// then shows
//   "M42-TEST / altitude 9.8° below site minimum 30.0°"   (the engine's text)
// next to a STATUS chip reading "Below horizon"           (the widget's copy).
//
// These tests pin the RENDERED chip, and the last one fails if a second ladder
// grows back inside the widget.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/scheduler/widgets/target_score_row.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

TargetScore _rejected(String reason) => TargetScore(
      targetId: 1,
      targetName: 'M42-TEST',
      totalScore: 0,
      factors: const [],
      hardConstraintFailed: true,
      rejectionReasons: [reason],
    );

Widget _host(TargetScore score) => MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: TargetScoreRow(
          score: score,
          progress: const [],
          isCurrent: false,
          isWinner: false,
        ),
      ),
    );

void main() {
  testWidgets(
    'a target that is up but under the site minimum is chipped "Too low"',
    (tester) async {
      // The rejecting case verbatim (site lat -35 / lon +21, alt 9.8°).
      await tester.pumpWidget(
        _host(_rejected('altitude 9.8° below site minimum 30.0°')),
      );

      expect(find.text('Below horizon'), findsNothing);
      expect(find.text('Too low'), findsOneWidget);
    },
  );

  testWidgets('a target genuinely under the horizon still says so', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_rejected('altitude -12.4° below site minimum 30.0°')),
    );

    expect(find.text('Below horizon'), findsOneWidget);
  });

  testWidgets('a custom-horizon rejection is not called "Below horizon"', (
    tester,
  ) async {
    // This reason also contains "altitude" and "below", so a keyword ladder in
    // the widget would match those two words first and mislabel it.
    await tester.pumpWidget(
      _host(
        _rejected('altitude 41.0° below horizon profile "Trees" '
            '(45.0° at az 130°)'),
      ),
    );

    expect(find.text('Below horizon'), findsNothing);
    expect(find.text('Behind horizon'), findsOneWidget);
  });

  testWidgets('the two moon constraints keep their separate chips', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_rejected('moon separation 12.0° below required 30.0°')),
    );
    expect(find.text('Too close to moon'), findsOneWidget);

    await tester.pumpWidget(
      _host(_rejected('moon illumination 88% > 40%')),
    );
    expect(find.text('Moon too bright'), findsOneWidget);
  });

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
          reason: 'the shared ladder must recognise "${entry.key}"',
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

  test('the widget grows no second rejection ladder', () {
    // The guard that makes the two-implementations trap loud instead of
    // silent: the chip must come from skotiq_core, so this file may not
    // contain its own reason matching.
    final source = File(
      'lib/screens/scheduler/widgets/target_score_row.dart',
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
        reason:
            'target_score_row.dart must not classify rejection reasons itself; '
            'use schedulerRejectionChipLabel() from skotiq_core',
      );
    }
    expect(code, contains('schedulerRejectionChipLabel('));
  });
}
