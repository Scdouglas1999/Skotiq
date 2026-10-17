// ignore_for_file: invalid_annotation_target

part of '../../sequence_models.dart';

/// Meridian Flip instruction
class MeridianFlipNode extends SequenceNode {
  // Trigger conditions
  final MeridianTriggerMethod triggerMethod;
  final double minutesPastMeridian;
  final double minutesBeforeLimit;
  final double hourAngleThreshold;

  // Flip sequence options
  final bool pauseGuiding;
  final bool autoCenter;
  final bool refocusAfter;
  final double settleTime;
  final bool resumeGuiding;

  // Error handling
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
  String get nodeType => 'MeridianFlip';

  @override
  String get iconName => 'refresh-cw';

  /// A meridian flip is a parallel hour-angle / pier-side watchdog that fires
  /// whenever the configured trigger condition is met, regardless of where the
  /// node sits in the tree — it is not an ordered instruction that runs once in
  /// sequence. Classifying it as [NodeCategory.trigger] drives the warning
  /// color and watchdog affordance in every category-switch renderer
  /// (sequence_tree, sequence_minimap, visual_timeline, _input_primitives).
  ///
  /// Note: execution dispatch is unaffected — the Rust-bound executor matches
  /// `MeridianFlipNode` by concrete type, not by [category].
  @override
  NodeCategory get category => NodeCategory.trigger;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.mount};

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

/// Open Dome instruction
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
  String get nodeType => 'OpenDome';

  @override
  String get iconName => 'home';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.dome};

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

/// Close Dome instruction
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
  String get nodeType => 'CloseDome';

  @override
  String get iconName => 'home';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.dome};

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

/// Park Dome instruction
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
  String get nodeType => 'ParkDome';

  @override
  String get iconName => 'parking-circle';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.dome};

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

/// Polar alignment instruction
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
  String get nodeType => 'PolarAlignment';

  @override
  String get iconName => 'compass';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.camera, DeviceType.mount};

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
