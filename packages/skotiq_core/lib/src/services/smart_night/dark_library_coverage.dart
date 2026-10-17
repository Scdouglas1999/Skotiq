import '../../database/daos/flat_history_dao.dart';
import '../../models/calibration/dark_library_match_tolerances.dart';
import '../../providers/profiles_provider.dart' show EquipmentProfileModel;
import '../dark_library_coverage_service.dart';
import '../dark_library_service.dart';
import '../session_optimizer_service.dart' show SmartNightExposureContext;
import '../smart_night_service.dart';

/// Builds Smart Night dark-library requirements from the same strategy and
/// exposure recommendation inputs used by the sequence builder.
class SmartNightDarkLibraryCoverage {
  final DarkLibraryService darkLibraryService;
  final DarkLibraryCoverageService coverageService;

  const SmartNightDarkLibraryCoverage({
    required this.darkLibraryService,
    this.coverageService = const DarkLibraryCoverageService(),
  });

  /// Convenience wrapper that returns only the human-readable warning
  /// strings — retained for callers that just want to surface a soft
  /// warning. Use [missing] when you also need the structured
  /// requirements (e.g. to opt in to auto-scheduling dark capture).
  Future<List<String>> missingNotes({
    required EquipmentProfileModel profile,
    required SmartNightStrategy strategy,
    required SmartNightSettings settings,
    required SmartNightExposureContext exposureContext,
    required int minCoverage,
    DarkLibraryMatchTolerances tolerances = DarkLibraryMatchTolerances.defaults,
  }) async {
    final result = await missing(
      profile: profile,
      strategy: strategy,
      settings: settings,
      exposureContext: exposureContext,
      minCoverage: minCoverage,
      tolerances: tolerances,
    );
    return result.notes;
  }

  /// Compute both the structured [DarkFrameRequirement]s missing from
  /// the library AND the human-readable note strings, sharing the same
  /// underlying coverage evaluation so the two views never disagree.
  Future<SmartNightDarkLibraryMissing> missing({
    required EquipmentProfileModel profile,
    required SmartNightStrategy strategy,
    required SmartNightSettings settings,
    required SmartNightExposureContext exposureContext,
    required int minCoverage,
    DarkLibraryMatchTolerances tolerances = DarkLibraryMatchTolerances.defaults,
  }) async {
    final filters = resolveSmartNightFilterSet(
      strategy: strategy,
      availableFilters: profile.filterNames,
    );
    if (filters.isEmpty) return const SmartNightDarkLibraryMissing.empty();

    // Darks MUST be captured at the SAME sensor setpoint the lights are
    // cooled to, or they don't calibrate. The lights' setpoint is whatever
    // the Smart Night CoolCamera node uses, which is
    // `settings.coolDownTargetC` (see sequence_emitter.dart CoolCameraNode).
    // Not `profile.defaultCoolingTemp`: the wizard does not seed
    // coolDownTargetC from the profile, so a profile default that differs puts
    // the darks in a temperature bucket the lights never used.
    final targetTemp = settings.coolDownTargetC;
    final requirements = filters.map((filter) {
      final recommendation = exposureContext.recommendForFilter(filter);
      return DarkFrameRequirement(
        gain: profile.defaultGain ?? 0,
        offset: profile.defaultOffset ?? 0,
        durationSecs: recommendation.seconds,
        binX: profile.defaultBinX,
        binY: profile.defaultBinY,
        targetTemp: targetTemp,
      );
    }).toSet();

    final report = coverageService.evaluate(
      requirements: requirements,
      entries: await darkLibraryService.getAllEntries(),
      minCoverage: minCoverage,
      tolerances: tolerances,
    );
    if (report.isCovered) return const SmartNightDarkLibraryMissing.empty();

    final notes = <String>[
      for (final req in report.missing) req.describe(),
      for (final entry in report.underCovered.entries)
        '${entry.key.describe()} (${entry.value} of $minCoverage raw darks)',
    ];
    notes.sort();
    final missingRequirements = <DarkFrameRequirement>[
      ...report.missing,
      ...report.underCovered.keys,
    ];
    return SmartNightDarkLibraryMissing(
      notes: List.unmodifiable(notes),
      requirements: List.unmodifiable(missingRequirements),
    );
  }
}

/// Pair of (notes, requirements) returned by
/// [SmartNightDarkLibraryCoverage.missing]. The two views are computed
/// from the same coverage evaluation so they stay in sync.
class SmartNightDarkLibraryMissing {
  final List<String> notes;
  final List<DarkFrameRequirement> requirements;

  const SmartNightDarkLibraryMissing({
    required this.notes,
    required this.requirements,
  });

  const SmartNightDarkLibraryMissing.empty()
    : notes = const [],
      requirements = const [];

  bool get isEmpty => notes.isEmpty && requirements.isEmpty;
}

/// Resolves the per-filter flat sub-exposure Smart Night should emit for the
/// end-of-night panel flats, sourced from the ADU-targeted flat-calibration
/// history.
///
/// The ADU-converged exposures live in the `flat_history` table: each row
/// records the exposure that achieved a target histogram percentage
/// (`histogramTarget`) and the panel brightness that produced it, written by
/// the Flat Wizard's binary-search solver. This helper reads the most recent
/// calibration per filter so the auto-builder emits an exposure that hit the
/// ADU target; a blind exposure does not reliably land near half-well and so
/// does not calibrate the lights.
///
/// Filters with NO prior calibration are returned in [SmartNightFlatPlan.uncalibratedFilters]
/// so the builder can surface a loud "calibrate this filter once" reminder
/// rather than silently shooting a wrong blind exposure.
class SmartNightFlatCoverage {
  final FlatHistoryDao flatHistoryDao;

  const SmartNightFlatCoverage({required this.flatHistoryDao});

  /// Look up the calibrated flat exposure + panel brightness for each filter
  /// in [filters], matched to [profile] (and its default gain when present).
  ///
  /// Only the most recent matching calibration is used per filter. A filter
  /// with no matching history row is reported as uncalibrated.
  Future<SmartNightFlatPlan> resolve({
    required EquipmentProfileModel profile,
    required Set<String> filters,
  }) async {
    if (filters.isEmpty) return const SmartNightFlatPlan.empty();

    final perFilter = <String, SmartNightFlatExposure>{};
    final uncalibrated = <String>[];

    for (final filter in filters) {
      final entry = await flatHistoryDao.findMostRecentMatch(
        filterName: filter,
        equipmentProfileId: profile.id,
        gain: profile.defaultGain,
      );
      if (entry == null || entry.exposureTime <= 0) {
        uncalibrated.add(filter);
        continue;
      }
      perFilter[filter] = SmartNightFlatExposure(
        filterName: filter,
        exposureSecs: entry.exposureTime,
        panelBrightness: entry.panelBrightness,
        histogramTargetPercent: entry.histogramTarget,
        actualAdu: entry.actualAdu,
      );
    }

    uncalibrated.sort();
    return SmartNightFlatPlan(
      perFilter: Map.unmodifiable(perFilter),
      uncalibratedFilters: List.unmodifiable(uncalibrated),
    );
  }
}

/// A single filter's ADU-calibrated flat exposure, taken from the most recent
/// `flat_history` row that achieved the target histogram percentage.
class SmartNightFlatExposure {
  final String filterName;

  /// Exposure (seconds) that previously hit [histogramTargetPercent] /
  /// [actualAdu] for this filter on this rig.
  final double exposureSecs;

  /// Panel brightness (0..255) that produced the calibrated exposure. `null`
  /// when the calibration came from sky flats (no panel) — in that case the
  /// builder must fall back to the panel's own brightness control rather than
  /// a hardcoded value.
  final int? panelBrightness;

  /// Target histogram percentage the calibration aimed for (0..100).
  final double histogramTargetPercent;

  /// Actual ADU the calibrated exposure achieved.
  final int actualAdu;

  const SmartNightFlatExposure({
    required this.filterName,
    required this.exposureSecs,
    required this.panelBrightness,
    required this.histogramTargetPercent,
    required this.actualAdu,
  });
}

/// The set of per-filter ADU-calibrated flat exposures Smart Night should use,
/// plus the filters that have no calibration history yet.
class SmartNightFlatPlan {
  final Map<String, SmartNightFlatExposure> perFilter;
  final List<String> uncalibratedFilters;

  const SmartNightFlatPlan({
    required this.perFilter,
    required this.uncalibratedFilters,
  });

  const SmartNightFlatPlan.empty()
    : perFilter = const {},
      uncalibratedFilters = const [];

  /// Whether any filter has a calibrated exposure to emit.
  bool get hasAnyCalibration => perFilter.isNotEmpty;
}
