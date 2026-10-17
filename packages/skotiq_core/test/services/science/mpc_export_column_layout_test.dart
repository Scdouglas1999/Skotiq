// Column-layout cover for the MPC 80-column optical-observation export.
//
// The MPC optical format (https://www.minorplanetcenter.net/iau/info/
// OpticalObs.html) puts the OBSERVATION TYPE in Note 2 (column 15); Note 1
// (column 14) is a program/publication note. Putting 'C' in column 14 and a
// blank in column 15 sends every record to the MPC with no observation type at
// all and a non-standard Note 1 — a malformed submission the 80-character
// length check cannot catch.

import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/src/database/database.dart'
    show MovingObjectCandidateRow;
import 'package:skotiq_core/src/services/science/mpc_export_service.dart';

MovingObjectCandidateRow _row({
  String candidateId = 'cand-1',
  double raDegrees = 187.5,
  double decDegrees = 12.25,
  double? magnitude = 18.5,
  String? magnitudeBand = 'V',
  DateTime? timestamp,
}) {
  return MovingObjectCandidateRow(
    id: 1,
    candidateId: candidateId,
    raDegrees: raDegrees,
    decDegrees: decDegrees,
    motionArcsecPerMinute: 0.8,
    positionAngleDegrees: 95.0,
    confidence: 0.9,
    isKnownObject: false,
    source: 'test',
    magnitude: magnitude,
    magnitudeBand: magnitudeBand,
    timestamp: timestamp ?? DateTime.utc(2026, 3, 14, 6, 30),
  );
}

void main() {
  final service = MpcExportService();

  String singleLine(MovingObjectCandidateRow row) {
    final report = service.generateReport(
      candidates: [row],
      observatoryCode: 'G40',
    );
    final lines = report
        .split('\n')
        .where((l) => l.isNotEmpty)
        .toList(growable: false);
    expect(lines, hasLength(1));
    return lines.single;
  }

  group('MPC 80-column note placement', () {
    test('the CCD observation type is in column 15, not column 14', () {
      final line = singleLine(_row());

      expect(line.length, 80);
      // 0-indexed: column 14 is index 13, column 15 is index 14.
      expect(
        line[13],
        ' ',
        reason:
            'column 14 is Note 1 (program/publication note), not the '
            'observation type',
      );
      expect(
        line[14],
        'C',
        reason: 'column 15 is Note 2 — the observation type the MPC reads',
      );
    });

    test('the surrounding fields are undisturbed by the swap', () {
      final line = singleLine(_row());

      // Columns 1-5 minor planet number (blank), 6-12 designation,
      // 13 discovery asterisk (blank for follow-up).
      expect(line.substring(0, 5), '     ');
      expect(line[12], ' ');
      // Columns 16-32: date. First four characters are the year.
      expect(line.substring(15, 19), '2026');
      // Columns 78-80: observatory code.
      expect(line.substring(77, 80), 'G40');
    });

    test('an astrometry-only row keeps the type code in column 15', () {
      final line = singleLine(_row(magnitude: null, magnitudeBand: null));

      expect(line.length, 80);
      expect(line[13], ' ');
      expect(line[14], 'C');
      // Magnitude (66-70) and band (71) stay blank, which MPC allows.
      expect(line.substring(65, 71), '      ');
    });
  });
}
