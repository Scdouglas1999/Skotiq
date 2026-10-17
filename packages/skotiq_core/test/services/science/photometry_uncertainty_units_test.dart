// `photometry_measurements.uncertainty` is a 1-sigma MAGNITUDE for every role.
//
// That is not a stylistic preference: `AavsoExportService` writes the column
// straight into the MAGERR field of an AAVSO Extended Format upload, and
// `PeriodAnalysisService` weights the light curve by it. A comparison row
// carrying raw ADU flux noise instead is ~10^6 times larger than the
// target/check rows in the same column and the same CSV, with no unit column to
// tell the two apart.
//
// `ScienceProcessingService.buildPhotometryMeasurementRows` is the single place
// those rows are constructed, so asserting the unit here covers every write
// path into the table.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

StarMeasurement _star({
  required double flux,
  required double snr,
  double x = 100.0,
  double y = 100.0,
}) {
  return StarMeasurement(
    x: x,
    y: y,
    flux: flux,
    hfr: 2.4,
    fwhm: 2.4,
    snr: snr,
    eccentricity: 0.1,
    sharpness: 0.5,
    background: 440.0,
    peak: flux / 10.0,
  );
}

void main() {
  group('photometry uncertainty is always a magnitude', () {
    // The numbers are the ones from the reproduced defect: image 100 of the
    // audit session, where comparison_2 (flux 4506308, SNR 2090.34) was stored
    // with uncertainty 2155.777 ADU next to a target row at 0.000597 mag.
    const targetFlux = 4629522.0;
    const targetSnr = 2119.58;
    const comparisonFlux = 4506308.0;
    const comparisonSnr = 2090.34;

    List<dynamic> buildRows() {
      return ScienceProcessingService.buildPhotometryMeasurementRows(
        capturedImageId: 100,
        sessionId: 1,
        frameTimestamp: DateTime.utc(2026, 7, 29, 23, 30),
        targetObjectId: 'target_primary',
        target: _star(flux: targetFlux, snr: targetSnr),
        targetFlux: targetFlux,
        targetFluxSigma: targetFlux / targetSnr,
        comparisons: [
          (
            objectId: 'comparison_1',
            star: _star(
              flux: comparisonFlux,
              snr: comparisonSnr,
              x: 210,
              y: 90,
            ),
          ),
          (
            objectId: 'comparison_2',
            star: _star(
              flux: comparisonFlux * 0.98,
              snr: comparisonSnr * 0.99,
              x: 60,
              y: 300,
            ),
          ),
          (
            objectId: 'check_1',
            star: _star(
              flux: targetFlux * 1.01,
              snr: targetSnr * 1.01,
              x: 320,
              y: 410,
            ),
          ),
        ],
        checkObjectId: 'check_1',
        outlierObjectIds: const <String>{},
        comparisonFlux: comparisonFlux,
        comparisonFluxUncertainty: comparisonFlux / comparisonSnr,
        transform: null,
        airmass: null,
        exposureSeconds: 300.0,
      );
    }

    test('no row exceeds one magnitude of error at these SNRs', () {
      for (final row in buildRows()) {
        final role = row.role.value as String;
        final objectId = row.objectId.value as String;
        final uncertainty = row.uncertainty.value as double?;
        expect(
          uncertainty,
          isNotNull,
          reason: '$role/$objectId stored a null uncertainty',
        );
        // At SNR ~2000 the Poisson magnitude error is ~5e-4. Anything at or
        // above 1.0 in this column is not a magnitude at all — the ADU flux
        // noise for these stars was ~2.2e3.
        expect(
          uncertainty!,
          lessThan(1.0),
          reason:
              '$role/$objectId stored $uncertainty, which is not a magnitude '
              '(flux/SNR for this star is ${row.flux.value / row.snr.value})',
        );
        expect(uncertainty, greaterThan(0.0));
      }
    });

    test('a comparison row stores the Poisson magnitude sigma 1.0857/SNR', () {
      final rows = buildRows();
      final comparison = rows.firstWhere(
        (row) => row.objectId.value == 'comparison_1',
      );
      expect(comparison.role.value, 'comparison');
      expect(
        comparison.uncertainty.value as double,
        closeTo(1.0857 / comparisonSnr, 1e-12),
      );
    });

    test('target and check rows keep their propagated ensemble sigma', () {
      final rows = buildRows();
      final target = rows.firstWhere((row) => row.role.value == 'target');
      final check = rows.firstWhere((row) => row.role.value == 'check');

      // Both propagate their own SNR against the ensemble flux uncertainty, so
      // they land above a bare 1.0857/SNR but still well inside a magnitude.
      expect(target.uncertainty.value as double, greaterThan(0.0));
      expect(target.uncertainty.value as double, lessThan(0.01));
      expect(check.uncertainty.value as double, greaterThan(0.0));
      expect(check.uncertainty.value as double, lessThan(0.01));
    });

    test('all roles agree on the order of magnitude of the column', () {
      final values = buildRows()
          .map((row) => row.uncertainty.value as double)
          .toList();
      final smallest = values.reduce((a, b) => a < b ? a : b);
      final largest = values.reduce((a, b) => a > b ? a : b);
      // The defect had a spread of ~3.4 million between roles. Real photometric
      // errors on one frame differ by well under two orders of magnitude.
      expect(largest / smallest, lessThan(100.0));
    });
  });

  group('magnitudeSigmaFromSnr', () {
    test('is the Poisson limit 1.0857/SNR', () {
      expect(
        ScienceProcessingService.magnitudeSigmaFromSnr(100.0),
        closeTo(0.010857, 1e-9),
      );
    });

    test('clamps degenerate SNR rather than emitting an infinite error bar', () {
      expect(ScienceProcessingService.magnitudeSigmaFromSnr(0.0), 1.0857);
      expect(ScienceProcessingService.magnitudeSigmaFromSnr(-5.0), 1.0857);
      expect(
        ScienceProcessingService.magnitudeSigmaFromSnr(double.nan),
        1.0857,
      );
      // Non-finite SNR is treated as "unmeasured", not as "perfect": it must
      // produce the pessimistic 1.0857, never a zero error bar that would let a
      // bogus point dominate a weighted period fit.
      expect(
        ScienceProcessingService.magnitudeSigmaFromSnr(double.infinity),
        1.0857,
      );
    });
  });
}
