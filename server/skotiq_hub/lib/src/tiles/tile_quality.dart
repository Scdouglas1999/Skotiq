import 'dart:math' as math;

import 'tile_codec.dart';

/// Robust per-tile quality gate: detects whether an incoming contributor delta
/// is a statistical outlier against the already-fused base tile, so one bad
/// contributor cannot poison a shared stack even if their account trust has not
/// yet been beaten down.
///
/// The check operates on the finalized means: for the pixels both the base and
/// the delta cover, it forms the per-pixel difference `delta - base`, takes its
/// robust centre + spread (median / MAD), and flags the delta if that spread is
/// implausibly large relative to the base's own pixel-to-pixel noise. This is
/// the federation analogue of the keystone's online sigma clip, applied at the
/// contribution granularity instead of the frame granularity.
class TileQualityGate {
  TileQualityGate({this.sigmaThreshold = 6.0, this.minOverlapPixels = 64});

  /// How many robust sigma of base-frame noise the delta's median offset may be
  /// before the contribution is rejected outright.
  final double sigmaThreshold;

  /// Minimum overlapping covered pixels required to judge a contribution. Below
  /// this the overlap is too thin to judge, so the contribution is accepted on
  /// trust alone (the trust weight still scales it).
  final int minOverlapPixels;

  /// Evaluate [delta] against [base]. A fresh tile (base with no coverage)
  /// always passes — there is nothing to be an outlier against.
  TileQualityVerdict evaluate(TileAccumulator base, TileAccumulator delta) {
    final baseMean = base.finalizeMean();
    final deltaMean = delta.finalizeMean();
    final len = math.min(baseMean.length, deltaMean.length);

    // Per-pixel offset where both contributors actually have coverage. Fail
    // closed on any non-finite value in a covered slot: even though the codec
    // rejects NaN/Inf in the raw vectors, a degenerate `sum_wx / sum_w` (e.g. a
    // zero-weight covered slot) can still produce a non-finite mean, and a sort
    // over a list containing NaN is unspecified in Dart — so a hostile delta must
    // never reach the median/MAD math.
    final offsets = <double>[];
    var baseCovered = 0;
    for (var i = 0; i < len; i++) {
      final covered = base.coverage[i] > 0;
      if (covered) {
        baseCovered++;
        if (!baseMean[i].isFinite) {
          return const TileQualityVerdict(
            accepted: false,
            reason: 'non-finite-base',
            medianOffset: 0,
            robustSigma: 0,
            deviation: double.infinity,
          );
        }
      }
      if (covered && delta.coverage[i] > 0) {
        final off = deltaMean[i] - baseMean[i];
        if (!off.isFinite) {
          return const TileQualityVerdict(
            accepted: false,
            reason: 'non-finite-offset',
            medianOffset: 0,
            robustSigma: 0,
            deviation: double.infinity,
          );
        }
        offsets.add(off);
      }
    }

    if (baseCovered == 0 || offsets.length < minOverlapPixels) {
      return const TileQualityVerdict(
        accepted: true,
        reason: 'insufficient-overlap',
        medianOffset: 0,
        robustSigma: 0,
        deviation: 0,
      );
    }

    final med = _median(offsets);
    final mad = _medianAbsoluteDeviation(offsets, med);
    // Scale MAD to a Gaussian-consistent sigma estimate.
    final sigma = mad * 1.4826;

    // Base-frame intrinsic spread, so the threshold scales to the data range.
    final baseSpread = _robustSpread(baseMean, base.coverage);
    final referenceSigma = math.max(sigma, baseSpread * 1e-3);

    final deviation = referenceSigma > 0 ? (med.abs() / referenceSigma) : 0.0;
    final accepted = deviation <= sigmaThreshold;
    return TileQualityVerdict(
      accepted: accepted,
      reason: accepted ? 'within-tolerance' : 'outlier-rejected',
      medianOffset: med,
      robustSigma: referenceSigma,
      deviation: deviation,
    );
  }

  static double _robustSpread(List<double> values, List<int> coverage) {
    final covered = <double>[];
    for (var i = 0; i < values.length; i++) {
      if (coverage[i] > 0) covered.add(values[i]);
    }
    if (covered.isEmpty) return 0;
    final med = _median(covered);
    return _medianAbsoluteDeviation(covered, med) * 1.4826;
  }

  static double _median(List<double> values) {
    final sorted = List<double>.from(values)..sort();
    final n = sorted.length;
    if (n == 0) return 0;
    final mid = n ~/ 2;
    if (n.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  static double _medianAbsoluteDeviation(List<double> values, double center) {
    if (values.isEmpty) return 0;
    final dev = values.map((v) => (v - center).abs()).toList();
    return _median(dev);
  }
}

/// Outcome of a [TileQualityGate] evaluation.
class TileQualityVerdict {
  const TileQualityVerdict({
    required this.accepted,
    required this.reason,
    required this.medianOffset,
    required this.robustSigma,
    required this.deviation,
  });

  final bool accepted;
  final String reason;
  final double medianOffset;
  final double robustSigma;

  /// `|medianOffset| / robustSigma` — how many sigma the delta is off.
  final double deviation;

  Map<String, Object?> toJson() => <String, Object?>{
    'accepted': accepted,
    'reason': reason,
    'medianOffset': medianOffset,
    'robustSigma': robustSigma,
    'deviation': deviation,
  };
}
