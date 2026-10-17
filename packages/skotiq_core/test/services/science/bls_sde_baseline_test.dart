// BLS Signal Detection Efficiency must rank a real transit ABOVE noise.
//
// SDE was computed over the whole SR spectrum, peak included, so a coherent
// signal inflated its own baseline mean and standard deviation and deflated
// its own score. The measured consequence: pure noise scored HIGHER than an
// injected box transit, and no light curve could reach the 6.0 threshold the
// service documents at period_analysis_service.dart:81 — which is why the
// Strong/Noteworthy badge in the BLS card never fired.
//
// Two datasets, same injected signal, both deterministic:
//   * the 80-point curve from the original finding — thin data, so the test is
//     about ORDERING (noise < sinusoid < transit);
//   * a 300-point curve — enough data that the transit must actually clear the
//     documented significance threshold while noise stays well under it.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/src/services/science/period_analysis_service.dart';

const _periodMinutes = 20.0;
const _periodDays = _periodMinutes / 1440.0;
const _noiseSigma = 0.01;
const _transitDepth = 0.150;
const _transitDurationFraction = 0.10;
const _sinusoidAmplitude = 0.10;

/// Deterministic Gaussian noise so every assertion here is reproducible.
List<double> _noise(int count, int seed) {
  final rng = math.Random(seed);
  return List<double>.generate(count, (_) {
    final u1 = rng.nextDouble().clamp(1e-12, 1.0);
    final u2 = rng.nextDouble();
    return _noiseSigma *
        math.sqrt(-2.0 * math.log(u1)) *
        math.cos(2 * math.pi * u2);
  });
}

/// The three curves the original finding used, on a shared time grid.
class _Curves {
  final List<double> times;
  final List<double> errs;
  final List<double> flat;
  final List<double> sinusoid;
  final List<double> transit;

  factory _Curves.build(int count, double cadenceMinutes, int seed) {
    final times = List<double>.generate(
      count,
      (i) => i * cadenceMinutes / 1440.0,
    );
    final noise = _noise(count, seed);
    return _Curves._(
      times: times,
      errs: List<double>.filled(count, _noiseSigma),
      flat: List<double>.generate(count, (i) => 12.0 + noise[i]),
      sinusoid: List<double>.generate(
        count,
        (i) =>
            12.0 +
            _sinusoidAmplitude *
                math.sin(2 * math.pi * times[i] / _periodDays) +
            noise[i],
      ),
      transit: List<double>.generate(count, (i) {
        final phase = (times[i] % _periodDays) / _periodDays;
        final inTransit = phase < _transitDurationFraction;
        return 12.0 + (inTransit ? _transitDepth : 0.0) + noise[i];
      }),
    );
  }

  _Curves._({
    required this.times,
    required this.errs,
    required this.flat,
    required this.sinusoid,
    required this.transit,
  });
}

void main() {
  const service = PeriodAnalysisService();

  BlsResult run(_Curves c, List<double> mags) => service.computeBls(
    times: c.times,
    mags: mags,
    errs: c.errs,
    minPeriod: 10.0 / 1440.0,
    maxPeriod: 40.0 / 1440.0,
    nbins: 20,
  );

  group('BLS SDE baseline excludes the peak it is measuring', () {
    test('80 points: transit > sinusoid > noise', () {
      final c = _Curves.build(80, 2.25, 1234);
      final noiseSde = run(c, c.flat).signalDetectionEfficiency;
      final sinusoidSde = run(c, c.sinusoid).signalDetectionEfficiency;
      final transitSde = run(c, c.transit).signalDetectionEfficiency;

      expect(
        sinusoidSde,
        greaterThan(noiseSde),
        reason: 'SDE(sinusoid)=$sinusoidSde must beat SDE(noise)=$noiseSde',
      );
      expect(
        transitSde,
        greaterThan(sinusoidSde),
        reason: 'SDE(transit)=$transitSde must beat SDE(sinusoid)=$sinusoidSde',
      );
    });

    test('300 points: the transit clears the documented 6.0 threshold', () {
      final c = _Curves.build(300, 2.0, 1234);
      final transit = run(c, c.transit);
      final noiseSde = run(c, c.flat).signalDetectionEfficiency;

      expect(
        transit.signalDetectionEfficiency,
        greaterThan(6.0),
        reason:
            'the service documents SDE > ~6 as significant; the Strong badge '
            'can never fire otherwise. Got '
            '${transit.signalDetectionEfficiency}',
      );
      expect(
        noiseSde,
        lessThan(6.0),
        reason: 'pure noise must stay under the threshold. Got $noiseSde',
      );

      // Sanity: the peak the SDE describes is the injected signal, not an
      // alias — otherwise a high SDE would be meaningless.
      expect(transit.bestPeriod * 1440.0, closeTo(_periodMinutes, 1.0));
      expect(transit.transitDepth, closeTo(_transitDepth, 0.02));
    });
  });
}
