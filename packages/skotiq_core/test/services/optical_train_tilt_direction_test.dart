// Does the optical-train diagnostic point at the right edge of the frame?
//
// A tilt readout sends the user to a specific adjustment screw, so pointing at
// the wrong edge is worse than saying nothing. Each case below plants a PSF
// gradient whose steepest direction is known by construction.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// 3x3 tile grid whose HFR rises along [angleDeg], measured from +x (right)
/// towards +y (increasing tileRow, i.e. downwards in image order).
List<PsfFieldTileRow> _tiltedTiles({
  required double angleDeg,
  double gradientPx = 0.55,
  double baseHfr = 2.0,
}) {
  final c = math.cos(angleDeg * math.pi / 180.0);
  final s = math.sin(angleDeg * math.pi / 180.0);
  final tiles = <PsfFieldTileRow>[];
  var id = 0;
  for (var row = 0; row < 3; row++) {
    for (var col = 0; col < 3; col++) {
      final proj = (col - 1) * c + (row - 1) * s;
      final hfr = baseHfr + gradientPx * proj / math.sqrt2;
      tiles.add(
        PsfFieldTileRow(
          id: id++,
          capturedImageId: 1,
          sessionId: 1,
          tileRow: row,
          tileCol: col,
          starCount: 200,
          medianFwhm: hfr * 2.68,
          medianHfr: hfr,
          medianEccentricity: 0.3,
          roundness: 0.95,
          timestamp: DateTime.utc(2026, 7, 28),
        ),
      );
    }
  }
  return tiles;
}

void main() {
  const service = OpticalTrainDiagnosticsService();

  OpticalTrainDiagnostics run(double angleDeg) => service.analyze(
    psfTiles: _tiltedTiles(angleDeg: angleDeg),
    residualVectors: const [],
  );

  // angle -> the edge the gradient actually points at.
  final cases = <double, String>{
    0.0: 'right edge',
    90.0: 'bottom edge',
    180.0: 'left edge',
    270.0: 'top edge',
  };

  cases.forEach((angle, expected) {
    test('a gradient at $angle deg is reported as the $expected', () {
      final result = run(angle);
      expect(
        result.dominantTiltDirection,
        expected,
        reason:
            'gradient points at $expected, '
            'service said ${result.dominantTiltDirection}',
      );
    });
  });

  test('a mostly-vertical diagonal is not reported as a horizontal edge', () {
    // 118 deg: the vertical component (sin = 0.883) is nearly twice the
    // horizontal (|cos| = 0.469), so the worst edge is the bottom.
    final result = run(118.0);
    expect(
      result.dominantTiltDirection,
      'bottom edge',
      reason:
          'vertical component dominates; service said '
          '${result.dominantTiltDirection}',
    );
  });
}
