// The Session Report must not appear as a modal once a minute all night.
//
// With the autopilot armed and its dispatched runs failing fast, every terminal
// run would open a MODAL Session Report plus a "How did this run go? / Write
// note" prompt over whatever screen the operator is on, each one swallowing the
// click aimed at the app underneath.
//
// Two halves are pinned here:
//   1. an ending run the presentation gate calls unattended queues its report
//      and opens no dialog, and
//   2. the queue those reports go into is reachable — the toast says "open it
//      from Sequencer ▸ History", and this is the card that makes that true.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/pending_session_reports_card.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree/ledger_columns.dart';
import 'package:skotiq_app/screens/sequencer/widgets/session_report_dialog.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;
import '../../harness/pump_app_screen.dart';

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: SingleChildScrollView(child: PendingSessionReportsCard()),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a hand-driven night never sees the queue card', (tester) async {
    final container = ProviderContainer(
      overrides: [inMemoryDatabaseOverride()],
    );
    addTearDown(container.dispose);

    await _pump(tester, container);

    expect(find.byType(PendingSessionReportsCard), findsOneWidget);
    expect(find.textContaining('SESSION REPORT'), findsNothing);
  });

  testWidgets('queued reports are listed and openable', (tester) async {
    final container = ProviderContainer(
      overrides: [inMemoryDatabaseOverride()],
    );
    addTearDown(container.dispose);
    final notifier = container.read(pendingSessionReportsProvider.notifier);
    notifier.enqueue(
      PendingSessionReport(
        sessionId: 1,
        runId: 11,
        endedAt: DateTime(2026, 8, 14, 0, 6, 13),
      ),
    );
    notifier.enqueue(
      PendingSessionReport(
        sessionId: 2,
        runId: 12,
        endedAt: DateTime(2026, 8, 14, 0, 6, 53),
      ),
    );

    await _pump(tester, container);

    // The count is the panel's head, which renders uppercase.
    expect(
      find.text('2 SESSION REPORTS FROM UNATTENDED IMAGING'),
      findsOneWidget,
    );
    expect(find.text('Open report'), findsNWidgets(2));
    // Newest first — the last run of the night is the one being asked about.
    expect(find.text('Finished 00:06'), findsNWidgets(2));
  });

  testWidgets('Dismiss all empties the queue', (tester) async {
    final container = ProviderContainer(
      overrides: [inMemoryDatabaseOverride()],
    );
    addTearDown(container.dispose);
    container.read(pendingSessionReportsProvider.notifier).enqueue(
          PendingSessionReport(
            sessionId: 1,
            runId: 11,
            endedAt: DateTime(2026, 8, 14, 0, 6, 13),
          ),
        );

    await _pump(tester, container);
    await tester.tap(find.text('Dismiss all'));
    await tester.pump();

    expect(container.read(pendingSessionReportsProvider), isEmpty);
    expect(find.text('Open report'), findsNothing);
  });

  testWidgets(
      'an unattended run that ends queues its report instead of a modal',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const SequencerScreen(),
      size: const Size(1600, 900),
      extraOverrides: [
        sessionReportPresentationProvider
            .overrideWithValue(SessionReportPresentation.queued),
        // The ETA column's wall clock would leave a periodic timer behind.
        ledgerClockProvider
            .overrideWith((ref) => const Stream<DateTime>.empty()),
      ],
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 600));

    handle.container.read(runRecordProvider.notifier).seed(
          (record) => record.copyWith(
            terminal: const SequenceTerminalRunResult(
              generation: 1,
              outcome: SequenceExecutionState.failed,
              runStatus: SequenceRunStatus.failed,
              runId: 11,
              dbSessionId: 7,
            ),
          ),
        );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final queued = handle.container.read(pendingSessionReportsProvider);
    expect(queued.map((r) => (r.sessionId, r.runId)), [(7, 11)]);
    expect(find.byType(SessionReportDialog), findsNothing,
        reason: 'no modal over the screen the operator is on');
    expect(find.byType(Dialog), findsNothing);
  });
}
