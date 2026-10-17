import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/mosaic_service.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// Proves the imaging-side [MosaicService.generatePanels] and the planetarium
/// preview [MosaicPlanner] share a single panel-layout source of truth: for an
/// equivalent grid configuration they must produce bit-identical panel centers
/// (RA hours + Dec degrees) in the same row-major order. If the two ever drift,
/// this test fails — that is the whole point of unifying the geometry onto
/// [mosaicPanelCenters].
void main() {
  group('Mosaic panel-geometry parity (MosaicService vs MosaicPlanner)', () {
    /// Run one representative grid through both implementations and assert the
    /// panel centers match exactly.
    void expectParity({
      required double centerRaHours,
      required double centerDecDeg,
      required double panelFovWidthDeg,
      required double panelFovHeightDeg,
      required double overlapFraction,
      required int columns,
      required int rows,
      required double rotationDeg,
    }) {
      const service = MosaicService();

      // Imaging-side: dimensions in arcminutes, overlap as a percentage.
      final serviceConfig = MosaicConfig(
        centerRa: centerRaHours,
        centerDec: centerDecDeg,
        panelWidthArcmin: panelFovWidthDeg * 60.0,
        panelHeightArcmin: panelFovHeightDeg * 60.0,
        overlapPercent: overlapFraction * 100.0,
        rotation: rotationDeg,
        panelsHorizontal: columns,
        panelsVertical: rows,
      );
      final servicePanels = service.generatePanels(serviceConfig);

      // Preview-side: dimensions in degrees, overlap as a fraction.
      final plan = MosaicPlanner.generateRectangularMosaic(
        center: CelestialCoordinate(ra: centerRaHours, dec: centerDecDeg),
        rows: rows,
        columns: columns,
        panelFovWidth: panelFovWidthDeg,
        panelFovHeight: panelFovHeightDeg,
        overlap: MosaicOverlap(
          horizontal: overlapFraction,
          vertical: overlapFraction,
        ),
        rotation: rotationDeg,
      );
      // panels is row-major (capture order is a separate index list).
      final previewPanels = plan.panels;

      expect(servicePanels.length, previewPanels.length);
      for (var i = 0; i < servicePanels.length; i++) {
        final s = servicePanels[i];
        final p = previewPanels[i];
        expect(s.row, p.row, reason: 'row mismatch at index $i');
        expect(s.col, p.column, reason: 'col mismatch at index $i');
        expect(
          s.raHours,
          closeTo(p.center.ra, 1e-9),
          reason: 'RA mismatch at panel $i',
        );
        expect(
          s.decDegrees,
          closeTo(p.center.dec, 1e-9),
          reason: 'Dec mismatch at panel $i',
        );
      }
    }

    test('3x2 grid, rotated, off-pole', () {
      expectParity(
        centerRaHours: 5.5,
        centerDecDeg: 22.0,
        panelFovWidthDeg: 2.0,
        panelFovHeightDeg: 1.5,
        overlapFraction: 0.1,
        columns: 3,
        rows: 2,
        rotationDeg: 30.0,
      );
    });

    test('1x1 grid, no rotation', () {
      expectParity(
        centerRaHours: 12.0,
        centerDecDeg: 30.0,
        panelFovWidthDeg: 1.0,
        panelFovHeightDeg: 1.0,
        overlapFraction: 0.15,
        columns: 1,
        rows: 1,
        rotationDeg: 0.0,
      );
    });

    test('4x4 grid, high declination, no rotation', () {
      expectParity(
        centerRaHours: 0.5,
        centerDecDeg: 65.0,
        panelFovWidthDeg: 0.75,
        panelFovHeightDeg: 0.5,
        overlapFraction: 0.2,
        columns: 4,
        rows: 4,
        rotationDeg: 0.0,
      );
    });
  });
}
