import 'package:test/test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

void main() {
  group('normalizeRaHours', () {
    test('never returns 24.0 for a tiny negative input', () {
      // `-1e-16 % 24.0` rounds to exactly 24.0 in double precision, so the
      // naive normalize returned an out-of-contract RA.
      for (final ra in const [-1e-16, -1e-18, -5e-17]) {
        final normalized = normalizeRaHours(ra);
        expect(normalized, greaterThanOrEqualTo(0.0), reason: 'ra=$ra');
        expect(normalized, lessThan(24.0), reason: 'ra=$ra');
      }
    });

    test('folds the whole real line into [0, 24)', () {
      for (final ra in const [0.0, 23.999, 24.0, 25.5, -1.0, -24.0, -49.5]) {
        final normalized = normalizeRaHours(ra);
        expect(normalized, greaterThanOrEqualTo(0.0), reason: 'ra=$ra');
        expect(normalized, lessThan(24.0), reason: 'ra=$ra');
      }
    });
  });

  group('meanRaHours', () {
    test('averages a mosaic straddling RA 0h to 0h, not the opposite sky', () {
      // The 2x2 grid a mosaic centred on RA 0h produces once panel RAs are
      // normalized into [0, 24). An arithmetic mean of these is 12.0h.
      final mean = meanRaHours(const [23.97, 0.03, 23.97, 0.03]);
      expect(mean, isNotNull);
      expect(mean, greaterThanOrEqualTo(0.0));
      expect(mean, lessThan(24.0));
      // Circular mean lands back at the true centre (0h), not 12h.
      final wrapped = mean! > 12.0 ? mean - 24.0 : mean;
      expect(wrapped, closeTo(0.0, 1e-6));
    });

    test('matches the arithmetic mean well away from the seam', () {
      final mean = meanRaHours(const [5.4, 5.5, 5.6]);
      expect(mean, isNotNull);
      expect(mean!, closeTo(5.5, 1e-6));
    });

    test('returns null rather than inventing a center for no panels', () {
      expect(meanRaHours(const <double>[]), isNull);
    });

    test('returns null when the directions cancel (no meaningful mean)', () {
      // Antipodal in RA: any answer would be arbitrary.
      expect(meanRaHours(const [0.0, 12.0]), isNull);
      expect(meanRaHours(const [3.0, 9.0, 15.0, 21.0]), isNull);
    });

    test('ignores non-finite RA values instead of poisoning the mean', () {
      final mean = meanRaHours(const [double.nan, 6.0, double.infinity]);
      expect(mean, isNotNull);
      expect(mean!, closeTo(6.0, 1e-6));
    });
  });

  group('MosaicPlanner', () {
    test('generates finite panel centers near celestial pole', () {
      final plan = MosaicPlanner.generateRectangularMosaic(
        center: const CelestialCoordinate(ra: 12, dec: 90),
        rows: 2,
        columns: 2,
        panelFovWidth: 2,
        panelFovHeight: 2,
      );

      for (final panel in plan.panels) {
        expect(panel.center.ra.isFinite, isTrue);
        expect(panel.center.dec.isFinite, isTrue);
        expect(panel.center.ra, greaterThanOrEqualTo(0));
        expect(panel.center.ra, lessThan(24));

        for (final corner in panel.corners) {
          expect(corner.ra.isFinite, isTrue);
          expect(corner.dec.isFinite, isTrue);
          expect(corner.ra, greaterThanOrEqualTo(0));
          expect(corner.ra, lessThan(24));
        }
      }
    });
  });
}
