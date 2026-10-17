part of '../smart_night_models.dart';

/// Snapshot of cross-system inputs the auto-builder consumes. Each field
/// has a sensible "missing" fallback so the wizard can run end-to-end even
/// before all data sources have warmed up.
class SmartNightContext {
  /// Tonight's dark window — astronomical dusk → dawn at the observer's
  /// site. When polar latitudes prevent astronomical darkness, this falls
  /// back to nautical / civil twilight (see [SmartNightService.calculateWindow]).
  final DateTime windowStart;
  final DateTime windowEnd;

  /// Probability (0..1) of rain or cloud cover within the planning
  /// window. When `null` the builder skips the weather-arriving recovery
  /// node. When > 0.4 the builder prepends a `CloudArrivingIn` recovery
  /// trigger (cross-system integration).
  final double? rainOrCloudProbability;

  /// Lead time (minutes) before the storm arrival when the recovery
  /// trigger should fire. Pulled from the weather alert settings.
  final int cloudArrivalLeadTimeMinutes;

  /// Site Bortle class (1..9). The exposure calculator's sky electron
  /// rate scales off this. Falls back to Bortle 5 (the historic default)
  /// when unknown.
  final int bortleClass;

  /// Most recent guide RMS for the active mount (arcsec) — pulled from
  /// the SkyBrightnessTracker / PHD2 history. `null` until we have at
  /// least one guided session for this mount.
  final double? recentGuideRmsArcsec;
  final int recentGuideSamples;

  /// Number of days since the last successful polar alignment for the
  /// active profile. `null` when no record exists. The builder injects a
  /// [PolarAlignmentNode] when this exceeds
  /// `settings.polarAlignmentStaleAfterDays`.
  final int? daysSinceLastPolarAlignment;

  /// Coverage gaps in the dark library — set of `(gain, durationSecs)`
  /// pairs that the wizard found no master dark for. When non-empty the
  /// builder surfaces a warning in [SmartNightPlan.warnings]. When
  /// [SmartNightSettings.autoScheduleMissingDarks] is true AND
  /// [missingDarkRequirements] is non-empty, the builder ALSO appends a
  /// "Dark Library Refresh" instruction group at the end of the lights
  /// tree that captures the missing combinations.
  final List<String> missingDarkLibraryNotes;

  /// Structured form of the same gaps surfaced in
  /// [missingDarkLibraryNotes]. The wizard's coverage analyzer populates
  /// this with the (gain, offset, exposure, binning, temperature)
  /// tuples representing missing dark combinations. The builder only
  /// consumes this list when [SmartNightSettings.autoScheduleMissingDarks]
  /// is true — otherwise it is informational metadata round-tripped
  /// through draft persistence.
  final List<DarkFrameRequirement> missingDarkRequirements;

  /// Whether the SkyBrightnessTracker reports the site is currently
  /// brighter than the camera/filter's "adaptive" reference, indicating
  /// the user should enable the per-target adaptive exposure config.
  final bool adaptiveExposuresRecommended;

  /// The operator's default site-horizon profile (azimuth-dependent
  /// minimum altitude). When present the auto-builder carries it into the
  /// emitted in-sequence [TargetSchedulerNode] so the behavior-tree
  /// scheduler respects the same azimuth horizon mask the live autopilot
  /// already consults via the `customHorizon` target constraint. `null`
  /// leaves the in-sequence node on a flat altitude floor.
  final HorizonProfile? horizonProfile;

  const SmartNightContext({
    required this.windowStart,
    required this.windowEnd,
    this.rainOrCloudProbability,
    this.cloudArrivalLeadTimeMinutes = 30,
    this.bortleClass = 5,
    this.recentGuideRmsArcsec,
    this.recentGuideSamples = 0,
    this.daysSinceLastPolarAlignment,
    this.missingDarkLibraryNotes = const [],
    this.missingDarkRequirements = const [],
    this.adaptiveExposuresRecommended = false,
    this.horizonProfile,
  });

  SmartNightContext copyWith({
    DateTime? windowStart,
    DateTime? windowEnd,
    double? rainOrCloudProbability,
    int? cloudArrivalLeadTimeMinutes,
    int? bortleClass,
    double? recentGuideRmsArcsec,
    int? recentGuideSamples,
    int? daysSinceLastPolarAlignment,
    List<String>? missingDarkLibraryNotes,
    List<DarkFrameRequirement>? missingDarkRequirements,
    bool? adaptiveExposuresRecommended,
    HorizonProfile? horizonProfile,
  }) {
    return SmartNightContext(
      windowStart: windowStart ?? this.windowStart,
      windowEnd: windowEnd ?? this.windowEnd,
      rainOrCloudProbability:
          rainOrCloudProbability ?? this.rainOrCloudProbability,
      cloudArrivalLeadTimeMinutes:
          cloudArrivalLeadTimeMinutes ?? this.cloudArrivalLeadTimeMinutes,
      bortleClass: bortleClass ?? this.bortleClass,
      recentGuideRmsArcsec: recentGuideRmsArcsec ?? this.recentGuideRmsArcsec,
      recentGuideSamples: recentGuideSamples ?? this.recentGuideSamples,
      daysSinceLastPolarAlignment:
          daysSinceLastPolarAlignment ?? this.daysSinceLastPolarAlignment,
      missingDarkLibraryNotes:
          missingDarkLibraryNotes ?? this.missingDarkLibraryNotes,
      missingDarkRequirements:
          missingDarkRequirements ?? this.missingDarkRequirements,
      adaptiveExposuresRecommended:
          adaptiveExposuresRecommended ?? this.adaptiveExposuresRecommended,
      horizonProfile: horizonProfile ?? this.horizonProfile,
    );
  }

  Map<String, dynamic> toJson() => {
    'windowStart': windowStart.toIso8601String(),
    'windowEnd': windowEnd.toIso8601String(),
    'rainOrCloudProbability': rainOrCloudProbability,
    'cloudArrivalLeadTimeMinutes': cloudArrivalLeadTimeMinutes,
    'bortleClass': bortleClass,
    'recentGuideRmsArcsec': recentGuideRmsArcsec,
    'recentGuideSamples': recentGuideSamples,
    'daysSinceLastPolarAlignment': daysSinceLastPolarAlignment,
    'missingDarkLibraryNotes': missingDarkLibraryNotes,
    'missingDarkRequirements': missingDarkRequirements
        .map(_darkRequirementToJson)
        .toList(),
    'adaptiveExposuresRecommended': adaptiveExposuresRecommended,
    if (horizonProfile != null)
      'horizonProfile': {
        if (horizonProfile!.id != null) 'id': horizonProfile!.id,
        'name': horizonProfile!.name,
        'samples': horizonProfile!.samples.map((s) => s.toJson()).toList(),
      },
  };

  factory SmartNightContext.fromJson(Map<String, dynamic> json) {
    return SmartNightContext(
      windowStart: DateTime.parse(json['windowStart'] as String),
      windowEnd: DateTime.parse(json['windowEnd'] as String),
      rainOrCloudProbability: (json['rainOrCloudProbability'] as num?)
          ?.toDouble(),
      cloudArrivalLeadTimeMinutes: _jsonInt(
        json['cloudArrivalLeadTimeMinutes'],
        30,
      ),
      bortleClass: _jsonInt(json['bortleClass'], 5),
      recentGuideRmsArcsec: (json['recentGuideRmsArcsec'] as num?)?.toDouble(),
      recentGuideSamples: _jsonInt(json['recentGuideSamples'], 0),
      daysSinceLastPolarAlignment: json['daysSinceLastPolarAlignment'] as int?,
      missingDarkLibraryNotes: _stringList(json['missingDarkLibraryNotes']),
      missingDarkRequirements: _darkRequirementsFromJson(
        json['missingDarkRequirements'],
      ),
      adaptiveExposuresRecommended:
          json['adaptiveExposuresRecommended'] as bool? ?? false,
      horizonProfile: _horizonProfileFromJson(json['horizonProfile']),
    );
  }
}

HorizonProfile? _horizonProfileFromJson(Object? raw) {
  if (raw is! Map) return null;
  final map = raw.cast<String, dynamic>();
  final samplesRaw = map['samples'] as List<dynamic>? ?? const [];
  if (samplesRaw.isEmpty) return null;
  return HorizonProfile(
    id: (map['id'] as num?)?.toInt(),
    name: map['name'] as String? ?? 'Site horizon',
    samples: samplesRaw
        .map((e) => HorizonSample.fromJson((e as Map).cast<String, dynamic>()))
        .toList(),
  );
}

/// Container for the wizard's "preview" step: the [Sequence] that will be
/// loaded into the editor, plus per-target rationale and any warnings the
/// service surfaced while building.
class SmartNightPlan {
  final Sequence sequence;

  /// Targets the scheduler / linear chain will image, in the order they
  /// were placed into the tree.
  final List<SmartNightPlannedTarget> plannedTargets;

  /// Total integration time across all targets, in seconds. The wizard
  /// renders this on the preview screen as "Total integration: Xh Ym".
  final double totalIntegrationSecs;

  /// Estimated wall-clock duration (with overhead) of the generated
  /// sequence. The wizard compares this to the dark window length and
  /// warns if it doesn't fit.
  final double estimatedWallClockSecs;

  /// Soft-warnings to surface in the wizard preview. Examples:
  /// - "Dark library missing 120s @ G100 — consider a dark night."
  /// - "Polar alignment last ran 14 days ago — running a fresh
  ///   alignment is recommended."
  /// - "Rain probability 60% within the next 3h — Cloud Arriving
  ///   recovery added."
  final List<String> warnings;

  /// Strategy that was selected — surfaced in the wizard summary.
  final SmartNightStrategy strategy;

  /// The settings actually used (after wizard overrides).
  final SmartNightSettings settings;

  /// The cross-system context that drove the build.
  final SmartNightContext context;

  const SmartNightPlan({
    required this.sequence,
    required this.plannedTargets,
    required this.totalIntegrationSecs,
    required this.estimatedWallClockSecs,
    required this.warnings,
    required this.strategy,
    required this.settings,
    required this.context,
  });

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'sequence': SequenceFileService().sequenceToMap(sequence),
    'plannedTargets': plannedTargets.map((t) => t.toJson()).toList(),
    'totalIntegrationSecs': totalIntegrationSecs,
    'estimatedWallClockSecs': estimatedWallClockSecs,
    'warnings': warnings,
    'strategy': strategy.name,
    'settings': settings.toJson(),
    'context': context.toJson(),
  };

  factory SmartNightPlan.fromJson(Map<String, dynamic> json) {
    final sequenceJson = (json['sequence'] as Map).cast<String, dynamic>();
    return SmartNightPlan(
      sequence: SequenceFileService().parseFromMap(sequenceJson),
      plannedTargets: (json['plannedTargets'] as List? ?? const [])
          .map(
            (e) => SmartNightPlannedTarget.fromJson(
              (e as Map).cast<String, dynamic>(),
            ),
          )
          .toList(),
      totalIntegrationSecs: _jsonDouble(json['totalIntegrationSecs'], 0.0),
      estimatedWallClockSecs: _jsonDouble(json['estimatedWallClockSecs'], 0.0),
      warnings: _stringList(json['warnings']),
      strategy: _enumByName(
        SmartNightStrategy.values,
        json['strategy'],
        SmartNightStrategy.autoLrgb,
      ),
      settings: SmartNightSettings.fromJson(
        (json['settings'] as Map).cast<String, dynamic>(),
      ),
      context: SmartNightContext.fromJson(
        (json['context'] as Map).cast<String, dynamic>(),
      ),
    );
  }
}
