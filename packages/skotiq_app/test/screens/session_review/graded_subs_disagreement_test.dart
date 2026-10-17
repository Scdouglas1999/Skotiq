// The Night Doctor must not report "no problems detected" on a night whose every
// sub the same screen badges POOR.
//
// Advisory badges never changing ACCEPTANCE is documented policy; a perfect
// score with zero findings on a night where every frame graded POOR is a
// different claim, and a false one.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/narrative_view.dart';
import 'package:skotiq_core/skotiq_core.dart';

DbCapturedImage _sub(int id,
        {required double hfr, double? qualityScore, int starCount = 400}) =>
    DbCapturedImage(
      id: id,
      filePath: '/tmp/$id.fits',
      fileName: '$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 3,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 8, 13, 18, 45),
      createdAt: DateTime.utc(2026, 8, 13, 18, 45),
      isAccepted: true,
      isPlateSolved: false,
      hfr: hfr,
      starCount: starCount,
      qualityScore: qualityScore,
    );

NightReport _clean() => NightReport(
      sessionId: 1,
      score: 100,
      headline: 'A clean night — no problems detected.',
      findings: const [],
      createdAt: DateTime.utc(2026, 8, 13, 19),
    );

void main() {
  test('a clean verdict over four POOR subs is contradicted out loud', () {
    final subs = [
      for (var i = 1; i <= 4; i++)
        _sub(i, hfr: 5.7, qualityScore: 12, starCount: 39),
    ];

    final message = gradedSubsDisagreementMessage(subs: subs, report: _clean());

    expect(
      message,
      isNotNull,
      reason: 'the screen reported 100/100 with 0 findings while badging every '
          'one of these subs POOR',
    );
    expect(message, contains('all 4 subs POOR'));
    expect(message, contains('5.7'));
    expect(message, contains('Workbench'));
  });

  test('a clean verdict over good subs says nothing', () {
    final subs = [
      for (var i = 1; i <= 4; i++) _sub(i, hfr: 2.1, qualityScore: 92),
    ];

    expect(gradedSubsDisagreementMessage(subs: subs, report: _clean()), isNull);
  });

  test('a verdict that already lists findings is not second-guessed', () {
    final subs = [
      for (var i = 1; i <= 4; i++)
        _sub(i, hfr: 5.7, qualityScore: 12, starCount: 39),
    ];
    final report = NightReport(
      sessionId: 1,
      score: 62,
      headline: 'Focus drifted.',
      findings: const [
        NightFinding(
          id: 'focus-drift',
          severity: NightFindingSeverity.warn,
          title: 'Focus drift',
          explanation: 'HFR climbed through the run.',
        ),
      ],
      createdAt: DateTime.utc(2026, 8, 13, 19),
    );

    expect(gradedSubsDisagreementMessage(subs: subs, report: report), isNull);
  });

  test('an ungraded night is not second-guessed either', () {
    final subs = [
      for (var i = 1; i <= 4; i++)
        _sub(i, hfr: 5.7, qualityScore: 12, starCount: 39),
    ];
    final report = NightReport(
      sessionId: 1,
      score: NightReport.ungradedScore,
      headline: 'Not graded.',
      findings: const [],
      createdAt: DateTime.utc(2026, 8, 13, 19),
    );

    expect(gradedSubsDisagreementMessage(subs: subs, report: report), isNull);
  });
}
