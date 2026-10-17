// ignore_for_file: invalid_annotation_target

part of '../../sequence_models.dart';

class LoopNode extends SequenceNode {
  final LoopConditionType conditionType;
  final int? repeatCount;
  final DateTime? repeatUntil;
  final double? repeatUntilAltitude;

  /// Target total integration time in seconds for [LoopConditionType.integrationTime]
  final double? integrationTimeTarget;

  /// Safety limit for unbounded loops (Forever, WhileDark, etc.).
  /// Caps the maximum number of iterations to prevent runaway loops.
  /// null means no safety limit is set (a validation warning will be shown).
  final int? maxSafetyIterations;

  /// Whether this loop's condition type is unbounded (has no natural termination count).
  bool get isUnbounded =>
      conditionType == LoopConditionType.forever ||
      conditionType == LoopConditionType.whileDark;

  LoopNode({
    super.id,
    super.name = 'Loop',
    super.isEnabled,
    super.childIds,
    super.parentId,
    super.orderIndex,
    super.comment,
    this.conditionType = LoopConditionType.count,
    this.repeatCount = 1,
    this.repeatUntil,
    this.repeatUntilAltitude,
    this.integrationTimeTarget,
    this.maxSafetyIterations,
  });

  @override
  String get nodeType => 'Loop';

  @override
  String get iconName => 'repeat';

  @override
  NodeCategory get category => NodeCategory.logic;

  @override
  LoopNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    LoopConditionType? conditionType,
    int? repeatCount,
    DateTime? repeatUntil,
    double? repeatUntilAltitude,
    double? integrationTimeTarget,
    int? maxSafetyIterations,
  }) {
    return LoopNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      conditionType: conditionType ?? this.conditionType,
      repeatCount: repeatCount ?? this.repeatCount,
      repeatUntil: repeatUntil ?? this.repeatUntil,
      repeatUntilAltitude: repeatUntilAltitude ?? this.repeatUntilAltitude,
      integrationTimeTarget:
          integrationTimeTarget ?? this.integrationTimeTarget,
      maxSafetyIterations: maxSafetyIterations ?? this.maxSafetyIterations,
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    conditionType,
    repeatCount,
    repeatUntil,
    repeatUntilAltitude,
    integrationTimeTarget,
    maxSafetyIterations,
  ];
}

/// Parallel node - executes children in parallel
class ParallelNode extends SequenceNode {
  final int? requiredSuccesses;

  ParallelNode({
    super.id,
    super.name = 'Parallel',
    super.isEnabled,
    super.childIds,
    super.parentId,
    super.orderIndex,
    super.comment,
    this.requiredSuccesses,
  });

  @override
  String get nodeType => 'Parallel';

  @override
  String get iconName => 'git-branch';

  @override
  NodeCategory get category => NodeCategory.logic;

  @override
  ParallelNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    int? requiredSuccesses,
  }) {
    return ParallelNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      requiredSuccesses: requiredSuccesses ?? this.requiredSuccesses,
    );
  }

  @override
  List<Object?> get props => [...super.props, requiredSuccesses];
}

/// Conditional node - executes children only if condition is met
class ConditionalNode extends SequenceNode {
  final ConditionalType conditionType;
  final double? thresholdValue;
  final DateTime? thresholdTime;

  /// Audit C2 — when [conditionType] is [ConditionalType.safetyMonitorSafe]
  /// and the user has multiple safety monitors configured, this names the
  /// specific monitor the conditional branch should consult. `null` =
  /// fall back to the profile-default / aggregated safety state (current
  /// behaviour for single-monitor setups). Ignored for any other
  /// [ConditionalType].
  final String? safetyMonitorId;

  ConditionalNode({
    super.id,
    super.name = 'Conditional',
    super.isEnabled,
    super.childIds,
    super.parentId,
    super.orderIndex,
    super.comment,
    this.conditionType = ConditionalType.always,
    this.thresholdValue,
    this.thresholdTime,
    this.safetyMonitorId,
  });

  @override
  String get nodeType => 'Conditional';

  @override
  String get iconName => 'git-merge';

  @override
  NodeCategory get category => NodeCategory.logic;

  @override
  ConditionalNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    ConditionalType? conditionType,
    double? thresholdValue,
    DateTime? thresholdTime,
    // Plain `?? this.safetyMonitorId` semantics — omitted or null keeps,
    // non-null replaces. To clear the override back to the aggregated /
    // profile-default safety state, pass `clearSafetyMonitorId: true`,
    // which wins over `safetyMonitorId` and nulls the field.
    String? safetyMonitorId,
    bool clearSafetyMonitorId = false,
  }) {
    return ConditionalNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      conditionType: conditionType ?? this.conditionType,
      thresholdValue: thresholdValue ?? this.thresholdValue,
      thresholdTime: thresholdTime ?? this.thresholdTime,
      safetyMonitorId: clearSafetyMonitorId
          ? null
          : (safetyMonitorId ?? this.safetyMonitorId),
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    conditionType,
    thresholdValue,
    thresholdTime,
    safetyMonitorId,
  ];
}
