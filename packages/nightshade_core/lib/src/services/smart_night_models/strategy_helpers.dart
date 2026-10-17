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

/// Map a Smart Night strategy to the actual filter slots present on a rig.
///
/// This is intentionally public because the sequence builder and pre-build
/// integrations, such as dark-library coverage, must agree on the exact
/// filter set before the plan is emitted.
List<String> resolveSmartNightFilterSet({
  required SmartNightStrategy strategy,
  required List<String> availableFilters,
}) {
  final lookup = {for (final f in availableFilters) f.toLowerCase(): f};
  String? present(String wanted) => lookup[wanted.toLowerCase()];

  switch (strategy) {
    case SmartNightStrategy.autoLrgb:
    case SmartNightStrategy.monoLrgb:
      final out = <String>[];
      final l = present('L') ?? present('Lum') ?? present('Luminance');
      final r = present('R') ?? present('Red');
      final g = present('G') ?? present('Green');
      final b = present('B') ?? present('Blue');
      if (l != null) out.add(l);
      if (r != null) out.add(r);
      if (g != null) out.add(g);
      if (b != null) out.add(b);
      return out;
    case SmartNightStrategy.narrowbandHoo:
      final out = <String>[];
      final ha = present('Ha') ?? present('H-alpha') ?? present('Halpha');
      final oiii = present('OIII') ?? present('O3');
      if (ha != null) out.add(ha);
      if (oiii != null) out.add(oiii);
      return out;
    case SmartNightStrategy.narrowbandSho:
      final out = <String>[];
      final ha = present('Ha') ?? present('H-alpha') ?? present('Halpha');
      final oiii = present('OIII') ?? present('O3');
      final sii = present('SII') ?? present('S2');
      if (ha != null) out.add(ha);
      if (oiii != null) out.add(oiii);
      if (sii != null) out.add(sii);
      return out;
    case SmartNightStrategy.oscOneShot:
      final preferred =
          present('L-eXtreme') ??
          present('L-uLtimate') ??
          present('L-Pro') ??
          present('L') ??
          present('UV/IR') ??
          present('UVIR') ??
          present('Light');
      if (preferred != null) return [preferred];
      if (availableFilters.isNotEmpty) return [availableFilters.first];
      return const [smartNightUnfilteredName];
  }
}

/// Strategy-specific ratio weighting. Keys are lowercased filter names; values
/// are weight units normalised against the integration window in
/// [composeSmartNightFilterPlans].
Map<String, double> smartNightFilterRatios(SmartNightStrategy strategy) {
  switch (strategy) {
    case SmartNightStrategy.autoLrgb:
      return const {
        'l': 2.0,
        'lum': 2.0,
        'luminance': 2.0,
        'r': 1.0,
        'g': 1.0,
        'b': 1.0,
      };
    case SmartNightStrategy.monoLrgb:
      return const {
        'l': 1.0,
        'lum': 1.0,
        'luminance': 1.0,
        'r': 1.0,
        'g': 1.0,
        'b': 1.0,
      };
    case SmartNightStrategy.narrowbandHoo:
      return const {
        'ha': 1.0,
        'h-alpha': 1.0,
        'halpha': 1.0,
        'oiii': 1.0,
        'o3': 1.0,
      };
    case SmartNightStrategy.narrowbandSho:
      return const {
        'ha': 1.0,
        'h-alpha': 1.0,
        'halpha': 1.0,
        'oiii': 1.0,
        'o3': 1.0,
        'sii': 1.0,
        's2': 1.0,
      };
    case SmartNightStrategy.oscOneShot:
      return const {
        'osc': 1.0,
        'l': 1.0,
        'lum': 1.0,
        'uv/ir': 1.0,
        'uvir': 1.0,
        'light': 1.0,
      };
  }
}

/// True for emission / HII targets that benefit from narrowband rotation.
bool isEmissionNebulaTarget(TargetSuggestion suggestion) {
  final type = suggestion.objectType?.toLowerCase().trim() ?? '';
  if (type.isEmpty) return false;
  return type.contains('emission') ||
      type.contains('hii') ||
      type.contains('h ii') ||
      type == 'emission nebula';
}

/// Infer the Smart Night filter strategy from target type and wheel/profile
/// filters. Broadband galaxies pick LRGB when available; emission nebulae
/// prefer SHO or HOO; single-filter / OSC rigs fall back to one-shot.
SmartNightStrategy inferSmartNightStrategy(
  TargetSuggestion suggestion,
  List<String> availableFilters,
) {
  if (availableFilters.isEmpty) return SmartNightStrategy.oscOneShot;

  final lookup = {for (final f in availableFilters) f.toLowerCase(): f};
  final hasHa = _filterAliasPresent(lookup, ['Ha', 'H-alpha', 'Halpha']);
  final hasOiii = _filterAliasPresent(lookup, ['OIII', 'O3']);
  final hasSii = _filterAliasPresent(lookup, ['SII', 'S2']);

  final lrgbFilters = resolveSmartNightFilterSet(
    strategy: SmartNightStrategy.autoLrgb,
    availableFilters: availableFilters,
  );

  if (isEmissionNebulaTarget(suggestion)) {
    if (hasHa && hasOiii && hasSii) return SmartNightStrategy.narrowbandSho;
    if (hasHa && hasOiii) return SmartNightStrategy.narrowbandHoo;
  }

  // Galaxies, planetary/reflection nebulae, and SNRs prefer broadband LRGB.
  if (lrgbFilters.length >= 4) return SmartNightStrategy.autoLrgb;
  if (lrgbFilters.isNotEmpty) return SmartNightStrategy.autoLrgb;

  if (hasHa && hasOiii && hasSii) return SmartNightStrategy.narrowbandSho;
  if (hasHa && hasOiii) return SmartNightStrategy.narrowbandHoo;

  return SmartNightStrategy.oscOneShot;
}

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

bool _filterAliasPresent(Map<String, String> lookup, Iterable<String> aliases) {
  for (final alias in aliases) {
    if (lookup.containsKey(alias.toLowerCase())) return true;
  }
  return false;
}

bool _allStrategyFiltersHaveRemainingGoals({
  required List<String> activeFilters,
  required List<IntegrationGoalProgress>? integrationGoalProgress,
  required List<String> availableFilters,
}) {
  if (activeFilters.isEmpty) return false;
  if (integrationGoalProgress == null || integrationGoalProgress.isEmpty) {
    return false;
  }

  final lookup = {for (final f in availableFilters) f.toLowerCase(): f};
  for (final filter in activeFilters) {
    final key = filter.toLowerCase();
    final hasRemaining = integrationGoalProgress.any((progress) {
      if (progress.remainingFrames <= 0) return false;
      final matched = lookup[progress.goal.filter.toLowerCase()];
      return matched != null && matched.toLowerCase() == key;
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

  final ratios = smartNightFilterRatios(strategy);
  final sumRatios = activeFilters.fold<double>(
    0,
    (sum, f) => sum + (ratios[f.toLowerCase()] ?? 1.0),
  );
  final perFilterBudget = sumRatios <= 0
      ? <String, double>{}
      : {
          for (final f in activeFilters)
            f: windowSecs * (ratios[f.toLowerCase()] ?? 1.0) / sumRatios,
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

  final lookup = {for (final f in availableFilters) f.toLowerCase(): f};
  final out = <SmartNightFilterPlan>[];

  for (final progress in integrationGoalProgress) {
    if (progress.remainingFrames <= 0) continue;
    final matched = lookup[progress.goal.filter.toLowerCase()];
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
