// ignore_for_file: unused_element

part of '../imaging_service.dart';

extension _ImagingServiceQualityProcessing on ImagingService {
  /// Calculate image quality score (0-100)
  /// Mirrors the Rust implementation in imaging/fits.rs
  /// Delegates to [computeFrameQualityScore] so this path and the sequencer's
  /// frame path cannot drift apart again — they disagreed for long enough that
  /// every sequencer frame carried a NULL score while this one carried a real
  /// number. Kept as a method for the existing call site and its tests.
  double _calculateQualityScore({
    required double? hfr,
    required int? starCount,
    required double mean,
    required double stdDev,
  }) {
    final score = computeFrameQualityScore(
      hfr: hfr,
      starCount: starCount,
      mean: mean,
      stdDev: stdDev,
    );
    // This path returns a non-null double; an unmeasurable frame scores 0.0.
    return score.isNaN ? 0.0 : score;
  }
}
