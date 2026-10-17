import 'dart:math' as math;

/// The 0-100 composite quality score stamped on a captured frame.
///
/// One implementation for both capture paths: a frame that reaches the
/// database with `quality_score` NULL is assessed from
/// `FrameQualityAssessmentService`'s `?? 75.0` fallback, so every such frame
/// scores identically and anything that ranks or rejects on quality (stack
/// frame selection, auto-reject, the "best frame" pick) ranks a constant.
///
/// The weights and bands below match `ImagingService._calculateQualityScore`
/// and the Rust implementation in `imaging/fits.rs`; they are not retuned here.
double computeFrameQualityScore({
  required double? hfr,
  required int? starCount,
  double? mean,
  double? stdDev,
}) {
  double score = 0.0;
  double weightSum = 0.0;

  // HFR (40%). Excellent < 2.0, good 2-3, fair 3-5, poor > 5.
  if (hfr != null && hfr > 0.0) {
    final hfrScore = hfr < 2.0
        ? 100.0
        : hfr < 3.0
        ? 100.0 - (hfr - 2.0) * 25.0
        : hfr < 5.0
        ? 75.0 - (hfr - 3.0) * 25.0
        : math.max(0.0, 25.0 - math.min(5.0, hfr - 5.0) * 5.0);
    score += hfrScore * 0.4;
    weightSum += 0.4;
  }

  // Star count (30%). Excellent > 100, good 50-100, fair 20-50, poor < 20.
  if (starCount != null) {
    final starScore = starCount >= 100
        ? 100.0
        : starCount >= 50
        ? 66.0 + (starCount - 50) / 50.0 * 34.0
        : starCount >= 20
        ? 33.0 + (starCount - 20) / 30.0 * 33.0
        : math.max(0.0, starCount / 20.0 * 33.0);
    score += starScore * 0.3;
    weightSum += 0.3;
  }

  // Background uniformity (30%), via the coefficient of variation.
  //
  // The sequencer's frame event does not carry mean/stdDev, so this component
  // is simply absent there rather than counted as zero — hence the
  // renormalisation below. Scoring a missing measurement as 0 would punish
  // every sequencer frame for a number nobody measured, which is the same
  // mistake in a different place.
  if (mean != null && stdDev != null && mean > 0.0) {
    final cv = stdDev / mean;
    final uniformityScore = cv < 0.1
        ? 100.0
        : cv < 0.3
        ? 100.0 - (cv - 0.1) * 333.0
        : math.max(0.0, 33.0 - math.min(0.33, cv - 0.3) * 100.0);
    score += uniformityScore * 0.3;
    weightSum += 0.3;
  }

  // No measurement at all: say so with a null rather than inventing a number.
  // The assessment service's own `?? 75.0` fallback then applies, and at least
  // it is applying to a frame we genuinely could not measure.
  if (weightSum <= 0.0) return double.nan;

  return (score / weightSum).clamp(0.0, 100.0);
}
