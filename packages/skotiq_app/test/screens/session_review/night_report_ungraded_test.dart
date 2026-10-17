// The Night Doctor verdict must never invent a grade.
//
// Observed defect: a FAILED run with "0 accepted · 0 rejected", a 35-second
// dark-only run, and a stopped 1-frame run all rendered the identical card —
// green 100/100 ring, "Excellent", "A clean night — no problems detected." The
// score only ever subtracts penalties, so a night that produced nothing to
// analyse scored perfectly. These tests pin the honest rendering.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/widgets/night_report_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<void> _pumpPanel(WidgetTester tester, NightReport report) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: SkotiqColors.dark.background,
        body: SingleChildScrollView(
          child: NightReportPanel(report: report),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  final createdAt = DateTime.utc(2026, 7, 28, 6);

  testWidgets('an un-graded night shows "Not graded", no score, no grade word',
      (tester) async {
    await _pumpPanel(
      tester,
      NightReport.ungraded(
        sessionId: 7,
        headline:
            'Not graded — this session captured no light frames, so there '
            'is nothing to analyse.',
        createdAt: createdAt,
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Not graded'), findsOneWidget);
    expect(find.text('not graded'), findsOneWidget); // ring caption
    // No number, and none of the flattering grade words.
    expect(find.text('100'), findsNothing);
    expect(find.text('/ 100'), findsNothing);
    expect(find.text('Excellent'), findsNothing);
    expect(find.text('Good'), findsNothing);
    // The reason is on screen.
    expect(
      find.textContaining('captured no light frames'),
      findsOneWidget,
    );
    // And it must NOT claim the night was checked and clean.
    expect(find.textContaining('No problems'), findsNothing);
    expect(find.textContaining('clean night'), findsNothing);
    // "0 findings" would imply the detectors ran and came back clean.
    expect(find.text('0 findings'), findsNothing);
    expect(find.text('nothing to analyse'), findsOneWidget);
  });

  testWidgets('a genuinely clean graded night still shows 100 / Excellent',
      (tester) async {
    await _pumpPanel(
      tester,
      NightReport(
        sessionId: 7,
        score: 100,
        headline: 'A clean night — no problems detected.',
        createdAt: createdAt,
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('100'), findsOneWidget);
    expect(find.text('/ 100'), findsOneWidget);
    expect(find.text('Excellent'), findsOneWidget);
    expect(find.text('Not graded'), findsNothing);
  });

  test('the un-graded flag survives the score-column round trip', () {
    final report = NightReport.ungraded(
      headline: 'Not graded — nothing to analyse.',
      createdAt: createdAt,
    );
    expect(report.graded, isFalse);
    expect(report.score, NightReport.ungradedScore);
    // toJson/fromJson is the wire the persisted row and any remote payload use.
    final decoded = NightReport.fromJson(report.toJson());
    expect(decoded.graded, isFalse);
    expect(decoded.headline, report.headline);
    // A blob with no score at all is un-graded, not a real zero.
    expect(
      NightReport.fromJson(
          {'headline': 'x', 'createdAt': '2026-07-28T06:00:00Z'}).graded,
      isFalse,
    );
  });
}
