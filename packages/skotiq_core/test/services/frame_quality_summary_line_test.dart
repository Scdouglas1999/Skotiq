// SCI-38: the frame inspector graded a frame "Good" and then printed a fault as
// the only reason — "Good — Low star count (39)" on every frame of a clean
// session. The assessor collects every observation it makes into `reasons`,
// including ones that never moved the verdict, and the UI joined them onto the
// label with an em dash, which reads as the reason FOR the grade.
//
// SCI-37: the same assessment carries two numbers that both get called "the
// score" — the recorded `quality_score` and the assessor's `advisoryScore`,
// which is that score minus review penalties. They must be nameable apart.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show FrameQualityAssessmentService, FrameQualityLevel;
import 'package:skotiq_core/src/database/database.dart' show CapturedImage;

CapturedImage _frame({double? hfr, int? starCount, double? qualityScore}) =>
    CapturedImage(
      id: 1,
      filePath: '/lights/l1.fits',
      fileName: 'l1.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 3,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 8, 13, 9),
      createdAt: DateTime.utc(2026, 8, 13, 9),
      isAccepted: true,
      isPlateSolved: false,
      hfr: hfr,
      starCount: starCount,
      qualityScore: qualityScore,
    );

void main() {
  const assessor = FrameQualityAssessmentService();

  test('a Good frame does not present an observation as the grade reason', () {
    // The live shape: HFR 2.1 px, 39 stars, recorded quality score 85. The
    // low-star observation costs 10 points, which leaves 75 — comfortably
    // "Good" — yet the observation is still recorded.
    final assessment = assessor.assessFrame(
      _frame(hfr: 2.1, starCount: 39, qualityScore: 85),
    );

    expect(assessment.level, FrameQualityLevel.good);
    expect(assessment.reasons, contains('Low star count (39)'));
    expect(
      assessment.summaryLine,
      isNot('Good — Low star count (39)'),
      reason: 'the dash-clause reads as the reason for the verdict',
    );
    expect(assessment.summaryLine, startsWith('Good'));
    expect(assessment.summaryLine, contains('Low star count (39)'));
    expect(
      assessment.summaryLine,
      contains('not disqualifying'),
      reason: 'the observation must be marked as not having moved the verdict',
    );
  });

  test('a demoted frame still states its observations as the reason', () {
    final assessment = assessor.assessFrame(
      _frame(hfr: 5.0, starCount: 200, qualityScore: 85),
    );

    expect(assessment.level, FrameQualityLevel.poor);
    expect(assessment.summaryLine, startsWith('Poor — '));
    expect(assessment.summaryLine, isNot(contains('not disqualifying')));
  });

  test('a clean frame with nothing to note is just its label', () {
    final assessment = assessor.assessFrame(
      _frame(hfr: 2.1, starCount: 200, qualityScore: 85),
    );

    expect(assessment.reasons, isEmpty);
    expect(assessment.summaryLine, 'Good');
  });

  test('the advisory score is named apart from the recorded quality score', () {
    final assessment = assessor.assessFrame(
      _frame(hfr: 2.1, starCount: 39, qualityScore: 85),
    );

    expect(assessment.advisoryScore, 75);
    expect(assessment.recordedQualityScore, 85);
    expect(
      assessment.scoreExplanation,
      contains('85'),
      reason:
          'the number the database keeps has to appear somewhere the user '
          'can see it next to the one on the tile',
    );
    expect(assessment.scoreExplanation, contains('75'));
  });

  test('an advisory score with no recorded score says where it started', () {
    final assessment = assessor.assessFrame(_frame(hfr: 2.1, starCount: 200));

    expect(assessment.recordedQualityScore, isNull);
    expect(assessment.scoreExplanation, contains('no recorded quality score'));
  });
}
