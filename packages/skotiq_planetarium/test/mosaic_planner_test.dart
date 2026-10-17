import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/coordinate_system.dart';
import 'package:skotiq_planetarium/src/services/mosaic_geometry.dart';
import 'package:skotiq_planetarium/src/services/mosaic_planner.dart';

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

    test('returns null rather than inventing a centre for no panels', () {
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

  group('MosaicExporter.toJson', () {
    test('emits spec-valid JSON that round-trips a label with special '
        'characters', () {
      final plan = MosaicPlanner.generateRectangularMosaic(
        center: const CelestialCoordinate(ra: 5.5, dec: -10.25),
        rows: 1,
        columns: 2,
        panelFovWidth: 1.5,
        panelFovHeight: 1.0,
      );

      // A label a bespoke encoder would emit unescaped, producing invalid JSON.
      const trickyLabel = 'Orion "A1" \\ panel\nline2\ttab';
      plan.panelsInCaptureOrder.first.label = trickyLabel;

      final json = MosaicExporter.toJson(plan);

      // Must be parseable.
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final panels = decoded['panels'] as List<dynamic>;
      final first = panels.first as Map<String, dynamic>;

      // The label survives verbatim through encode -> decode.
      expect(first['name'], equals(trickyLabel));

      // Numeric fields are preserved.
      expect(first['index'], equals(plan.panelsInCaptureOrder.first.index));
      expect(
        (first['ra_hours'] as num).toDouble(),
        equals(plan.panelsInCaptureOrder.first.center.ra),
      );
      expect(
        (first['dec_deg'] as num).toDouble(),
        equals(plan.panelsInCaptureOrder.first.center.dec),
      );

      // Human-readable: 2-space indentation.
      expect(json, contains('\n  "center_ra_hours"'));
    });

    test('label-free plan decodes to the documented structure in capture '
        'order', () {
      final plan = MosaicPlanner.generateRectangularMosaic(
        center: const CelestialCoordinate(ra: 12, dec: 45),
        rows: 2,
        columns: 2,
        panelFovWidth: 1.0,
        panelFovHeight: 1.0,
      );

      final decoded =
          jsonDecode(MosaicExporter.toJson(plan)) as Map<String, dynamic>;

      expect(decoded.keys, contains('center_ra_hours'));
      expect(decoded.keys, contains('center_dec_deg'));
      expect(decoded['rows'], equals(plan.rows));
      expect(decoded['columns'], equals(plan.columns));
      expect(decoded['panel_count'], equals(plan.panelCount));

      final panels = decoded['panels'] as List<dynamic>;
      expect(panels.length, equals(plan.panelsInCaptureOrder.length));

      // Panels stay in capture order: names/indices align positionally.
      final ordered = plan.panelsInCaptureOrder;
      for (var i = 0; i < ordered.length; i++) {
        final panelJson = panels[i] as Map<String, dynamic>;
        expect(panelJson['index'], equals(ordered[i].index));
        expect(panelJson['name'], equals(ordered[i].name));
        for (final key in const [
          'row',
          'column',
          'ra_hours',
          'ra_deg',
          'dec_deg',
          'rotation_deg',
          'fov_width_deg',
          'fov_height_deg',
        ]) {
          expect(panelJson.containsKey(key), isTrue, reason: 'missing $key');
        }
      }
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
