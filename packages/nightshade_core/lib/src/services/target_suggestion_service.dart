import 'dart:math';

import 'package:flutter/foundation.dart' show compute;
import 'package:nightshade_planetarium/nightshade_planetarium.dart';

import '../database/database.dart';
import '../models/optical_config.dart';
import '../models/planning/target_suggestion.dart';
import '../providers/settings_provider.dart' show HorizonProfile;
import 'logging_service.dart';

/// Service for generating target suggestions for tonight's imaging session.
///
/// Uses [TargetScoringService] from nightshade_planetarium to score targets
/// based on altitude, moon distance, transit proximity, darkness, and airmass.
/// Also factors in data collection progress to prioritize incomplete targets.
///
/// SCOPE (architecture-unification plan, subsystem 1): this is the whole-night
/// OUTLOOK supplement — peak altitude, transit timing, imaging-window hours,
/// framing-fit and human-readable reasoning across the entire dusk→dawn window.
/// It is NOT the authoritative "what will run tonight" ranker. That authority
/// belongs solely to the live `SchedulerEngine`, whose pure
/// `previewDecision`/`previewRanking` the Planner surfaces as the headline pick
/// (see `schedulerPreviewDecisionProvider`). This service samples the whole
/// night rather than the imaging instant, so its #1 can legitimately differ
/// from the autopilot's instantaneous pick; the UI presents it as advisory
/// outlook beneath the autopilot banner, never as a competing live decider.
class TargetSuggestionService {
  final LoggingService _logging;

  static const String _source = 'TargetSuggestionService';

  TargetSuggestionService({required LoggingService loggingService})
    : _logging = loggingService;

  /// Generate target suggestions for tonight based on the full night window.
  ///
  /// Instead of scoring at a single moment, this evaluates each target across
  /// the entire upcoming or current night (astronomical dusk to dawn). Targets
  /// are scored on their peak altitude, best airmass, transit timing relative
  /// to the night, and total imaging hours available.
  ///
  /// Parameters:
  /// - [config]: Configuration for filtering and sorting suggestions
  /// - [latitude]: Observer latitude in degrees
  /// - [longitude]: Observer longitude in degrees
  /// - [targets]: List of database targets to score
  /// - [sessions]: List of imaging sessions for progress calculation
  /// - [observationTime]: Time to calculate positions for (defaults to now)
  ///
  /// Returns a sorted list of [TargetSuggestion] objects matching the config criteria.
  Future<List<TargetSuggestion>> getSuggestionsForTonight({
    required TargetSuggestionConfig config,
    required double latitude,
    required double longitude,
    required List<Target> targets,
    required List<ImagingSession> sessions,
    DateTime? observationTime,
    OpticalConfig? opticalConfig,
    HorizonProfile? horizonProfile,
  }) async {
    if (targets.isEmpty) return [];
    final elapsed = Stopwatch()..start();
    _logging.debug(
      'Generating suggestions for ${targets.length} targets at lat=$latitude, lon=$longitude',
      source: _source,
    );
    final result = await compute(_scoreTonight, (
      config: config,
      latitude: latitude,
      longitude: longitude,
      targets: targets,
      sessions: sessions,
      observationTime: observationTime ?? DateTime.now(),
      opticalConfig: opticalConfig,
      horizonProfile: horizonProfile,
    ), debugLabel: 'tonight-target-scoring');
    for (final warning in result.warnings) {
      _logging.warning(warning, source: _source);
    }
    _logging.info(
      'Generated ${result.suggestions.length} suggestions from ${targets.length} '
      'targets in ${elapsed.elapsedMilliseconds}ms (background scoring)',
      source: _source,
    );
    return result.suggestions;
  }
}

typedef _SuggestionRequest = ({
  TargetSuggestionConfig config,
  double latitude,
  double longitude,
  List<Target> targets,
  List<ImagingSession> sessions,
  DateTime observationTime,
  OpticalConfig? opticalConfig,
  HorizonProfile? horizonProfile,
});

typedef _SuggestionResult = ({
  List<TargetSuggestion> suggestions,
  List<String> warnings,
});

// A top-level callback keeps UI services and logging handles out of the worker.
_SuggestionResult _scoreTonight(_SuggestionRequest request) {
  final scorer = _TonightSuggestionScorer();
  final suggestions = scorer.score(
    config: request.config,
    latitude: request.latitude,
    longitude: request.longitude,
    targets: request.targets,
    sessions: request.sessions,
    observationTime: request.observationTime,
    opticalConfig: request.opticalConfig,
    horizonProfile: request.horizonProfile,
  );
  return (suggestions: suggestions, warnings: scorer.warnings);
}

class _TonightSuggestionScorer {
  final warnings = <String>[];
  static const double _typicalExposureSecs = 300.0;

  List<TargetSuggestion> score({
    required TargetSuggestionConfig config,
    required double latitude,
    required double longitude,
    required List<Target> targets,
    required List<ImagingSession> sessions,
    required DateTime observationTime,
    OpticalConfig? opticalConfig,
    HorizonProfile? horizonProfile,
  }) {
    final now = observationTime;

    // Determine the night window (astronomical dusk to dawn).
    // If we're currently in a night (after midnight, before dawn), use that
    // night's window. Otherwise use the upcoming night.
    final nightWindow = _calculateNightWindow(now, latitude, longitude);

    // Get moon position at the midpoint of the night (moon moves slowly)
    final nightMid = nightWindow.start.add(
      Duration(
        seconds: nightWindow.end.difference(nightWindow.start).inSeconds ~/ 2,
      ),
    );
    final moonPos = AstronomyCalculations.moonPosition(nightMid);
    final moonRaDeg = moonPos.$1;
    final moonDecDeg = moonPos.$2;
    final moonIllumination = AstronomyCalculations.moonIllumination(nightMid);

    // Create the scoring service. When a custom horizon profile is set, feed
    // it in as a per-azimuth altitude mask so "hours above minimum altitude"
    // becomes "hours above the LOCAL skyline" — a target whose entire nightly
    // track stays behind a hill/tree yields zero observable hours and a peak
    // altitude that already reflects the obstruction.
    final HorizonMask? horizonMask =
        (horizonProfile != null && !horizonProfile.isFlat)
        ? horizonProfile.altitudeAtAzimuth
        : null;
    final scoringService = TargetScoringService(
      latitude: latitude,
      longitude: longitude,
      observationTime: now,
      moonPosition: (moonRaDeg, moonDecDeg),
      moonIllumination: moonIllumination,
      twilight: nightWindow.twilight,
      horizonMask: horizonMask,
    );

    // Compute FOV short axis in arcminutes if optical config is available
    double? fovShortAxisArcmin;
    final fov = opticalConfig?.fieldOfView;
    if (fov != null) {
      fovShortAxisArcmin = min(fov.$1, fov.$2) * 60.0;
    }

    final suggestions = <TargetSuggestion>[];

    for (final target in targets) {
      // Convert database target to CelestialObject for scoring
      final celestialObj = _targetToCelestialObject(target);

      // Score the target across the entire night window
      final score = scoringService.scoreTargetForNight(
        target: celestialObj,
        nightStart: nightWindow.start,
        nightEnd: nightWindow.end,
        minAltitude: config.minAltitude,
      );

      // Skip targets that never clear the minimum altitude during the night.
      // With [horizonMask] wired into the scorer above, the reported peak
      // altitude is the highest point the target reaches WHILE clearing the
      // local skyline (or, if it never clears it, the unobstructed peak with
      // zero observable hours) — so this single check enforces both the flat
      // minimum and the custom horizon profile.
      final peakAlt =
          score.visibility.peakAltitude ?? score.visibility.currentAltitude;
      final hoursAboveHorizon = score.visibility.hoursAboveMinAlt ?? 0.0;
      if (peakAlt < config.minAltitude || hoursAboveHorizon <= 0.0) {
        continue;
      }

      // Skip targets below minimum score
      if (score.totalScore < config.minScore) {
        continue;
      }

      // A bare star with no angular size is not a deep-sky imaging subject.
      // Live, tonight's #1 pick (score 96) was "gam Cyg / IC1318" carrying
      // gamma Cygni's stellar type and mag 2.2 — a naked-eye point source
      // recommended over every nebula and galaxy in the list, with the
      // exposure suggestion and the magnitude sort inheriting the error. Rows
      // typed as a star are only offered when the user asked for them.
      if (config.preferredObjectTypes.isEmpty &&
          _parseDsoType(target.objectType) == DsoType.star &&
          (target.sizeArcmin == null || target.sizeArcmin! <= 0)) {
        continue;
      }

      // Filter by preferred object types if specified
      if (config.preferredObjectTypes.isNotEmpty) {
        final objectType = target.objectType?.toLowerCase() ?? '';
        final matches = config.preferredObjectTypes.any(
          (type) => objectType.contains(type.toLowerCase()),
        );
        if (!matches) {
          continue;
        }
      }

      // Calculate data progress
      final dataProgress = _calculateDataProgress(target.id, target, sessions);

      // Compute framing fit score and adjusted total score
      double adjustedTotalScore = score.totalScore;
      double? framingFitScore;
      final tags = <String>[];

      if (fovShortAxisArcmin != null && fovShortAxisArcmin > 0) {
        framingFitScore = _scoreFramingFit(
          target.sizeArcmin,
          fovShortAxisArcmin,
        );
        const framingWeight = 0.08;
        const scaleFactor = 1.0 / (1.0 + framingWeight);
        adjustedTotalScore =
            (score.totalScore + framingFitScore * framingWeight) * scaleFactor;

        // Tag targets that overflow the FOV as mosaic candidates
        if (target.sizeArcmin != null && target.sizeArcmin! > 0) {
          final fillRatio = target.sizeArcmin! / fovShortAxisArcmin;
          if (fillRatio > 1.0) {
            tags.add('Mosaic recommended');
          }
        }
      }

      // Generate human-readable reasoning
      final reasoning = _generateNightReasoning(
        score,
        dataProgress,
        nightWindow,
        moonIllumination: moonIllumination,
        framingFitScore: framingFitScore,
        targetSizeArcmin: target.sizeArcmin,
        fovShortAxisArcmin: fovShortAxisArcmin,
      );

      // Build score breakdown map
      final scoreBreakdown = <String, double>{
        'altitude': score.altitudeScore,
        'moonDistance': score.moonDistanceScore,
        'transitProximity': score.transitProximityScore,
        'darkness': score.darknessScore,
        'airmass': score.airmassScore,
        if (framingFitScore != null) 'framingFit': framingFitScore,
      };

      final suggestion = TargetSuggestion(
        targetId: target.id,
        targetName: target.name,
        catalogId: target.catalogId,
        raHours: target.ra,
        decDegrees: target.dec,
        totalScore: adjustedTotalScore,
        scoreBreakdown: scoreBreakdown,
        warnings: score.warnings,
        visibility: score.visibility,
        reasoning: reasoning,
        dataProgress: dataProgress,
        objectType: target.objectType,
        magnitude: target.magnitude,
        sizeArcmin: target.sizeArcmin,
        constellation: target.constellation,
        tags: tags,
      );

      suggestions.add(suggestion);
    }

    // Sort by configured mode
    _sortSuggestions(suggestions, config.sortMode, config.prioritizeIncomplete);

    return suggestions;
  }

  /// Convert a database Target to a CelestialObject for scoring.
  CelestialObject _targetToCelestialObject(Target target) {
    // Target.ra is in decimal hours, Target.dec is in decimal degrees
    final coordinate = CelestialCoordinate(ra: target.ra, dec: target.dec);

    // Determine DSO type from object type string
    final dsoType = _parseDsoType(target.objectType);

    return DeepSkyObject(
      id: target.id.toString(),
      name: target.name,
      coordinates: coordinate,
      type: dsoType,
      magnitude: target.magnitude,
      sizeArcMin: target.sizeArcmin,
      constellation: target.constellation,
      catalogIds: target.catalogId != null ? [target.catalogId!] : [],
    );
  }

  /// Parse object type string to DsoType enum.
  DsoType _parseDsoType(String? objectType) {
    if (objectType == null || objectType.isEmpty) {
      return DsoType.other;
    }

    final type = objectType.toLowerCase();

    if (type.contains('galaxy')) return DsoType.galaxy;
    if (type.contains('nebula')) {
      if (type.contains('planetary')) return DsoType.planetaryNebula;
      if (type.contains('emission')) return DsoType.emissionNebula;
      if (type.contains('reflection')) return DsoType.reflectionNebula;
      if (type.contains('dark')) return DsoType.darkNebula;
      return DsoType.nebula;
    }
    if (type.contains('cluster')) {
      if (type.contains('globular')) return DsoType.globularCluster;
      if (type.contains('open')) return DsoType.openCluster;
      return DsoType.openCluster;
    }
    if (type.contains('hii') || type.contains('h ii')) return DsoType.hiiRegion;
    if (type.contains('supernova')) return DsoType.supernova;
    if (type.contains('star')) return DsoType.star;

    return DsoType.other;
  }

  /// Calculate data collection progress for a target.
  ///
  /// Returns a value from 0.0 (no data) to 1.0 (complete).
  double _calculateDataProgress(
    int targetId,
    Target target,
    List<ImagingSession> sessions,
  ) {
    // Sum total integration time from all sessions for this target
    double totalIntegrationSecs = 0;
    for (final session in sessions) {
      if (session.targetId == targetId) {
        totalIntegrationSecs += session.totalIntegrationSecs;
      }
    }

    // Also include any integration time already stored on the target itself
    totalIntegrationSecs += target.totalIntegrationSecs;

    // Calculate expected total integration time
    final plannedSubs = target.totalPlannedSubs;
    if (plannedSubs <= 0) {
      // If no planned subs, we can't calculate progress
      // Return 0 if no data, or a small value if we have some data
      if (totalIntegrationSecs > 0) {
        // We have data but no plan - show as partially complete
        return 0.1; // 10% to indicate some data exists
      }
      return 0.0;
    }

    final expectedTotalSecs = plannedSubs * _typicalExposureSecs;
    final progress = totalIntegrationSecs / expectedTotalSecs;

    // Clamp to 0-1 range
    return progress.clamp(0.0, 1.0);
  }

  /// Determine the night window (astronomical dusk to dawn) for the given time.
  ///
  /// If the observer is currently in a night (after midnight, before dawn), returns
  /// that night's window. Otherwise returns the upcoming night's window.
  /// Falls back to nautical or civil twilight at high latitudes where
  /// astronomical darkness may not occur.
  _NightWindow _calculateNightWindow(
    DateTime now,
    double latitude,
    double longitude,
  ) {
    // Check if we're currently in "last night" (past midnight, before dawn).
    // calculateTwilightTimes starts from noon, so passing yesterday's date
    // gives us yesterday's evening dusk → this morning's dawn.
    final prevDate = DateTime(now.year, now.month, now.day - 1);
    final prevTwilight = AstronomyCalculations.calculateTwilightTimes(
      date: prevDate,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );

    final prevNight = _extractNightBounds(prevTwilight);
    if (prevNight != null &&
        now.isAfter(prevNight.start) &&
        now.isBefore(prevNight.end)) {
      // We're in last night's darkness
      return _NightWindow(
        start: prevNight.start,
        end: prevNight.end,
        twilight: prevTwilight,
      );
    }

    // Not in last night → use today's date for the upcoming/current evening
    final todayDate = DateTime(now.year, now.month, now.day);
    final todayTwilight = AstronomyCalculations.calculateTwilightTimes(
      date: todayDate,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );

    final todayNight = _extractNightBounds(todayTwilight);
    if (todayNight != null) {
      return _NightWindow(
        start: todayNight.start,
        end: todayNight.end,
        twilight: todayTwilight,
      );
    }

    // No astronomical/nautical/civil darkness (e.g. polar midnight sun).
    // Use a reasonable default window: 9 PM to 5 AM local.
    warnings.add(
      'No twilight boundaries found - using default 21:00-05:00 window',
    );
    final defaultStart = DateTime(now.year, now.month, now.day, 21);
    var defaultEnd = DateTime(now.year, now.month, now.day + 1, 5);
    if (now.isAfter(defaultEnd)) {
      // If we're past 5 AM, shift to tonight
      defaultEnd = defaultEnd.add(const Duration(days: 1));
    }
    return _NightWindow(
      start: defaultStart,
      end: defaultEnd,
      twilight: todayTwilight,
    );
  }

  /// Extract the best available night bounds from twilight times.
  /// Prefers astronomical darkness, falls back to nautical then civil.
  ({DateTime start, DateTime end})? _extractNightBounds(TwilightTimes tw) {
    // Prefer astronomical darkness
    if (tw.astronomicalDusk != null && tw.astronomicalDawn != null) {
      return (start: tw.astronomicalDusk!, end: tw.astronomicalDawn!);
    }
    // Fallback to nautical twilight (high latitudes in summer)
    if (tw.nauticalDusk != null && tw.nauticalDawn != null) {
      return (start: tw.nauticalDusk!, end: tw.nauticalDawn!);
    }
    // Fallback to civil twilight
    if (tw.civilDusk != null && tw.civilDawn != null) {
      return (start: tw.civilDusk!, end: tw.civilDawn!);
    }
    // Fallback to sunset/sunrise
    if (tw.sunset != null && tw.sunrise != null) {
      return (start: tw.sunset!, end: tw.sunrise!);
    }
    return null;
  }

  /// Generate a human-readable reasoning string for the night-based suggestion.
  String _generateNightReasoning(
    TargetScore score,
    double dataProgress,
    _NightWindow nightWindow, {
    required double moonIllumination,
    double? framingFitScore,
    double? targetSizeArcmin,
    double? fovShortAxisArcmin,
  }) {
    final parts = <String>[];

    // Peak altitude assessment
    final peakAlt =
        score.visibility.peakAltitude ?? score.visibility.currentAltitude;
    if (peakAlt >= 60) {
      parts.add('Excellent peak altitude (${peakAlt.toStringAsFixed(0)}°)');
    } else if (peakAlt >= 45) {
      parts.add('High peak altitude (${peakAlt.toStringAsFixed(0)}°)');
    } else if (peakAlt >= 30) {
      parts.add('Good peak altitude (${peakAlt.toStringAsFixed(0)}°)');
    } else {
      parts.add('Low peak altitude (${peakAlt.toStringAsFixed(0)}°)');
    }

    // Moon: separation AND illumination. Separation alone reads as good news
    // on a full-moon night ("far from moon (101°)") when the whole sky is
    // washed out, so the phase is always stated alongside it.
    final moonDist = score.visibility.moonDistance;
    final illum = moonIllumination.clamp(0.0, 100.0);
    final moonPhase = '${illum.toStringAsFixed(0)}% moon';
    if (moonDist >= 90) {
      parts.add('far from the $moonPhase (${moonDist.toStringAsFixed(0)}°)');
    } else if (moonDist >= 60) {
      parts.add(
        'good separation from the $moonPhase (${moonDist.toStringAsFixed(0)}°)',
      );
    } else if (moonDist >= 30) {
      parts.add('$moonPhase nearby (${moonDist.toStringAsFixed(0)}°)');
    } else {
      parts.add('close to the $moonPhase (${moonDist.toStringAsFixed(0)}°)');
    }

    // Transit timing relative to the night
    final transitTime = score.visibility.transitTime;
    if (transitTime != null) {
      if (transitTime.isAfter(nightWindow.start) &&
          transitTime.isBefore(nightWindow.end)) {
        final hour = transitTime.hour.toString().padLeft(2, '0');
        final minute = transitTime.minute.toString().padLeft(2, '0');
        parts.add('transits at $hour:$minute tonight');
      }
    }

    // Build first sentence
    var reasoning = parts.join(', ');
    if (reasoning.isNotEmpty) {
      reasoning = '${reasoning[0].toUpperCase()}${reasoning.substring(1)}.';
    }

    // Imaging window
    final hoursAbove = score.visibility.hoursAboveMinAlt;
    if (hoursAbove != null && hoursAbove > 0) {
      reasoning +=
          ' ${hoursAbove.toStringAsFixed(1)} hours above minimum altitude.';
    }

    // Bright-moon disclosure, independent of separation. A wide separation does
    // not rescue a broadband target under a bright moon: the sky background is
    // elevated across the whole sky. Saying nothing at all made a full-moon
    // night read exactly like a new-moon night.
    if (illum >= 65) {
      reasoning +=
          ' Sky background is elevated by the '
          '${illum.toStringAsFixed(0)}%-illuminated moon; narrowband filters '
          'will fare much better than broadband tonight.';
    }

    // Data progress
    if (dataProgress > 0) {
      final pct = (dataProgress * 100).toStringAsFixed(0);
      reasoning += ' $pct% of planned data collected.';
    } else {
      reasoning += ' No data collected yet.';
    }

    // Framing fit note
    if (framingFitScore != null && fovShortAxisArcmin != null) {
      if (targetSizeArcmin != null && targetSizeArcmin > 0) {
        final fillPct = (targetSizeArcmin / fovShortAxisArcmin * 100)
            .toStringAsFixed(0);
        if (framingFitScore >= 80) {
          reasoning += ' Well-framed at $fillPct% of FOV.';
        } else if (framingFitScore >= 50) {
          reasoning += ' Fills $fillPct% of FOV.';
        } else {
          reasoning += ' May not frame ideally ($fillPct% of FOV).';
        }
      }
    }

    // Add warning summary if any significant warnings
    final criticalWarnings = score.warnings
        .where(
          (w) =>
              w.severity == WarningSeverity.critical ||
              w.severity == WarningSeverity.warning,
        )
        .toList();
    if (criticalWarnings.isNotEmpty) {
      final warningMsg = criticalWarnings.first.message;
      reasoning += ' Note: $warningMsg';
    }

    return reasoning;
  }

  /// Score how well a target's angular size fits the field of view.
  ///
  /// Returns a score from 1-100 based on the fill ratio
  /// (target size / FOV short axis). The curve is intentionally asymmetric:
  /// overflow targets (larger than FOV) are penalized gently because
  /// imaging a portion of a large nebula is common and produces great
  /// results. Undersized targets are penalized more heavily because a
  /// tiny speck genuinely isn't a good match for the setup.
  ///
  /// The curve is continuous with many brackets for smooth transitions:
  ///
  /// Overflow side (gentle):
  /// - >200% fill: 50 (neutral — no penalty for huge targets)
  /// - 100-200% fill: 50→60 (overflows but imageable)
  /// - 90-100% fill: 60→70 (barely fits)
  ///
  /// Upper ideal zone:
  /// - 75-90% fill: 70→80 (tight)
  /// - 60-75% fill: 80→100 (good)
  ///
  /// Sweet spot:
  /// - 40-60% fill: 100 (ideal framing)
  ///
  /// Lower zone (steeper penalty):
  /// - 30-40% fill: 85→100 (good but slightly small)
  /// - 20-30% fill: 75→85 (decent but small)
  /// - 10-20% fill: 45→75 (small for the setup)
  /// - 5-10% fill: 20→45 (very small)
  /// - <5% fill: 1→20 (tiny speck)
  ///
  /// - No size data: 50 (neutral)
  double _scoreFramingFit(double? targetSizeArcmin, double fovShortAxisArcmin) {
    if (targetSizeArcmin == null || targetSizeArcmin <= 0) return 50; // neutral

    final fillRatio = targetSizeArcmin / fovShortAxisArcmin;

    // Sweet spot
    if (fillRatio >= 0.40 && fillRatio <= 0.60) return 100;

    // Above sweet spot (tight side, gentle dropoff)
    if (fillRatio > 0.60 && fillRatio <= 0.75) {
      // 100→80
      return 100 - ((fillRatio - 0.60) / 0.15) * 20;
    }
    if (fillRatio > 0.75 && fillRatio <= 0.90) {
      // 80→70
      return 80 - ((fillRatio - 0.75) / 0.15) * 10;
    }
    if (fillRatio > 0.90 && fillRatio <= 1.0) {
      // 70→60
      return 70 - ((fillRatio - 0.90) / 0.10) * 10;
    }

    // Overflow side (gentle — large targets are still great)
    if (fillRatio > 1.0 && fillRatio <= 2.0) {
      // 60→50
      return 60 - ((fillRatio - 1.0) / 1.0) * 10;
    }
    if (fillRatio > 2.0) {
      // Neutral — no meaningful penalty for huge targets
      return 50;
    }

    // Below sweet spot (steeper penalty — small targets)
    if (fillRatio >= 0.30 && fillRatio < 0.40) {
      // 85→100
      return 85 + ((fillRatio - 0.30) / 0.10) * 15;
    }
    if (fillRatio >= 0.20 && fillRatio < 0.30) {
      // 75→85
      return 75 + ((fillRatio - 0.20) / 0.10) * 10;
    }
    if (fillRatio >= 0.10 && fillRatio < 0.20) {
      // 45→75
      return 45 + ((fillRatio - 0.10) / 0.10) * 30;
    }
    if (fillRatio >= 0.05 && fillRatio < 0.10) {
      // 20→45
      return 20 + ((fillRatio - 0.05) / 0.05) * 25;
    }

    // Tiny speck
    // 1→20
    return 1 + (fillRatio / 0.05) * 19;
  }

  /// Sort suggestions according to the configured mode.
  void _sortSuggestions(
    List<TargetSuggestion> suggestions,
    SuggestionSortMode sortMode,
    bool prioritizeIncomplete,
  ) {
    suggestions.sort((a, b) {
      // If prioritizing incomplete, put targets with less data first
      if (prioritizeIncomplete) {
        // Only prioritize if one is significantly more complete than the other
        if ((a.dataProgress - b.dataProgress).abs() > 0.2) {
          // Less complete targets get priority
          final progressComparison = a.dataProgress.compareTo(b.dataProgress);
          if (progressComparison != 0) {
            return progressComparison;
          }
        }
      }

      // Then apply the configured sort mode
      switch (sortMode) {
        case SuggestionSortMode.bestScore:
          return b.totalScore.compareTo(a.totalScore);

        case SuggestionSortMode.highestAltitude:
          // Use peak altitude (night-aware) if available, else current altitude
          final aAlt =
              a.visibility.peakAltitude ?? a.visibility.currentAltitude;
          final bAlt =
              b.visibility.peakAltitude ?? b.visibility.currentAltitude;
          return bAlt.compareTo(aAlt);

        case SuggestionSortMode.nearestTransit:
          // Sort by transit time (earlier transits first for planning)
          final aTransit = a.visibility.transitTime;
          final bTransit = b.visibility.transitTime;
          if (aTransit == null && bTransit == null) return 0;
          if (aTransit == null) return 1;
          if (bTransit == null) return -1;
          return aTransit.compareTo(bTransit);

        case SuggestionSortMode.leastDataCollected:
          return a.dataProgress.compareTo(b.dataProgress);
      }
    });
  }
}

/// Internal representation of the night window for scoring.
class _NightWindow {
  final DateTime start;
  final DateTime end;
  final TwilightTimes twilight;

  const _NightWindow({
    required this.start,
    required this.end,
    required this.twilight,
  });
}
