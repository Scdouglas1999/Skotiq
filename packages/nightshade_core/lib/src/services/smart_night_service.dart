import 'dart:math' as math;

import 'package:nightshade_planetarium/nightshade_planetarium.dart';
import 'package:uuid/uuid.dart';

import '../database/database.dart' as db;
import '../models/imaging/imaging_models.dart' show FrameType;
import '../models/notification/notification_categories.dart'
    show NotificationTransportKind;
import '../models/planning/target_suggestion.dart';
import '../models/scheduler/integration_goal.dart';
import '../models/sequence/sequence_models.dart';
import '../providers/profiles_provider.dart' show EquipmentProfileModel;
import 'logging_service.dart';
import 'hardware_presets/hardware_presets_service.dart';
import 'smart_night/camera_capture_defaults.dart';
import 'pre_session_simulator.dart';
import 'sensor_specs/camera_sensor_spec_resolver.dart';
import 'session_optimizer_service.dart' show SmartNightExposureContext;
import 'smart_night/dark_library_coverage.dart'
    show SmartNightFlatPlan, SmartNightFlatExposure;
import 'smart_night/exposure_calculator.dart';
import 'smart_night/hardware_specs_service.dart';
import 'smart_night_models.dart';
import 'target_suggestion_service.dart';

// Re-export model classes, enums, exceptions, and pure helpers so the
// existing `package:nightshade_core/nightshade_core.dart` barrel surface
// remains stable for consumers (Smart Night dialog, plan launcher, planner
// screens, draft service, tests). The orchestration class
// [SmartNightService] stays in this file; everything else now lives in
// `smart_night_models.dart`.
export 'smart_night_models.dart';

part 'smart_night_service/sequence_emitter.dart';

bool _profileHasGuider(EquipmentProfileModel profile) {
  final id = profile.guiderId?.trim() ?? '';
  final name = profile.guiderName?.trim() ?? '';
  return id.isNotEmpty || name.isNotEmpty;
}

/// The auto-builder service.
///
/// Reuses (does NOT reinvent) existing services per the design doc:
///   * [TargetSuggestionService] — scores tonight's candidate targets
///   * [SmartNightExposureCalculator] — per-filter sub-length
///   * [AstronomyCalculations] (planetarium) — twilight bounds + altitude
///
/// Reads (cross-system integrations per the strategic report):
///   * weather forecast → injects CloudArrivingIn recovery on rainy nights
///   * sky brightness tracker → flags adaptive exposures recommended
///   * equipment health / polar alignment history → injects a polar
///     alignment node when stale
///   * dark library coverage → surfaces gaps as warnings
class SmartNightService {
  final TargetSuggestionService _suggestionService;
  final LoggingService _logging;
  final SmartNightExposureCalculator _exposureCalculator;
  final HardwareSpecsService _hardwareSpecs;
  final HardwarePresetsService _cameraLibrary;

  static const _source = 'SmartNightService';
  static const _uuid = Uuid();

  /// Minimum dark-window slice (seconds) that's still worth slewing to.
  /// Shorter than this and we drop the target rather than spend 5 min of
  /// slew + center + focus only to take two subs.
  static const double _minTargetWindowSecs = 30 * 60; // 30 minutes

  /// Wall-clock seconds reserved between targets for slew + center +
  /// refocus + guide re-acquisition. Used by the scheduling step so we
  /// don't over-stuff the dark window.
  static const double _transitionOverheadSecs = 20 * 60; // 20 minutes

  /// Cloud/rain forecast probability above which the night plan prepends a
  /// weather-unsafe [RecoveryNode] watchdog. Single source of truth shared
  /// by [build] and [willInjectWeatherRecovery] so the plan preview can
  /// never disagree with what the builder actually emits.
  static const double weatherRecoveryCloudProbabilityThreshold = 0.4;

  /// Whether [build] will inject a [MeridianFlipNode] for [planned].
  ///
  /// The flip is added only when the target's transit time lands strictly
  /// inside its scheduled imaging window. This is the authoritative
  /// predicate: both the sequence builder and the plan preview call it so
  /// the preview never claims (or omits) a meridian-flip watchdog that the
  /// emitted sequence wouldn't (or would) contain.
  static bool willInjectMeridianFlip(SmartNightPlannedTarget planned) {
    final transit = planned.suggestion.visibility.transitTime;
    return transit != null &&
        transit.isAfter(planned.windowStart) &&
        transit.isBefore(planned.windowEnd);
  }

  /// Whether [build] will prepend a weather-unsafe [RecoveryNode] watchdog
  /// for [context]. Authoritative predicate shared by the builder and the
  /// plan preview (see [willInjectMeridianFlip]).
  static bool willInjectWeatherRecovery(SmartNightContext context) {
    final prob = context.rainOrCloudProbability;
    return prob != null && prob > weatherRecoveryCloudProbabilityThreshold;
  }

  const SmartNightService({
    required TargetSuggestionService suggestionService,
    required LoggingService logging,
    SmartNightExposureCalculator exposureCalculator =
        const SmartNightExposureCalculator(),
    HardwareSpecsService hardwareSpecs = const HardwareSpecsService(),
    HardwarePresetsService cameraLibrary = const HardwarePresetsService(),
  }) : _suggestionService = suggestionService,
       _logging = logging,
       _exposureCalculator = exposureCalculator,
       _hardwareSpecs = hardwareSpecs,
       _cameraLibrary = cameraLibrary;

  /// Compute tonight's dark window from the observer location. Falls back
  /// to nautical / civil twilight at high latitudes. During polar night,
  /// when the Sun remains below the horizon, a conservative 21:00 → 05:00
  /// window is returned. Polar midnight sun is rejected rather than being
  /// presented as darkness.
  ///
  /// [now] is exposed for testability — production code passes
  /// `DateTime.now()`.
  ({DateTime start, DateTime end, TwilightTimes twilight}) calculateWindow({
    required double latitudeDeg,
    required double longitudeDeg,
    DateTime? now,
  }) {
    final reference = now ?? DateTime.now();

    // If we're already past midnight but before dawn, use last night's
    // twilight. Mirrors the heuristic in [TargetSuggestionService].
    final prevDate = DateTime(
      reference.year,
      reference.month,
      reference.day,
    ).subtract(const Duration(days: 1));
    final prevTwilight = AstronomyCalculations.calculateTwilightTimes(
      date: prevDate,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
    );
    final prevBounds = _extractNightBounds(prevTwilight);
    if (prevBounds != null &&
        reference.isAfter(prevBounds.$1) &&
        reference.isBefore(prevBounds.$2)) {
      return (start: prevBounds.$1, end: prevBounds.$2, twilight: prevTwilight);
    }

    final todayDate = DateTime(reference.year, reference.month, reference.day);
    final todayTwilight = AstronomyCalculations.calculateTwilightTimes(
      date: todayDate,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
    );
    final todayBounds = _extractNightBounds(todayTwilight);
    if (todayBounds != null) {
      return (
        start: todayBounds.$1,
        end: todayBounds.$2,
        twilight: todayTwilight,
      );
    }

    final sunVisibility = AstronomyCalculations.calculateSunVisibility(
      date: todayDate,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
    );
    if (!sunVisibility.neverRises) {
      _logging.warning(
        'No twilight bounds and the Sun does not remain below the horizon at '
        'lat=$latitudeDeg lon=$longitudeDeg. Smart Night cannot derive a dark '
        'window.',
        source: _source,
      );
      throw const SmartNightBuildException(
        'The Sun does not set at this location tonight, so Smart Night cannot '
        'create a safe deep-sky imaging window. Choose a different date or '
        'build a manual sequence for intentional daylight/twilight imaging.',
      );
    }

    // With no crossings and the Sun below the horizon all day, this is polar
    // night. Use a conservative clock window rather than claiming all 24 hours.
    _logging.warning(
      'The Sun remains below the horizon at lat=$latitudeDeg lon=$longitudeDeg; '
      'using a conservative 21:00 → 05:00 local polar-night window.',
      source: _source,
    );
    final fallbackStart = DateTime(
      reference.year,
      reference.month,
      reference.day,
      21,
    );
    var fallbackEnd = fallbackStart.add(const Duration(hours: 8));
    if (reference.isAfter(fallbackEnd)) {
      fallbackEnd = fallbackEnd.add(const Duration(days: 1));
    }
    return (start: fallbackStart, end: fallbackEnd, twilight: todayTwilight);
  }

  (DateTime, DateTime)? _extractNightBounds(TwilightTimes tw) {
    if (tw.astronomicalDusk != null && tw.astronomicalDawn != null) {
      return (tw.astronomicalDusk!, tw.astronomicalDawn!);
    }
    if (tw.nauticalDusk != null && tw.nauticalDawn != null) {
      return (tw.nauticalDusk!, tw.nauticalDawn!);
    }
    if (tw.civilDusk != null && tw.civilDawn != null) {
      return (tw.civilDusk!, tw.civilDawn!);
    }
    if (tw.sunset != null && tw.sunrise != null) {
      return (tw.sunset!, tw.sunrise!);
    }
    return null;
  }

  /// Score and rank the catalogue of saved targets for tonight using the
  /// existing TargetSuggestionService — no reinvention.
  Future<List<TargetSuggestion>> rankCandidates({
    required EquipmentProfileModel profile,
    required double latitudeDeg,
    required double longitudeDeg,
    required List<db.Target> targets,
    required List<db.ImagingSession> sessions,
    DateTime? observationTime,
    double minAltitude = 30.0,
    double minScore = 30.0,
  }) async {
    if (targets.isEmpty) return const [];
    return _suggestionService.getSuggestionsForTonight(
      config: TargetSuggestionConfig(
        minAltitude: minAltitude,
        minScore: minScore,
      ),
      latitude: latitudeDeg,
      longitude: longitudeDeg,
      targets: targets,
      sessions: sessions,
      observationTime: observationTime,
    );
  }

  /// Build the night's [Sequence].
  ///
  /// `selectedSuggestions` is the user's chosen target list — either
  /// hand-picked from the wizard step 3 list, or the top-N picks of
  /// [rankCandidates]. The service does NOT re-rank; the wizard
  /// composes that pipeline.
  ///
  /// Validates required inputs and throws [SmartNightBuildException] when an
  /// essential field is missing, rather than planning a night around a
  /// substituted value.
  SmartNightPlan build({
    required EquipmentProfileModel profile,
    required double latitudeDeg,
    required double longitudeDeg,
    required SmartNightContext context,
    required List<TargetSuggestion> selectedSuggestions,
    required SmartNightStrategy strategy,
    required SmartNightSettings settings,
    SmartNightExposureContext? exposureContext,
    SmartNightFlatPlan? flatPlan,
  }) {
    _validateInputs(
      profile: profile,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      selectedSuggestions: selectedSuggestions,
      context: context,
    );

    // Bound the planning window by max session hours.
    final effectiveWindowEnd = _capWindowToMaxHours(
      windowStart: context.windowStart,
      windowEnd: context.windowEnd,
      maxHours: settings.maxSessionHours,
    );

    final activeFilters = _resolveFilterSet(
      strategy: strategy,
      availableFilters: profile.filterNames,
    );
    if (activeFilters.isEmpty) {
      throw SmartNightBuildException(
        'No filters from strategy "${strategy.name}" matched profile '
        '"${profile.name}" (available filters: '
        '${profile.filterNames.isEmpty ? "<none>" : profile.filterNames.join(", ")}). '
        'Either switch strategies (the OSC One-Shot strategy works without '
        'a wheel) or add the required filters to the equipment profile.',
      );
    }

    final pixelSizeUm =
        exposureContext?.pixelSizeMicrons ?? _pixelSize(profile);
    final focalLength = profile.focalLength > 0
        ? profile.focalLength
        : (exposureContext?.focalLengthMm ?? profile.telescopeFocalLength ?? 0);
    final aperture = profile.aperture > 0
        ? profile.aperture
        : (exposureContext?.apertureMm ?? profile.telescopeAperture ?? 0);
    final cameraSpec =
        exposureContext?.camera ?? _cameraSpecFromProfile(profile);

    // Guide-RMS ceiling: the mount-tracking exposure limit only engages when
    // we actually know the mount's recent guide RMS. The cross-system
    // [context] carries it when the caller populated it, but the wizard's
    // main path builds the context from weather/dark-library data and does
    // NOT thread guide history into it — that lives on [exposureContext]
    // (guideRmsArcsec / guideSampleCount, sourced from the PHD2 / guide-stats
    // history). Fall back to the exposure context so the tracking-limited
    // ceiling is honoured instead of being permanently dead. This mirrors
    // [previewTargetIntegration] and [buildSingleTargetSequence], which
    // already read the guide RMS off [exposureContext].
    final recentGuideRmsArcsec =
        context.recentGuideRmsArcsec ?? exposureContext?.guideRmsArcsec;
    final recentGuideSamples = context.recentGuideSamples > 0
        ? context.recentGuideSamples
        : (exposureContext?.guideSampleCount ?? 0);

    if (focalLength <= 0 || aperture <= 0 || pixelSizeUm <= 0) {
      throw SmartNightBuildException(
        'Equipment profile "${profile.name}" is missing aperture, focal '
        'length, or pixel size — these are required to compute exposure '
        'recommendations. Aperture=$aperture mm, '
        'focal length=$focalLength mm, '
        'pixel size=$pixelSizeUm µm.'
        '${pixelSizeUm <= 0 ? ' The camera '
                  '"${profile.cameraName ?? profile.cameraId ?? "<unknown>"}" is not '
                  'in the bundled hardware catalog — connect the camera so its real '
                  'pixel size is read, or add it to the Smart Night camera '
                  'overrides. Smart Night will not guess a pixel size.' : ''}',
      );
    }

    // Schedule targets into the dark window. We use a deep-first
    // chaining strategy: take the highest-scoring target until its
    // usable window inside the dark window is exhausted, then move to
    // the next, accounting for the slew/center/refocus overhead.
    final planned = <SmartNightPlannedTarget>[];
    DateTime cursor = context.windowStart;
    var first = true;
    for (final suggestion in selectedSuggestions) {
      if (cursor.isAfter(effectiveWindowEnd) ||
          !cursor.isBefore(effectiveWindowEnd)) {
        break;
      }
      // Reserve transition overhead between targets so we don't claim
      // the same minute twice.
      if (!first) {
        cursor = cursor.add(Duration(seconds: _transitionOverheadSecs.round()));
      }
      if (!cursor.isBefore(effectiveWindowEnd)) break;

      final usable = _usableTargetWindow(
        suggestion: suggestion,
        intervalStart: cursor,
        intervalEnd: effectiveWindowEnd,
        minAltitude: settings.minAltitudeDeg,
      );
      if (usable == null) {
        _logging.debug(
          'Skipping ${suggestion.targetName}: no usable window inside '
          '$cursor..$effectiveWindowEnd at min alt ${settings.minAltitudeDeg}°',
          source: _source,
        );
        continue;
      }

      final intervalWindowSecs = usable.$2
          .difference(usable.$1)
          .inSeconds
          .toDouble();
      final windowSecs = _integrationWindowSecs(
        suggestion: suggestion,
        intervalWindowSecs: intervalWindowSecs,
        integrationBudgetHours: null,
        settings: settings,
      );
      if (windowSecs < _minTargetWindowSecs) {
        _logging.debug(
          'Skipping ${suggestion.targetName}: usable window '
          '${(windowSecs / 60).toStringAsFixed(0)} min < '
          '${(_minTargetWindowSecs / 60).toStringAsFixed(0)} min minimum.',
          source: _source,
        );
        continue;
      }

      final filterPlans = _composeFilterPlans(
        suggestion: suggestion,
        strategy: strategy,
        activeFilters: activeFilters,
        windowSecs: windowSecs,
        profile: profile,
        cameraSpec: cameraSpec,
        focalLengthMm: focalLength,
        apertureMm: aperture,
        pixelSizeUm: pixelSizeUm,
        bortleClass: context.bortleClass,
        recentGuideRmsArcsec: recentGuideRmsArcsec,
        recentGuideSamples: recentGuideSamples,
        settings: settings,
      );
      if (filterPlans.isEmpty) continue;

      final integrationSecs = filterPlans.fold<double>(
        0,
        (sum, plan) => sum + plan.integrationSecs,
      );
      final actualEnd = usable.$1.add(
        Duration(seconds: integrationSecs.round()),
      );
      final clampedEnd = actualEnd.isBefore(usable.$2) ? actualEnd : usable.$2;

      planned.add(
        SmartNightPlannedTarget(
          suggestion: suggestion,
          windowStart: usable.$1,
          windowEnd: clampedEnd,
          filterPlans: filterPlans,
          integrationSecs: integrationSecs,
          rationale: _composeTargetRationale(
            suggestion: suggestion,
            filterPlans: filterPlans,
            windowSecs: clampedEnd.difference(usable.$1).inSeconds.toDouble(),
          ),
        ),
      );
      cursor = clampedEnd;
      first = false;
    }

    if (planned.isEmpty) {
      throw SmartNightBuildException(
        'None of the selected targets had a usable imaging window inside '
        'the dark window (sunset → sunrise) with current settings. Try '
        'lowering the minimum altitude (currently '
        '${settings.minAltitudeDeg.toStringAsFixed(0)}°) or selecting '
        'different targets.',
      );
    }

    final warnings = <String>[];
    final autoDarksActive =
        settings.autoScheduleMissingDarks &&
        context.missingDarkRequirements.isNotEmpty;
    if (context.missingDarkLibraryNotes.isNotEmpty && !autoDarksActive) {
      warnings.add(
        'Dark library is missing matching frames for: '
        '${context.missingDarkLibraryNotes.join(", ")}. '
        'Smart Night does not auto-schedule dark capture — consider a '
        'cloudy night for a dark library run.',
      );
    } else if (autoDarksActive) {
      final framesPerCombo = math.max(1, settings.darkFramesPerRequirement);
      final totalFrames =
          context.missingDarkRequirements.length * framesPerCombo;
      warnings.add(
        'Dark library refresh scheduled — $totalFrames dark frames '
        '(${context.missingDarkRequirements.length} combinations × '
        '$framesPerCombo frames each) will be captured after lights '
        'because auto-schedule is enabled.',
      );
    }
    if (context.daysSinceLastPolarAlignment != null &&
        context.daysSinceLastPolarAlignment! >
            settings.polarAlignmentStaleAfterDays) {
      warnings.add(
        'Last polar alignment was '
        '${context.daysSinceLastPolarAlignment} days ago '
        '(threshold: ${settings.polarAlignmentStaleAfterDays} days). '
        'A polar alignment instruction has been prepended.',
      );
    }
    if (context.rainOrCloudProbability != null &&
        context.rainOrCloudProbability! > 0.4) {
      warnings.add(
        'Cloud / rain probability '
        '${(context.rainOrCloudProbability! * 100).toStringAsFixed(0)}% '
        'within tonight\'s window — a Cloud Arriving recovery node was '
        'added so the executor can safely park if the storm rolls in.',
      );
    }
    if (context.adaptiveExposuresRecommended) {
      warnings.add(
        'Sky brightness tracker reports your site is brighter than '
        'reference — adaptive exposures will be enabled on each target.',
      );
    }
    if (settings.includeFlatsAtEnd && settings.hasCoverCalibrator) {
      final flatFilters = <String>{
        for (final p in planned)
          for (final fp in p.filterPlans) fp.filterName,
      };
      final missingFlatCalibration =
          flatFilters
              .where((f) => (flatPlan?.perFilter[f]?.exposureSecs ?? 0) <= 0)
              .toList()
            ..sort();
      if (missingFlatCalibration.isNotEmpty) {
        warnings.add(
          'No ADU-calibrated flat exposure exists for: '
          '${missingFlatCalibration.join(", ")}. Smart Night will NOT shoot '
          'blind flats — run the Flat Wizard once for these filters so the '
          'target-ADU exposure + panel brightness are learned and reused.',
        );
      }
    }
    if (recentGuideRmsArcsec == null || recentGuideSamples < 3) {
      warnings.add(
        'Mount guide-RMS history is sparse — exposure recommendations '
        'use the user cap rather than the mount-tracking ceiling. The '
        'ceiling becomes active after ~3 guided sessions on this mount.',
      );
    }

    final sequence = _emitSequence(
      profile: profile,
      latitudeDeg: latitudeDeg,
      strategy: strategy,
      settings: settings,
      context: context,
      planned: planned,
      flatPlan: flatPlan,
    );
    final simulation = const PreSessionSimulator().simulate(
      sequence,
      start: context.windowStart,
      latitude: latitudeDeg,
      longitude: longitudeDeg,
      minAltitude: settings.minAltitudeDeg,
      darkWindowStart: context.windowStart,
      darkWindowEnd: context.windowEnd,
    );
    for (final issue in simulation.issues) {
      if (!warnings.contains(issue.message)) {
        warnings.add(issue.message);
      }
    }

    final integrationSecs = planned.fold<double>(
      0,
      (sum, p) => sum + p.integrationSecs,
    );

    return SmartNightPlan(
      sequence: sequence,
      plannedTargets: planned,
      totalIntegrationSecs: integrationSecs,
      estimatedWallClockSecs: simulation.duration.inSeconds.toDouble(),
      warnings: warnings,
      strategy: strategy,
      settings: settings,
      context: context,
    );
  }

  /// Estimates per-target integration time for Plan Tonight without building
  /// a sequence. Returns null when the rig lacks the data Smart Night needs.
  TargetIntegrationPreview? previewTargetIntegration({
    required EquipmentProfileModel profile,
    required TargetSuggestion suggestion,
    required DateTime windowStart,
    required DateTime windowEnd,
    required List<String> availableFilters,
    SmartNightExposureContext? exposureContext,
    SmartNightSettings settings = const SmartNightSettings(),
    List<IntegrationGoalProgress>? integrationGoalProgress,
    SmartNightStrategy? strategy,
  }) {
    final planningFilters = smartNightPlanningFilters(availableFilters);
    final resolvedStrategy =
        strategy ?? inferSmartNightStrategy(suggestion, planningFilters);
    final activeFilters = _resolveFilterSet(
      strategy: resolvedStrategy,
      availableFilters: planningFilters,
    );
    if (activeFilters.isEmpty) return null;

    final pixelSizeUm =
        exposureContext?.pixelSizeMicrons ?? _pixelSize(profile);
    final focalLength = profile.focalLength > 0
        ? profile.focalLength
        : (exposureContext?.focalLengthMm ?? profile.telescopeFocalLength ?? 0);
    final aperture = profile.aperture > 0
        ? profile.aperture
        : (exposureContext?.apertureMm ?? profile.telescopeAperture ?? 0);
    final cameraSpec =
        exposureContext?.camera ?? _cameraSpecFromProfile(profile);

    if (focalLength <= 0 || aperture <= 0 || pixelSizeUm <= 0) {
      return null;
    }

    final usable = _usableTargetWindow(
      suggestion: suggestion,
      intervalStart: windowStart,
      intervalEnd: windowEnd,
      minAltitude: settings.minAltitudeDeg,
    );
    if (usable == null) return null;

    final intervalWindowSecs = usable.$2
        .difference(usable.$1)
        .inSeconds
        .toDouble();
    final windowSecs = _integrationWindowSecs(
      suggestion: suggestion,
      intervalWindowSecs: intervalWindowSecs,
      integrationBudgetHours: null,
      settings: settings,
    );
    if (windowSecs <= 0) return null;

    final filterPlans = _composeFilterPlans(
      suggestion: suggestion,
      strategy: resolvedStrategy,
      activeFilters: activeFilters,
      windowSecs: windowSecs,
      profile: profile,
      cameraSpec: cameraSpec,
      focalLengthMm: focalLength,
      apertureMm: aperture,
      pixelSizeUm: pixelSizeUm,
      bortleClass: exposureContext?.bortleClass ?? 5,
      recentGuideRmsArcsec: exposureContext?.guideRmsArcsec,
      recentGuideSamples: exposureContext?.guideSampleCount ?? 0,
      settings: settings,
      integrationGoalProgress: integrationGoalProgress,
      availableFiltersForGoals: planningFilters,
    );
    if (filterPlans.isEmpty) return null;

    final integrationSecs = filterPlans.fold<double>(
      0,
      (sum, plan) => sum + plan.integrationSecs,
    );
    final usableWindowHours =
        (suggestion.visibility.hoursAboveMinAlt ?? (windowSecs / 3600)).clamp(
          0.0,
          24.0,
        );

    return TargetIntegrationPreview(
      estimatedIntegrationHours: integrationSecs / 3600,
      usableWindowHours: usableWindowHours,
      subExposureSecs: filterPlans.first.durationSecs,
      filterNames: filterPlans.map((p) => p.filterName).toList(),
    );
  }

  /// Build a single-target sequence for Plan Tonight / dashboard "Add to
  /// Sequencer". Emits a TargetHeader sub-tree with SmartExposureNode filter
  /// rotation matching Smart Night per-target semantics.
  SingleTargetSequenceResult buildSingleTargetSequence({
    required EquipmentProfileModel profile,
    required TargetSuggestion suggestion,
    required DateTime windowStart,
    required DateTime windowEnd,
    required List<String> availableFilters,
    SmartNightExposureContext? exposureContext,
    SmartNightSettings settings = const SmartNightSettings(),
    SmartNightStrategy? strategy,
    double? integrationBudgetHours,
    List<IntegrationGoalProgress>? integrationGoalProgress,
    bool includeSessionPreamble = false,
    bool? includeSessionShutdown,
    bool fillWindow = false,
  }) {
    final planningFilters = smartNightPlanningFilters(availableFilters);
    final resolvedStrategy =
        strategy ?? inferSmartNightStrategy(suggestion, planningFilters);
    final activeFilters = _resolveFilterSet(
      strategy: resolvedStrategy,
      availableFilters: planningFilters,
    );
    if (activeFilters.isEmpty) {
      throw SmartNightBuildException(
        'No filters from strategy "${resolvedStrategy.name}" matched the '
        'available filter list (${availableFilters.join(", ")}).',
      );
    }

    final pixelSizeUm =
        exposureContext?.pixelSizeMicrons ?? _pixelSize(profile);
    final focalLength = profile.focalLength > 0
        ? profile.focalLength
        : (exposureContext?.focalLengthMm ?? profile.telescopeFocalLength ?? 0);
    final aperture = profile.aperture > 0
        ? profile.aperture
        : (exposureContext?.apertureMm ?? profile.telescopeAperture ?? 0);
    final cameraSpec =
        exposureContext?.camera ?? _cameraSpecFromProfile(profile);

    if (focalLength <= 0 || aperture <= 0 || pixelSizeUm <= 0) {
      throw SmartNightBuildException(
        'Equipment profile "${profile.name}" is missing aperture, focal '
        'length, or pixel size — these are required to compute exposure '
        'recommendations.',
      );
    }

    final usable = _usableTargetWindow(
      suggestion: suggestion,
      intervalStart: windowStart,
      intervalEnd: windowEnd,
      minAltitude: settings.minAltitudeDeg,
    );
    if (usable == null) {
      throw SmartNightBuildException(
        'Target "${suggestion.targetName}" has no usable imaging window '
        'between ${windowStart.toIso8601String()} and '
        '${windowEnd.toIso8601String()} at min altitude '
        '${settings.minAltitudeDeg.toStringAsFixed(0)}°.',
      );
    }

    final intervalWindowSecs = usable.$2
        .difference(usable.$1)
        .inSeconds
        .toDouble();
    final windowSecs = _integrationWindowSecs(
      suggestion: suggestion,
      intervalWindowSecs: intervalWindowSecs,
      integrationBudgetHours: integrationBudgetHours,
      settings: settings,
    );

    final filterPlans = _composeFilterPlans(
      suggestion: suggestion,
      strategy: resolvedStrategy,
      activeFilters: activeFilters,
      windowSecs: windowSecs,
      profile: profile,
      cameraSpec: cameraSpec,
      focalLengthMm: focalLength,
      apertureMm: aperture,
      pixelSizeUm: pixelSizeUm,
      bortleClass: exposureContext?.bortleClass ?? 5,
      recentGuideRmsArcsec: exposureContext?.guideRmsArcsec,
      recentGuideSamples: exposureContext?.guideSampleCount ?? 0,
      settings: settings,
      integrationGoalProgress: integrationGoalProgress,
      availableFiltersForGoals: planningFilters,
    );
    if (filterPlans.isEmpty) {
      throw SmartNightBuildException(
        'Could not compose filter plans for "${suggestion.targetName}".',
      );
    }

    final integrationSecs = filterPlans.fold<double>(
      0,
      (sum, plan) => sum + plan.integrationSecs,
    );
    final actualEnd = usable.$1.add(Duration(seconds: integrationSecs.round()));
    final clampedEnd = !fillWindow && actualEnd.isBefore(usable.$2)
        ? actualEnd
        : usable.$2;

    final planned = SmartNightPlannedTarget(
      suggestion: suggestion,
      windowStart: usable.$1,
      windowEnd: clampedEnd,
      filterPlans: filterPlans,
      integrationSecs: integrationSecs,
      rationale: _composeTargetRationale(
        suggestion: suggestion,
        filterPlans: filterPlans,
        windowSecs: clampedEnd.difference(usable.$1).inSeconds.toDouble(),
      ),
    );

    final context = SmartNightContext(
      windowStart: usable.$1,
      windowEnd: clampedEnd,
      bortleClass: exposureContext?.bortleClass ?? 5,
      recentGuideRmsArcsec: exposureContext?.guideRmsArcsec,
      recentGuideSamples: exposureContext?.guideSampleCount ?? 0,
    );

    final sequence = _emitSingleTargetSequence(
      profile: profile,
      planned: planned,
      strategy: resolvedStrategy,
      settings: settings,
      context: context,
      includeSessionPreamble: includeSessionPreamble,
      includeSessionShutdown: includeSessionShutdown,
      fillWindow: fillWindow,
    );

    return SingleTargetSequenceResult(
      sequence: sequence,
      strategy: resolvedStrategy,
      filterPlans: filterPlans,
      plannedTarget: planned,
    );
  }

  /// Validate the hard requirements. Failing fast at the input boundary
  /// keeps the rest of the code free of "what if profile is null" branches.
  void _validateInputs({
    required EquipmentProfileModel profile,
    required double latitudeDeg,
    required double longitudeDeg,
    required List<TargetSuggestion> selectedSuggestions,
    required SmartNightContext context,
  }) {
    if (profile.name.trim().isEmpty) {
      throw const SmartNightBuildException(
        'No equipment profile selected — Smart Night needs to know which '
        'rig you\'re using so it can compose filter rotation, gain, and '
        'cooling sub-trees.',
      );
    }
    if (!latitudeDeg.isFinite ||
        !longitudeDeg.isFinite ||
        (latitudeDeg == 0.0 && longitudeDeg == 0.0)) {
      throw const SmartNightBuildException(
        'No observer location set — Smart Night needs your latitude / '
        'longitude to compute the dark window and target altitudes.',
      );
    }
    if (selectedSuggestions.isEmpty) {
      throw const SmartNightBuildException(
        'No targets selected — pick at least one target on step 3 or let '
        'Smart Night auto-select the top-scoring candidates.',
      );
    }
    if (!context.windowEnd.isAfter(context.windowStart)) {
      throw SmartNightBuildException(
        'Observation window is invalid: windowEnd '
        '(${context.windowEnd.toIso8601String()}) is not after '
        'windowStart (${context.windowStart.toIso8601String()}).',
      );
    }
  }

  DateTime _capWindowToMaxHours({
    required DateTime windowStart,
    required DateTime windowEnd,
    required double maxHours,
  }) {
    final maxEnd = windowStart.add(
      Duration(seconds: (maxHours * 3600).round()),
    );
    return maxEnd.isBefore(windowEnd) ? maxEnd : windowEnd;
  }

  /// Resolve the camera pixel size (µm) for [profile] WITHOUT a live
  /// exposure context.
  ///
  /// Goes through [CameraSensorSpecResolver], so it sees the user's own entry
  /// and then the manufacturer's published pitch for the profile's camera —
  /// the same chain the Plan screen uses. It cannot see the live camera or the
  /// remembered reading: this path runs off a profile alone, with no provider
  /// container to read them from. The real value normally arrives via
  /// `exposureContext.pixelSizeMicrons`, which does.
  ///
  /// Returns `0` — a deliberate "unknown" sentinel — when nothing resolves.
  /// There is no hardcoded fallback pitch: a stand-in figure (3.76µm, say)
  /// mis-scales the sky-limited exposure math for every camera that does not
  /// have it, so each caller's `pixelSizeUm <= 0` guard fires loudly instead.
  /// [build] / [buildSingleTargetSequence] throw a [SmartNightBuildException]
  /// naming pixel size, and [previewTargetIntegration] returns null.
  double _pixelSize(EquipmentProfileModel profile) {
    final specs = CameraSensorSpecResolver().resolve(
      CameraSensorSpecInputs(
        cameraName: profile.cameraName,
        cameraId: profile.cameraId,
        gain: profile.defaultGain,
        overrides: _hardwareSpecs.overridesFor(
          cameraName: profile.cameraName,
          cameraId: profile.cameraId,
          gain: profile.defaultGain,
        ),
      ),
    );
    return specs.pixelSizeMicrons?.value ?? 0;
  }

  /// Map the strategy to the filter rotation that matters for this rig.
  List<String> _resolveFilterSet({
    required SmartNightStrategy strategy,
    required List<String> availableFilters,
  }) {
    return resolveSmartNightFilterSet(
      strategy: strategy,
      availableFilters: availableFilters,
    );
  }

  /// Compose per-filter plans — delegates to the public helper.
  List<SmartNightFilterPlan> _composeFilterPlans({
    required TargetSuggestion suggestion,
    required SmartNightStrategy strategy,
    required List<String> activeFilters,
    required double windowSecs,
    required EquipmentProfileModel profile,
    required CameraExposureSpec cameraSpec,
    required double focalLengthMm,
    required double apertureMm,
    required double pixelSizeUm,
    required int bortleClass,
    required double? recentGuideRmsArcsec,
    required int recentGuideSamples,
    required SmartNightSettings settings,
    List<IntegrationGoalProgress>? integrationGoalProgress,
    List<String>? availableFiltersForGoals,
  }) {
    return composeSmartNightFilterPlans(
      suggestion: suggestion,
      strategy: strategy,
      activeFilters: activeFilters,
      windowSecs: windowSecs,
      profile: profile,
      cameraSpec: cameraSpec,
      focalLengthMm: focalLengthMm,
      apertureMm: apertureMm,
      pixelSizeUm: pixelSizeUm,
      bortleClass: bortleClass,
      recentGuideRmsArcsec: recentGuideRmsArcsec,
      recentGuideSamples: recentGuideSamples,
      settings: settings,
      integrationGoalProgress: integrationGoalProgress,
      availableFiltersForGoals: availableFiltersForGoals,
      exposureCalculator: _exposureCalculator,
    );
  }

  String _composeSequenceName(
    List<SmartNightPlannedTarget> planned,
    SmartNightStrategy strategy,
  ) {
    final today = DateTime.now();
    final dateStr =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';
    final names = planned.map((p) => p.suggestion.targetName).join(' · ');
    return 'Smart Night $dateStr — $names (${_strategyLabel(strategy)})';
  }

  String _composeSequenceDescription(
    List<SmartNightPlannedTarget> planned,
    SmartNightStrategy strategy,
    SmartNightSettings settings,
  ) {
    final integrationHours =
        planned.fold<double>(0, (s, p) => s + p.integrationSecs) / 3600;
    final filters = planned
        .expand(
          (p) =>
              p.filterPlans.map((fp) => smartNightFilterLabel(fp.filterName)),
        )
        .toSet()
        .toList();
    return 'Auto-built by Smart Night using the '
        '${_strategyLabel(strategy)} strategy. '
        '${planned.length} target${planned.length == 1 ? '' : 's'}, '
        '${integrationHours.toStringAsFixed(1)}h integration, '
        'filters: ${filters.join(", ")}. '
        'AF cadence: ${_afCadenceLabel(settings)}. '
        'Min altitude: ${settings.minAltitudeDeg.toStringAsFixed(0)}°.';
  }

  String _strategyLabel(SmartNightStrategy s) {
    switch (s) {
      case SmartNightStrategy.autoLrgb:
        return 'Auto-balance LRGB';
      case SmartNightStrategy.monoLrgb:
        return 'Mono LRGB';
      case SmartNightStrategy.narrowbandHoo:
        return 'Narrowband HOO';
      case SmartNightStrategy.narrowbandSho:
        return 'Narrowband SHO';
      case SmartNightStrategy.oscOneShot:
        return 'OSC One-Shot';
    }
  }

  String _afCadenceLabel(SmartNightSettings s) {
    switch (s.afCadence) {
      case SmartNightAfCadence.everyNFrames:
        return 'every ${s.afEveryFrames} frames';
      case SmartNightAfCadence.everyNMinutes:
        return 'every ${s.afEveryMinutes} min';
      case SmartNightAfCadence.onTempDelta:
        return 'on Δtemp ${s.afTempDeltaC.toStringAsFixed(1)}°C';
    }
  }
}

/// Northern hemisphere → true (PolarAlignmentNode.isNorth).
///
/// Sourced from the observer latitude the wizard already threads through
/// [SmartNightService.build] (degrees, positive north / negative south).
/// Southern-hemisphere sites (latitude < 0) correctly resolve to `false`
/// so the emitted PolarAlignmentNode targets the south celestial pole.
///
/// Falls back to `true` when no latitude is available (e.g. an exactly-zero
/// equatorial site or a missing fix); the polar-alignment dialog still
/// exposes a North/South toggle the user can flip on Step 5 before run.
bool latitudeSign(double? latitudeDeg) {
  if (latitudeDeg == null || !latitudeDeg.isFinite) return true;
  return latitudeDeg >= 0;
}
