import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart'
    as drift
    show CapturedImage;

drift.CapturedImage _light({int id = 1, double? hfr, bool accepted = true}) {
  final ts = DateTime(2026, 1, 1);
  return drift.CapturedImage(
    id: id,
    filePath: '/tmp/$id.fits',
    fileName: '$id.fits',
    fileFormat: 'fits',
    frameType: 'light',
    exposureDuration: 60,
    binX: 1,
    binY: 1,
    isPlateSolved: true,
    capturedAt: ts,
    createdAt: ts,
    isAccepted: accepted,
    hfr: hfr,
  );
}

void main() {
  test('conservativeDefaults rejects bloated HFR', () {
    const rules = FrameGradeRules.conservativeDefaults;
    expect(rules.gradeFrame(_light(hfr: 4.0)), isNotNull);
    expect(rules.gradeFrame(_light(hfr: 2.0)), isNull);
  });

  test('rules round-trip through JSON', () {
    const rules = FrameGradeRules(maxHfr: 2.8, minStars: 40);
    final restored = FrameGradeRules.fromJsonString(rules.toJsonString());
    expect(restored?.maxHfr, 2.8);
    expect(restored?.minStars, 40);
  });
}
