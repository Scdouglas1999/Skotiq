// ignore_for_file: invalid_annotation_target

part of '../../sequence_models.dart';

class MeridianFlipNode extends SequenceNode {
  final MeridianTriggerMethod triggerMethod;
  final double minutesPastMeridian;
  final double minutesBeforeLimit;
  final double hourAngleThreshold;

  final bool pauseGuiding;
  final bool autoCenter;
  final bool refocusAfter;
  final double settleTime;
  final bool resumeGuiding;

  final int maxRetries;
  final FlipFailureAction failureAction;

  /// Whether this node should pull its effective configuration from the global
  /// `globalMeridianFlipSettingsProvider` at execution time.
  ///
  /// Fresh nodes (from the palette / quick-start wizard / canonical importers)
  /// carry `useGlobalDefaults: true`, so a change in Sequencer Settings takes
  /// effect without per-node editing. The node's own fields remain as explicit
  /// per-node overrides.
  ///
  /// Editing one of the 11 flip-config fields in the properties panel flips
  /// this to `false` so the edit beats the global setting. That side-effect is
  /// owned by
  /// `applyMeridianFlipEdit(...)` in the editor layer (see
  /// `packages/skotiq_app/lib/screens/sequencer/widgets/`
  /// `meridian_flip_edit_helper.dart`) — NOT by [copyWith], which is a plain
  /// field-replace. Programmatic call sites (JSON load, sequence diff, import
  /// mappers) must use [copyWith] and decide for themselves whether to touch
  /// `useGlobalDefaults`.
  final bool useGlobalDefaults;

  MeridianFlipNode({
    super.id,
    super.name = 'Meridian Flip',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.triggerMethod = MeridianTriggerMethod.minutesPastMeridian,
    this.minutesPastMeridian = 5.0,
    this.minutesBeforeLimit = 10.0,
    this.hourAngleThreshold = 0.5,
    this.pauseGuiding = true,
    this.autoCenter = true,
    this.refocusAfter = false,
    this.settleTime = 10.0,
    this.resumeGuiding = true,
    this.maxRetries = 3,
    this.failureAction = FlipFailureAction.pauseAndAlert,
    this.useGlobalDefaults = true,
  });

  @override
  NodeKind<MeridianFlipNode> get kind => NodeKinds.meridianFlip;

  /// Plain field-replace copy. Per-field UX side-effects (specifically the
  /// "edit clears useGlobalDefaults" sticky override) live in
  /// `applyMeridianFlipEdit(...)` in `skotiq_app`'s editor layer; this
  /// method must stay vanilla so the freezed migration (Phase 6) can replace
  /// it without behavioural drift.
  @override
  MeridianFlipNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    MeridianTriggerMethod? triggerMethod,
    double? minutesPastMeridian,
    double? minutesBeforeLimit,
    double? hourAngleThreshold,
    bool? pauseGuiding,
    bool? autoCenter,
    bool? refocusAfter,
    double? settleTime,
    bool? resumeGuiding,
    int? maxRetries,
    FlipFailureAction? failureAction,
    bool? useGlobalDefaults,
  }) {
    return MeridianFlipNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      triggerMethod: triggerMethod ?? this.triggerMethod,
      minutesPastMeridian: minutesPastMeridian ?? this.minutesPastMeridian,
      minutesBeforeLimit: minutesBeforeLimit ?? this.minutesBeforeLimit,
      hourAngleThreshold: hourAngleThreshold ?? this.hourAngleThreshold,
      pauseGuiding: pauseGuiding ?? this.pauseGuiding,
      autoCenter: autoCenter ?? this.autoCenter,
      refocusAfter: refocusAfter ?? this.refocusAfter,
      settleTime: settleTime ?? this.settleTime,
      resumeGuiding: resumeGuiding ?? this.resumeGuiding,
      maxRetries: maxRetries ?? this.maxRetries,
      failureAction: failureAction ?? this.failureAction,
      useGlobalDefaults: useGlobalDefaults ?? this.useGlobalDefaults,
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    triggerMethod,
    minutesPastMeridian,
    minutesBeforeLimit,
    hourAngleThreshold,
    pauseGuiding,
    autoCenter,
    refocusAfter,
    settleTime,
    resumeGuiding,
    maxRetries,
    failureAction,
    useGlobalDefaults,
  ];
}

class OpenDomeNode extends SequenceNode {
  final bool shutterOnly;

  OpenDomeNode({
    super.id,
    super.name = 'Open Dome',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.shutterOnly = false,
  });

  @override
  NodeKind<OpenDomeNode> get kind => NodeKinds.openDome;

  @override
  OpenDomeNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    bool? shutterOnly,
  }) {
    return OpenDomeNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      shutterOnly: shutterOnly ?? this.shutterOnly,
    );
  }

  @override
  List<Object?> get props => [...super.props, shutterOnly];
}

class CloseDomeNode extends SequenceNode {
  final bool shutterOnly;

  CloseDomeNode({
    super.id,
    super.name = 'Close Dome',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.shutterOnly = false,
  });

  @override
  NodeKind<CloseDomeNode> get kind => NodeKinds.closeDome;

  @override
  CloseDomeNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    bool? shutterOnly,
  }) {
    return CloseDomeNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      shutterOnly: shutterOnly ?? this.shutterOnly,
    );
  }

  @override
  List<Object?> get props => [...super.props, shutterOnly];
}

class ParkDomeNode extends SequenceNode {
  final bool shutterOnly;

  ParkDomeNode({
    super.id,
    super.name = 'Park Dome',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.shutterOnly = false,
  });

  @override
  NodeKind<ParkDomeNode> get kind => NodeKinds.parkDome;

  @override
  ParkDomeNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    bool? shutterOnly,
  }) {
    return ParkDomeNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      shutterOnly: shutterOnly ?? this.shutterOnly,
    );
  }

  @override
  List<Object?> get props => [...super.props, shutterOnly];
}

class PolarAlignmentNode extends SequenceNode {
  final double exposureDuration;
  final int binning;
  final double startAltitude;
  final double rotationStep;
  final int? gain;
  final int? offset;
  final bool startFromCurrent;
  final bool isNorth;
  final bool manualSlew;

  PolarAlignmentNode({
    super.id,
    super.name = 'Polar Alignment',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.exposureDuration = 2.0,
    this.binning = 2,
    this.startAltitude = 45.0,
    this.rotationStep = 20.0,
    this.gain,
    this.offset,
    this.startFromCurrent = true,
    this.isNorth = true,
    this.manualSlew = false,
  });

  @override
  NodeKind<PolarAlignmentNode> get kind => NodeKinds.polarAlignment;

  @override
  PolarAlignmentNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    double? exposureDuration,
    int? binning,
    double? startAltitude,
    double? rotationStep,
    int? gain,
    int? offset,
    bool? startFromCurrent,
    bool? isNorth,
    bool? manualSlew,
  }) {
    return PolarAlignmentNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      exposureDuration: exposureDuration ?? this.exposureDuration,
      binning: binning ?? this.binning,
      startAltitude: startAltitude ?? this.startAltitude,
      rotationStep: rotationStep ?? this.rotationStep,
      gain: gain ?? this.gain,
      offset: offset ?? this.offset,
      startFromCurrent: startFromCurrent ?? this.startFromCurrent,
      isNorth: isNorth ?? this.isNorth,
      manualSlew: manualSlew ?? this.manualSlew,
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    exposureDuration,
    binning,
    startAltitude,
    rotationStep,
    gain,
    offset,
    startFromCurrent,
    isNorth,
    manualSlew,
  ];
}
