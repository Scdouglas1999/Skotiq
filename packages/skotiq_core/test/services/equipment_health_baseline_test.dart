import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart' show ImagingSession;
import 'package:skotiq_core/src/services/equipment_health_service.dart';

/// A user with too little history must not be told their rig is degrading.
///
/// `analyze()` compares the last 5 sessions against sessions 6..15. For anyone
/// with five or fewer sessions that baseline is EMPTY, and a clamped mean of
/// nothing is a floor value (0.1 arcsec guiding, 0.1 px HFR) that any real rig
/// beats by a factor of five — firing both degradation triggers on a first
/// night and quoting a concrete multiple derived from no data.
ImagingSession _session(int id, {double? guiding, double? hfr}) =>
    ImagingSession(
      id: id,
      startTime: DateTime.utc(2026, 8, 1).subtract(Duration(days: id)),
      avgGuidingRms: guiding,
      avgHfr: hfr,
      // No failures: the only thing under test is the baseline comparison, so
      // nothing else may deduct from the score.
      totalExposures: 20,
      successfulExposures: 20,
      failedExposures: 0,
      totalIntegrationSecs: 1800,
      autofocusCount: 1,
      status: 'completed',
    );

void main() {
  const service = EquipmentHealthService();

  group('no baseline history', () {
    test('five sessions produce no degradation insights and no deduction', () {
      final sessions = [
        _session(1, guiding: 0.65, hfr: 2.90),
        _session(2, guiding: 1.10, hfr: 4.20),
        _session(3, guiding: 0.70, hfr: 3.00),
        _session(4, guiding: 0.55, hfr: 2.50),
        _session(5, guiding: 0.60, hfr: 2.20),
      ];

      final report = service.analyze(
        sessions: sessions,
        deviceHealth: const [],
      );

      expect(
        report.insights.map((i) => i.title),
        isNot(contains('Guiding degradation')),
        reason: 'there is no history to have degraded from',
      );
      expect(
        report.insights.map((i) => i.title),
        isNot(contains('Focus quality drift')),
      );
      expect(
        report.score,
        100.0,
        reason: 'nothing measurable went wrong, so nothing may be deducted',
      );
    });
  });

  group('with baseline history', () {
    test('genuine guiding degradation is still reported', () {
      // 5 recent sessions at ~2.0 arcsec against 10 older ones at ~0.6 —
      // a real 3.3x degradation, which must still fire.
      final sessions = <ImagingSession>[
        for (var i = 1; i <= 5; i++) _session(i, guiding: 2.0, hfr: 3.0),
        for (var i = 6; i <= 15; i++) _session(i, guiding: 0.6, hfr: 2.9),
      ];

      final report = service.analyze(
        sessions: sessions,
        deviceHealth: const [],
      );

      expect(
        report.insights.map((i) => i.title),
        contains('Guiding degradation'),
        reason: 'a real regression against real history must still be caught',
      );
      expect(report.score, lessThan(100.0));
    });
  });
}
