part of '../smart_night_models.dart';

// Public strategy / filter / exposure-plan helpers
//
// These functions operate purely on the model types above (settings, plans,
// strategies, target suggestions, equipment profiles). They are colocated
// with the models because [SmartNightService] and other call sites (Plan
// Tonight integration goals, tests) consume them as a public API surface —
// keeping them with their domain types avoids a circular service ↔ models
// import.

/// Filter-plan name used by a rig with no filter wheel.
///
/// The empty name is the wire contract for "capture the frame as it comes":
/// the emitted `ExposureNode` leaves `filter` null, so no filter-change
/// instruction is produced and the executor renders the `${filter}` filename
/// token as `nofilter` — the same path manual capture takes on a wheel-less
/// rig.
const String smartNightUnfilteredName = '';

/// The filter list Smart Night plans against for a rig.
///
/// A rig that reports no named filters plans one unfiltered row rather than
/// refusing to plan — OSC / one-shot-colour imagers have no wheel at all.
List<String> smartNightPlanningFilters(List<String> availableFilters) {
  final named = availableFilters
      .map((f) => f.trim())
      .where((f) => f.isNotEmpty)
      .toList(growable: false);
  return named.isEmpty ? const [smartNightUnfilteredName] : named;
}

/// Human-readable label for a filter name that may be the unfiltered
/// sentinel. Used in plan prose and node titles.
String smartNightFilterLabel(String filterName) =>
    filterName.trim().isEmpty ? 'no filter' : filterName;

/// Share of the window each filter of [strategy] gets, by filter identity
/// (`filterIdentity`); a filter not listed gets 1. LRGB gives luminance
/// twice a color's time; LRGB + Ha gives Ha a color's share, as it is
/// blended into the red and luminance like one more color.
Map<String, double> _smartNightFilterRatios(SmartNightStrategy strategy) =>
    switch (strategy) {
      SmartNightStrategy.autoLrgb ||
      SmartNightStrategy.haLrgb => const {'L': 2.0},
      SmartNightStrategy.monoLrgb ||
      SmartNightStrategy.narrowbandHa ||
      SmartNightStrategy.narrowbandHoo ||
      SmartNightStrategy.narrowbandSho ||
      SmartNightStrategy.oscOneShot => const {},
    };

/// Compose per-filter (count, durationSecs) using the exposure calculator,
/// strategy ratios, and integration window budget.
///
/// When [integrationGoalProgress] contains goals with remaining frames, those
/// rows take precedence for matching filters. Other strategy filters without
/// goals (or with zero remaining) are filled from the leftover window budget.
List<SmartNightFilterPlan> composeSmartNightFilterPlans({
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
  SmartNightExposureCalculator exposureCalculator =
      const SmartNightExposureCalculator(),
}) {
  final availableForGoals = availableFiltersForGoals ?? activeFilters;
  final goalPlans = _composeFilterPlansFromIntegrationGoals(
    availableFilters: availableForGoals,
    integrationGoalProgress: integrationGoalProgress,
    cameraSpec: cameraSpec,
    focalLengthMm: focalLengthMm,
    apertureMm: apertureMm,
    pixelSizeUm: pixelSizeUm,
    bortleClass: bortleClass,
    recentGuideRmsArcsec: recentGuideRmsArcsec,
    recentGuideSamples: recentGuideSamples,
    settings: settings,
    exposureCalculator: exposureCalculator,
  );

  if (goalPlans != null &&
      goalPlans.isNotEmpty &&
      _allStrategyFiltersHaveRemainingGoals(
        activeFilters: activeFilters,
        integrationGoalProgress: integrationGoalProgress,
        availableFilters: availableForGoals,
      )) {
    return goalPlans;
  }

  if (goalPlans != null && goalPlans.isNotEmpty) {
    final goalIntegrationSecs = goalPlans.fold<double>(
      0,
      (sum, plan) => sum + plan.integrationSecs,
    );
    final remainingWindowSecs = math
        .max(0.0, windowSecs - goalIntegrationSecs)
        .toDouble();
    final goalNames = goalPlans.map((p) => p.filterName.toLowerCase()).toSet();
    final budgetFilters = activeFilters
        .where((f) => !goalNames.contains(f.toLowerCase()))
        .toList();

    final budgetPlans = budgetFilters.isEmpty || remainingWindowSecs <= 0
        ? const <SmartNightFilterPlan>[]
        : _composeBudgetFilterPlans(
            strategy: strategy,
            activeFilters: budgetFilters,
            windowSecs: remainingWindowSecs,
            cameraSpec: cameraSpec,
            focalLengthMm: focalLengthMm,
            apertureMm: apertureMm,
            pixelSizeUm: pixelSizeUm,
            bortleClass: bortleClass,
            recentGuideRmsArcsec: recentGuideRmsArcsec,
            recentGuideSamples: recentGuideSamples,
            settings: settings,
            exposureCalculator: exposureCalculator,
          );

    return _mergeFilterPlansInStrategyOrder(
      activeFilters: activeFilters,
      goalPlans: goalPlans,
      budgetPlans: budgetPlans,
    );
  }

  return _composeBudgetFilterPlans(
    strategy: strategy,
    activeFilters: activeFilters,
    windowSecs: windowSecs,
    cameraSpec: cameraSpec,
    focalLengthMm: focalLengthMm,
    apertureMm: apertureMm,
    pixelSizeUm: pixelSizeUm,
    bortleClass: bortleClass,
    recentGuideRmsArcsec: recentGuideRmsArcsec,
    recentGuideSamples: recentGuideSamples,
    settings: settings,
    exposureCalculator: exposureCalculator,
  );
}

// Private helpers — used exclusively by the model classes / public helpers
// above. Kept in this file so model JSON serde + filter-plan composition
// stay self-contained.

bool _allStrategyFiltersHaveRemainingGoals({
  required List<String> activeFilters,
  required List<IntegrationGoalProgress>? integrationGoalProgress,
  required List<String> availableFilters,
}) {
  if (activeFilters.isEmpty) return false;
  if (integrationGoalProgress == null || integrationGoalProgress.isEmpty) {
    return false;
  }

  for (final filter in activeFilters) {
    final hasRemaining = integrationGoalProgress.any((progress) {
      if (progress.remainingFrames <= 0) return false;
      return matchingFilterName(progress.goal.filter, availableFilters) ==
          filter;
    });
    if (!hasRemaining) return false;
  }
  return true;
}

List<SmartNightFilterPlan> _mergeFilterPlansInStrategyOrder({
  required List<String> activeFilters,
  required List<SmartNightFilterPlan> goalPlans,
  required List<SmartNightFilterPlan> budgetPlans,
}) {
  final byName = {
    for (final plan in [...goalPlans, ...budgetPlans])
      plan.filterName.toLowerCase(): plan,
  };
  return [
    for (final filter in activeFilters)
      if (byName.containsKey(filter.toLowerCase()))
        byName[filter.toLowerCase()]!,
  ];
}

List<SmartNightFilterPlan> _composeBudgetFilterPlans({
  required SmartNightStrategy strategy,
  required List<String> activeFilters,
  required double windowSecs,
  required CameraExposureSpec cameraSpec,
  required double focalLengthMm,
  required double apertureMm,
  required double pixelSizeUm,
  required int bortleClass,
  required double? recentGuideRmsArcsec,
  required int recentGuideSamples,
  required SmartNightSettings settings,
  required SmartNightExposureCalculator exposureCalculator,
}) {
  if (activeFilters.isEmpty) return const [];

  final ratios = _smartNightFilterRatios(strategy);
  final sumRatios = activeFilters.fold<double>(
    0,
    (sum, f) => sum + (ratios[filterIdentity(f)] ?? 1.0),
  );
  final perFilterBudget = sumRatios <= 0
      ? <String, double>{}
      : {
          for (final f in activeFilters)
            f: windowSecs * (ratios[filterIdentity(f)] ?? 1.0) / sumRatios,
        };

  final out = <SmartNightFilterPlan>[];
  for (final filterName in activeFilters) {
    final recommendation = exposureCalculator.recommend(
      ExposureCalculatorInput(
        camera: cameraSpec,
        filter: FilterExposureSpec.fromName(filterName),
        bortleClass: bortleClass,
        focalLengthMm: focalLengthMm,
        apertureMm: apertureMm,
        pixelSizeMicrons: pixelSizeUm,
        guideRmsArcsec: recentGuideRmsArcsec,
        guideSampleCount: recentGuideSamples,
        gloverKFactor: 10,
        targetSnr: settings.targetSnr,
        userCapSeconds: settings.subExposureCeilingSecs,
        floorSeconds: settings.subExposureFloorSecs,
      ),
    );
    final preset =
        settings.defaultFrameDurationSecs[filterName] ??
        settings.defaultFrameDurationSecs[FilterExposureSpec.fromName(
          filterName,
        ).name] ??
        180.0;
    final pickedSecs = settings.useExposurePresets
        ? preset
        : (recommendation.seconds > 0 ? recommendation.seconds : preset);
    final budgetSecs = perFilterBudget[filterName] ?? 0;
    final count = budgetSecs <= 0
        ? 1
        : math.max(1, (budgetSecs / pickedSecs).floor());
    out.add(
      SmartNightFilterPlan(
        filterName: filterName,
        count: count,
        durationSecs: pickedSecs,
        recommendation: recommendation,
      ),
    );
  }
  return out;
}

List<SmartNightFilterPlan>? _composeFilterPlansFromIntegrationGoals({
  required List<String> availableFilters,
  required List<IntegrationGoalProgress>? integrationGoalProgress,
  required CameraExposureSpec cameraSpec,
  required double focalLengthMm,
  required double apertureMm,
  required double pixelSizeUm,
  required int bortleClass,
  required double? recentGuideRmsArcsec,
  required int recentGuideSamples,
  required SmartNightSettings settings,
  required SmartNightExposureCalculator exposureCalculator,
}) {
  if (integrationGoalProgress == null || integrationGoalProgress.isEmpty) {
    return null;
  }

  final out = <SmartNightFilterPlan>[];

  for (final progress in integrationGoalProgress) {
    if (progress.remainingFrames <= 0) continue;
    final matched = matchingFilterName(progress.goal.filter, availableFilters);
    if (matched == null) continue;

    final goalSecs = progress.goal.exposureSeconds;
    ExposureRecommendation? recommendation;
    var durationSecs = goalSecs;
    if (goalSecs <= 0) {
      recommendation = exposureCalculator.recommend(
        ExposureCalculatorInput(
          camera: cameraSpec,
          filter: FilterExposureSpec.fromName(matched),
          bortleClass: bortleClass,
          focalLengthMm: focalLengthMm,
          apertureMm: apertureMm,
          pixelSizeMicrons: pixelSizeUm,
          guideRmsArcsec: recentGuideRmsArcsec,
          guideSampleCount: recentGuideSamples,
          gloverKFactor: 10,
          targetSnr: settings.targetSnr,
          userCapSeconds: settings.subExposureCeilingSecs,
          floorSeconds: settings.subExposureFloorSecs,
        ),
      );
      durationSecs = recommendation.seconds > 0
          ? recommendation.seconds
          : settings.defaultFrameDurationSecs[matched.toUpperCase()] ??
                settings.defaultFrameDurationSecs[matched] ??
                180.0;
    }

    out.add(
      SmartNightFilterPlan(
        filterName: matched,
        count: progress.remainingFrames,
        durationSecs: durationSecs,
        recommendation: recommendation,
      ),
    );
  }

  return out.isEmpty ? null : out;
}

// JSON serde helpers — used exclusively by the model classes above.
