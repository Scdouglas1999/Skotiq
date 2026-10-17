import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/night_reports_dao.dart';
import 'package:skotiq_core/src/database/daos/science_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/night_report.dart';
import 'package:skotiq_core/src/services/night_analysis_service.dart';

/// A run whose every sub the app itself grades POOR must not score 100 / 100
/// with no findings: every session-level detector looks for a *change* over the
/// night, and a night that is uniformly bad has no change in it.
///
/// The fixture numbers (HFR 5.69–5.74, quality_score 35.3–35.4, against
/// 2.19–2.22 / 84 for the quick captures) come from a real run.
// analyze() is pure over NightData; the DAOs are never queried, so one
// never-used in-memory DB underneath them is enough — and sharing it avoids
// drift's "multiple databases" warning.
final SkotiqDatabase _db = SkotiqDatabase.forTesting(
  NativeDatabase.memory(),
);

NightAnalysisService _pureService() {
  final db = _db;
  return NightAnalysisService(
    images: db.imagesDao,
    science: ScienceDao(db),
    reports: NightReportsDao(db),
    clock: () => DateTime.utc(2026, 8, 14, 6),
  );
}

NightSub _sub(int id, {required double hfr, required double qualityScore}) =>
    NightSub(
      id: id,
      capturedAt: DateTime.utc(
        2026,
        8,
        13,
        20,
        53,
        44,
      ).add(Duration(seconds: 4 * id)),
      hfr: hfr,
      starCount: 400,
      qualityScore: qualityScore,
    );

void main() {
  test('a night the frame grader marks all-POOR is not scored 100/100', () {
    final data = NightData([
      _sub(13, hfr: 5.69, qualityScore: 35.26),
      _sub(14, hfr: 5.74, qualityScore: 35.42),
      _sub(15, hfr: 5.70, qualityScore: 35.31),
      _sub(16, hfr: 5.72, qualityScore: 35.38),
    ]);

    final report = _pureService().analyze(data, sessionId: 1);

    expect(report.graded, isTrue, reason: 'four measured subs are gradable');
    expect(
      report.findings.map((f) => f.id),
      contains('frames_graded_poor'),
      reason: 'the grader verdict the Workbench shows must reach the verdict',
    );
    expect(report.score, lessThan(100));
    expect(report.headline, isNot(contains('clean night')));
    final finding = report.findings.firstWhere(
      (f) => f.id == 'frames_graded_poor',
    );
    expect(finding.severity, NightFindingSeverity.critical);
    expect(finding.evidenceSubIds, [13, 14, 15, 16]);
  });

  test('a night of good subs keeps its clean verdict', () {
    final data = NightData([
      _sub(1, hfr: 2.19, qualityScore: 84),
      _sub(2, hfr: 2.22, qualityScore: 84),
      _sub(3, hfr: 2.20, qualityScore: 85),
      _sub(4, hfr: 2.21, qualityScore: 84),
    ]);

    final report = _pureService().analyze(data, sessionId: 1);

    expect(report.findings, isEmpty);
    expect(report.score, 100);
    expect(report.headline, contains('clean night'));
  });

  test('a single POOR sub in a good night is not a night-level failure', () {
    final data = NightData([
      _sub(1, hfr: 2.19, qualityScore: 84),
      _sub(2, hfr: 2.22, qualityScore: 84),
      _sub(3, hfr: 2.20, qualityScore: 85),
      _sub(4, hfr: 5.90, qualityScore: 34),
    ]);

    final report = _pureService().analyze(data, sessionId: 1);

    expect(
      report.findings.map((f) => f.id),
      isNot(contains('frames_graded_poor')),
    );
  });
}
