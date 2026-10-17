// ignore_for_file: invalid_annotation_target

part of '../sequence_models.dart';

/// Per-frame photometric quality gates. Mirrors the Rust
/// `PhotometryQualityGates` struct one-to-one. Frames failing any gate
/// are routed to the Image Grading reject folder and their
/// `photometry_measurements` row is marked outlier.
@Freezed(fromJson: true, toJson: true)
abstract class PhotometryQualityGates with _$PhotometryQualityGates {
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory PhotometryQualityGates({
    /// Minimum target SNR. AAVSO research-grade default is 50.
    @Default(50.0) double minSnr,

    /// Maximum acceptable FWHM in arcseconds. Default 5".
    @Default(5.0) double maxFwhmArcsec,

    /// When true, frames where any reference star failed to extract are
    /// rejected.
    @Default(true) bool requireAllRefsVisible,

    /// Maximum airmass. AAVSO Bright Star Monitor cut-off ≈ 2.5.
    @Default(2.5) double maxAirmass,
  }) = _PhotometryQualityGates;

  factory PhotometryQualityGates.fromJson(Map<String, dynamic> json) =>
      _$PhotometryQualityGatesFromJson(json);
}

/// Standard photometric bands recognised by the Dart-side validator.
/// Matches `SciencePhotometryConfig::is_photometric_filter_name` in Rust.
const Set<String> kPhotometricFilterBands = {
  'V',
  'B',
  'R',
  'I',
  'U',
  'g',
  'r',
  'i',
  'z',
  "g'",
  "r'",
  "i'",
  "z'",
  'Clear',
  'CV',
  'CR',
  'CB',
};

bool isPhotometricFilterBand(String name) =>
    kPhotometricFilterBands.contains(name.trim());

/// Cadence-enforced photometric capture node. Mirrors the Rust
/// `NodeType::SciencePhotometry(SciencePhotometryConfig)` variant.
///
/// The node delegates per-frame capture to the standard
/// `TakeExposure` pipeline and layers in per-frame photometric
/// reduction (instrumental + differential magnitude) + cadence
/// tracking. Frames failing the configured quality gates are routed
/// to the Image Grading reject path.
class SciencePhotometryNode extends SequenceNode {
  /// Target object identifier (catalogue ID, e.g. "V0376 Per").
  final String targetDesignation;

  /// Catalogue IDs of reference stars used for differential photometry.
  /// Empty when [applyDifferential] is false.
  final List<String> referenceStars;

  /// Maximum inter-frame start-to-start gap (seconds) before a
  /// cadence-broken warning is emitted. 0.0 disables the check.
  /// Default 2.0s — matches the brief's V0376 Per example.
  final double maxCadenceGapSecs;

  /// Photometric filter (one of [kPhotometricFilterBands]).
  final String filter;

  /// Per-frame exposure duration in seconds.
  final double exposureSecs;

  /// Number of frames to capture in the burst.
  final int count;

  /// When true, the runtime extracts the target's instrumental
  /// magnitude from each captured frame in real time and writes a row
  /// to `photometry_measurements`.
  final bool reduceLive;

  /// When true (and [reduceLive] is true), additionally computes the
  /// differential magnitude against [referenceStars].
  final bool applyDifferential;

  /// Per-frame quality gates.
  final PhotometryQualityGates quality;

  /// Optional gain override.
  final int? gain;

  /// Optional offset override.
  final int? offset;

  /// Binning.
  final BinningMode binning;

  SciencePhotometryNode({
    super.id,
    super.name = 'Science Photometry',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.targetDesignation = '',
    this.referenceStars = const [],
    this.maxCadenceGapSecs = 2.0,
    this.filter = 'Clear',
    this.exposureSecs = 60.0,
    this.count = 60,
    this.reduceLive = true,
    this.applyDifferential = true,
    this.quality = const PhotometryQualityGates(),
    this.gain,
    this.offset,
    this.binning = BinningMode.one,
  });

  @override
  String get nodeType => 'SciencePhotometry';

  @override
  String get iconName => 'analytics';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => {
    DeviceType.camera,
    DeviceType.filterWheel,
  };

  bool get isPhotometricFilter => isPhotometricFilterBand(filter);

  /// True when the configured cadence is structurally invalid. The
  /// runtime computes the start-to-start gap and compares it against
  /// `exposure_secs + max_cadence_gap_secs`, so the only nonsense
  /// values are negative or NaN. We treat `< 0` as impossible.
  bool get hasImpossibleCadence => maxCadenceGapSecs < 0.0;

  @override
  SciencePhotometryNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    String? targetDesignation,
    List<String>? referenceStars,
    double? maxCadenceGapSecs,
    String? filter,
    double? exposureSecs,
    int? count,
    bool? reduceLive,
    bool? applyDifferential,
    PhotometryQualityGates? quality,
    // Plain `?? this.X` for gain and offset. To clear back to null
    // (i.e. "no per-node override; use the device default"), pass
    // `clearGain: true` / `clearOffset: true`, which win over the
    // corresponding value arg and null the field.
    int? gain,
    int? offset,
    bool clearGain = false,
    bool clearOffset = false,
    BinningMode? binning,
  }) {
    return SciencePhotometryNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      targetDesignation: targetDesignation ?? this.targetDesignation,
      referenceStars: referenceStars ?? this.referenceStars,
      maxCadenceGapSecs: maxCadenceGapSecs ?? this.maxCadenceGapSecs,
      filter: filter ?? this.filter,
      exposureSecs: exposureSecs ?? this.exposureSecs,
      count: count ?? this.count,
      reduceLive: reduceLive ?? this.reduceLive,
      applyDifferential: applyDifferential ?? this.applyDifferential,
      quality: quality ?? this.quality,
      gain: clearGain ? null : (gain ?? this.gain),
      offset: clearOffset ? null : (offset ?? this.offset),
      binning: binning ?? this.binning,
    );
  }

  /// Serialise to the JSON shape expected by the Rust
  /// `SciencePhotometryConfig` (snake_case keys, externally tagged).
  Map<String, dynamic> toRustConfigJson() => {
    'target_designation': targetDesignation,
    'reference_stars': referenceStars,
    'max_cadence_gap_secs': maxCadenceGapSecs,
    'filter': filter,
    'exposure_secs': exposureSecs,
    'count': count,
    'reduce_live': reduceLive,
    'apply_differential': applyDifferential,
    'quality': quality.toJson(),
    'gain': gain,
    'offset': offset,
    'binning': _binningModeToRustString(binning),
  };

  factory SciencePhotometryNode.fromRustConfigJson(
    Map<String, dynamic> json, {
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
  }) {
    final refs =
        (json['reference_stars'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList(growable: false) ??
        const <String>[];
    final qualityJson = json['quality'];
    final quality = qualityJson is Map<String, dynamic>
        ? PhotometryQualityGates.fromJson(qualityJson)
        : const PhotometryQualityGates();
    return SciencePhotometryNode(
      id: id,
      name: name ?? 'Science Photometry',
      isEnabled: isEnabled ?? true,
      childIds: childIds ?? const [],
      parentId: parentId,
      orderIndex: orderIndex ?? 0,
      comment: comment,
      targetDesignation: (json['target_designation'] as String?) ?? '',
      referenceStars: refs,
      maxCadenceGapSecs:
          (json['max_cadence_gap_secs'] as num?)?.toDouble() ?? 2.0,
      filter: (json['filter'] as String?) ?? 'Clear',
      exposureSecs: (json['exposure_secs'] as num?)?.toDouble() ?? 60.0,
      count: (json['count'] as num?)?.toInt() ?? 60,
      reduceLive: json['reduce_live'] as bool? ?? true,
      applyDifferential: json['apply_differential'] as bool? ?? true,
      quality: quality,
      gain: (json['gain'] as num?)?.toInt(),
      offset: (json['offset'] as num?)?.toInt(),
      binning: _rustStringToBinningMode(json['binning'] as String?),
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    targetDesignation,
    referenceStars,
    maxCadenceGapSecs,
    filter,
    exposureSecs,
    count,
    reduceLive,
    applyDifferential,
    quality,
    gain,
    offset,
    binning,
  ];
}

/// Operator-configured backup plan consulted by
/// `RecoveryActionType.switchTargetOrFilter`. Mirrors the Rust
/// `TransparencyBackupPlan` struct.
///
/// Either [backupFilter] or [backupTargetId] may be set independently
/// (or both). When both are null the recovery action falls back to
/// `PauseAndWaitForClear` rather than silently no-oping.
@Freezed(fromJson: true, toJson: true)
abstract class TransparencyBackupPlan with _$TransparencyBackupPlan {
  const TransparencyBackupPlan._();

  @JsonSerializable(fieldRename: FieldRename.snake, includeIfNull: true)
  const factory TransparencyBackupPlan({
    /// Filter to switch to when transparency drops (e.g. `"Lum"`).
    String? backupFilter,

    /// Sequence node id to skip to when transparency drops.
    String? backupTargetId,

    /// Optional human-readable description surfaced in the UI / logs.
    String? description,
  }) = _TransparencyBackupPlan;

  factory TransparencyBackupPlan.fromJson(Map<String, dynamic> json) =>
      _$TransparencyBackupPlanFromJson(json);

  bool get isEmpty => backupFilter == null && backupTargetId == null;
}

/// Plugin-contributed sequence instruction.
///
/// Holds the metadata required to identify a plugin-authored node in the
/// sequence tree (`pluginId`, `nodeTypeId`) and the opaque plugin-authored
/// JSON config that the Dart-side `PluginNodeExecutor` will pass to
/// `PluginSequenceNode.execute` at runtime. The Rust executor only forwards
/// these fields verbatim — every interpretation of `configJson` happens on
/// the Dart side.
///
/// The node is a *leaf*: container behaviour is owned by the plugin itself
/// (which can fan out internally via the plugin event bus / nested executor
/// hooks), so the editor refuses child drops.
///
/// Serialisation contract (Rust `NodeType::PluginNode`):
///
/// ```json
/// {
///   "type": "PluginNode",
///   "plugin_id": "<pluginId>",
///   "node_type_id": "<nodeTypeId>",
///   "config_json": "<configJson>",
///   "display_name": "<name>",
///   "timeout_secs": <timeoutSecs?>
/// }
/// ```
class PluginInstructionNode extends SequenceNode {
  /// Stable plugin identifier the host registered the owning plugin under
  /// (e.g. `com.example.pushover`).
  final String pluginId;

  /// Stable per-plugin node-type id (e.g. `pushover.notify`). Combined with
  /// [pluginId] this is the composite registry key the Dart-side executor
  /// uses to look up the plugin's `SequenceNodeDefinition`.
  final String nodeTypeId;

  /// Opaque JSON blob the plugin author owns. The dispatcher passes this
  /// through `jsonDecode` and hands the resulting map to
  /// `PluginSequenceNode.execute(params)`. Defaults to `'{}'` so a
  /// freshly-dropped palette node round-trips through `jsonDecode` cleanly.
  final String configJson;

  /// Optional per-node timeout override (seconds). `null` falls back to the
  /// Rust executor default (600s). `0` is treated the same as `null` by the
  /// Rust side rather than as a zero-second fail-now.
  final int? timeoutSecs;

  /// Human-readable plugin name surfaced in logs / properties panel. Mirrors
  /// the [pluginId] registration; pinned to the node so importing a
  /// sequence whose owning plugin is currently unavailable still shows a
  /// sensible label.
  final String pluginName;

  /// Icon hint forwarded from the plugin's `SequenceNodeDefinition`. The
  /// palette widget falls back to the generic puzzle-piece icon when the
  /// hint is unknown.
  final String iconHint;

  PluginInstructionNode({
    super.id,
    super.name = 'Plugin Node',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    required this.pluginId,
    required this.nodeTypeId,
    this.configJson = '{}',
    this.timeoutSecs,
    this.pluginName = '',
    this.iconHint = 'puzzle',
  });

  @override
  String get nodeType => 'PluginNode';

  @override
  String get iconName => iconHint;

  @override
  NodeCategory get category => NodeCategory.instruction;

  /// Composite registry key, mirroring `PluginNodeRegistration.composeKey`.
  /// Lives here so the executor can build the lookup key without depending
  /// on the plugins package.
  String get registrationKey => '$pluginId::$nodeTypeId';

  @override
  PluginInstructionNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    String? pluginId,
    String? nodeTypeId,
    String? configJson,
    int? timeoutSecs,
    String? pluginName,
    String? iconHint,
  }) {
    return PluginInstructionNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      pluginId: pluginId ?? this.pluginId,
      nodeTypeId: nodeTypeId ?? this.nodeTypeId,
      configJson: configJson ?? this.configJson,
      timeoutSecs: timeoutSecs ?? this.timeoutSecs,
      pluginName: pluginName ?? this.pluginName,
      iconHint: iconHint ?? this.iconHint,
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    pluginId,
    nodeTypeId,
    configJson,
    timeoutSecs,
    pluginName,
    iconHint,
  ];
}
