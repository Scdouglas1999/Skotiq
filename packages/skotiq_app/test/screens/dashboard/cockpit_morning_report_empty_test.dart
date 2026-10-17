// Ticking "Morning Report" in the dashboard widget picker has to produce a
// tile. The widget returned SizedBox.shrink() with no completed runs, so on a
// fresh profile the checkbox read as a broken toggle: no tile appeared anywhere
// in either column.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/cockpit_morning_report.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _app(List<SequenceRun> runs) {
  return ProviderScope(
    overrides: [
      sequenceRunsProvider.overrideWith((ref) => Stream.value(runs)),
      sequenceRunSessionIdProvider.overrideWith((ref, runId) async => null),
    ],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: const Scaffold(body: CockpitMorningReport()),
    ),
  );
}

void main() {
  testWidgets('renders an empty state instead of vanishing', (tester) async {
    await tester.pumpWidget(_app(const []));
    await tester.pump();

    expect(find.byType(SizedBox), findsWidgets); // spacing only
    expect(find.text('No completed runs yet'), findsOneWidget);
    expect(
      find.textContaining('accepted and rejected frame counts'),
      findsOneWidget,
      reason: 'the tile must say what will appear here and when',
    );
  });

  testWidgets('still shows the report once a run has finished', (tester) async {
    await tester.pumpWidget(_app([
      SequenceRun(
        id: 41,
        sequenceId: 7,
        sequenceName: 'Rosette',
        startedAt: DateTime.utc(2026, 7, 14, 1),
        endedAt: DateTime.utc(2026, 7, 14, 5),
        status: 'completed',
        statsJson: '{"framesCaptured":12,"framesRejected":2}',
      ),
    ]));
    await tester.pump();

    expect(find.text('No completed runs yet'), findsNothing);
    expect(find.text('Rosette'), findsOneWidget);
  });
}
