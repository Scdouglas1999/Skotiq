// FrameGradeRules unit tests. The dialog itself (sliders, list, etc.)
// is exercised via integration; here we lock the *grading* logic itself
// so reject reasons cannot regress silently — that's how SGP's grader
// shipped a bug that flipped FWHM sign on rejection reasons for two
// versions before anyone noticed.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as drift
    show CapturedImage;

drift.CapturedImage _frame({
  int id = 1,
  double? hfr,
  int? starCount,
  double? guidingRmsTotal,
}) {
  final ts = DateTime.parse('2025-01-01T20:00:00.000Z');
  return drift.CapturedImage(
    id: id,
    filePath: '/tmp/$id.fits',
    fileName: '$id.fits',
    fileFormat: 'fits',
    frameType: 'light',
    exposureDuration: 60.0,
    binX: 1,
    binY: 1,
    isPlateSolved: true,
    capturedAt: ts,
    createdAt: ts,
    isAccepted: true,
    hfr: hfr,
    starCount: starCount,
    guidingRmsTotal: guidingRmsTotal,
  );
}

void main() {
  test('empty rules accept every frame', () {
    const rules = FrameGradeRules();
    expect(rules.isEmpty, isTrue);
    expect(rules.gradeFrame(_frame(hfr: 3.5, starCount: 5)), isNull);
  });

  test('HFR rule rejects frames above the cap and not below', () {
    const rules = FrameGradeRules(maxHfr: 2.5);
    expect(rules.gradeFrame(_frame(hfr: 1.8)), isNull);
    expect(rules.gradeFrame(_frame(hfr: 3.2)), contains('HFR'));
    expect(rules.gradeFrame(_frame(hfr: 3.2)), contains('2.50'));
    // A frame with no HFR is ambiguous — we keep it (a real test should
    // surface the missing metric rather than guess).
    expect(rules.gradeFrame(_frame(hfr: null)), isNull);
  });

  test('minStars rule rejects frames below the floor', () {
    const rules = FrameGradeRules(minStars: 30);
    expect(rules.gradeFrame(_frame(starCount: 50)), isNull);
    expect(rules.gradeFrame(_frame(starCount: 12)), contains('Stars 12 < 30'));
  });

  test('multiple failing rules concatenate into one rejection note', () {
    const rules = FrameGradeRules(maxHfr: 2.0, minStars: 80);
    final note = rules.gradeFrame(_frame(hfr: 3.5, starCount: 12));
    expect(note, isNotNull);
    expect(note, contains('HFR'));
    expect(note, contains('Stars'));
    expect(note, startsWith('Auto-grade:'));
  });

  test('guiding RMS rule rejects loose guiding only', () {
    const rules = FrameGradeRules(maxGuidingRmsTotalArcsec: 1.0);
    expect(rules.gradeFrame(_frame(guidingRmsTotal: 0.6)), isNull);
    expect(
      rules.gradeFrame(_frame(guidingRmsTotal: 1.6)),
      allOf(contains('Guiding'), contains('1.60')),
    );
  });

  test('copyWith clear flags wipe individual rules', () {
    const base = FrameGradeRules(maxHfr: 2.0, minStars: 40);
    final cleared = base.copyWith(clearHfr: true);
    expect(cleared.maxHfr, isNull);
    expect(cleared.minStars, 40);
  });
}
