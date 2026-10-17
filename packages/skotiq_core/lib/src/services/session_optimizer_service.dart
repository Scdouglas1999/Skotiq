import '../database/database.dart' as db;
import '../models/optical_config.dart';
import '../models/planning/target_suggestion.dart';
import '../models/session_report.dart';
import '../utils/duration_format.dart';
import 'mosaic_service.dart';
import 'target_suggestion_service.dart';
import 'smart_night/exposure_calculator.dart';
import 'smart_night_service.dart';

/// Kind of suggestion the post-session optimizer can emit.
///
/// Each kind corresponds to one "apply" semantic: the UI consults this
/// value to decide whether the Apply button should open the target
/// editor with a pre-filled `startWhen` altitude, the autofocus
/// settings, or just be omitted entirely.
enum SessionInsightKind {
  /// "M31 was below altitude X for Y hours — consider tightening
  /// `start_when` to AltitudeAbove(X+5)." Apply opens the target
  /// editor with the suggested altitude crossing.
  altitudeWindow,

  /// "Autofocus fired N times — temperature compensation could prevent
  /// some." Apply opens Settings → Autofocus.
  autofocusFrequency,

  /// "Filter changes ate X% of the night — consider longer sub
  /// stretches per filter." Apply opens the target editor (filter
  /// group length).
  filterChangeOverhead,

  /// "Rejection rate was X% — consider relaxing the HFR threshold or
  /// improving guiding." Apply opens Settings → Image Grading.
  rejectionRate,

  /// "Guiding RMS exceeded X arcsec on Y% of frames." Apply opens the
  /// guiding screen.
  guidingDegraded,

  /// "Effective imaging fraction was only X% — downtime dominated."
  /// Informational; no Apply (the user needs to investigate the
  /// downtime breakdown themselves).
  efficiencyLow,

  /// Generic informational insight with no actionable knob.
  informational,
}

/// One actionable retrospective observation produced by the optimizer.
///
/// All numeric fields are read-only. The `applyHint` is the only
/// machine-readable knob: it identifies a payload the UI can pre-fill
/// in the target editor (e.g. an altitude crossing). When `applyHint`
/// is null, the Apply button is hidden and the insight is "FYI only".
class SessionInsight {
  /// Stable identifier for this insight within the session. Used by
  /// the dismissed-insights persistence path so a user who clicks
  /// "Don't suggest this again" doesn't see the same recommendation
  /// after every session.
  final String id;

  /// Insight category — drives the icon + Apply behaviour in the UI.
  final SessionInsightKind kind;

  /// One-line human description (e.g. "M31 was below 50° for 1h 47m").
  final String title;

  /// Optional longer body with the supporting numbers.
  final String? body;

  /// Optional resolution hint shown when the user expands the insight.
  /// Different from [body] — this is the "what to do" line, not the
  /// "what happened" line.
  final String? recommendation;

  /// `[0.0, 1.0]` confidence. The UI renders this as a small badge so
  /// the operator can ignore weak signals.
  final double confidence;

  /// When non-null, the Apply button opens the target editor with this
  /// `targetId` selected (the UI inspects [applyHint] to decide what
  /// to pre-fill — e.g. `altitudeAboveDeg`).
  final int? targetId;

  /// Optional machine-readable hint the UI uses to pre-fill an action.
  /// Currently supported keys:
  ///   * `altitudeAboveDeg` (double) — for `altitudeWindow` kind.
  ///   * `targetName` (String) — for `altitudeWindow` kind; lets the UI
  ///     resolve the correct target on a multi-target sequence.
  ///   * `autofocusInterval` (int) — for `autofocusFrequency` kind.
  final Map<String, Object?>? applyHint;

  const SessionInsight({
    required this.id,
    required this.kind,
    required this.title,
    this.body,
    this.recommendation,
    required this.confidence,
    this.targetId,
    this.applyHint,
  });

  /// True when the UI should render an Apply button next to this
  /// insight.
  bool get isActionable => applyHint != null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'title': title,
    'body': body,
    'recommendation': recommendation,
    'confidence': confidence,
    'targetId': targetId,
    'applyHint': applyHint,
  };
}

/// Per-target altitude trace used by the post-session optimizer.
///
/// The optimizer accepts a list of these so the analyzer can be
/// driven from test fixtures without depending on the live ephemeris
/// service. In production, the provider builds them by walking the
/// captured-image timestamps through `AstronomyCalculations`.
class SessionTargetAltitudeTrace {
  final int? targetId;
  final String targetName;

  /// Number of seconds the target was below [minRecommendedAltitudeDeg]
  /// while frames were being captured for it.
  final double secondsBelowMinAltitude;

  /// The minimum altitude (deg) below which we count "wasted" time.
  /// Defaults to 30° if the caller has no per-target preference.
  final double minRecommendedAltitudeDeg;

  /// The lowest altitude (deg) observed during the run for this
  /// target — used to suggest a tighter `start_when` value.
  final double? minObservedAltitudeDeg;

  /// True when the target dipped below [minRecommendedAltitudeDeg]
  /// at any point during capture. Drives the altitudeWindow insight.
  bool get hadLowAltitudeCapture => secondsBelowMinAltitude > 0;

  const SessionTargetAltitudeTrace({
    required this.targetId,
    required this.targetName,
    required this.secondsBelowMinAltitude,
    required this.minRecommendedAltitudeDeg,
    required this.minObservedAltitudeDeg,
  });
}

/// Settings sourced from app-settings that tune insight generation.
class SessionInsightThresholds {
  /// Minimum confidence to surface an insight. Insights below this are
  /// dropped — used so a user-facing "tone down recommendations" knob
  /// in settings can take effect without touching the math.
  final double minConfidence;

  /// Insights with these `id` values are suppressed entirely. Sourced
  /// from the dismissed-insights persistence path.
  final Set<String> dismissedIds;

  /// Threshold (fraction of wall-clock time) above which filter
  /// changes are flagged. Default 15% based on operator surveys.
  final double filterChangeOverheadFraction;

  /// Threshold (fraction of accepted frames) above which the rejection
  /// rate is flagged. Default 10% — anything below is "normal".
  final double rejectionRateFraction;

  /// Threshold (arcsec) above which guiding is considered degraded.
  /// Default 1.5".
  final double guidingDegradedArcsec;

  /// Threshold (fraction of wall-clock time) below which the night
  /// is flagged as "downtime-heavy". Default 0.5 (i.e. <50% effective
  /// imaging).
  final double efficiencyLowFraction;

  /// Threshold (autofocus runs per hour) above which AF frequency is
  /// flagged. Default 4/hour — anything beyond suggests temperature
  /// compensation could help.
  final double autofocusRunsPerHour;

  /// `[0.0, 1.0]` margin above [minRecommendedAltitudeDeg] suggested by
  /// the altitude-window insight. Default 0.10 → +5° margin on a 50°
  /// floor.
  final double altitudeSuggestionMarginDeg;

  const SessionInsightThresholds({
    this.minConfidence = 0.4,
    this.dismissedIds = const <String>{},
    this.filterChangeOverheadFraction = 0.15,
    this.rejectionRateFraction = 0.10,
    this.guidingDegradedArcsec = 1.5,
    this.efficiencyLowFraction = 0.5,
    this.autofocusRunsPerHour = 4.0,
    this.altitudeSuggestionMarginDeg = 5.0,
  });
}

/// A concrete plan for the next imaging session.
class SessionOptimizationPlan {
  final DateTime generatedAt;
  final TargetSuggestion? primaryTarget;
  final List<TargetSuggestion> alternates;
  final double recommendedExposureSeconds;
  final String? recommendedFilterName;

  /// Full filter rotation inferred from target type and available filters.
  final List<String> recommendedFilterNames;
  final double estimatedUsableHours;
  final List<String> rationale;
  final List<String> riskFactors;

  const SessionOptimizationPlan({
    required this.generatedAt,
    required this.primaryTarget,
    required this.alternates,
    required this.recommendedExposureSeconds,
    this.recommendedFilterName,
    this.recommendedFilterNames = const [],
    required this.estimatedUsableHours,
    required this.rationale,
    required this.riskFactors,
  });

  bool get hasRecommendation => primaryTarget != null;
}

/// Inputs the Smart Night exposure calculator needs.
class SmartNightExposureContext {
  final CameraExposureSpec camera;
  final int bortleClass;
  final double focalLengthMm;
  final double apertureMm;
  final double pixelSizeMicrons;
  final List<String> availableFilterNames;
  final double? guideRmsArcsec;
  final int guideSampleCount;
  final double gloverKFactor;
  final double targetSnr;
  final double userCapSeconds;
  final double floorSeconds;
  final List<String> caveats;

  const SmartNightExposureContext({
    required this.camera,
    required this.bortleClass,
    required this.focalLengthMm,
    required this.apertureMm,
    required this.pixelSizeMicrons,
    this.availableFilterNames = const [],
    this.guideRmsArcsec,
    this.guideSampleCount = 0,
    this.gloverKFactor = 10,
    this.targetSnr = 30,
    this.userCapSeconds = 300,
    this.floorSeconds = 60,
    this.caveats = const [],
  });

  ExposureRecommendation recommendForFilter(
    String? filterName, {
    SmartNightExposureCalculator calculator =
        const SmartNightExposureCalculator(),
  }) {
    return calculator.recommend(
      ExposureCalculatorInput(
        camera: camera,
        filter: FilterExposureSpec.fromName(filterName ?? 'L'),
        bortleClass: bortleClass,
        focalLengthMm: focalLengthMm,
        apertureMm: apertureMm,
        pixelSizeMicrons: pixelSizeMicrons,
        guideRmsArcsec: guideRmsArcsec,
        guideSampleCount: guideSampleCount,
        gloverKFactor: gloverKFactor,
        targetSnr: targetSnr,
        userCapSeconds: userCapSeconds,
        floorSeconds: floorSeconds,
      ),
    );
  }

  ExposureRecommendation recommendForTarget(
    TargetSuggestion suggestion, {
    SmartNightExposureCalculator calculator =
        const SmartNightExposureCalculator(),
  }) {
    return calculator.recommend(
      ExposureCalculatorInput(
        camera: camera,
        filter: selectFilterForTarget(suggestion),
        bortleClass: bortleClass,
        focalLengthMm: focalLengthMm,
        apertureMm: apertureMm,
        pixelSizeMicrons: pixelSizeMicrons,
        guideRmsArcsec: guideRmsArcsec,
        guideSampleCount: guideSampleCount,
        gloverKFactor: gloverKFactor,
        targetSnr: targetSnr,
        userCapSeconds: userCapSeconds,
        floorSeconds: floorSeconds,
      ),
    );
  }

  FilterExposureSpec selectFilterForTarget(TargetSuggestion suggestion) {
    final filters = availableFilterNames
        .map((f) => f.trim())
        .where((f) => f.isNotEmpty)
        .toList(growable: false);

    // Align with inferSmartNightStrategy: only emission nebulae prefer Ha.
    // Planetary/reflection nebulae and SNRs use broadband luminance.
    if (isEmissionNebulaTarget(suggestion)) {
      final narrowband = filters.where(_isNarrowbandFilter).toList();
      if (narrowband.isNotEmpty) {
        final ha = narrowband.where((f) => f.toLowerCase().contains('ha'));
        return FilterExposureSpec.fromName(
          ha.isNotEmpty ? ha.first : narrowband.first,
        );
      }
    }

    if (filters.isEmpty) {
      return const FilterExposureSpec.luminance();
    }

    return FilterExposureSpec.fromName(
      _preferredBroadbandFilterName(filters) ?? filters.first,
    );
  }

  /// Shared default for mosaic builders: prefer the luminance/clear channel
  /// when present, otherwise use the first configured filter, and run the
  /// same Smart Night exposure calculator used by Plan Tonight and the
  /// sequencer property panels.
  MosaicExposureSettings recommendMosaicExposureSettings({
    int exposuresPerPanel = 10,
    int binning = 1,
  }) {
    final filterName = _preferredBroadbandFilterName(availableFilterNames);
    final recommendation = recommendForFilter(filterName);
    return MosaicExposureSettings(
      exposureSeconds: recommendation.seconds,
      exposuresPerPanel: exposuresPerPanel,
      filterName: filterName,
      binning: binning,
    );
  }
}

bool _isNarrowbandFilter(String filterName) {
  final normalized = filterName.toLowerCase();
  return normalized.contains('ha') ||
      normalized.contains('oiii') ||
      normalized.contains('sii') ||
      normalized.contains('h-alpha') ||
      normalized.contains('oxygen') ||
      normalized.contains('sulfur') ||
      normalized.contains('sulphur');
}

String? _preferredBroadbandFilterName(List<String> filters) {
  final cleaned = filters
      .map((f) => f.trim())
      .where((f) => f.isNotEmpty)
      .toList(growable: false);
  if (cleaned.isEmpty) return null;
  final luminance = cleaned.where((f) {
    final normalized = f.toLowerCase();
    return normalized == 'l' ||
        normalized == 'lum' ||
        normalized == 'luminance' ||
        normalized == 'clear';
  });
  return luminance.isNotEmpty ? luminance.first : cleaned.first;
}

/// Centralized mosaic exposure defaults for every UI/API surface. Passing
/// `null` is the explicit degraded path used before Smart Night context has
/// loaded; callers should not invent their own hardcoded exposure fallback.
MosaicExposureSettings smartNightMosaicExposureSettings(
  SmartNightExposureContext? exposureContext, {
  int exposuresPerPanel = 10,
  int binning = 1,
}) {
  if (exposureContext == null) {
    return MosaicExposureSettings(
      exposureSeconds: _fallbackExposureContext
          .recommendMosaicExposureSettings(
            exposuresPerPanel: exposuresPerPanel,
            binning: binning,
          )
          .exposureSeconds,
      exposuresPerPanel: exposuresPerPanel,
      filterName: null,
      binning: binning,
    );
  }
  return exposureContext.recommendMosaicExposureSettings(
    exposuresPerPanel: exposuresPerPanel,
    binning: binning,
  );
}

const SmartNightExposureContext
_fallbackExposureContext = SmartNightExposureContext(
  camera: CameraExposureSpec(readNoiseE: 3.5, fullWellE: 18000, qePeak: 0.65),
  bortleClass: 5,
  focalLengthMm: 500,
  apertureMm: 80,
  pixelSizeMicrons: 3.76,
  availableFilterNames: ['L'],
  caveats: [
    'Equipment optics are incomplete; using a conservative Smart Night planning estimate.',
    'Configure focal length, aperture, and camera sensor values for target-specific exposure recommendations.',
  ],
);

class _ExposurePlan {
  final double seconds;
  final String? filterName;
  final String? rationale;
  final List<String> caveats;

  const _ExposurePlan({
    required this.seconds,
    this.filterName,
    this.rationale,
    this.caveats = const [],
  });
}

/// Produces a session-ready plan from the nightly suggestion engine.
class SessionOptimizerService {
  final TargetSuggestionService _suggestionService;
  final SmartNightExposureCalculator _exposureCalculator;

  const SessionOptimizerService({
    required TargetSuggestionService suggestionService,
    SmartNightExposureCalculator exposureCalculator =
        const SmartNightExposureCalculator(),
  }) : _suggestionService = suggestionService,
       _exposureCalculator = exposureCalculator;

  Future<SessionOptimizationPlan> optimizeTonight({
    required TargetSuggestionConfig config,
    required double latitude,
    required double longitude,
    required List<db.Target> targets,
    required List<db.ImagingSession> sessions,
    DateTime? observationTime,
    OpticalConfig? opticalConfig,
  }) async {
    final generatedAt = observationTime ?? DateTime.now();
    final suggestions = await _suggestionService.getSuggestionsForTonight(
      config: config,
      latitude: latitude,
      longitude: longitude,
      targets: targets,
      sessions: sessions,
      observationTime: generatedAt,
      opticalConfig: opticalConfig,
    );

    return buildPlanFromSuggestions(suggestions, generatedAt: generatedAt);
  }

  /// Builds a session-ready plan from already-computed target suggestions.
  ///
  /// This lets UI surfaces share the same suggestion pipeline, including
  /// catalog-backed targets and filters, without duplicating plan scoring.
  SessionOptimizationPlan buildPlanFromSuggestions(
    List<TargetSuggestion> suggestions, {
    DateTime? generatedAt,
    SmartNightExposureContext? exposureContext,
  }) {
    final planGeneratedAt = generatedAt ?? DateTime.now();

    if (suggestions.isEmpty) {
      return SessionOptimizationPlan(
        generatedAt: planGeneratedAt,
        primaryTarget: null,
        alternates: const [],
        recommendedExposureSeconds: 0,
        recommendedFilterName: null,
        recommendedFilterNames: const [],
        estimatedUsableHours: 0,
        rationale: const ['No viable targets matched tonight\'s constraints.'],
        riskFactors: const [
          'Check location, horizon limits, and scoring constraints.',
        ],
      );
    }

    final primary = suggestions.first;
    final alternates = suggestions.skip(1).take(3).toList(growable: false);
    final estimatedUsableHours = (primary.visibility.hoursAboveMinAlt ?? 0)
        .clamp(0.0, 24.0);

    final exposurePlan = _recommendExposure(primary, exposureContext);
    final availableFilters = exposureContext?.availableFilterNames ?? const [];
    final recommendedFilterNames = availableFilters.isEmpty
        ? const <String>[]
        : resolveSmartNightFilterSet(
            strategy: inferSmartNightStrategy(primary, availableFilters),
            availableFilters: availableFilters,
          );
    // A rig that reports no filter names at all captures unfiltered. The
    // exposure model still uses a luminance passband to size the sub, but
    // reporting that as "L" would promise a filter the built sequence never
    // selects. A missing exposure context is a different case — that falls
    // back to the planning-estimate rig, which does name a filter.
    final rigNamesFilters = (exposureContext ?? _fallbackExposureContext)
        .availableFilterNames
        .any((name) => name.trim().isNotEmpty);

    final rationale = <String>[
      primary.reasoning,
      if (exposurePlan.rationale != null) exposurePlan.rationale!,
      // dataProgress is EXACTLY 0.0 when the target has no integration at all
      // (target_suggestion_service._calculateDataProgress returns 0.1 for
      // "some data, no plan"), so the `> 0` half of the test is what keeps a
      // target with zero captured frames from being called partially captured.
      if (primary.dataProgress > 0 && primary.dataProgress < 0.25)
        'Partially captured already, so finishing it is an efficient use of '
            'tonight.',
      if (primary.tags.contains('Mosaic recommended'))
        'Optical framing suggests a mosaic-friendly target for tonight.',
      if ((primary.visibility.peakAltitude ??
              primary.visibility.currentAltitude) >=
          60)
        'Peak altitude is excellent, which reduces atmospheric penalty.',
    ];

    final riskFactors = <String>[
      for (final warning in primary.warnings.take(3)) warning.message,
      if ((primary.visibility.moonDistance) < 45)
        'Moon separation is tight; gradients or contrast loss are more likely.',
      if (estimatedUsableHours < 2.0)
        'Usable imaging window is short; prioritize quick setup and acquisition.',
      if (primary.dataProgress > 0.85)
        'Target is nearly complete; consider alternates if you want fresh integration.',
      ...exposurePlan.caveats,
    ];

    return SessionOptimizationPlan(
      generatedAt: planGeneratedAt,
      primaryTarget: primary,
      alternates: alternates,
      recommendedExposureSeconds: exposurePlan.seconds,
      recommendedFilterName: rigNamesFilters ? exposurePlan.filterName : null,
      recommendedFilterNames: recommendedFilterNames,
      estimatedUsableHours: estimatedUsableHours,
      rationale: rationale,
      riskFactors: riskFactors.toSet().toList(growable: false),
    );
  }

  _ExposurePlan _recommendExposure(
    TargetSuggestion suggestion,
    SmartNightExposureContext? context,
  ) {
    final effectiveContext = context ?? _fallbackExposureContext;

    final filter = effectiveContext.selectFilterForTarget(suggestion);
    final recommendation = effectiveContext.recommendForTarget(
      suggestion,
      calculator: _exposureCalculator,
    );

    return _ExposurePlan(
      seconds: recommendation.seconds,
      filterName: filter.name,
      rationale: recommendation.rationale,
      caveats: [...effectiveContext.caveats, ...recommendation.caveats],
    );
  }

  /// Post-session retrospective analysis.
  ///
  /// Given the immutable session report, the per-target altitude traces
  /// collected during the run, and the operator's threshold preferences,
  /// produce a list of [SessionInsight]s ranked by confidence (descending).
  ///
  /// This is **read-only**: no settings are mutated; no provider state is
  /// touched. The caller (post-session report dialog) is responsible for
  /// rendering and for routing "Apply" clicks to the right editor.
  ///
  /// The algorithm is intentionally simple — each insight class has a
  /// closed-form scoring rule that converts an observation (e.g. "filter
  /// changes ate 18% of the night") into a confidence in `[0.0, 1.0]`.
  /// The rules are documented inline; tests drive each branch with a
  /// hand-crafted [SessionReport].
  List<SessionInsight> analyze({
    required SessionReport report,
    List<SessionTargetAltitudeTrace> altitudeTraces = const [],
    SessionInsightThresholds thresholds = const SessionInsightThresholds(),
  }) {
    final out = <SessionInsight>[];

    // -- Altitude window per-target ---------------------------------------
    // For each per-target trace that spent meaningful time below the
    // recommended floor we emit an `altitudeWindow` insight with a
    // suggested tighter `start_when` value.
    for (final trace in altitudeTraces) {
      if (!trace.hadLowAltitudeCapture) continue;
      // Confidence scales with the fraction of session-wall-clock spent
      // below the floor — half an hour out of a 6-hour night = 0.083,
      // 2 hours = 0.33. We cap at 1.0 and floor at 0.2.
      final wallSecs = report.wallClockDuration.inSeconds;
      final fraction = wallSecs > 0
          ? (trace.secondsBelowMinAltitude / wallSecs)
          : 0.0;
      final confidence = (0.2 + fraction * 3.5).clamp(0.0, 1.0);
      final suggestedAlt =
          (trace.minObservedAltitudeDeg ?? trace.minRecommendedAltitudeDeg) +
          thresholds.altitudeSuggestionMarginDeg;
      final formattedDur = DurationFormat.of(
        Duration(seconds: trace.secondsBelowMinAltitude.round()),
        style: DurationStyle.compact,
      );
      final id =
          'altitude_window:${trace.targetId ?? trace.targetName.toLowerCase()}';
      out.add(
        SessionInsight(
          id: id,
          kind: SessionInsightKind.altitudeWindow,
          title:
              '${trace.targetName} was below '
              '${trace.minRecommendedAltitudeDeg.toStringAsFixed(0)}° '
              'for $formattedDur',
          body:
              'During capture, ${trace.targetName} spent $formattedDur '
              'below the ${trace.minRecommendedAltitudeDeg.toStringAsFixed(0)}° '
              'altitude floor. Frames acquired at low altitude carry more '
              'atmospheric extinction and seeing penalty.',
          recommendation:
              'Tighten this target\'s start_when crossing to '
              'AltitudeAbove(${suggestedAlt.toStringAsFixed(0)}°) so the '
              'sequencer waits until the target clears the haze.',
          confidence: confidence,
          targetId: trace.targetId,
          applyHint: {
            'altitudeAboveDeg': suggestedAlt,
            'targetName': trace.targetName,
          },
        ),
      );
    }

    // -- Autofocus frequency ----------------------------------------------
    final wallHours = report.wallClockDuration.inSeconds / 3600.0;
    if (wallHours > 0.5) {
      final afRuns = report.mountStats.autofocusRuns;
      final perHour = afRuns / wallHours;
      if (perHour >= thresholds.autofocusRunsPerHour) {
        // Confidence ramps from 0.5 at the threshold to 1.0 at 2x the
        // threshold; values above 2x cap at 1.0.
        final overshoot = (perHour / thresholds.autofocusRunsPerHour).clamp(
          1.0,
          2.0,
        );
        final confidence = (0.5 + (overshoot - 1.0) * 0.5).clamp(0.0, 1.0);
        out.add(
          SessionInsight(
            id: 'autofocus_frequency',
            kind: SessionInsightKind.autofocusFrequency,
            title:
                'Autofocus fired $afRuns times '
                '(${perHour.toStringAsFixed(1)}/hour)',
            body:
                'A high autofocus cadence eats wall-clock time and can '
                'jitter the focus position. Temperature compensation can '
                'absorb most of the drift between explicit runs.',
            recommendation:
                'Enable focuser temperature compensation in '
                'Settings → Autofocus, or relax the trigger threshold.',
            confidence: confidence,
            applyHint: {'autofocusInterval': (60 / perHour).round()},
          ),
        );
      }
    }

    // -- Filter-change overhead -------------------------------------------
    // We approximate filter-change time as the downtime that scales with
    // the number of distinct filter rows in each target. This is rough but
    // is the only signal we have without a per-filter wheel-move log.
    final wallSecs = report.wallClockDuration.inSeconds;
    if (wallSecs > 0) {
      var distinctFilterChanges = 0;
      for (final t in report.targets) {
        // Each filter that has frames was visited at least once. Subtract
        // one because the very first filter doesn't count as a "change".
        if (t.filters.length > 1) {
          distinctFilterChanges += t.filters.length - 1;
        }
      }
      if (distinctFilterChanges >= 4) {
        // Estimate 20s per filter change (typical wheel + refocus offset).
        const secondsPerChange = 20;
        final estimatedOverheadSecs = (distinctFilterChanges * secondsPerChange)
            .toDouble();
        final fraction = estimatedOverheadSecs / wallSecs;
        if (fraction >= thresholds.filterChangeOverheadFraction) {
          final confidence =
              (fraction / (thresholds.filterChangeOverheadFraction * 2.0))
                  .clamp(0.3, 1.0);
          final pct = (fraction * 100).toStringAsFixed(1);
          out.add(
            SessionInsight(
              id: 'filter_change_overhead',
              kind: SessionInsightKind.filterChangeOverhead,
              title: 'Filter changes consumed ~$pct% of the night',
              body:
                  'You changed filters about $distinctFilterChanges times. '
                  'Each change costs roughly $secondsPerChange seconds of '
                  'wheel + refocus time; that adds up over a long run.',
              recommendation:
                  'Consider longer sub-stretches per filter '
                  '(group frames by filter inside each target).',
              confidence: confidence,
            ),
          );
        }
      }
    }

    // -- Rejection rate ---------------------------------------------------
    final attempted = report.totalFramesAttempted;
    if (attempted >= 10) {
      final rejected = report.totalFramesRejected;
      final fraction = rejected / attempted;
      if (fraction >= thresholds.rejectionRateFraction) {
        final confidence = (fraction / (thresholds.rejectionRateFraction * 2.0))
            .clamp(0.3, 1.0);
        final pct = (fraction * 100).toStringAsFixed(1);
        out.add(
          SessionInsight(
            id: 'rejection_rate',
            kind: SessionInsightKind.rejectionRate,
            title: '$pct% of frames were rejected',
            body:
                '$rejected of $attempted attempted frames did not pass '
                'image grading. High rejection rates often point at seeing, '
                'guiding, or an HFR threshold that is too tight for the night.',
            recommendation:
                'Review the rejection reasons in the Targets '
                'block above, then either relax the grading threshold in '
                'Settings → Image Grading or address the upstream cause.',
            confidence: confidence,
          ),
        );
      }
    }

    // -- Guiding degraded --------------------------------------------------
    final gs = report.guideStats;
    final meanTotal = gs.meanRmsTotalArcsec;
    if (meanTotal != null && meanTotal >= thresholds.guidingDegradedArcsec) {
      final overshoot = (meanTotal / thresholds.guidingDegradedArcsec).clamp(
        1.0,
        3.0,
      );
      final confidence = (0.4 + (overshoot - 1.0) * 0.3).clamp(0.0, 1.0);
      out.add(
        SessionInsight(
          id: 'guiding_degraded',
          kind: SessionInsightKind.guidingDegraded,
          title:
              'Mean guide RMS was '
              '${meanTotal.toStringAsFixed(2)}" '
              '(threshold ${thresholds.guidingDegradedArcsec.toStringAsFixed(2)}")',
          body:
              'Guiding ran consistently above the threshold for this '
              'session. Soft stars and HFR rejections are likely correlated.',
          recommendation:
              'Re-run polar alignment, recalibrate PHD2, or '
              'shorten subs until the mount catches up.',
          confidence: confidence,
        ),
      );
    }

    // -- Effective imaging fraction (efficiency) ---------------------------
    if (report.wallClockDuration.inMinutes >= 30) {
      final eff = report.effectiveImagingFraction;
      if (eff > 0 && eff < thresholds.efficiencyLowFraction) {
        // The further below the floor, the higher the confidence.
        final shortfall = (thresholds.efficiencyLowFraction - eff).clamp(
          0.0,
          thresholds.efficiencyLowFraction,
        );
        final confidence = (0.3 + shortfall * 1.5).clamp(0.0, 1.0);
        final pct = (eff * 100).toStringAsFixed(1);
        out.add(
          SessionInsight(
            id: 'efficiency_low',
            kind: SessionInsightKind.efficiencyLow,
            title: 'Effective imaging was only $pct% of the wall clock',
            body:
                'Slew, dither, autofocus and download dominated the night. '
                'A 50% effective fraction is a reasonable target for a '
                'multi-target run; below that, examine the longest downtime '
                'events in the operations history.',
            confidence: confidence,
          ),
        );
      }
    }

    // Filter out insights below the operator's confidence floor or that
    // have been explicitly dismissed (see `SessionInsightThresholds`).
    final filtered = out
        .where(
          (i) =>
              i.confidence >= thresholds.minConfidence &&
              !thresholds.dismissedIds.contains(i.id),
        )
        .toList(growable: false);

    // Sort by confidence descending so the strongest insights surface first.
    filtered.sort((a, b) => b.confidence.compareTo(a.confidence));

    return filtered;
  }
}
