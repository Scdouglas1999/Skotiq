import 'dart:math' as math;

/// Calculates optimal flat frame exposure with improved convergence
class FlatExposureCalculator {
  /// Safe full-scale ADU when the connected camera's effective range is
  /// unknown (a 16-bit sensor). Real cameras can be 8/10/12/14/16-bit or expose
  /// an explicit max-ADU capability; callers that know the effective range MUST
  /// pass it as [maxAdu] so a 12/14-bit camera does not chase impossible levels
  /// (a target percentage is always relative to the DETECTED full scale).
  static const int fallbackMaxAdu = 65535;

  /// Convert histogram percentage to an absolute ADU against the effective
  /// full-scale [maxAdu] (default: the safe 16-bit [fallbackMaxAdu]).
  static int histogramPercentToAdu(
    double percent, {
    int maxAdu = fallbackMaxAdu,
  }) {
    final scale = maxAdu > 0 ? maxAdu : fallbackMaxAdu;
    return ((percent / 100.0) * scale).round();
  }

  /// Convert an absolute ADU to a histogram percentage of the effective
  /// full-scale [maxAdu] (default: the safe 16-bit [fallbackMaxAdu]).
  static double aduToHistogramPercent(int adu, {int maxAdu = fallbackMaxAdu}) {
    final scale = maxAdu > 0 ? maxAdu : fallbackMaxAdu;
    return (adu / scale) * 100.0;
  }

  // Next-exposure convergence math lives in one engine,
  // [FlatWizardService.calculateNextExposure], which drives the standalone
  // flat-wizard screen, the headless /api/flat-wizard handlers (via
  // calibrateFilter) and the rate-tracking fallback. Pinned by
  // test/services/flat_convergence_snapshot_test.dart.

  /// Binary search with early termination
  ///
  /// More efficient than proportional adjustment for stable light sources
  static double binarySearchExposure({
    required double lowExposure,
    required double highExposure,
    required double measuredAdu,
    required double targetAdu,
    required double tolerancePercent,
  }) {
    final toleranceAdu = targetAdu * tolerancePercent / 100.0;

    // Check if within tolerance
    if ((measuredAdu - targetAdu).abs() <= toleranceAdu) {
      // Already good, return current midpoint
      return (lowExposure + highExposure) / 2.0;
    }

    // Narrow the search range
    final midpoint = (lowExposure + highExposure) / 2.0;

    if (measuredAdu < targetAdu) {
      // Need more light, search upper half
      return (midpoint + highExposure) / 2.0;
    } else {
      // Too bright, search lower half
      return (lowExposure + midpoint) / 2.0;
    }
  }

  /// Get starting exposure from history or geometric mean
  static double getStartingExposure({
    double? historicalExposure,
    required double minExposure,
    required double maxExposure,
    double? currentSkyAduRate,
    double? historicalSkyAduRate,
  }) {
    if (historicalExposure != null) {
      // Adjust historical exposure for current sky conditions if available
      if (currentSkyAduRate != null &&
          historicalSkyAduRate != null &&
          historicalSkyAduRate.abs() > 0.001) {
        final ratio = currentSkyAduRate / historicalSkyAduRate;
        // Inverse relationship: brighter sky = shorter exposure
        final adjusted = historicalExposure / ratio.clamp(0.5, 2.0);
        return adjusted.clamp(minExposure, maxExposure);
      }
      return historicalExposure.clamp(minExposure, maxExposure);
    }

    // No history, use geometric mean (good for wide ranges)
    return math.sqrt(minExposure * maxExposure);
  }

  /// Check if exposure is at limits and suggest action
  static ExposureLimitStatus checkLimits({
    required double exposure,
    required double measuredAdu,
    required double targetAdu,
    required double minExposure,
    required double maxExposure,
    required double tolerancePercent,
  }) {
    final toleranceAdu = targetAdu * tolerancePercent / 100.0;
    final isOnTarget = (measuredAdu - targetAdu).abs() <= toleranceAdu;

    if (isOnTarget) {
      return ExposureLimitStatus.onTarget;
    }

    if (exposure >= maxExposure * 0.99 && measuredAdu < targetAdu) {
      return ExposureLimitStatus.maxExposureReached;
    }

    if (exposure <= minExposure * 1.01 && measuredAdu > targetAdu) {
      return ExposureLimitStatus.minExposureReached;
    }

    return ExposureLimitStatus.adjusting;
  }
}

enum ExposureLimitStatus {
  onTarget,
  adjusting,
  maxExposureReached,
  minExposureReached,
}
