// ADES 2017 PSV export: the MPC's current format for optical astrometry,
// next to the legacy 80-column report.

import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/src/database/database.dart'
    show MovingObjectCandidateRow;
import 'package:skotiq_core/src/services/science/mpc_export_service.dart';

MovingObjectCandidateRow _row({
  required int id,
  required String candidateId,
  required DateTime timestamp,
  double raDegrees = 35.6377,
  double decDegrees = 42.3491,
  double? magnitude = 18.71,
  String? magnitudeBand = 'R',
}) => MovingObjectCandidateRow(
  id: id,
  candidateId: candidateId,
  raDegrees: raDegrees,
  decDegrees: decDegrees,
  motionArcsecPerMinute: 0.6,
  positionAngleDegrees: 250,
  confidence: 0.8,
  isKnownObject: false,
  source: 'local',
  magnitude: magnitude,
  magnitudeBand: magnitudeBand,
  timestamp: timestamp,
);

void main() {
  final service = MpcExportService();
  final t0 = DateTime.utc(2026, 10, 24, 1, 2, 3, 456);
  final rows = [
    _row(
      id: 2,
      candidateId: 'mo_a',
      timestamp: t0.add(const Duration(minutes: 2)),
    ),
    _row(id: 1, candidateId: 'mo_a', timestamp: t0),
    _row(
      id: 3,
      candidateId: 'mo_b',
      timestamp: t0.add(const Duration(minutes: 1)),
      decDegrees: -5.25,
      magnitude: null,
      magnitudeBand: null,
    ),
  ];

  List<String> lines(String report) =>
      report.split('\n').where((l) => l.isNotEmpty).toList();

  test('header blocks and one data row per observation, oldest first', () {
    final report = service.generateAdesPsv(
      candidates: rows,
      header: const AdesReportHeader(
        observatoryCode: 'X01',
        submitter: 'S. Douglas',
        observers: ['S. Douglas'],
        measurers: ['S. Douglas'],
        telescopeAperture: 0.2,
      ),
    );
    final l = lines(report);
    expect(l.first, '# version=2017');
    expect(l, contains('! mpcCode X01'));
    expect(l, contains('! aperture 0.200'));
    expect(l, contains('! detector CCD'));
    final headerRow = l.indexOf('trkSub|mode|stn|obsTime|ra|dec|astCat');
    expect(headerRow, greaterThan(0));
    final data = l.sublist(headerRow + 1);
    expect(data, hasLength(3));
    expect(
      data[0],
      'NS0001|CCD|X01|2026-10-24T01:02:03.46Z|35.637700|+42.349100|Gaia3',
    );
    // One tracklet keeps one trkSub; a different object gets its own.
    expect(data[1].split('|')[0], 'NS0002');
    expect(data[2].split('|')[0], 'NS0001');
    expect(data[1].split('|')[5], '-5.250000');
  });

  test(
    'magnitudes appear only with a photometric catalog, in the stored band',
    () {
      final report = service.generateAdesPsv(
        candidates: rows,
        header: const AdesReportHeader(observatoryCode: 'X01'),
        photCat: 'Gaia3',
      );
      final l = lines(report);
      expect(
        l,
        contains('trkSub|mode|stn|obsTime|ra|dec|astCat|mag|band|photCat'),
      );
      expect(l.last, endsWith('|18.71|R|Gaia3'));
      // The row without a magnitude leaves the photometry fields empty.
      expect(l.firstWhere((x) => x.contains('-5.250000')), endsWith('|||'));
    },
  );

  test('a wrong-length station code is refused', () {
    expect(
      () => service.generateAdesPsv(
        candidates: rows,
        header: const AdesReportHeader(observatoryCode: 'X1'),
      ),
      throwsArgumentError,
    );
  });
}
