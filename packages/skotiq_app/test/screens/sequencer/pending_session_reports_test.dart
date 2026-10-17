// The Session Report must not appear as a modal once a minute all night.
//
// With the autopilot armed and its dispatched runs failing fast, every terminal
// run would open a MODAL Session Report plus a "How did this run go? / Write
// note" prompt over whatever screen the operator is on, each one swallowing the
// click aimed at the app underneath.
//
// Two halves are pinned here:
//   1. the sequencer screen asks `sessionReportPresentationProvider` BEFORE it
//      shows the dialog, and
//   2. the queue those reports go into is reachable — the toast says "open it
//      from Sequencer ▸ History", and this is the card that makes that true.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/pending_session_reports_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

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
    expect(find.textContaining('session report'), findsNothing);
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

    expect(
      find.text('2 session reports from unattended imaging'),
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

  // Structural guard: the gate has to be consulted at the ONE place the modal
  // is opened. A widget test of the whole sequencer screen cannot be built
  // cheaply, and the failure mode being guarded is someone restoring the
  // unconditional `SessionReportDialog.show` above it.
  test('the terminal-run listener consults the presentation gate first', () {
    final source = File(
      'lib/screens/sequencer/sequencer_screen.dart',
    ).readAsStringSync();
    final listener = source.substring(
      source.indexOf('ref.listenManual<SequenceTerminalRunResult?>'),
      source.indexOf('SessionReportDialog.show(context, sessionId'),
    );
    expect(listener, contains('sessionReportPresentationProvider'));
    expect(listener, contains('SessionReportPresentation.queued'));
    expect(listener, contains('pendingSessionReportsProvider'));
  });
}
