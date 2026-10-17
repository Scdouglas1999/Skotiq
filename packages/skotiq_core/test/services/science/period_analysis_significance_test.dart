// Significance statistics of the Lomb-Scargle periodogram.
//
// The expectations below were calibrated against astropy 8.0.1 (LombScargle,
// normalization='standard', Baluev FAP) on the very same synthetic curves:
//   20-cycle sinusoid  -> astropy power 0.9655, FAP 0.0
//   pure white noise   -> astropy power 0.0023, FAP 0.58
// Before this was fixed the service returned power ~0.48 for the sinusoid (a
// perfect sinusoid capped at 0.5) and FAP == 1.0 for EVERY input, so the
// panel's "Significant" (FAP<0.01) and "Strong" (FAP<0.001) verdicts could
// never fire on a real detection.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

const _service = PeriodAnalysisService();
final _epoch = DateTime.utc(2026, 7, 30, 21);

List<LightCurvePoint> _curve({
  required int count,
  required double cadenceSeconds,
  required double Function(double days, math.Random rng) magnitude,
  double sigma = 0.011,
  int seed = 20260730,
}) {
  final rng = math.Random(seed);
  return List.generate(count, (i) {
    final days = i * cadenceSeconds / 86400.0;
    return LightCurvePoint(
      timestamp: _epoch.add(
        Duration(microseconds: (days * 86400 * 1e6).round()),
      ),
      flux: 1.0,
      differentialMagnitude: magnitude(days, rng),
      snr: 100,
      uncertainty: sigma,
    );
  });
}

/// Box-Muller: dart:math has no Gaussian generator.
double _gauss(math.Random rng, double sigma) {
  final u1 = 1.0 - rng.nextDouble();
  final u2 = rng.nextDouble();
  return sigma * math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
}

void main() {
  const truePeriod = 0.21374; // days
  const amplitude = 0.085; // mag
  const sigma = 0.011;

  test('a strong sinusoid is reported as a significant detection', () {
    final points = _curve(
      count: 4103,
      cadenceSeconds: 90,
      sigma: sigma,
      magnitude: (days, rng) =>
          12.43 +
          amplitude * math.sin(2 * math.pi * days / truePeriod) +
          _gauss(rng, sigma),
    );

    final ls = _service
        .analyze(points: points, minPeriodDays: 0.05, maxPeriodDays: 1.5)
        .lombScargle;

    // Period recovered to well under a percent.
    expect(
      (ls.bestPeriod / truePeriod - 1).abs(),
      lessThan(0.01),
      reason: 'best period ${ls.bestPeriod} vs true $truePeriod',
    );
    // Standard normalization: a near-pure sinusoid explains almost all the
    // variance, so power approaches 1 (astropy measured 0.9655).
    expect(ls.peakPower, greaterThan(0.85));
    expect(ls.peakPower, lessThanOrEqualTo(1.0));
    // Must clear the panel's "Strong" threshold.
    expect(ls.falseAlarmProbability, lessThan(0.001));
  });

  test('pure noise is NOT reported as a significant detection', () {
    final points = _curve(
      count: 4800,
      cadenceSeconds: 90,
      sigma: sigma,
      magnitude: (days, rng) => 12.43 + _gauss(rng, sigma),
    );

    final ls = _service
        .analyze(points: points, minPeriodDays: 0.05, maxPeriodDays: 1.5)
        .lombScargle;

    expect(
      ls.peakPower,
      lessThan(0.05),
      reason: 'noise should not explain much variance',
    );
    // Above the panel's "Significant" threshold, i.e. no verdict chip.
    expect(
      ls.falseAlarmProbability,
      greaterThan(0.01),
      reason: 'noise must not be badged as a detection',
    );
  });

  test('a run shorter than the period reports an unconstrained result', () {
    // One 4.18 h night of a 5.13 h variable: 0.81 cycles. The periodogram has
    // no choice but to pile up against the low-frequency edge and hand back the
    // baseline, so the result must not present itself as a measured period.
    const nightHours = 4.18;
    const cadence = 72.0;
    final count = (nightHours * 3600 / cadence).floor();
    final points = _curve(
      count: count,
      cadenceSeconds: cadence,
      sigma: sigma,
      magnitude: (days, rng) =>
          12.43 +
          amplitude * math.sin(2 * math.pi * days / truePeriod) +
          _gauss(rng, sigma),
    );

    final ls = _service
        .analyze(points: points, minPeriodDays: 0.01, maxPeriodDays: 10.0)
        .lombScargle;

    // The search cannot look past the baseline, whatever the caller asked for.
    expect(ls.searchedMaxPeriod, closeTo(nightHours / 24.0, 0.01));
    expect(ls.observedCycles, lessThan(2.0));
    expect(
      ls.isPeriodConstrained,
      isFalse,
      reason:
          'best period ${ls.bestPeriod} d over a '
          '${ls.timeBaseline} d baseline is ${ls.observedCycles} cycles',
    );
    // And the peak really is the baseline reporting itself back.
    expect(
      ls.bestPeriod,
      closeTo(ls.searchedMaxPeriod, ls.searchedMaxPeriod * 0.05),
    );
  });

  test('a long enough run reports a constrained result', () {
    final points = _curve(
      count: 4103,
      cadenceSeconds: 90,
      sigma: sigma,
      magnitude: (days, rng) =>
          12.43 +
          amplitude * math.sin(2 * math.pi * days / truePeriod) +
          _gauss(rng, sigma),
    );
    final ls = _service
        .analyze(points: points, minPeriodDays: 0.05, maxPeriodDays: 1.5)
        .lombScargle;
    expect(ls.observedCycles, greaterThan(15));
    expect(ls.isPeriodConstrained, isTrue);
  });
}
