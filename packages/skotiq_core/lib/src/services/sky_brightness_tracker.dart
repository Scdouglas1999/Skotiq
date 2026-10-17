import 'dart:math' as math;

/// Tracks sky brightness changes during twilight for predictive exposure calculation
class SkyBrightnessTracker {
  final List<_BrightnessSample> _samples = [];

  /// Maximum age of samples to consider (5 minutes)
  static const _maxSampleAge = Duration(minutes: 5);

  /// Maximum age retained for session summaries. Rate math still uses
  /// [_maxSampleAge]; this longer horizon lets post-session diagnostics report
  /// the sky-brightness range seen across a normal unattended night.
  static const _maxSummarySampleAge = Duration(hours: 12);

  /// Minimum samples needed for rate calculation
  static const _minSamples = 2;

  /// Calibration anchor for converting ADU/sec to
  /// mag/arcsec² for the sky-brightness adaptive exposure path. We
  /// pin a single reference point (one ADU/sec rate measured at a
  /// known mag/arcsec² sky brightness) and use Pogson's relation to
  /// convert other rates. Per-camera defaults are wildly different;
  /// a sensible Bortle-1 dark-site anchor for a typical ASI camera is
  /// ~10 ADU/sec at 21.5 mag/arcsec² (1×1 binning, default gain),
  /// which yields right-order-of-magnitude readings under more
  /// polluted skies. The user override is plumbed through
  /// [setCalibration] when a calibrated SQM or known site brightness
  /// is available.
  double _calibrationAduPerSec = 10.0;
  double _calibrationMagPerArcsec2 = 21.5;

  /// Override the default ADU/sec ↔ mag/arcsec² calibration. Called
  /// from settings UI when the user has a known reference reading
  /// (e.g. an SQM-L meter on-site, or a pre-twilight sample taken
  /// during commissioning).
  void setCalibration({
    required double aduPerSec,
    required double magPerArcsec2,
  }) {
    if (aduPerSec > 0 && magPerArcsec2 > 0) {
      _calibrationAduPerSec = aduPerSec;
      _calibrationMagPerArcsec2 = magPerArcsec2;
    }
  }

  /// Convert the latest ADU/sec reading to
  /// mag/arcsec² using the configured calibration anchor.
  ///
  /// Pogson's relation: m₁ - m₂ = -2.5·log₁₀(F₁/F₂). With F₁ =
  /// [_calibrationAduPerSec] at m₁ = [_calibrationMagPerArcsec2],
  /// and F₂ = the current rate, we solve for m₂ (the current sky
  /// brightness):
  ///
  ///   m₂ = m₁ + 2.5·log₁₀(F₁ / F₂)
  ///
  /// Returns `null` until at least one sample has been recorded so
  /// the adapter falls back to nominal duration (rather than firing
  /// on the calibration anchor as a stand-in).
  double? currentMagPerArcsec2() {
    final samples = _recentSamples();
    if (samples.isEmpty) return null;
    return _magPerArcsec2ForAduPerSec(samples.last.aduPerSecond);
  }

  double? _magPerArcsec2ForAduPerSec(double aduPerSec) {
    if (aduPerSec <= 0) return null;
    return _calibrationMagPerArcsec2 +
        2.5 * (math.log(_calibrationAduPerSec / aduPerSec) / math.ln10);
  }

  /// Calibrated mag/arcsec² samples retained since [since].
  ///
  /// The tracker already owns the rolling sky-brightness sample buffer used by
  /// adaptive exposure. Post-session diagnostics reuse that source instead of
  /// inventing a second telemetry store, so the report describes the same sky
  /// readings that the sequencer acted on.
  List<double> magSamplesSince(DateTime? since) {
    _pruneOldSamples();
    final mags = <double>[];
    for (final sample in _samples) {
      if (since != null && sample.timestamp.isBefore(since)) continue;
      final mag = _magPerArcsec2ForAduPerSec(sample.aduPerSecond);
      if (mag != null && mag.isFinite) {
        mags.add(mag);
      }
    }
    return mags;
  }

  /// Add a brightness measurement
  void addSample({
    required double adu,
    required double exposureTime,
    required DateTime timestamp,
  }) {
    // Normalize ADU to ADU per second for comparison
    final aduPerSecond = adu / exposureTime;

    _samples.add(
      _BrightnessSample(aduPerSecond: aduPerSecond, timestamp: timestamp),
    );

    // Prune old samples outside the diagnostic retention horizon. Live rate
    // calculations filter to the much shorter [_maxSampleAge] window.
    _pruneOldSamples();
  }

  void _pruneOldSamples() {
    final cutoff = DateTime.now().subtract(_maxSummarySampleAge);
    _samples.removeWhere((s) => s.timestamp.isBefore(cutoff));
  }

  List<_BrightnessSample> _recentSamples() {
    _pruneOldSamples();
    final cutoff = DateTime.now().subtract(_maxSampleAge);
    return _samples
        .where((sample) => !sample.timestamp.isBefore(cutoff))
        .toList(growable: false);
  }

  /// Calculate current rate of brightness change (ADU/s per second)
  /// Positive = brightening (dawn), Negative = darkening (dusk)
  double? calculateRate() {
    final samples = _recentSamples();
    if (samples.length < _minSamples) return null;

    // Use linear regression for rate calculation
    final n = samples.length;
    final now = DateTime.now();

    double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;

    for (final sample in samples) {
      // X = seconds ago (negative so older = smaller)
      final x = sample.timestamp.difference(now).inMilliseconds / 1000.0;
      final y = sample.aduPerSecond;

      sumX += x;
      sumY += y;
      sumXY += x * y;
      sumX2 += x * x;
    }

    final denominator = n * sumX2 - sumX * sumX;
    if (denominator.abs() < 0.0001) return null;

    // Slope = rate of change
    final slope = (n * sumXY - sumX * sumY) / denominator;

    return slope;
  }

  /// Predict ADU at a future time given current conditions
  double? predictAdu({
    required double exposureTime,
    required Duration futureOffset,
  }) {
    final samples = _recentSamples();
    if (samples.isEmpty) return null;

    final rate = calculateRate();
    final currentAduPerSec = samples.last.aduPerSecond;

    if (rate == null) {
      // No rate info, just use current value
      return currentAduPerSec * exposureTime;
    }

    // Account for exposure duration (average over exposure period)
    final futureSeconds = futureOffset.inMilliseconds / 1000.0;
    final exposureMidpoint = futureSeconds + (exposureTime / 2);
    final midpointAduPerSec = currentAduPerSec + (rate * exposureMidpoint);

    return midpointAduPerSec * exposureTime;
  }

  /// Calculate optimal exposure to achieve target ADU
  double? calculateOptimalExposure({
    required double targetAdu,
    required double minExposure,
    required double maxExposure,
  }) {
    final samples = _recentSamples();
    if (samples.isEmpty) return null;

    final rate = calculateRate();
    final currentAduPerSec = samples.last.aduPerSecond;

    if (currentAduPerSec <= 0) return null;

    // Simple case: no rate change
    if (rate == null || rate.abs() < 0.001) {
      final exposure = targetAdu / currentAduPerSec;
      return exposure.clamp(minExposure, maxExposure);
    }

    // With rate change, solve iteratively
    // Start with naive estimate
    double exposure = targetAdu / currentAduPerSec;

    for (int i = 0; i < 5; i++) {
      final predictedAdu = predictAdu(
        exposureTime: exposure,
        futureOffset: Duration.zero,
      );

      if (predictedAdu == null || predictedAdu <= 0) break;

      // Adjust exposure
      final ratio = targetAdu / predictedAdu;
      exposure = (exposure * ratio).clamp(minExposure, maxExposure);

      // Check convergence
      if ((ratio - 1.0).abs() < 0.02) break;
    }

    return exposure.clamp(minExposure, maxExposure);
  }

  /// Whether sky is getting brighter (dawn) or darker (dusk)
  bool? isBrightening() {
    final rate = calculateRate();
    if (rate == null) return null;
    return rate > 0;
  }

  /// Get number of samples
  int get sampleCount => _recentSamples().length;

  /// Clear all samples
  void clear() => _samples.clear();
}

class _BrightnessSample {
  final double aduPerSecond;
  final DateTime timestamp;

  _BrightnessSample({required this.aduPerSecond, required this.timestamp});
}
