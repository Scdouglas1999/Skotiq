// ignore_for_file: invalid_annotation_target

part of '../../sequence_models.dart';

class SmartExposureNode extends SequenceNode {
  /// Ordered list of per-filter plans. Rotation order when [rotateFilters]
  /// is true.
  final List<FilterPlan> plans;

  /// If true, take one batch from each plan in order before repeating
  /// (RGRGRG …). If false, drain each plan before moving to the next
  /// (RRRRRGGG …). Default true (rotation).
  final bool rotateFilters;

  /// If true, run a dither between filter changes in addition to the
  /// per-plan [FilterPlan.ditherEvery]. Default false.
  final bool ditherOnFilterChange;

  /// Global integration budget cap in seconds. When > 0 and the
  /// node-local accumulated exposure time exceeds this value, SmartExposure
  /// returns Success even if some plans have unfilled counts.
  ///
  /// 0 = no cap (run every plan to completion).
  final double integrationBudgetSecs;

  /// Number of exposures to take per filter before rotating to the next
  /// (only meaningful when [rotateFilters] is true). Default 1.
  final int batchSize;

  /// "Loop until stopped" mode. When true, SmartExposure ignores the
  /// per-plan [FilterPlan.count]s entirely and takes exactly one sub per
  /// filter, round-robin, repeating indefinitely until EITHER the
  /// [integrationBudgetSecs] cap is met OR the surrounding target's window
  /// (`endWhen`) closes (or the sequence is stopped/skipped), so every filter
  /// stays evenly sampled across the whole window instead of draining fixed
  /// counts and stopping early.
  ///
  /// In this mode [batchSize] is effectively 1 and [rotateFilters] true
  /// regardless of their stored values (the Rust executor coerces them).
  /// Default false, which keeps the count-draining behaviour.
  ///
  /// Entering this mode with no integration budget AND no bounding target
  /// window is a misconfiguration: the Rust executor fails closed rather than
  /// looping forever, and the editor surfaces a hint.
  final bool loopUntilStopped;

  SmartExposureNode({
    super.id,
    super.name = 'Smart Exposure',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.plans = const [],
    this.rotateFilters = true,
    this.ditherOnFilterChange = false,
    this.integrationBudgetSecs = 0.0,
    this.batchSize = 1,
    this.loopUntilStopped = false,
  });

  @override
  String get nodeType => 'SmartExposure';

  @override
  String get iconName => 'layers';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {
    DeviceType.camera,
    DeviceType.filterWheel,
  };

  /// Sum of per-plan integration time across all filter rows (count *
  /// duration), in seconds. The dashboard's "estimated total" indicator
  /// reads this; wall-clock estimates that include filter-change and
  /// dither overhead live in `sequence_time_estimator.dart`.
  double get totalIntegrationSecs =>
      plans.fold(0.0, (sum, p) => sum + p.integrationSecs);

  /// Number of distinct filter names across [plans]. Used by the UI's
  /// "duplicate filter" warning — two plans with the same filter name are
  /// legal (e.g. two different exposure lengths for the same band) but
  /// usually a UX mistake.
  int get distinctFilterCount => plans.map((p) => p.filterName).toSet().length;

  /// True when at least two plans share the same filter name. Surfaced by
  /// [SmartExposureDuplicateFilterRule].
  bool get hasDuplicateFilter => distinctFilterCount != plans.length;

  @override
  SmartExposureNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    List<FilterPlan>? plans,
    bool? rotateFilters,
    bool? ditherOnFilterChange,
    double? integrationBudgetSecs,
    int? batchSize,
    bool? loopUntilStopped,
  }) {
    return SmartExposureNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      plans: plans ?? this.plans,
      rotateFilters: rotateFilters ?? this.rotateFilters,
      ditherOnFilterChange: ditherOnFilterChange ?? this.ditherOnFilterChange,
      integrationBudgetSecs:
          integrationBudgetSecs ?? this.integrationBudgetSecs,
      batchSize: batchSize ?? this.batchSize,
      loopUntilStopped: loopUntilStopped ?? this.loopUntilStopped,
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    plans,
    rotateFilters,
    ditherOnFilterChange,
    integrationBudgetSecs,
    batchSize,
    loopUntilStopped,
  ];
}
