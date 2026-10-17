// Widget tests for the session-handoff carry-over dialog.
//
// We exercise rendering and the basic decision-pick path. The dialog
// reads carry-over data from its constructor arg, so we don't need
// to spin up the DAO stack — just hand it a fixture list.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/session_handoff_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

SessionCarryOver _fake(int id, String name) {
  return SessionCarryOver(
    targetId: id,
    targetName: name,
    previousSessionId: 99,
    previousSessionStartedAt: DateTime(2026, 5, 17, 22),
    previousAcceptedFrames: 50,
    previousIntegrationSecs: 15000,
    campaignIntegrationSecs: 21600,
    budgetSecs: 43200,
    perFilterIntegrationSecs: const {'l': 10800, 'ha': 10800},
  );
}

Widget _harness(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      theme: ThemeData(
        extensions: const [SkotiqColors.dark],
      ),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('renders carry-over rows and default Resume decision',
      (tester) async {
    final co = _fake(1, 'M31');
    Map<int, SessionHandoffDecision>? captured;
    await tester.pumpWidget(_harness(
      SessionHandoffDialog(
        sequenceId: 7,
        carryOvers: [co],
        onDecisionsChosen: (m) => captured = m,
      ),
    ));
    await tester.pump();

    // Header
    expect(find.text('Resume from previous night?'), findsOneWidget);

    // Per-target tile shows the target name and the campaign total.
    expect(find.text('M31'), findsOneWidget);

    // Decision chips. The bulk row at the top of the dialog uses
    // "Resume all" / "Restart all" / "Continue new" labels (note the
    // asymmetry — Continue new has no "all" suffix), and each
    // per-target row repeats the bare "Resume" / "Restart" /
    // "Continue new" chip labels. So "Resume" and "Restart" appear
    // exactly once, but "Continue new" appears twice (once in the bulk
    // row, once in the per-target chip).
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);
    expect(find.text('Continue new'), findsNWidgets(2));

    // Confirm with default selection (Resume).
    await tester.tap(find.text('Confirm'));
    await tester.pump();

    expect(captured, isNotNull);
    expect(captured![1], SessionHandoffDecision.resume);
  });

  testWidgets('switching to Restart updates the decision map', (tester) async {
    final co = _fake(2, 'M42');
    Map<int, SessionHandoffDecision>? captured;
    await tester.pumpWidget(_harness(
      SessionHandoffDialog(
        sequenceId: 7,
        carryOvers: [co],
        onDecisionsChosen: (m) => captured = m,
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('Restart'));
    await tester.pump();
    await tester.tap(find.text('Confirm'));
    await tester.pump();

    expect(captured, isNotNull);
    expect(captured![2], SessionHandoffDecision.restart);
  });

  // A sub-minute carry-over rounded to "0m" makes the tile read "M31 has 0m
  // from the most recent session (4 accepted frames)" — four real frames on disk
  // described as no integration at all. The dialog shares
  // `formatIntegrationSeconds` with the Continue Session dialog and the
  // dashboard's run cards.
  testWidgets('a sub-minute carry-over is not reported as zero',
      (tester) async {
    final co = SessionCarryOver(
      targetId: 3,
      targetName: 'M13',
      previousSessionId: 99,
      previousSessionStartedAt: DateTime(2026, 5, 17, 22),
      previousAcceptedFrames: 4,
      previousIntegrationSecs: 12,
      campaignIntegrationSecs: 12,
      budgetSecs: 3600,
      perFilterIntegrationSecs: const {'l': 12},
    );
    await tester.pumpWidget(_harness(
      SessionHandoffDialog(
        sequenceId: 7,
        carryOvers: [co],
        onDecisionsChosen: (_) {},
      ),
    ));
    await tester.pump();

    String textAt(Finder f) => tester.widget<Text>(f).data ?? '';
    final tile = find.textContaining('from the most');
    expect(tile, findsOneWidget);
    expect(textAt(tile), contains('12s'));
    expect(
      textAt(tile),
      isNot(contains('0m')),
      reason: '4 accepted frames must never be described as 0 integration',
    );

    // The summary tiles and the per-filter chip read the same run.
    expect(find.text('12s'), findsWidgets);
    expect(find.text('0m'), findsNothing);
    expect(find.text('l: 12s'), findsOneWidget);
  });

  testWidgets('"Restart all" bulk button propagates to every target',
      (tester) async {
    final cos = [_fake(1, 'M31'), _fake(2, 'M42')];
    Map<int, SessionHandoffDecision>? captured;
    await tester.pumpWidget(_harness(
      SessionHandoffDialog(
        sequenceId: 7,
        carryOvers: cos,
        onDecisionsChosen: (m) => captured = m,
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('Restart all'));
    await tester.pump();
    await tester.tap(find.text('Confirm'));
    await tester.pump();

    expect(captured![1], SessionHandoffDecision.restart);
    expect(captured![2], SessionHandoffDecision.restart);
  });
}
