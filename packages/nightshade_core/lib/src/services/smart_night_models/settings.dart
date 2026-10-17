part of '../smart_night_models.dart';

// Public enums

/// High-level strategy for the auto-builder.
///
/// Each strategy picks per-filter sub counts + a sane filter rotation given
/// the equipment profile's available filters. The wizard exposes this as a
/// radio group on step 4.
enum SmartNightStrategy {
  /// Auto: LRGB rotation with 2x luminance weighting for galaxies / RGB
  /// reflection nebulae and falls back to whichever broadband filters are
  /// present. Treated as the default.
  autoLrgb,

  /// Narrowband bicolor — Ha + OIII. Used by emission-nebula nights on
  /// duo/quad-band rigs and for mono shooters who only own Ha + OIII.
  narrowbandHoo,

  /// Narrowband tricolor (Hubble palette) — Ha + OIII + SII. Requires all
  /// three filters in the equipment profile.
  narrowbandSho,

  /// One-shot color cameras — single light filter with no wheel rotation.
  oscOneShot,

  /// Mono LRGB — even L/R/G/B counts without luminance over-weighting.
  monoLrgb,
}

/// AF cadence policy.
///
/// Mirrors what the executor's `AutofocusOnFilterChange` /
/// `AutofocusEveryNExposures` / temp-delta gates already implement; the
/// wizard surfaces one toggle group and SmartNightService maps it to the
/// per-target sub-tree the executor understands.
enum SmartNightAfCadence {
  /// Autofocus after every N exposures.
  everyNFrames,

  /// Autofocus every N minutes of wall-clock time.
  everyNMinutes,

  /// Autofocus when ambient temperature has drifted by `tempDeltaC` since
  /// the last successful AF run.
  onTempDelta,
}

// Public model classes

/// Compact "user prefs" envelope owned by the wizard. The wizard initialises
/// it from per-profile defaults if available; otherwise from these sane
/// values. Not stored in a DB table — the wizard mutates a copy per build
/// and the resulting tree is what gets persisted to the sequence library.
class SmartNightSettings {
  /// Maximum session wall-clock duration (hours). When the dark window is
  /// longer than this, the auto-builder caps the planning window.
  final double maxSessionHours;

  /// Autofocus cadence policy.
  final SmartNightAfCadence afCadence;

  /// When [afCadence] is [SmartNightAfCadence.everyNFrames] this is the N.
  final int afEveryFrames;

  /// When [afCadence] is [SmartNightAfCadence.everyNMinutes] this is the N.
  final int afEveryMinutes;

  /// When [afCadence] is [SmartNightAfCadence.onTempDelta] this is the
  /// temperature delta (°C) above the last successful AF that triggers a
  /// new run.
  final double afTempDeltaC;

  /// Minimum integration time per target (hours). Targets that can't fit
  /// this much usable sky time inside the dark window are dropped.
  final double defaultIntegrationBudgetHours;

  /// Default per-filter sub-duration (seconds) if the exposure calculator
  /// has no opinion for a given filter (e.g. user is at default Bortle
  /// with an unknown camera).
  final Map<String, double> defaultFrameDurationSecs;

  /// Use the chosen per-filter recipe instead of the exposure calculator.
  final bool useExposurePresets;

  /// Explicit recipe edits override the camera library for this build.
  final int? gainOverride;
  final int? offsetOverride;

  /// Whether to append automatic flats at end-of-session when the profile
  /// has a cover calibrator.
  final bool includeFlatsAtEnd;

  /// Number of flats per filter when [includeFlatsAtEnd] is true.
  final int flatCountPerFilter;

  /// Whether to wrap multi-target sessions in a [TargetSchedulerNode]
  /// (scheduler mode) or to chain them linearly. The wizard auto-picks
  /// scheduler when target count >= [schedulerTargetThreshold].
  final bool useSchedulerForMultiTarget;
  final int schedulerTargetThreshold;

  /// Whether the emitted in-sequence [TargetSchedulerNode] should opt into
  /// adaptive sky-conditions target swapping. When true the node carries a
  /// `swapOnConditionsBelow` floor (80% — the brief default), so the
  /// already-built in-sequence swap engine re-orders the candidate pick when
  /// the live conditions score drops. Defaults to `true` so the Smart-Night
  /// preset is self-driving out of the box; the value is purely an
  /// in-sequence-node config and never touches the live autopilot's W1–W5
  /// decision math.
  final bool adaptiveTargetSwap;

  /// Minimum altitude (deg) below which a target is considered "not usable".
  /// Drives the per-target start/end altitude triggers and the schedule
  /// window math.
  final double minAltitudeDeg;

  /// Hard ceiling on a single sub-exposure (seconds). Surfaced into the
  /// exposure calculator.
  final double subExposureCeilingSecs;

  /// Hard floor on a single sub-exposure (seconds).
  final double subExposureFloorSecs;

  /// Planning SNR target used by the Smart Night exposure calculator. Higher
  /// values bias the sky-limited recommendation longer, lower values shorter.
  final double targetSnr;

  /// Settle/dither cadence for SmartExposure rotation (every N frames).
  final int ditherEveryFrames;

  /// Whether to prepend a polar alignment instruction when the equipment
  /// health service reports the rig's last polar alignment is stale.
  final bool prependPolarAlignmentIfStale;

  /// Days after which a polar alignment is "stale" enough to warrant
  /// prepending an alignment node.
  final int polarAlignmentStaleAfterDays;

  /// Whether the rig has a flat panel / cover calibrator. The wizard
  /// pre-fills this from the EquipmentProfile but the user can override.
  final bool hasCoverCalibrator;

  /// Cooling target temperature for the initial CoolCamera node. Pulled
  /// from the profile if available.
  final double coolDownTargetC;

  /// Opt-in: when true and the [SmartNightContext.missingDarkRequirements]
  /// list is non-empty, the builder appends a "Dark Library Refresh"
  /// instruction group at the end of the lights/flats tree that captures
  /// the missing dark combinations (count = [darkFramesPerRequirement]
  /// per missing combo).
  ///
  /// Defaults to `false`: auto-capturing darks surprises an operator who asked
  /// for lights tonight, so the missing combinations are a warning unless this
  /// is opted into.
  final bool autoScheduleMissingDarks;

  /// Frames captured per missing-dark combination when
  /// [autoScheduleMissingDarks] is true. Defaults to 20 — the same
  /// quorum the dark-library wizard's "Capture missing darks" deep-link
  /// uses and the typical master-dark sample size for modern CMOS.
  final int darkFramesPerRequirement;

  /// Conditions-score floor (0..100) handed to the in-sequence
  /// [TargetSchedulerNode] when [adaptiveTargetSwap] is enabled. Below this
  /// the node's adaptive-swap engine re-ranks the candidate pick. 80 follows
  /// the Phase-B brief.
  static const double adaptiveSwapConditionsFloor = 80.0;

  const SmartNightSettings({
    this.maxSessionHours = 12.0,
    this.afCadence = SmartNightAfCadence.everyNFrames,
    this.afEveryFrames = 25,
    this.afEveryMinutes = 60,
    this.afTempDeltaC = 1.5,
    this.defaultIntegrationBudgetHours = 4.0,
    this.defaultFrameDurationSecs = const {
      'L': 120,
      'R': 180,
      'G': 180,
      'B': 180,
      'Ha': 300,
      'OIII': 300,
      'SII': 300,
      'OSC': 180,
    },
    this.useExposurePresets = false,
    this.gainOverride,
    this.offsetOverride,
    this.includeFlatsAtEnd = true,
    this.flatCountPerFilter = 20,
    this.useSchedulerForMultiTarget = true,
    this.schedulerTargetThreshold = 3,
    this.adaptiveTargetSwap = true,
    this.minAltitudeDeg = 30.0,
    this.subExposureCeilingSecs = 300.0,
    this.subExposureFloorSecs = 30.0,
    this.targetSnr = 30.0,
    this.ditherEveryFrames = 3,
    this.prependPolarAlignmentIfStale = true,
    this.polarAlignmentStaleAfterDays = 7,
    this.hasCoverCalibrator = false,
    this.coolDownTargetC = -10.0,
    this.autoScheduleMissingDarks = false,
    this.darkFramesPerRequirement = 20,
  });

  SmartNightSettings copyWith({
    double? maxSessionHours,
    SmartNightAfCadence? afCadence,
    int? afEveryFrames,
    int? afEveryMinutes,
    double? afTempDeltaC,
    double? defaultIntegrationBudgetHours,
    Map<String, double>? defaultFrameDurationSecs,
    bool? useExposurePresets,
    int? gainOverride,
    int? offsetOverride,
    bool? includeFlatsAtEnd,
    int? flatCountPerFilter,
    bool? useSchedulerForMultiTarget,
    int? schedulerTargetThreshold,
    bool? adaptiveTargetSwap,
    double? minAltitudeDeg,
    double? subExposureCeilingSecs,
    double? subExposureFloorSecs,
    double? targetSnr,
    int? ditherEveryFrames,
    bool? prependPolarAlignmentIfStale,
    int? polarAlignmentStaleAfterDays,
    bool? hasCoverCalibrator,
    double? coolDownTargetC,
    bool? autoScheduleMissingDarks,
    int? darkFramesPerRequirement,
  }) {
    return SmartNightSettings(
      maxSessionHours: maxSessionHours ?? this.maxSessionHours,
      afCadence: afCadence ?? this.afCadence,
      afEveryFrames: afEveryFrames ?? this.afEveryFrames,
      afEveryMinutes: afEveryMinutes ?? this.afEveryMinutes,
      afTempDeltaC: afTempDeltaC ?? this.afTempDeltaC,
      defaultIntegrationBudgetHours:
          defaultIntegrationBudgetHours ?? this.defaultIntegrationBudgetHours,
      defaultFrameDurationSecs:
          defaultFrameDurationSecs ?? this.defaultFrameDurationSecs,
      useExposurePresets: useExposurePresets ?? this.useExposurePresets,
      gainOverride: gainOverride ?? this.gainOverride,
      offsetOverride: offsetOverride ?? this.offsetOverride,
      includeFlatsAtEnd: includeFlatsAtEnd ?? this.includeFlatsAtEnd,
      flatCountPerFilter: flatCountPerFilter ?? this.flatCountPerFilter,
      useSchedulerForMultiTarget:
          useSchedulerForMultiTarget ?? this.useSchedulerForMultiTarget,
      schedulerTargetThreshold:
          schedulerTargetThreshold ?? this.schedulerTargetThreshold,
      adaptiveTargetSwap: adaptiveTargetSwap ?? this.adaptiveTargetSwap,
      minAltitudeDeg: minAltitudeDeg ?? this.minAltitudeDeg,
      subExposureCeilingSecs:
          subExposureCeilingSecs ?? this.subExposureCeilingSecs,
      subExposureFloorSecs: subExposureFloorSecs ?? this.subExposureFloorSecs,
      targetSnr: targetSnr ?? this.targetSnr,
      ditherEveryFrames: ditherEveryFrames ?? this.ditherEveryFrames,
      prependPolarAlignmentIfStale:
          prependPolarAlignmentIfStale ?? this.prependPolarAlignmentIfStale,
      polarAlignmentStaleAfterDays:
          polarAlignmentStaleAfterDays ?? this.polarAlignmentStaleAfterDays,
      hasCoverCalibrator: hasCoverCalibrator ?? this.hasCoverCalibrator,
      coolDownTargetC: coolDownTargetC ?? this.coolDownTargetC,
      autoScheduleMissingDarks:
          autoScheduleMissingDarks ?? this.autoScheduleMissingDarks,
      darkFramesPerRequirement:
          darkFramesPerRequirement ?? this.darkFramesPerRequirement,
    );
  }

  Map<String, dynamic> toJson() => {
    'maxSessionHours': maxSessionHours,
    'afCadence': afCadence.name,
    'afEveryFrames': afEveryFrames,
    'afEveryMinutes': afEveryMinutes,
    'afTempDeltaC': afTempDeltaC,
    'defaultIntegrationBudgetHours': defaultIntegrationBudgetHours,
    'defaultFrameDurationSecs': defaultFrameDurationSecs,
    'useExposurePresets': useExposurePresets,
    if (gainOverride != null) 'gainOverride': gainOverride,
    if (offsetOverride != null) 'offsetOverride': offsetOverride,
    'includeFlatsAtEnd': includeFlatsAtEnd,
    'flatCountPerFilter': flatCountPerFilter,
    'useSchedulerForMultiTarget': useSchedulerForMultiTarget,
    'schedulerTargetThreshold': schedulerTargetThreshold,
    'adaptiveTargetSwap': adaptiveTargetSwap,
    'minAltitudeDeg': minAltitudeDeg,
    'subExposureCeilingSecs': subExposureCeilingSecs,
    'subExposureFloorSecs': subExposureFloorSecs,
    'targetSnr': targetSnr,
    'ditherEveryFrames': ditherEveryFrames,
    'prependPolarAlignmentIfStale': prependPolarAlignmentIfStale,
    'polarAlignmentStaleAfterDays': polarAlignmentStaleAfterDays,
    'hasCoverCalibrator': hasCoverCalibrator,
    'coolDownTargetC': coolDownTargetC,
    'autoScheduleMissingDarks': autoScheduleMissingDarks,
    'darkFramesPerRequirement': darkFramesPerRequirement,
  };

  factory SmartNightSettings.fromJson(Map<String, dynamic> json) {
    return SmartNightSettings(
      maxSessionHours: _jsonDouble(json['maxSessionHours'], 12.0),
      afCadence: _enumByName(
        SmartNightAfCadence.values,
        json['afCadence'],
        SmartNightAfCadence.everyNFrames,
      ),
      afEveryFrames: _jsonInt(json['afEveryFrames'], 25),
      afEveryMinutes: _jsonInt(json['afEveryMinutes'], 60),
      afTempDeltaC: _jsonDouble(json['afTempDeltaC'], 1.5),
      defaultIntegrationBudgetHours: _jsonDouble(
        json['defaultIntegrationBudgetHours'],
        4.0,
      ),
      defaultFrameDurationSecs: _stringDoubleMap(
        json['defaultFrameDurationSecs'],
      ),
      useExposurePresets: json['useExposurePresets'] as bool? ?? false,
      gainOverride: (json['gainOverride'] as num?)?.toInt(),
      offsetOverride: (json['offsetOverride'] as num?)?.toInt(),
      includeFlatsAtEnd: json['includeFlatsAtEnd'] as bool? ?? true,
      flatCountPerFilter: _jsonInt(json['flatCountPerFilter'], 20),
      useSchedulerForMultiTarget:
          json['useSchedulerForMultiTarget'] as bool? ?? true,
      schedulerTargetThreshold: _jsonInt(json['schedulerTargetThreshold'], 3),
      adaptiveTargetSwap: json['adaptiveTargetSwap'] as bool? ?? true,
      minAltitudeDeg: _jsonDouble(json['minAltitudeDeg'], 30.0),
      subExposureCeilingSecs: _jsonDouble(
        json['subExposureCeilingSecs'],
        300.0,
      ),
      subExposureFloorSecs: _jsonDouble(json['subExposureFloorSecs'], 30.0),
      targetSnr: _jsonDouble(json['targetSnr'], 30.0),
      ditherEveryFrames: _jsonInt(json['ditherEveryFrames'], 3),
      prependPolarAlignmentIfStale:
          json['prependPolarAlignmentIfStale'] as bool? ?? true,
      polarAlignmentStaleAfterDays: _jsonInt(
        json['polarAlignmentStaleAfterDays'],
        7,
      ),
      hasCoverCalibrator: json['hasCoverCalibrator'] as bool? ?? false,
      coolDownTargetC: _jsonDouble(json['coolDownTargetC'], -10.0),
      autoScheduleMissingDarks:
          json['autoScheduleMissingDarks'] as bool? ?? false,
      darkFramesPerRequirement: _jsonInt(json['darkFramesPerRequirement'], 20),
    );
  }
}
