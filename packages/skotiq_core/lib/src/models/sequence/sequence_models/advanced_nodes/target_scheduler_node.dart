// ignore_for_file: invalid_annotation_target

part of '../../sequence_models.dart';

class TargetSchedulerNode extends SequenceNode {
  /// Altitude axis weight (default 0.25).
  final double altitudeWeight;

  /// Moon-distance axis weight (default 0.25).
  final double moonDistanceWeight;

  /// Transit-proximity axis weight (default 0.20).
  final double transitProximityWeight;

  /// Darkness axis weight (default 0.15).
  final double darknessWeight;

  /// Airmass axis weight (default 0.15).
  final double airmassWeight;

  /// Minimum total score (0..=100) below which the scheduler treats every
  /// target as unrunnable. When no child clears this floor the node returns
  /// Skipped. Default 30.
  final double minScoreToRun;

  /// Recompute the schedule every N exposures completed inside the
  /// currently-running target's subtree. 0 means "boundary-only" — only
  /// re-decide when the current target finishes.
  final int recomputeEveryNExposures;

  /// Once a target's subtree starts, finish its current Loop iteration
  /// before switching even if a recompute would otherwise pick someone else.
  /// Prevents abandoning a partially-completed exposure burst. Default true.
  final bool finishIterationOnSwitch;

  /// Conditions-score floor below which adaptive swap engages.
  /// `null` disables the feature for this scheduler instance.
  final double? swapOnConditionsBelow;

  /// Minimum seconds between consecutive adaptive swaps
  /// (hysteresis). Default 180s (3 minutes).
  final double swapHysteresisSecs;

  /// Per-tier conditions-score floors. Defaults follow the
  /// brief (faint ≥ 70, medium ≥ 50, bright ≥ 30).
  final BrightnessTierPreferences brightnessTierPreferences;

  /// Score readings older than this are treated as missing
  /// telemetry and the scheduler falls back to the ordinary ranking.
  /// Default 300s (5 minutes).
  final int maxConditionsScoreAgeSecs;

  /// Optional HARD moon-avoidance gate in degrees. When set, any target
  /// within this angular separation of an up, >=10%-illuminated moon is
  /// excluded from scheduling (with a skip reason), regardless of its score —
  /// the NINA/Ekos-style moon-avoidance gate. `null` (default) keeps only the
  /// soft moon-distance score weight.
  final double? minMoonSeparationDeg;

  /// Optional azimuth-dependent site-horizon mask. When set, the in-sequence
  /// scheduler treats any target below `horizonProfile.minAltitudeAt(az)` as
  /// unrunnable — the same per-azimuth horizon mask the live autopilot
  /// consults via the `customHorizon` target constraint. Serialized to the
  /// Rust `horizon_profile` config as the samples-only shape
  /// (`{"samples":[{"az":..,"alt":..}]}`); `null` (default) leaves the node
  /// on a flat altitude floor.
  final HorizonProfile? horizonProfile;

  TargetSchedulerNode({
    super.id,
    super.name = 'Scheduler',
    super.isEnabled,
    super.childIds,
    super.parentId,
    super.orderIndex,
    super.comment,
    this.altitudeWeight = 0.25,
    this.moonDistanceWeight = 0.25,
    this.transitProximityWeight = 0.20,
    this.darknessWeight = 0.15,
    this.airmassWeight = 0.15,
    this.minScoreToRun = 30.0,
    // Sane self-driving default: re-rank the target list every 5 exposures so
    // the scheduler actually adapts to the changing sky over a night. 0 (the
    // old default) meant "pick once, never re-rank" — the adaptive engine
    // never engaged out of the box. Existing saved sequences keep their
    // persisted value (the decoder fallback is unchanged).
    this.recomputeEveryNExposures = 5,
    this.finishIterationOnSwitch = true,
    this.swapOnConditionsBelow,
    this.swapHysteresisSecs = 180.0,
    this.brightnessTierPreferences = const BrightnessTierPreferences(),
    this.maxConditionsScoreAgeSecs = 300,
    this.minMoonSeparationDeg,
    this.horizonProfile,
  });

  /// View of this node's five preview weights as the shared planetarium
  /// [ScoringWeights] contract — the SAME type the planner
  /// [TargetScoringService] consumes and the verbatim Dart mirror of the Rust
  /// `scheduling::scoring::ScoringWeights`. The node's five fields are the
  /// authoritative serialized values (they round-trip through the Rust
  /// `TargetSchedulerConfig` serde); this getter just adapts them so the
  /// in-sequence preview can run through the one shared scorer instead of a
  /// parallel copy. Field set + order + defaults are pinned cross-language by
  /// `target_scheduler_contract_parity_test.dart`.
  ScoringWeights get scoringWeights => ScoringWeights(
    altitudeWeight: altitudeWeight,
    moonDistanceWeight: moonDistanceWeight,
    transitProximityWeight: transitProximityWeight,
    darknessWeight: darknessWeight,
    airmassWeight: airmassWeight,
  );

  /// Stable nodeType identifier. Must match the Rust `NodeType` discriminant
  /// (`TargetScheduler`) so `serde_json::from_str` on the round-tripped
  /// config picks the right variant.
  @override
  String get nodeType => 'TargetScheduler';

  @override
  String get iconName => 'scheduler';

  /// Categorised as `logic` because the node is a container; the editor
  /// colour-codes it the same way as Loop/Parallel.
  @override
  NodeCategory get category => NodeCategory.logic;

  /// The scheduler does not directly require any device — its children
  /// (TargetHeaders) accumulate the device requirements.
  @override
  Set<DeviceType> get requiredDevices => {DeviceType.mount};

  /// True when the five weights sum to approximately 1.0 (lenient ±5% band
  /// so floating-point rounding from UI sliders doesn't trip the warning).
  /// Used by the validator's [TargetSchedulerWeightsRule].
  bool get weightsNormalised {
    final sum =
        altitudeWeight +
        moonDistanceWeight +
        transitProximityWeight +
        darknessWeight +
        airmassWeight;
    return sum >= 0.95 && sum <= 1.05;
  }

  /// Sum of all five weights — surfaced in the UI's "normalised: 1.00"
  /// indicator.
  double get weightsSum =>
      altitudeWeight +
      moonDistanceWeight +
      transitProximityWeight +
      darknessWeight +
      airmassWeight;

  /// Return a copy whose weights sum to exactly 1.0. Used by the
  /// properties-editor "Normalise" button so users don't have to nudge five
  /// sliders by hand.
  TargetSchedulerNode normalisedWeights() {
    final sum = weightsSum;
    if (sum <= 0) return this;
    return copyWith(
      altitudeWeight: altitudeWeight / sum,
      moonDistanceWeight: moonDistanceWeight / sum,
      transitProximityWeight: transitProximityWeight / sum,
      darknessWeight: darknessWeight / sum,
      airmassWeight: airmassWeight / sum,
    );
  }

  @override
  TargetSchedulerNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    double? altitudeWeight,
    double? moonDistanceWeight,
    double? transitProximityWeight,
    double? darknessWeight,
    double? airmassWeight,
    double? minScoreToRun,
    int? recomputeEveryNExposures,
    bool? finishIterationOnSwitch,
    // Keep-or-replace: omitted or null keeps the current value. Clearing it
    // back to null is rebuild-explicit at the editor — see
    // target_scheduler_properties.dart's adaptive-swap toggle.
    double? swapOnConditionsBelow,
    double? swapHysteresisSecs,
    BrightnessTierPreferences? brightnessTierPreferences,
    int? maxConditionsScoreAgeSecs,
    // Keep-or-replace like swapOnConditionsBelow; clearing to null (disable the
    // gate) is rebuild-explicit at the editor.
    double? minMoonSeparationDeg,
    // Keep-or-replace; clearing the mask (back to a flat floor) is
    // rebuild-explicit at the editor.
    HorizonProfile? horizonProfile,
  }) {
    return TargetSchedulerNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      altitudeWeight: altitudeWeight ?? this.altitudeWeight,
      moonDistanceWeight: moonDistanceWeight ?? this.moonDistanceWeight,
      transitProximityWeight:
          transitProximityWeight ?? this.transitProximityWeight,
      darknessWeight: darknessWeight ?? this.darknessWeight,
      airmassWeight: airmassWeight ?? this.airmassWeight,
      minScoreToRun: minScoreToRun ?? this.minScoreToRun,
      recomputeEveryNExposures:
          recomputeEveryNExposures ?? this.recomputeEveryNExposures,
      finishIterationOnSwitch:
          finishIterationOnSwitch ?? this.finishIterationOnSwitch,
      swapOnConditionsBelow:
          swapOnConditionsBelow ?? this.swapOnConditionsBelow,
      swapHysteresisSecs: swapHysteresisSecs ?? this.swapHysteresisSecs,
      brightnessTierPreferences:
          brightnessTierPreferences ?? this.brightnessTierPreferences,
      maxConditionsScoreAgeSecs:
          maxConditionsScoreAgeSecs ?? this.maxConditionsScoreAgeSecs,
      minMoonSeparationDeg: minMoonSeparationDeg ?? this.minMoonSeparationDeg,
      horizonProfile: horizonProfile ?? this.horizonProfile,
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    altitudeWeight,
    moonDistanceWeight,
    transitProximityWeight,
    darknessWeight,
    airmassWeight,
    minScoreToRun,
    recomputeEveryNExposures,
    finishIterationOnSwitch,
    swapOnConditionsBelow,
    swapHysteresisSecs,
    brightnessTierPreferences,
    maxConditionsScoreAgeSecs,
    minMoonSeparationDeg,
    horizonProfile,
  ];
}

// SmartExposure — multi-filter container instruction

/// One row in a [SmartExposureNode]'s filter plan.
///
/// Mirrors the Rust `FilterPlan` struct in
/// `native/skotiq_native/sequencer/src/lib.rs`. The field set is the
/// minimal "what to take per filter": filter name (+ optional index), how
/// many subs, sub-length, gain/offset/binning, and a per-plan dither
/// cadence override.
@Freezed(fromJson: true, toJson: true)
abstract class FilterPlan with _$FilterPlan {
  const FilterPlan._();

  // `explicitToJson` because [depthGoal] is itself a model: without it
  // `toJson()` leaves a `DepthGoalBinding` OBJECT under `depth_goal` instead
  // of its map, so the returned map is only JSON by accident — `jsonEncode`
  // recovers it through `toEncodable`, and every other consumer of the map
  // gets a Dart instance where the Rust side's `Option<DepthGoalBinding>`
  // expects an object. `AdaptiveSwapSnapshot` already sets it for the same
  // reason.
  @JsonSerializable(
    fieldRename: FieldRename.snake,
    includeIfNull: true,
    explicitToJson: true,
  )
  const factory FilterPlan({
    /// Filter wheel slot name (e.g. "L", "Ha"). Matched against the
    /// connected filter wheel's name list when [filterIndex] is null.
    @Default('') String filterName,

    /// 0-based filter wheel index. Preferred over [filterName] for
    /// reliability — matches `ExposureNode.filterIndex` / Rust
    /// `FilterConfig::filter_index`.
    int? filterIndex,

    /// Total number of exposures to take for this filter.
    @Default(10) int count,

    /// Sub-exposure duration in seconds.
    @Default(60.0) double durationSecs,

    /// Optional gain override. null means "use camera/profile default".
    int? gain,

    /// Optional offset override.
    int? offset,

    /// Binning for this filter. Defaults to 1x1.
    @Default(BinningMode.one) @BinningModeJsonConverter() BinningMode binning,

    /// Per-plan dither cadence (every N frames). null disables dithering for
    /// this filter regardless of any global default. 0 is treated as "no
    /// dither" — matches `ExposureNode.ditherEvery`.
    int? ditherEvery,

    /// Optional DepthLock binding. When set, the executor asks the goal
    /// store for a verdict before each batch of this plan and treats an
    /// achieved goal (with automatic completion enabled) as the plan being
    /// complete. null keeps the plan purely count-bounded — matches Rust
    /// `FilterPlan::depth_goal`.
    DepthGoalBinding? depthGoal,
  }) = _FilterPlan;

  factory FilterPlan.fromJson(Map<String, dynamic> json) =>
      _$FilterPlanFromJson(json);

  /// Estimated integration time for this row, in seconds (count * duration).
  /// Does NOT include filter change or dither overhead — that's added by
  /// `SmartExposureNode.estimateTotalSecs`.
  double get integrationSecs => count * durationSecs;
}

/// A Smart Exposure plan's link to one revision of a DepthLock goal.
///
/// Mirrors Rust `depth_goal::DepthGoalBinding`. The revision is part of the
/// binding on purpose: editing a goal's region or definition produces a new
/// revision with fresh evidence, and a plan authored against the old one
/// must not complete on the new one's verdict.
@Freezed(fromJson: true, toJson: true)
abstract class DepthGoalBinding with _$DepthGoalBinding {
  const DepthGoalBinding._();

  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory DepthGoalBinding({
    required String goalId,
    required int revision,
  }) = _DepthGoalBinding;

  factory DepthGoalBinding.fromJson(Map<String, dynamic> json) =>
      _$DepthGoalBindingFromJson(json);
}

/// Map [BinningMode] to the PascalCase string Rust's serde expects.
/// Kept private and local: SciencePhotometryNode and SmartExposureNode
/// (SequenceNode subclasses) still call into these helpers directly because
/// their freezed conversion is deferred.
/// New non-SequenceNode classes should use [BinningModeJsonConverter]
/// from `_json_converters.dart` instead — `FilterPlan` does.
String _binningModeToRustString(BinningMode mode) {
  switch (mode) {
    case BinningMode.one:
      return 'One';
    case BinningMode.two:
      return 'Two';
    case BinningMode.three:
      return 'Three';
    case BinningMode.four:
      return 'Four';
  }
}

BinningMode _rustStringToBinningMode(String? value) {
  switch (value) {
    case 'One':
      return BinningMode.one;
    case 'Two':
      return BinningMode.two;
    case 'Three':
      return BinningMode.three;
    case 'Four':
      return BinningMode.four;
    default:
      return BinningMode.one;
  }
}

/// SmartExposure container instruction. One row per filter; the node
/// internally handles filter changes, dither cadence, and rotation order
/// — see the Rust `SmartExposureConfig` doc-comment for the full execution
/// semantics.
///
/// SmartExposure is a *leaf* in the Dart tree (no childIds): the per-filter
/// behaviour is fully encoded in the [plans] field. The Rust executor
/// dispatches each plan row through the existing `TakeExposure` /
/// `ChangeFilter` instruction nodes via the InstructionRegistry, so a
/// hand-authored `FilterChange → Loop(N) → TakeExposure` chain and a
/// SmartExposure with the equivalent plan rows produce indistinguishable
/// imaging output.
