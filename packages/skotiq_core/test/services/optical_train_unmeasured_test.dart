import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// A session with no PSF field map and no astrometric residuals used to grade
/// "A / Excellent" — 0 is the best possible penalty, so "not measured" and
/// "perfect" were the same number. These lock the distinction in.
void main() {
  const service = OpticalTrainDiagnosticsService();

  PsfFieldTileRow tile(int row, int col, double hfr) => PsfFieldTileRow(
    id: row * 10 + col,
    tileRow: row,
    tileCol: col,
    starCount: 25,
    medianFwhm: hfr * 1.05,
    medianHfr: hfr,
    medianEccentricity: 0.2,
    roundness: 0.9,
    timestamp: DateTime.utc(2026, 8, 1),
  );

  AstrometryResidualVectorRow residual(
    int id,
    double x,
    double y,
    double mag,
  ) => AstrometryResidualVectorRow(
    id: id,
    x: x,
    y: y,
    dxArcsec: mag / 1.41,
    dyArcsec: mag / 1.41,
    magnitudeArcsec: mag,
    timestamp: DateTime.utc(2026, 8, 1),
  );

  test('no tiles and no residuals grades as not measured, not as an A', () {
    final diagnostics = service.analyze(
      psfTiles: const [],
      residualVectors: const [],
    );

    expect(diagnostics.tiltMeasured, isFalse);
    expect(diagnostics.collimationMeasured, isFalse);

    final health = diagnostics.healthScore;
    expect(health.isMeasured, isFalse);
    expect(health.letterGrade, '—');
    expect(health.qualityLabel, 'Not measured');
  });

  test('tiles without residuals do not vouch for collimation', () {
    final diagnostics = service.analyze(
      psfTiles: [
        for (var row = 0; row < 2; row++)
          for (var col = 0; col < 2; col++) tile(row, col, 2.0),
      ],
      residualVectors: const [],
    );

    expect(diagnostics.tiltMeasured, isTrue);
    expect(diagnostics.collimationMeasured, isFalse);
    expect(
      diagnostics.issues.map((i) => i.title),
      contains('Collimation not measured'),
    );
    expect(
      diagnostics.issues.map((i) => i.title),
      isNot(contains('Optical train looks stable')),
      reason: 'nothing measured the residual pattern it claims is balanced',
    );
    // One unmeasured axis is enough to void the combined grade.
    expect(diagnostics.healthScore.letterGrade, '—');
  });

  test('residuals on one side of the split are not a comparison', () {
    final diagnostics = service.analyze(
      psfTiles: [
        for (var row = 0; row < 2; row++)
          for (var col = 0; col < 2; col++) tile(row, col, 2.0),
      ],
      // Edge samples only: the centre denominator would be the 0.1 clamp
      // floor, which manufactures a maxed-out collimation penalty.
      residualVectors: [
        residual(1, 0.05, 0.05, 1.4),
        residual(2, 0.95, 0.95, 1.5),
      ],
    );

    expect(diagnostics.collimationMeasured, isFalse);
    expect(
      diagnostics.issues.map((i) => i.title),
      isNot(contains('Collimation or spacing mismatch')),
    );
  });

  test('a single tile is not evidence of a flat field', () {
    final diagnostics = service.analyze(
      psfTiles: [tile(0, 0, 2.0)],
      residualVectors: [
        residual(1, 0.5, 0.5, 0.2),
        residual(2, 0.05, 0.5, 0.21),
      ],
    );

    expect(diagnostics.tiltMeasured, isFalse);
    expect(diagnostics.dominantTiltDirection, 'unknown');
    expect(diagnostics.healthScore.letterGrade, '—');
  });

  test('a genuinely measured, balanced field still grades A', () {
    final diagnostics = service.analyze(
      psfTiles: [
        for (var row = 0; row < 3; row++)
          for (var col = 0; col < 3; col++) tile(row, col, 2.0),
      ],
      residualVectors: [
        residual(1, 0.5, 0.5, 0.20),
        residual(2, 0.05, 0.5, 0.21),
        residual(3, 0.95, 0.5, 0.20),
      ],
    );

    final health = diagnostics.healthScore;
    expect(health.isMeasured, isTrue);
    expect(health.letterGrade, 'A');
    expect(health.qualityLabel, 'Excellent');
    expect(
      diagnostics.issues.map((i) => i.title),
      contains('Optical train looks stable'),
    );
  });
}
