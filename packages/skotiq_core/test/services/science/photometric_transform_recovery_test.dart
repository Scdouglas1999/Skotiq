// Ground-truth recovery test for the photometric transform fit.
//
// Star fluxes are SYNTHESISED from known (zeroPoint, extinction, colorTerm)
// through the service's own documented equation, so the fit must return the
// coefficients that generated them. Anything else is a real error in the fit.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

const double kTrueZeroPoint = 21.350;
const double kTrueExtinction = 0.1800; // mag per airmass
const double kTrueColorTerm = 0.0850;

/// M_std = m_inst - k*X + T*(B-V) + zp  =>  m_inst = V + k*X - T*(B-V) - zp
double _instrumentalMag(double v, double airmass, double colorIndex) =>
    v +
    kTrueExtinction * airmass -
    kTrueColorTerm * colorIndex -
    kTrueZeroPoint;

double _fluxFor(double instMag) => math.pow(10, -0.4 * instMag).toDouble();

double _gauss(math.Random rng, double sigma) {
  final u1 = 1.0 - rng.nextDouble();
  final u2 = rng.nextDouble();
  return sigma * math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
}

List<CatalogStarMatch> _stars({
  required int count,
  required double noiseMag,
  int seed = 4242,
  double airmassMin = 1.05,
  double airmassMax = 1.95,
}) {
  final rng = math.Random(seed);
  return List.generate(count, (i) {
    final frac = count == 1 ? 0.0 : i / (count - 1);
    final airmass = airmassMin + (airmassMax - airmassMin) * frac;
    // Spread colours across a realistic main-sequence range.
    final colorIndex = -0.15 + 1.85 * rng.nextDouble();
    final v = 10.0 + 5.0 * rng.nextDouble();
    final instMag =
        _instrumentalMag(v, airmass, colorIndex) + _gauss(rng, noiseMag);
    return CatalogStarMatch(
      x: 100.0 + i,
      y: 200.0 + i,
      raDegrees: 180.0,
      decDegrees: 20.0,
      catalogMagV: v,
      catalogMagB: v + colorIndex,
      instrumentalFlux: _fluxFor(instMag),
      snr: 50,
      airmass: airmass,
    );
  });
}

void main() {
  late ProviderContainer container;
  late PhotometricTransformService service;

  setUp(() {
    container = ProviderContainer();
    service = container.read(photometricTransformServiceProvider);
  });
  tearDown(() => container.dispose());

  test('recovers the coefficients that generated the data (noiseless)', () {
    final fit = service.computeTransformCoefficients(
      starMatches: _stars(count: 40, noiseMag: 0.0),
      filterName: 'V',
    );

    expect(fit, isNotNull);
    expect(fit!.zeroPoint, closeTo(kTrueZeroPoint, 1e-6));
    expect(fit.extinctionCoefficient, closeTo(kTrueExtinction, 1e-6));
    expect(fit.colorTerm, closeTo(kTrueColorTerm, 1e-6));
    expect(fit.rmsResidual, lessThan(1e-6));
    expect(fit.matchedStarCount, 40);
  });

  test('recovers coefficients from noisy photometry', () {
    final fit = service.computeTransformCoefficients(
      starMatches: _stars(count: 60, noiseMag: 0.020),
      filterName: 'V',
    );

    expect(fit, isNotNull);
    expect(fit!.zeroPoint, closeTo(kTrueZeroPoint, 0.02));
    expect(fit.extinctionCoefficient, closeTo(kTrueExtinction, 0.02));
    expect(fit.colorTerm, closeTo(kTrueColorTerm, 0.02));
  });

  test('reported RMS residual estimates the true scatter', () {
    const injected = 0.030;
    final fit = service.computeTransformCoefficients(
      starMatches: _stars(count: 12, noiseMag: injected),
      filterName: 'V',
    );

    expect(fit, isNotNull);
    // The quoted RMS is what the wizard shows as fit quality, so it must not
    // flatter the fit.
    expect(fit!.rmsResidual, closeTo(injected, injected * 0.35));
  });

  test('reported RMS is unbiased across noise draws', () {
    // Averaged over many realisations the reported scatter equals the injected
    // scatter. Dividing the residual sum of squares by n instead of the
    // residual degrees of freedom pulls this to 0.65 at 6 stars and 0.86 at 12
    // — and the wizard accepts fits from as few as 4 matched stars, so the
    // small-N end is exactly where the number gets quoted.
    for (final n in [6, 12, 30, 100]) {
      var sum = 0.0;
      var trials = 0;
      for (var seed = 0; seed < 300; seed++) {
        final fit = service.computeTransformCoefficients(
          starMatches: _stars(count: n, noiseMag: 0.030, seed: seed),
          filterName: 'V',
        );
        if (fit == null) continue;
        sum += fit.rmsResidual / 0.030;
        trials++;
      }
      final mean = sum / trials;
      expect(
        mean,
        closeTo(1.0, n <= 6 ? 0.12 : 0.05),
        reason: 'N=$n mean(reported/true)=$mean over $trials draws',
      );
    }
  });

  test('single-frame data drops the unfittable extinction term', () {
    // Every star on one frame shares an airmass: k is unconstrained.
    final fit = service.computeTransformCoefficients(
      starMatches: _stars(
        count: 25,
        noiseMag: 0.0,
        airmassMin: 1.30,
        airmassMax: 1.30,
      ),
      filterName: 'V',
    );

    expect(fit, isNotNull);
    expect(fit!.extinctionCoefficient, 0.0);
    // The extinction at the observed airmass folds into the zero point.
    expect(
      fit.zeroPoint,
      closeTo(kTrueZeroPoint - kTrueExtinction * 1.30, 1e-6),
    );
    expect(fit.colorTerm, closeTo(kTrueColorTerm, 1e-6));
  });
}
