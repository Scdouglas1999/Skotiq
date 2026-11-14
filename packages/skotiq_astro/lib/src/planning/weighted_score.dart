/// Shared DECIDE scoring contract.
///
/// The one home for the weighted-sum aggregation the three target scorers
/// share:
///
///  * the live autopilot [`SchedulerEngine._scoreCandidate`] (6 factors,
///    UNNORMALIZED additive),
///  * the planner [`TargetScoringService.scoreTarget`] (5 axes, NORMALIZED:
///    divide by the weight-sum),
///  * the in-sequence `TargetSchedulerNode` preview + its Rust mirror
///    (`scheduling::scoring`), which use the SAME normalized 5-axis math.
///
/// Their axes and weighting models legitimately differ; only the aggregation is
/// shared. This primitive does NOT pick the weights and does NOT change any
/// numbers — each caller passes its own factors/weights, and
/// [WeightedScoreMode] selects additive vs normalized.
///
/// It lives in `skotiq_planetarium` because the dependency direction is
/// one-way (`skotiq_core` -> `skotiq_planetarium`), so both core
/// callers can delegate here without a cycle.
library;

/// How a [WeightedScore] folds its weighted factors into a single total.
enum WeightedScoreMode {
  /// `total = Σ(factor.value * factor.weight)`.
  ///
  /// The live autopilot [`SchedulerEngine`] aggregation: factors are in
  /// `[0, 1]`, weights are unbounded, and the total is NOT divided by the
  /// weight-sum (so a heavier weight set yields a larger total).
  additive,

  /// `total = Σ(factor.value * factor.weight) / Σ(factor.weight)`.
  ///
  /// The planner [`TargetScoringService`] / in-sequence `TargetSchedulerNode`
  /// aggregation: each factor is a `0..100` axis score and the result is the
  /// weighted *average*, so the total stays on the same `0..100` scale as the
  /// inputs regardless of the weight magnitudes. The divisor is floored at
  /// [epsilon] to mirror the Rust `score_target` `weight_sum.max(EPSILON)`.
  normalized,
}

/// A single weighted factor going into a [WeightedScore].
class WeightedFactor {
  /// Stable identifier for the axis (e.g. `altitude`, `meridian`). Carried so
  /// callers can surface a per-factor breakdown without a parallel structure.
  final String name;

  /// The factor's raw value before weighting. Scale is caller-defined
  /// (`0..1` for the engine, `0..100` for the planner) — the aggregator does
  /// not interpret it.
  final double value;

  /// The weight applied to [value].
  final double weight;

  /// The product `value * weight`, precomputed so callers that already build
  /// a breakdown row do not recompute it.
  double get weighted => value * weight;

  const WeightedFactor({
    required this.name,
    required this.value,
    required this.weight,
  });
}

/// The shared weighted-sum primitive. Folds a list of [WeightedFactor]s into a
/// single total under the chosen [WeightedScoreMode].
class WeightedScore {
  /// Floor for the [WeightedScoreMode.normalized] divisor. Matches the Rust
  /// `score_target` `weight_sum.max(EPSILON)` guard so an all-zero weight set
  /// yields `0` instead of `NaN`.
  static const double epsilon = 1e-9;

  /// Fold [factors] into a single total under [mode].
  ///
  /// [WeightedScoreMode.additive] returns `Σ(value*weight)`.
  /// [WeightedScoreMode.normalized] returns `Σ(value*weight) / Σ(weight)`,
  /// with the divisor floored at [epsilon].
  static double total(
    List<WeightedFactor> factors, {
    required WeightedScoreMode mode,
  }) {
    var weightedSum = 0.0;
    var weightSum = 0.0;
    for (final f in factors) {
      weightedSum += f.value * f.weight;
      weightSum += f.weight;
    }
    switch (mode) {
      case WeightedScoreMode.additive:
        return weightedSum;
      case WeightedScoreMode.normalized:
        final divisor = weightSum < epsilon ? epsilon : weightSum;
        return weightedSum / divisor;
    }
  }
}
