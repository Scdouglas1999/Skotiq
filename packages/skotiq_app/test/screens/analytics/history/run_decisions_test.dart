// The Run log lists every decision the sequencer logged for the run, on the
// host and on a linked client alike.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/history/night_views/run_decisions.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

ReplayDecision _decision(
  int id,
  DateTime timestamp,
  String summary, {
  DecisionCategory category = DecisionCategory.unknown,
  Map<String, dynamic> details = const {},
}) =>
    ReplayDecision(
      id: id,
      sequenceRunId: 7,
      timestamp: timestamp,
      category: category,
      summary: summary,
      details: details,
    );

void main() {
  final startedAt = DateTime.utc(2026, 8, 13, 20, 53, 44);
  final endedAt = DateTime.utc(2026, 8, 13, 20, 54, 1);

  Future<void> pump(
    WidgetTester tester,
    List<ReplayDecision> decisions, {
    bool remote = false,
    Size size = const Size(1000, 800),
  }) async {
    await pumpAppScreen(
      tester,
      CustomScrollView(
        slivers: [
          RunDecisionsSliver(runId: 7, startedAt: startedAt, endedAt: endedAt),
        ],
      ),
      size: size,
      settle: false,
      extraOverrides: [
        if (remote) isRemoteModeProvider.overrideWithValue(true),
        decisionsForRunProvider(7)
            .overrideWith((ref) => Stream.value(decisions)),
      ],
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a decision written past the run end is reachable and counted',
      (tester) async {
    await pump(tester, [
      _decision(1, startedAt, 'Sequence started'),
      _decision(2, endedAt.add(const Duration(milliseconds: 120)),
          'Sequence completed'),
    ]);

    expect(find.text('2 of 2'), findsOneWidget);
    expect(find.text('Sequence started'), findsOneWidget);
    expect(find.text('Sequence completed'), findsOneWidget);
  });

  testWidgets('search narrows the list and the count follows', (tester) async {
    await pump(tester, [
      for (var i = 0; i < 5; i++)
        _decision(
            i + 1, startedAt.add(Duration(seconds: i * 3)), 'Decision $i'),
    ]);
    expect(find.text('5 of 5'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'decision 3');
    await tester.pump();

    expect(find.text('1 of 5'), findsOneWidget);
    expect(find.text('Decision 3'), findsOneWidget);
    expect(find.text('Decision 1'), findsNothing);

    await tester.tap(find.text('Clear filters'));
    await tester.pump();
    expect(find.text('5 of 5'), findsOneWidget);
  });

  testWidgets('a decision opens to its details and its frame', (tester) async {
    await pump(tester, [
      _decision(
        1,
        startedAt,
        'Rejected: trailed',
        category: DecisionCategory.frameRejected,
        details: const {'captured_image_id': 41, 'hfr': 6.2},
      ),
    ]);

    expect(find.text('Open frame'), findsNothing);
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is SkotiqIconButton && w.tooltip == 'Show details',
      ),
    );
    await tester.pump();

    expect(find.textContaining('"hfr": 6.2'), findsOneWidget);
    expect(find.text('Add note'), findsOneWidget);
    expect(find.text('Open frame'), findsOneWidget);
  });

  testWidgets('a run with no decisions says why', (tester) async {
    await pump(tester, const []);

    expect(find.text('No decisions recorded for this run'), findsOneWidget);
  });

  testWidgets('a linked client lists the host decisions', (tester) async {
    await pump(
      tester,
      [
        _decision(
          1,
          startedAt,
          'Selected M42 after altitude scoring',
          category: DecisionCategory.schedulerPick,
        ),
      ],
      remote: true,
    );

    expect(find.text('Selected M42 after altitude scoring'), findsOneWidget);
    expect(find.text('No decisions recorded for this run'), findsNothing);
  });

  testWidgets('at phone width a decision row fits', (tester) async {
    await pump(
      tester,
      [
        _decision(
          1,
          startedAt,
          'Selected M42 after altitude scoring and a long explanation of why',
          category: DecisionCategory.schedulerPick,
        ),
      ],
      size: const Size(390, 844),
    );

    expect(tester.takeException(), isNull);
  });
}
