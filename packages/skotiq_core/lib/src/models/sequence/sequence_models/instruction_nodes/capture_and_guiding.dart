// ignore_for_file: invalid_annotation_target

part of '../../sequence_models.dart';

// Instruction nodes

/// Slew to target instruction
class SlewNode extends SequenceNode {
  final bool useTargetCoords;
  final double? customRa;
  final double? customDec;

  SlewNode({
    super.id,
    super.name = 'Slew to Target',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.useTargetCoords = true,
    this.customRa,
    this.customDec,
  });

  @override
  String get nodeType => 'SlewToTarget';

  @override
  String get iconName => 'compass';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.mount};

  @override
  SlewNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    bool? useTargetCoords,
    double? customRa,
    double? customDec,
  }) {
    return SlewNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      useTargetCoords: useTargetCoords ?? this.useTargetCoords,
      customRa: customRa ?? this.customRa,
      customDec: customDec ?? this.customDec,
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    useTargetCoords,
    customRa,
    customDec,
  ];
}

/// Center target (plate solve + sync + slew)
class CenterNode extends SequenceNode {
  final double accuracyArcsec;
  final int maxAttempts;
  final bool useTargetCoords;
  final double? customRa;
  final double? customDec;

  /// Exposure duration for plate solve captures (seconds)
  final double exposureDuration;

  /// Filter to use for plate solve captures (null = current filter)
  final String? filter;

  CenterNode({
    super.id,
    super.name = 'Center Target',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.accuracyArcsec = 5.0,
    this.maxAttempts = 5,
    this.useTargetCoords = true,
    this.customRa,
    this.customDec,
    this.exposureDuration = 5.0,
    this.filter,
  });

  @override
  String get nodeType => 'CenterTarget';

  @override
  String get iconName => 'crosshair';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.mount, DeviceType.camera};

  @override
  CenterNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    double? accuracyArcsec,
    int? maxAttempts,
    bool? useTargetCoords,
    double? customRa,
    double? customDec,
    double? exposureDuration,
    String? filter,
    bool clearFilter = false,
  }) {
    return CenterNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      accuracyArcsec: accuracyArcsec ?? this.accuracyArcsec,
      maxAttempts: maxAttempts ?? this.maxAttempts,
      useTargetCoords: useTargetCoords ?? this.useTargetCoords,
      customRa: customRa ?? this.customRa,
      customDec: customDec ?? this.customDec,
      exposureDuration: exposureDuration ?? this.exposureDuration,
      filter: clearFilter ? null : (filter ?? this.filter),
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    accuracyArcsec,
    maxAttempts,
    useTargetCoords,
    customRa,
    customDec,
    exposureDuration,
    filter,
  ];
}

/// Sky-brightness adaptive exposure config carried on
/// an [ExposureNode] (or as a global default in app settings). Mirrors
/// the Rust `AdaptiveExposureConfig`. Plain immutable value class with
/// hand-rolled equality so we stay consistent with the rest of the
/// sequence-models package (no freezed annotations here).
@Freezed(fromJson: true, toJson: true)
abstract class AdaptiveExposureConfig with _$AdaptiveExposureConfig {
  const AdaptiveExposureConfig._();

  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory AdaptiveExposureConfig({
    /// Target SNR (informational; the current adapter scales by sky-
    /// background flux ratio rather than aiming at a numeric target).
    @Default(30.0) double targetSnr,

    /// Sky brightness in mag/arcsec² that the node's configured nominal
    /// exposure is calibrated for.
    @Default(21.5) double referenceSkyBrightnessMag,

    /// Global minimum exposure clamp (seconds).
    @Default(5.0) double minExposureSecs,

    /// Global maximum exposure clamp (seconds).
    @Default(600.0) double maxExposureSecs,

    /// Per-filter enable map. Filter name -> bool. Empty => apply globally.
    @Default(<String, bool>{}) Map<String, bool> perFilterEnabled,

    /// Per-filter minimum exposure overrides (seconds).
    @Default(<String, double>{}) Map<String, double> perFilterMinSecs,

    /// Per-filter maximum exposure overrides (seconds).
    @Default(<String, double>{}) Map<String, double> perFilterMaxSecs,

    /// Global enable toggle. When false the whole config is a no-op
    /// regardless of per-filter map content.
    @Default(true) bool enabled,
  }) = _AdaptiveExposureConfig;

  factory AdaptiveExposureConfig.fromJson(Map<String, dynamic> json) =>
      _$AdaptiveExposureConfigFromJson(json);

  /// Whether the adapter wants to act on the given filter. Mirrors the
  /// Rust `is_enabled_for_filter`.
  bool isEnabledForFilter(String? filter) {
    if (!enabled) return false;
    if (filter == null) return true;
    final per = perFilterEnabled[filter];
    if (per != null) return per;
    return perFilterEnabled.isEmpty;
  }

  /// Resolve the per-filter min clamp (per-filter wins over global).
  double minForFilter(String? filter) {
    if (filter != null) {
      final per = perFilterMinSecs[filter];
      if (per != null) return per;
    }
    return minExposureSecs;
  }

  /// Resolve the per-filter max clamp (per-filter wins over global).
  double maxForFilter(String? filter) {
    if (filter != null) {
      final per = perFilterMaxSecs[filter];
      if (per != null) return per;
    }
    return maxExposureSecs;
  }
}

/// Take exposure instruction
class ExposureNode extends SequenceNode {
  final double durationSecs;
  final int count;
  final FrameType frameType;
  final String? filter;

  /// Filter position (0-based index). When set, used instead of filter name for reliability.
  final int? filterIndex;
  final int? gain;
  final int? offset;
  final BinningMode binning;
  final int? ditherEvery;
  final List<Map<String, dynamic>> triggers;

  /// Per-node sky-brightness adaptive exposure config.
  /// `null` means "use the global default from app settings"; an
  /// explicit value overrides the global default for this node.
  final AdaptiveExposureConfig? adaptiveExposure;

  ExposureNode({
    super.id,
    super.name = 'Take Exposures',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.durationSecs = 60.0,
    this.count = 10,
    this.frameType = FrameType.light,
    this.filter,
    this.filterIndex,
    this.gain,
    this.offset,
    this.binning = BinningMode.one,
    this.ditherEvery = 3,
    this.triggers = const [],
    this.adaptiveExposure,
  });

  /// Get estimated total duration
  double get totalDurationSecs => durationSecs * count;

  @override
  String get nodeType => 'TakeExposure';

  @override
  String get iconName => 'camera';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.camera};

  @override
  ExposureNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    double? durationSecs,
    int? count,
    FrameType? frameType,
    String? filter,
    int? filterIndex,
    // Passing `filter`/`filterIndex` installs those values; omitting them keeps
    // the current ones. To CLEAR the filter (switch back to unfiltered/'(None)'),
    // pass `clearFilter: true` — it wins over `filter`/`filterIndex` and nulls
    // BOTH, so the editor's "(None)" selection is a single `copyWith` call.
    bool clearFilter = false,
    int? gain,
    int? offset,
    BinningMode? binning,
    int? ditherEvery,
    List<Map<String, dynamic>>? triggers,
    // Plain `?? this.X` semantics: passing `adaptiveExposure: someConfig`
    // installs an explicit per-node override; omitting it keeps the
    // current value. To CLEAR the override (reset to "use global default"),
    // pass `clearAdaptiveExposure: true` — this wins over `adaptiveExposure`
    // and nulls the field, so the editor's "use global default" reset is a
    // single `copyWith` call rather than a hand-rebuilt node.
    AdaptiveExposureConfig? adaptiveExposure,
    bool clearAdaptiveExposure = false,
  }) {
    return ExposureNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      durationSecs: durationSecs ?? this.durationSecs,
      count: count ?? this.count,
      frameType: frameType ?? this.frameType,
      filter: clearFilter ? null : (filter ?? this.filter),
      filterIndex: clearFilter ? null : (filterIndex ?? this.filterIndex),
      gain: gain ?? this.gain,
      offset: offset ?? this.offset,
      binning: binning ?? this.binning,
      ditherEvery: ditherEvery ?? this.ditherEvery,
      triggers: triggers ?? this.triggers,
      adaptiveExposure: clearAdaptiveExposure
          ? null
          : (adaptiveExposure ?? this.adaptiveExposure),
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    durationSecs,
    count,
    frameType,
    filter,
    filterIndex,
    gain,
    offset,
    binning,
    ditherEvery,
    triggers,
    adaptiveExposure,
  ];
}

/// Autofocus instruction
///
/// When [useSettingsDefaults] is true, the node's own values are ignored at
/// execution time and the persisted AppSettings AF parameters are used instead.
/// This lets users configure AF in one place and have all sequencer AF nodes
/// follow those settings automatically.
class AutofocusNode extends SequenceNode {
  final AutofocusMethod method;
  final int stepSize;
  final int stepsOut;
  final int exposuresPerPoint;
  final double exposureDuration;

  /// When true, ignore node-level values and use AppSettings defaults at runtime.
  final bool useSettingsDefaults;

  /// Maximum time in seconds the autofocus run is allowed to take before it
  /// is aborted and treated as a failure. Default 600s (10 minutes).
  final double maxDurationSecs;

  AutofocusNode({
    super.id,
    super.name = 'Autofocus',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.method = AutofocusMethod.vCurve,
    this.stepSize = 100,
    this.stepsOut = 7,
    this.exposuresPerPoint = 1,
    this.exposureDuration = 3.0,
    this.useSettingsDefaults = true,
    this.maxDurationSecs = 600.0,
  });

  @override
  String get nodeType => 'Autofocus';

  @override
  String get iconName => 'focus';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {
    DeviceType.camera,
    DeviceType.focuser,
  };

  @override
  AutofocusNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    AutofocusMethod? method,
    int? stepSize,
    int? stepsOut,
    int? exposuresPerPoint,
    double? exposureDuration,
    bool? useSettingsDefaults,
    double? maxDurationSecs,
  }) {
    return AutofocusNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      method: method ?? this.method,
      stepSize: stepSize ?? this.stepSize,
      stepsOut: stepsOut ?? this.stepsOut,
      exposuresPerPoint: exposuresPerPoint ?? this.exposuresPerPoint,
      exposureDuration: exposureDuration ?? this.exposureDuration,
      useSettingsDefaults: useSettingsDefaults ?? this.useSettingsDefaults,
      maxDurationSecs: maxDurationSecs ?? this.maxDurationSecs,
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    method,
    stepSize,
    stepsOut,
    exposuresPerPoint,
    exposureDuration,
    useSettingsDefaults,
    maxDurationSecs,
  ];
}

/// Dither instruction
/// Mirror of Rust `DitherPattern` (sequencer/src/lib.rs). `random` produces
/// classic uncorrelated offsets each call; `grid` cycles through an NxN
/// grid of positions, which yields more uniform sky coverage.
enum DitherPattern { random, grid }

class DitherNode extends SequenceNode {
  final double pixels;
  final double settleTime;
  final double settlePixels;

  /// Maximum time to wait for settling after dither (seconds)
  final double settleTimeout;

  /// If true, only dither in RA (useful for dec backlash-prone setups)
  final bool raOnly;

  /// Dither pattern selection. [DitherPattern.random] is classic; [DitherPattern.grid]
  /// walks a [gridSize] x [gridSize] grid for systematic coverage.
  final DitherPattern pattern;

  /// Grid side length (N for NxN) used when [pattern] is [DitherPattern.grid].
  /// Ignored for [DitherPattern.random]. Must be >= 2.
  final int gridSize;

  DitherNode({
    super.id,
    super.name = 'Dither',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.pixels = 5.0,
    this.settleTime = 30.0,
    this.settlePixels = 1.5,
    this.settleTimeout = 120.0,
    this.raOnly = false,
    this.pattern = DitherPattern.random,
    this.gridSize = 3,
  });

  @override
  String get nodeType => 'Dither';

  @override
  String get iconName => 'shuffle';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.guider};

  @override
  DitherNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    double? pixels,
    double? settleTime,
    double? settlePixels,
    double? settleTimeout,
    bool? raOnly,
    DitherPattern? pattern,
    int? gridSize,
  }) {
    return DitherNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      pixels: pixels ?? this.pixels,
      settleTime: settleTime ?? this.settleTime,
      settlePixels: settlePixels ?? this.settlePixels,
      settleTimeout: settleTimeout ?? this.settleTimeout,
      raOnly: raOnly ?? this.raOnly,
      pattern: pattern ?? this.pattern,
      gridSize: gridSize ?? this.gridSize,
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    pixels,
    settleTime,
    settlePixels,
    settleTimeout,
    raOnly,
    pattern,
    gridSize,
  ];
}

/// Start guiding instruction - connects to PHD2 and starts guiding
class StartGuidingNode extends SequenceNode {
  final double settlePixels;
  final double settleTime;
  final double settleTimeout;
  final bool autoSelectStar;

  StartGuidingNode({
    super.id,
    super.name = 'Start Guiding',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.settlePixels = 1.5,
    this.settleTime = 10.0,
    this.settleTimeout = 60.0,
    this.autoSelectStar = true,
  });

  @override
  String get nodeType => 'StartGuiding';

  @override
  String get iconName => 'crosshair';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.guider};

  @override
  StartGuidingNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    double? settlePixels,
    double? settleTime,
    double? settleTimeout,
    bool? autoSelectStar,
  }) {
    return StartGuidingNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      settlePixels: settlePixels ?? this.settlePixels,
      settleTime: settleTime ?? this.settleTime,
      settleTimeout: settleTimeout ?? this.settleTimeout,
      autoSelectStar: autoSelectStar ?? this.autoSelectStar,
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    settlePixels,
    settleTime,
    settleTimeout,
    autoSelectStar,
  ];
}

/// Stop guiding instruction - stops PHD2 guiding
class StopGuidingNode extends SequenceNode {
  StopGuidingNode({
    super.id,
    super.name = 'Stop Guiding',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
  });

  @override
  String get nodeType => 'StopGuiding';

  @override
  String get iconName => 'x-circle';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {DeviceType.guider};

  @override
  StopGuidingNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
  }) {
    return StopGuidingNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
    );
  }
}
