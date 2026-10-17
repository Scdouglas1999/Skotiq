// ignore_for_file: invalid_annotation_target

part of '../../sequence_models.dart';

/// Target header - the root node containing imaging instructions for a target.
/// Each target acts as an independent root in the sequence tree.
/// Provides rich display with coordinates, altitude plot, and progress tracking.
class TargetHeaderNode extends SequenceNode {
  final String targetName;
  final double raHours;
  final double decDegrees;
  final double? rotation;

  /// User priority used by scheduler scoring; higher values are more important.
  final int priority;
  final double? minAltitude;
  final double? maxAltitude;
  final DateTime? startAfter;
  final DateTime? endBefore;
  final MosaicPanelInfo? mosaicPanel;

  /// Optional per-target integration budget. `null` =
  /// no budget enforcement (current behaviour). When set, the
  /// TargetHeader runtime returns Success the moment the budget is met
  /// and the dashboard shows live per-filter progress bars.
  final IntegrationBudget? integrationBudget;

  /// Wait condition: target waits until this becomes true
  /// before imaging children. When `null` *and* none of the legacy
  /// `startAfter` / `minAltitude` fields are set, the target starts
  /// immediately.
  final TargetTrigger? startWhen;

  /// Stop condition: target ends as soon as this becomes true.
  /// When `null` *and* none of the legacy `endBefore` / `maxAltitude`
  /// fields are set, the target runs to natural completion of its
  /// children.
  final TargetTrigger? endWhen;

  /// How often (seconds) the runtime polls `startWhen` /
  /// `endWhen`. Default 30s.
  final int triggerPollIntervalSecs;

  /// Brightness tier hint consulted by the TargetScheduler's
  /// adaptive-swap logic. `null` lets the scheduler infer the tier (or
  /// default to [BrightnessTier.medium]). Pinned values:
  /// [BrightnessTier.faint] for galaxies / faint nebulae,
  /// [BrightnessTier.medium] for bright galaxies / dim nebulae,
  /// [BrightnessTier.bright] for planetary nebulae / open clusters.
  final BrightnessTier? brightnessTierHint;

  /// DB `targets.id` this header images, set when the sequence is generated
  /// from a known catalog/library target (the live scheduler populates it
  /// from the `SchedulerCandidate`). The frame-registration path walks the
  /// tree to this id so captured frames are attributed to the correct
  /// `targets` row and per-target integration goals can complete; without it
  /// frames register with `target_id=NULL` and no goal ever closes.
  ///
  /// RUNTIME-ONLY: deliberately NOT serialized (scheduler sequences are
  /// dispatched in-memory and never saved) and NOT sent to the Rust executor;
  /// it exists purely for Dart-side frame attribution. `null` for ad-hoc /
  /// manual sequences with no backing target row (frames stay unattributed,
  /// which is the honest result).
  final int? catalogTargetId;

  TargetHeaderNode({
    super.id,
    super.name = 'Target',
    super.isEnabled,
    super.childIds,
    super.parentId,
    super.orderIndex,
    super.comment,
    required this.targetName,
    required this.raHours,
    required this.decDegrees,
    this.rotation,
    this.priority = 0,
    this.minAltitude,
    this.maxAltitude,
    this.startAfter,
    this.endBefore,
    this.mosaicPanel,
    this.integrationBudget,
    this.startWhen,
    this.endWhen,
    this.triggerPollIntervalSecs = 30,
    this.brightnessTierHint,
    this.catalogTargetId,
  });

  @override
  String get nodeType => 'TargetHeader';

  @override
  String get iconName => 'target';

  @override
  NodeCategory get category => NodeCategory.target;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.mount};

  /// Get display name including mosaic panel info if applicable
  String get displayName {
    if (mosaicPanel != null) {
      return '$targetName (${mosaicPanel!.displayLabel})';
    }
    return targetName;
  }

  /// Check if this target has time constraints
  bool get hasTimeConstraints => startAfter != null || endBefore != null;

  /// Check if this target has altitude constraints
  bool get hasAltitudeConstraints => minAltitude != null || maxAltitude != null;

  /// True iff the integration budget is configured and
  /// will actually enforce a cap. Used by UI to gate the "Budget" panel.
  bool get hasActiveIntegrationBudget =>
      integrationBudget != null && integrationBudget!.isActive;

  /// True iff this target has an explicit start/end crossing
  /// configured. Used by the Targets tab to render the "Imaging window:
  /// HH:MM – HH:MM" row.
  bool get hasCrossingTriggers => startWhen != null || endWhen != null;

  /// One-line label describing the imaging window in human
  /// terms ("starts when altitude ≥ 35°, ends when altitude ≤ 30°").
  /// Returns `null` when no triggers are set. The dashboard / Targets
  /// tab uses this to render a friendly row without re-deriving labels.
  String? get crossingWindowLabel {
    if (startWhen == null && endWhen == null) return null;
    final parts = <String>[];
    if (startWhen != null) parts.add('starts when ${startWhen!.label}');
    if (endWhen != null) parts.add('ends when ${endWhen!.label}');
    return parts.join(' · ');
  }

  @override
  TargetHeaderNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    String? targetName,
    double? raHours,
    double? decDegrees,
    double? rotation,
    int? priority,
    double? minAltitude,
    double? maxAltitude,
    DateTime? startAfter,
    DateTime? endBefore,
    MosaicPanelInfo? mosaicPanel,
    // Keep-or-replace: omitted or null = keep, non-null = replace. Clearing
    // any of these back to null is rebuild-explicit at the editor — see
    // _target_node_properties.dart's integration-budget toggle for the
    // canonical recipe.
    IntegrationBudget? integrationBudget,
    TargetTrigger? startWhen,
    TargetTrigger? endWhen,
    int? triggerPollIntervalSecs,
    BrightnessTier? brightnessTierHint,
    int? catalogTargetId,
  }) {
    return TargetHeaderNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      targetName: targetName ?? this.targetName,
      raHours: raHours ?? this.raHours,
      decDegrees: decDegrees ?? this.decDegrees,
      rotation: rotation ?? this.rotation,
      priority: priority ?? this.priority,
      minAltitude: minAltitude ?? this.minAltitude,
      maxAltitude: maxAltitude ?? this.maxAltitude,
      startAfter: startAfter ?? this.startAfter,
      endBefore: endBefore ?? this.endBefore,
      mosaicPanel: mosaicPanel ?? this.mosaicPanel,
      integrationBudget: integrationBudget ?? this.integrationBudget,
      startWhen: startWhen ?? this.startWhen,
      endWhen: endWhen ?? this.endWhen,
      triggerPollIntervalSecs:
          triggerPollIntervalSecs ?? this.triggerPollIntervalSecs,
      brightnessTierHint: brightnessTierHint ?? this.brightnessTierHint,
      catalogTargetId: catalogTargetId ?? this.catalogTargetId,
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    targetName,
    raHours,
    decDegrees,
    rotation,
    priority,
    minAltitude,
    maxAltitude,
    startAfter,
    endBefore,
    mosaicPanel,
    integrationBudget,
    startWhen,
    endWhen,
    triggerPollIntervalSecs,
    brightnessTierHint,
    catalogTargetId,
  ];
}
