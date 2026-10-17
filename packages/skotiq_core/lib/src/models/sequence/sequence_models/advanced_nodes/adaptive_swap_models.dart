// ignore_for_file: invalid_annotation_target

part of '../../sequence_models.dart';

enum BrightnessTier {
  /// Galaxies, faint nebulae — needs pristine sky.
  faint,

  /// Bright galaxies, medium nebulae — tolerates degraded sky.
  medium,

  /// Planetary nebulae, open clusters — tolerates poor sky.
  bright;

  /// Stable wire string used by the Rust ↔ Dart bridge. Matches
  /// `BrightnessTier::as_str()` on the Rust side.
  String get wireValue => name; // 'faint' / 'medium' / 'bright'

  /// Human-friendly label for the properties editor dropdown.
  String get displayLabel {
    switch (this) {
      case BrightnessTier.faint:
        return 'Faint (galaxies, dim nebulae)';
      case BrightnessTier.medium:
        return 'Medium (bright galaxies, dim nebulae)';
      case BrightnessTier.bright:
        return 'Bright (planetary nebulae, open clusters)';
    }
  }

  /// Parse from the wire string. Returns `null` for unrecognised values
  /// so callers can fall back to "auto" rather than silently accepting
  /// junk input — schema drift between Rust and Dart should be loud.
  static BrightnessTier? fromWire(String? s) {
    if (s == null) return null;
    switch (s.toLowerCase()) {
      case 'faint':
        return BrightnessTier.faint;
      case 'medium':
        return BrightnessTier.medium;
      case 'bright':
        return BrightnessTier.bright;
      default:
        return null;
    }
  }
}

/// Per-tier conditions-score floor preferences. Mirrors the
/// Rust `BrightnessTierPreferences` struct.
@Freezed(fromJson: true, toJson: true)
abstract class BrightnessTierPreferences with _$BrightnessTierPreferences {
  const BrightnessTierPreferences._();

  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory BrightnessTierPreferences({
    @Default(70.0) double faintMinScore,
    @Default(50.0) double mediumMinScore,
    @Default(30.0) double brightMinScore,
  }) = _BrightnessTierPreferences;

  factory BrightnessTierPreferences.fromJson(Map<String, dynamic> json) =>
      _$BrightnessTierPreferencesFromJson(json);

  double floorFor(BrightnessTier tier) {
    switch (tier) {
      case BrightnessTier.faint:
        return faintMinScore;
      case BrightnessTier.medium:
        return mediumMinScore;
      case BrightnessTier.bright:
        return brightMinScore;
    }
  }

  bool accepts(BrightnessTier tier, double score) => score >= floorFor(tier);
}

/// Per-axis weights applied when composing the live
/// ConditionsScore. Mirrors the Rust `ConditionsScoreWeights` struct.
@Freezed(fromJson: true, toJson: true)
abstract class ConditionsScoreWeights with _$ConditionsScoreWeights {
  const ConditionsScoreWeights._();

  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory ConditionsScoreWeights({
    @Default(0.40) double transparencyWeight,
    @Default(0.25) double seeingWeight,
    @Default(0.25) double cloudWeight,
    @Default(0.10) double windWeight,
  }) = _ConditionsScoreWeights;

  factory ConditionsScoreWeights.fromJson(Map<String, dynamic> json) =>
      _$ConditionsScoreWeightsFromJson(json);

  double get sum =>
      transparencyWeight + seeingWeight + cloudWeight + windWeight;

  /// True when the weights sum to ~1.0 (validator lenient ±5% band).
  bool get isNormalised => sum >= 0.95 && sum <= 1.05;
}

/// Composite sky-conditions score (0..=100) pushed from Dart
/// to the Rust executor. Mirrors `ConditionsScore`.
@Freezed(fromJson: true, toJson: true)
abstract class ConditionsScore with _$ConditionsScore {
  const ConditionsScore._();

  // `explicitToJson: true` so the nested `weights` field is materialised
  // as a `Map<String, dynamic>` (via `ConditionsScoreWeights.toJson`)
  // rather than left as a raw `ConditionsScoreWeights` instance in the
  // emitted Map. Phase 1's `to_json_uses_snake_case_and_unix_secs...`
  // contract test asserts `json['weights'] is Map<String, dynamic>`.
  @JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
  const factory ConditionsScore({
    required double score,
    double? transparencyScore,
    double? seeingScore,
    double? cloudScore,
    double? windScore,
    @Default(ConditionsScoreWeights()) ConditionsScoreWeights weights,
    // `generated_unix_secs` (int seconds) on the wire. The Rust side uses
    // `serde_with::TimestampSeconds<i64>`. The field is required rather than
    // defaulting to `0` (epoch), so a missing key throws instead of decoding
    // into a fabricated timestamp. The Rust producer always emits it, so only
    // synthetic JSON can hit that path.
    @JsonKey(name: 'generated_unix_secs')
    @UnixSecsDateTimeConverter()
    required DateTime generatedAt,
  }) = _ConditionsScore;

  factory ConditionsScore.fromJson(Map<String, dynamic> json) =>
      _$ConditionsScoreFromJson(json);

  /// Convenience: classify the score band.
  String get qualityLabel {
    if (score >= 90) return 'Pristine';
    if (score >= 70) return 'Good';
    if (score >= 50) return 'Degraded';
    return 'Bad';
  }
}

/// Runtime adaptive-swap state pushed from Rust to the dashboard.
/// Mirrors the Rust `AdaptiveSwapRuntimeState` struct.
@Freezed(fromJson: true, toJson: true)
abstract class AdaptiveSwapRuntimeState with _$AdaptiveSwapRuntimeState {
  const AdaptiveSwapRuntimeState._();

  @JsonSerializable(fieldRename: FieldRename.snake, includeIfNull: true)
  const factory AdaptiveSwapRuntimeState({
    String? currentTargetId,
    String? currentTier,
    String? lastDecisionKind,
    String? lastDecisionReason,
    // `last_swap_unix_secs` (nullable int seconds). When `null`, the
    // JSON field is present-with-null (not omitted) — Phase 1's
    // `null_last_swap_serialises_as_null_field` contract test pins this.
    @JsonKey(name: 'last_swap_unix_secs')
    @NullableUnixSecsDateTimeConverter()
    DateTime? lastSwapAt,
    String? lastSwapFromTargetId,
    String? lastSwapToTargetId,
    double? lastObservedScore,
    double? configuredThreshold,
    @Default(180.0) double configuredHysteresisSecs,
  }) = _AdaptiveSwapRuntimeState;

  factory AdaptiveSwapRuntimeState.fromJson(Map<String, dynamic> json) =>
      _$AdaptiveSwapRuntimeStateFromJson(json);

  /// Seconds until the next swap is allowed by hysteresis. Returns `null`
  /// when no swap has fired yet or the cooldown has elapsed.
  double? cooldownRemainingSecs(DateTime now) {
    final last = lastSwapAt;
    if (last == null) return null;
    final elapsed = now.difference(last).inMilliseconds / 1000.0;
    final remaining = configuredHysteresisSecs - elapsed;
    return remaining > 0 ? remaining : null;
  }
}

/// Paired snapshot returned by
/// `api_sequencer_get_adaptive_swap_json`. The score may be null when
/// telemetry has been lost while a previous adaptive-swap decision is
/// still on display, so the two fields are independent.
@Freezed(fromJson: true, toJson: true)
abstract class AdaptiveSwapSnapshot with _$AdaptiveSwapSnapshot {
  // `explicitToJson: true` so the nested `score` and `state` fields are
  // serialised as `Map<String, dynamic>` rather than as raw freezed
  // instances. Phase 1's `to_json_nests_score_and_state` contract test
  // asserts both nested fields decode as Maps.
  @JsonSerializable(explicitToJson: true)
  const factory AdaptiveSwapSnapshot({
    ConditionsScore? score,
    // Default empty state used when the JSON payload is missing
    // `state` entirely (Phase 1's
    // `from_json_treats_missing_state_as_default_state` contract test).
    @Default(AdaptiveSwapRuntimeState()) AdaptiveSwapRuntimeState state,
  }) = _AdaptiveSwapSnapshot;

  factory AdaptiveSwapSnapshot.fromJson(Map<String, dynamic> json) =>
      _$AdaptiveSwapSnapshotFromJson(json);
}

/// Container node that picks the highest-scoring runnable [TargetHeaderNode]
/// child at runtime instead of executing them in author order.
///
/// Mirrors `TargetSchedulerConfig` in the Rust sequencer (see
/// `native/skotiq_native/sequencer/src/lib.rs`). All scoring weights and
/// thresholds are sent verbatim to the Rust scheduler which uses the same
/// scoring math as the planetarium-side `TargetScoringService` — see the
/// parity test in `target_scheduler/scoring.rs`.
