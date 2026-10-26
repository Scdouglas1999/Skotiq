import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Stars matched to APASS on the first and last M67 frames of 2026-10-26 in
/// B and G (60 s): airmass 1.39 → 1.31 over 26 minutes while thin cloud or
/// dew dimmed the field by about 0.28 mag.
List<CatalogStarMatch> _m67(String filter) {
  final lines = File(
    'test/fixtures/science/m67_transform_stars.csv',
  ).readAsLinesSync().skip(1).where((l) => l.trim().isNotEmpty);
  return [
    for (final line in lines)
      if (line.split(',')[1] == filter)
        () {
          final c = line.split(',');
          return CatalogStarMatch(
            x: 0,
            y: 0,
            raDegrees: 0,
            decDegrees: 0,
            catalogMagV: double.parse(c[5]),
            catalogMagB: double.parse(c[6]),
            instrumentalFlux: double.parse(c[3]),
            snr: double.parse(c[4]),
            airmass: double.parse(c[2]),
          );
        }(),
  ];
}

void main() {
  late ProviderContainer container;
  late PhotometricTransformService service;
  setUp(() {
    container = ProviderContainer();
    service = container.read(photometricTransformServiceProvider);
  });
  tearDown(() => container.dispose());

  test('a run spanning 0.08 airmass does not fit extinction', () {
    // Fitting k here gave -3.5 mag per airmass: the cloud trend.
    final fit = service.computeTransformCoefficients(
      starMatches: _m67('G'),
      filterName: 'G',
    )!;
    expect(fit.extinctionCoefficient, 0);
    // The G color term is reproducible between fields (about -0.2).
    expect(fit.colorTerm, inInclusiveRange(-0.35, -0.05));
  });

  test('a B transform gives Johnson B, not V', () {
    final stars = _m67('B');
    final fit = service.computeTransformCoefficients(
      starMatches: stars,
      filterName: 'B',
    )!;
    for (final match in fit.fitData.take(5)) {
      final star = stars.firstWhere(
        (s) => (s.catalogMagB - match.catalogMag).abs() < 1e-9,
      );
      expect(match.catalogMag, star.catalogMagB);
    }
    // Against B the residual color term is small; against V it was -0.7.
    expect(fit.colorTerm.abs(), lessThan(0.45));
  });

  test('an implausible extinction is refused with a reason', () {
    // The same G stars with the first (clearer) frame's airmass moved to
    // 1.70, so the 0.28 mag cloud trend reads as k = -0.7 over 0.39 airmass.
    final stars = [
      for (final s in _m67('G'))
        CatalogStarMatch(
          x: 0,
          y: 0,
          raDegrees: 0,
          decDegrees: 0,
          catalogMagV: s.catalogMagV,
          catalogMagB: s.catalogMagB,
          instrumentalFlux: s.instrumentalFlux,
          snr: s.snr,
          airmass: s.airmass > 1.35 ? 1.70 : s.airmass,
        ),
    ];
    final fit = service.computeTransformCoefficients(
      starMatches: stars,
      filterName: 'G',
    );
    expect(fit, isNull);
    expect(service.lastRefusalReason, contains('sky changed'));
  });

  test('standard magnitudes use the star color, or are not written', () {
    final transform = PhotometricTransformCoefficients(
      filterName: 'B',
      colorTerm: 0.27,
      extinctionCoefficient: 0.25,
      zeroPoint: 22.2,
      rmsResidual: 0.07,
      matchedStarCount: 300,
      dateComputed: DateTime.utc(2026, 10, 26),
    );
    StarMeasurement star(double flux) => StarMeasurement(
      x: 0,
      y: 0,
      flux: flux,
      hfr: 2.3,
      fwhm: 4.6,
      snr: 200,
      eccentricity: 0.2,
      sharpness: 0.1,
      background: 3900,
      peak: 20000,
    );
    List<double?> standards(Map<String, double> colors) =>
        ScienceProcessingService.buildPhotometryMeasurementRows(
          capturedImageId: 1,
          sessionId: 1,
          frameTimestamp: DateTime.utc(2026, 10, 26, 9),
          targetObjectId: 'AH_Cnc',
          target: star(120000),
          targetFlux: 120000,
          targetFluxSigma: 900,
          comparisons: [
            (objectId: 'C3', star: star(260000)),
            (objectId: 'C5', star: star(310000)),
          ],
          checkObjectId: null,
          outlierObjectIds: const {},
          comparisonFlux: 570000,
          comparisonFluxUncertainty: 2000,
          transform: transform,
          airmass: 1.39,
          exposureSeconds: 60,
          colorIndexByObject: colors,
        ).map((row) => row.standardMagnitude.value).toList();

    final withColor = standards({'AH_Cnc': 0.62, 'C3': 0.55, 'C5': 0.60});
    final inst = -2.5 * math.log(120000 / 60) / math.ln10;
    expect(
      withColor.first,
      closeTo(inst - 0.25 * 1.39 + 0.27 * 0.62 + 22.2, 1e-9),
    );
    expect(standards(const {}).every((m) => m == null), isTrue);
  });
}
