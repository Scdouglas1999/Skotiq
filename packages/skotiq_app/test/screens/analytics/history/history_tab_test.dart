// Analytics > History is the one list of past nights: a session and the run
// that made it are one row, grouped by observing night, under the lifetime
// totals that used to be the Equipment tab.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/analytics_empty_state.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'history_app.dart';
import 'history_fixtures.dart';

const _desktop = Size(1400, 1200);
const _phone = Size(390, 844);

Readout _readout(WidgetTester tester, String label) => tester
    .widgetList<Readout>(find.byType(Readout))
    .firstWhere((r) => r.label?.toLowerCase() == label.toLowerCase());

void main() {
  final evening = DateTime(2026, 11, 3, 20, 21, 22);

  testWidgets('a run and its session are one row under their night',
      (tester) async {
    useWindow(tester, _desktop);
    final built = historyApp(
      sessions: [
        session(
          1,
          name: 'Rig run-through',
          start: evening,
          end: evening.add(const Duration(hours: 2, minutes: 32)),
          status: 'failed',
          exposures: 12,
          integration: 600,
          hfr: 2.11,
        ),
        session(
          2,
          name: 'Morning calibration',
          start: DateTime(2026, 11, 4, 5, 10),
          end: DateTime(2026, 11, 4, 5, 13),
          exposures: 3,
        ),
      ],
      runs: [
        run(9, name: 'Rig run-through', start: evening, status: 'failed'),
      ],
    );
    await tester.pumpWidget(built.app);
    await settle(tester);

    expect(find.text('Rig run-through'), findsOneWidget);
    expect(
      find.textContaining('NIGHT OF NOV 3 TO 4'),
      findsOneWidget,
      reason: 'the run after midnight belongs to the same observing night',
    );
    expect(find.text('2h 32m'), findsOneWidget);
    expect(find.text('2.11 px'), findsOneWidget);
    expect(find.text('10m'), findsOneWidget);
  });

  testWidgets('each status is named and toned once, the way runs are',
      (tester) async {
    useWindow(tester, _desktop);
    final built = historyApp(
      sessions: [
        session(1, name: 'Failed night', start: evening, status: 'failed'),
        session(
          2,
          name: 'Kept checkpoint',
          start: evening.add(const Duration(minutes: 1)),
          status: 'paused-stopped',
        ),
        session(
          3,
          name: 'Old error',
          start: evening.add(const Duration(minutes: 2)),
          status: 'error',
        ),
        session(
          4,
          name: 'Done',
          start: evening.add(const Duration(minutes: 3)),
        ),
      ],
    );
    await tester.pumpWidget(built.app);
    await settle(tester);

    ChipTone toneOf(String label) =>
        tester.widget<SkotiqChip>(find.widgetWithText(SkotiqChip, label)).tone;
    expect(toneOf('Failed'), ChipTone.error);
    expect(toneOf('Stopped (resumable)'), ChipTone.neutral);
    expect(toneOf('Error'), ChipTone.error);
    expect(toneOf('Completed'), ChipTone.success);
  });

  testWidgets(
      'a run cut off by a restart shows no elapsed time and is not '
      'listed as running', (tester) async {
    useWindow(tester, _desktop);
    final started = DateTime.now().subtract(const Duration(hours: 1));
    final built = historyApp(
      runs: [
        run(1, name: 'Cut off', start: started, status: 'interrupted'),
        run(2, name: 'Live', start: started, status: 'running'),
      ],
    );
    await tester.pumpWidget(built.app);
    await settle(tester);

    expect(find.widgetWithText(SkotiqChip, 'Interrupted'), findsOneWidget);
    expect(find.widgetWithText(SkotiqChip, 'Running'), findsOneWidget);
    expect(find.textContaining('1h'), findsNothing);
  });

  testWidgets('an unclosed session is timed to its last frame, not to now',
      (tester) async {
    useWindow(tester, _desktop);
    final start = DateTime(2026, 8, 13, 21);
    final built = historyApp(
      sessions: [session(3, name: 'Crashed', start: start, status: 'active')],
      images: [
        for (final minutes in [0, 10, 20])
          frame(
            minutes + 1,
            sessionId: 3,
            at: start.add(Duration(minutes: minutes)),
          ),
      ],
    );
    await tester.pumpWidget(built.app);
    await settle(tester);

    expect(find.text('20m'), findsOneWidget);
    expect(find.textContaining('20m to last frame'), findsOneWidget);
  });

  testWidgets('quick captures are a row in the night they were taken',
      (tester) async {
    useWindow(tester, _desktop);
    final built = historyApp(
      sessions: [session(1, name: 'New Sequence', start: evening)],
      standalone: [
        for (var i = 1; i <= 32; i++)
          frame(i, at: DateTime(2026, 11, 1, 21, i), exposure: 30),
      ],
    );
    await tester.pumpWidget(built.app);
    await settle(tester);

    expect(find.text('New Sequence'), findsOneWidget);
    expect(find.text('Quick captures'), findsOneWidget);
    expect(find.text('32'), findsOneWidget);
    expect(find.text('16m'), findsOneWidget);
  });

  testWidgets('quick captures alone do not read as an empty history',
      (tester) async {
    useWindow(tester, _desktop);
    final built =
        historyApp(standalone: [frame(1, at: DateTime(2026, 11, 1, 21))]);
    await tester.pumpWidget(built.app);
    await settle(tester);

    expect(find.byType(AnalyticsEmptyState), findsNothing);
    expect(find.text('Quick captures'), findsOneWidget);
  });

  testWidgets('with nothing on record the page says so and shows no toolbar',
      (tester) async {
    useWindow(tester, _desktop);
    await tester.pumpWidget(historyApp().app);
    await settle(tester);

    expect(find.text('No nights recorded yet'), findsOneWidget);
    expect(find.byType(SkotiqSearchField), findsNothing);
    expect(find.byType(SkotiqFilterChip), findsNothing);
    expect(find.byType(Readout), findsNothing);
  });

  testWidgets('a history that failed to load offers Retry', (tester) async {
    useWindow(tester, _desktop);
    final built = historyApp(
      sessionStream: Stream.error(StateError('session database unavailable')),
    );
    await tester.pumpWidget(built.app);
    await settle(tester);

    expect(find.text('History did not load'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('the totals count what the equipment did over every night',
      (tester) async {
    useWindow(tester, _desktop);
    final at = DateTime(2026, 7, 14, 22);
    final built = historyApp(
      sessions: [
        session(1, name: 'A', start: at, autofocus: 2),
        session(2,
            name: 'B', start: at.add(const Duration(days: 1)), autofocus: 3),
      ],
      runs: [
        run(1, name: 'A', start: at, stats: {'meridianFlips': 2}),
      ],
      images: [
        frame(1,
            sessionId: 1,
            at: at,
            exposure: 3600,
            temperature: -10,
            hfr: 2,
            rms: 0.8),
        frame(2,
            sessionId: 1,
            at: at,
            accepted: false,
            exposure: 120,
            temperature: -5,
            hfr: 10,
            rms: 4),
        frame(3,
            sessionId: 1, at: at, type: 'flat', exposure: 2, temperature: 0),
      ],
    );
    await tester.pumpWidget(built.app);
    await settle(tester);

    expect(_readout(tester, 'Exposures').value, '3');
    expect(_readout(tester, 'Accepted integration').value, '1h');
    expect(_readout(tester, 'Meridian flips').value, '2');
    expect(_readout(tester, 'Autofocus runs').value, '5');
    expect(_readout(tester, 'Avg HFR').value, '2.00');
    final rms = _readout(tester, 'Avg guiding RMS');
    expect(rms.value, '0.80');
    expect(rms.unit, '"');
    final temperature = _readout(tester, 'Avg sensor temp');
    expect(temperature.value, '-5.0');
    expect(temperature.unit, '°C');
  });

  testWidgets('a filter that matches nothing can be cleared in place',
      (tester) async {
    useWindow(tester, _desktop);
    final built = historyApp(
      sessions: [session(1, name: 'M74 Plan', start: evening)],
    );
    await tester.pumpWidget(built.app);
    await settle(tester);

    await tester.enterText(find.byType(EditableText), 'andromeda');
    await settle(tester);
    expect(find.text('M74 Plan'), findsNothing);
    expect(find.text('No nights match'), findsOneWidget);

    await tester.tap(find.text('Clear filters'));
    await settle(tester);
    expect(find.text('M74 Plan'), findsOneWidget);
  });

  testWidgets('the status filter narrows the list from its menu',
      (tester) async {
    useWindow(tester, _desktop);
    final built = historyApp(
      sessions: [
        session(1, name: 'Good night', start: evening),
        session(
          2,
          name: 'Bad night',
          start: evening.add(const Duration(minutes: 5)),
          status: 'failed',
        ),
      ],
    );
    await tester.pumpWidget(built.app);
    await settle(tester);

    await tester.tap(find.text('Status: any'));
    await settle(tester);
    await tester.tap(find.text('Failed').last);
    await settle(tester);

    expect(find.text('Bad night'), findsOneWidget);
    expect(find.text('Good night'), findsNothing);
  });

  testWidgets('a link from Saved lists one sequence and can be widened',
      (tester) async {
    useWindow(tester, _desktop);
    final built = historyApp(
      location: '/analytics?tab=history&sequence=23',
      sessions: [
        session(1, name: 'Mine', start: evening, sequenceId: 23),
        session(
          2,
          name: 'Other',
          start: evening.add(const Duration(minutes: 5)),
          sequenceId: 4,
        ),
      ],
    );
    await tester.pumpWidget(built.app);
    await settle(tester);

    expect(find.text('Mine'), findsOneWidget);
    expect(find.text('Other'), findsNothing);

    await tester.tap(find.text('One sequence'));
    await settle(tester);
    expect(find.text('Other'), findsOneWidget);
    expect(
      built.router.routerDelegate.currentConfiguration.uri.toString(),
      '/analytics?tab=history',
    );
  });

  testWidgets('a row opens its night as a page', (tester) async {
    useWindow(tester, _desktop);
    final built = historyApp(
      sessions: [session(7, name: 'M74 Plan', start: evening)],
    );
    await tester.pumpWidget(built.app);
    await settle(tester);

    await tester.tap(find.text('M74 Plan'));
    await settle(tester);

    expect(
      built.router.routerDelegate.currentConfiguration.uri.toString(),
      '/analytics?tab=history&night=7',
    );
    expect(find.text('Summary'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('at phone width a row keeps its name and fits', (tester) async {
    useWindow(tester, _phone);
    final built = historyApp(
      sessions: [
        session(
          1,
          name: 'Rig run-through NGC 7814 2026-11-03',
          start: evening,
          end: evening.add(const Duration(hours: 2, minutes: 32)),
          status: 'failed',
          exposures: 12,
          hfr: 2.11,
        ),
      ],
    );
    await tester.pumpWidget(built.app);
    await settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Rig run-through NGC 7814 2026-11-03'), findsOneWidget);
    expect(
      find.textContaining('Failed · 20:21 · 2h 32m · 12 fr · 2.11 px'),
      findsOneWidget,
    );
    // The name is on one line, not broken letter by letter.
    expect(
      tester.getSize(find.text('Rig run-through NGC 7814 2026-11-03')).height,
      lessThan(24),
    );
  });
}
