import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Tilt, field curvature and collimation measured on PSF tiles and residual
/// vectors as the science pipeline stores them: star-less tiles with a star
/// size of 0, and residual positions in pixels.
void main() {
  const service = OpticalTrainDiagnosticsService();

  /// (row, col, stars, median HFR px) for a 4x6 grid.
  List<PsfFieldTileRow> tiles(List<(int, int, int, double)> rows) => [
    for (final (row, col, stars, hfr) in rows)
      PsfFieldTileRow(
        id: row * 6 + col,
        capturedImageId: 1,
        tileRow: row,
        tileCol: col,
        starCount: stars,
        medianFwhm: hfr * 2,
        medianHfr: hfr,
        medianEccentricity: stars == 0 ? 0 : 0.55,
        roundness: stars == 0 ? 0 : 0.45,
        timestamp: DateTime.utc(2026, 10, 26, 9),
      ),
  ];

  // M67_R_0001 (2026-10-26, 60 s R), the frame behind a "tilt score 25"
  // narrator card: the top-left tile holds no stars and the left column is
  // sparse; the field is softer in every corner than in the middle.
  final m67R0001 = tiles([
    (0, 0, 0, 0.0), (0, 1, 19, 2.892), (0, 2, 29, 2.602), //
    (0, 3, 42, 2.551), (0, 4, 26, 2.645), (0, 5, 12, 3.176),
    (1, 0, 5, 2.981), (1, 1, 31, 2.524), (1, 2, 118, 2.389),
    (1, 3, 119, 2.352), (1, 4, 41, 2.487), (1, 5, 17, 3.036),
    (2, 0, 2, 2.544), (2, 1, 49, 2.495), (2, 2, 152, 2.354),
    (2, 3, 125, 2.354), (2, 4, 61, 2.495), (2, 5, 22, 3.019),
    (3, 0, 2, 2.607), (3, 1, 13, 2.755), (3, 2, 38, 2.511),
    (3, 3, 44, 2.596), (3, 4, 33, 2.888), (3, 5, 9, 3.26),
  ]);

  // NGC0891_L_0002 (2026-10-22, 90 s L): every tile has stars; the corners
  // are about 20% larger than the inner field, with no side-to-side tilt.
  final ngc891L0002 = tiles([
    (0, 0, 10, 2.757), (0, 1, 22, 2.371), (0, 2, 29, 2.279), //
    (0, 3, 28, 2.334), (0, 4, 19, 2.42), (0, 5, 19, 2.726),
    (1, 0, 14, 2.566), (1, 1, 27, 2.267), (1, 2, 32, 2.259),
    (1, 3, 29, 2.355), (1, 4, 27, 2.243), (1, 5, 31, 2.472),
    (2, 0, 17, 2.392), (2, 1, 30, 2.294), (2, 2, 32, 2.15),
    (2, 3, 27, 2.343), (2, 4, 31, 2.385), (2, 5, 26, 2.532),
    (3, 0, 10, 2.54), (3, 1, 24, 2.374), (3, 2, 36, 2.314),
    (3, 3, 22, 2.383), (3, 4, 25, 2.405), (3, 5, 24, 2.932),
  ]);

  test('an empty tile is no measurement and does not read as tilt', () {
    final d = service.analyze(psfTiles: m67R0001, residualVectors: const []);
    expect(d.tiltScore, lessThan(OpticalHealthScore.tiltWarnThreshold));
    expect(
      d.issues.map((i) => i.title),
      isNot(contains('Field tilt detected')),
    );
  });

  test('a uniform field with one empty column scores no tilt', () {
    final d = service.analyze(
      psfTiles: tiles([
        for (var row = 0; row < 4; row++)
          for (var col = 0; col < 6; col++)
            (row, col, col == 5 ? 0 : 30, col == 5 ? 0.0 : 2.0),
      ]),
      residualVectors: const [],
    );
    expect(d.tiltScore, lessThan(1));
    expect(
      d.issues.map((i) => i.title),
      isNot(contains('Field tilt detected')),
    );
  });

  test('softer corners on every side are reported as field curvature', () {
    final d = service.analyze(psfTiles: ngc891L0002, residualVectors: const []);
    expect(d.tiltScore, lessThan(OpticalHealthScore.tiltWarnThreshold));
    expect(d.cornerToCenterRatio, closeTo(1.20, 0.02));
    final titles = d.issues.map((i) => i.title).toList();
    expect(titles, contains('Corners are 20% softer than the center'));
    expect(titles, isNot(contains('Optical train looks stable')));
  });

  test('the M67 frame reports its corners, not a tilt', () {
    final d = service.analyze(psfTiles: m67R0001, residualVectors: const []);
    expect(
      d.issues.map((i) => i.title),
      contains('Corners are 32% softer than the center'),
    );
  });

  test('residual positions in pixels support a collimation comparison', () {
    // 70 catalog matches spread over a 4656 x 3520 frame, as stored by the
    // residual stage (pixel coordinates), with residuals that grow toward
    // the edges.
    final vectors = <AstrometryResidualVectorRow>[];
    var id = 0;
    for (var i = 0; i < 10; i++) {
      for (var j = 0; j < 7; j++) {
        final x = 60.0 + i * 504.0;
        final y = 60.0 + j * 560.0;
        final r = ((x / 4656 - 0.5).abs() + (y / 3520 - 0.5).abs());
        vectors.add(
          AstrometryResidualVectorRow(
            id: id++,
            capturedImageId: 1,
            x: x,
            y: y,
            dxArcsec: 0.3 + r,
            dyArcsec: 0,
            magnitudeArcsec: 0.3 + r,
            timestamp: DateTime.utc(2026, 10, 22),
          ),
        );
      }
    }
    final d = service.analyze(psfTiles: ngc891L0002, residualVectors: vectors);
    expect(d.collimationMeasured, isTrue);
    expect(d.collimationScore, greaterThan(15));
  });
}
