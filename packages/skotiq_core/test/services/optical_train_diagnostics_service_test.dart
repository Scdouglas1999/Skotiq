import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('OpticalTrainDiagnosticsService', () {
    const service = OpticalTrainDiagnosticsService();

    test('reports stable optics for balanced field', () {
      final diagnostics = service.analyze(
        psfTiles: [
          for (var row = 0; row < 2; row++)
            for (var col = 0; col < 2; col++)
              PsfFieldTileRow(
                id: row * 2 + col,
                tileRow: row,
                tileCol: col,
                starCount: 25,
                medianFwhm: 2.1,
                medianHfr: 2.0,
                medianEccentricity: 0.2,
                roundness: 0.9,
                timestamp: DateTime.now(),
              ),
        ],
        residualVectors: [
          AstrometryResidualVectorRow(
            id: 1,
            x: 0.5,
            y: 0.5,
            dxArcsec: 0.2,
            dyArcsec: 0.2,
            magnitudeArcsec: 0.28,
            timestamp: DateTime.now(),
          ),
          // An edge sample as well as a centre one: "balanced across the image"
          // is a comparison, and the service now declines to make it when only
          // one side of the field was sampled.
          AstrometryResidualVectorRow(
            id: 2,
            x: 0.1,
            y: 0.9,
            dxArcsec: 0.2,
            dyArcsec: 0.2,
            magnitudeArcsec: 0.29,
            timestamp: DateTime.now(),
          ),
        ],
      );

      expect(diagnostics.tiltScore, lessThan(18));
      expect(diagnostics.hasIssues, isTrue);
      expect(diagnostics.issues.first.title, contains('stable'));
    });

    test('flags strong tilt and edge residual growth', () {
      final diagnostics = service.analyze(
        psfTiles: [
          PsfFieldTileRow(
            id: 1,
            tileRow: 0,
            tileCol: 0,
            starCount: 25,
            medianFwhm: 3.4,
            medianHfr: 3.2,
            medianEccentricity: 0.35,
            roundness: 0.8,
            timestamp: DateTime.now(),
          ),
          PsfFieldTileRow(
            id: 2,
            tileRow: 0,
            tileCol: 1,
            starCount: 25,
            medianFwhm: 2.0,
            medianHfr: 1.9,
            medianEccentricity: 0.2,
            roundness: 0.9,
            timestamp: DateTime.now(),
          ),
          PsfFieldTileRow(
            id: 3,
            tileRow: 1,
            tileCol: 0,
            starCount: 25,
            medianFwhm: 3.1,
            medianHfr: 3.0,
            medianEccentricity: 0.3,
            roundness: 0.8,
            timestamp: DateTime.now(),
          ),
          PsfFieldTileRow(
            id: 4,
            tileRow: 1,
            tileCol: 1,
            starCount: 25,
            medianFwhm: 2.1,
            medianHfr: 2.0,
            medianEccentricity: 0.2,
            roundness: 0.9,
            timestamp: DateTime.now(),
          ),
        ],
        residualVectors: [
          AstrometryResidualVectorRow(
            id: 1,
            x: 0.1,
            y: 0.1,
            dxArcsec: 0.8,
            dyArcsec: 0.8,
            magnitudeArcsec: 1.2,
            timestamp: DateTime.now(),
          ),
          AstrometryResidualVectorRow(
            id: 2,
            x: 0.5,
            y: 0.5,
            dxArcsec: 0.1,
            dyArcsec: 0.1,
            magnitudeArcsec: 0.14,
            timestamp: DateTime.now(),
          ),
        ],
      );

      expect(diagnostics.tiltScore, greaterThan(18));
      expect(diagnostics.collimationScore, greaterThan(15));
      expect(
        diagnostics.issues.any((issue) => issue.title.contains('Field tilt')),
        isTrue,
      );
    });
  });
}
