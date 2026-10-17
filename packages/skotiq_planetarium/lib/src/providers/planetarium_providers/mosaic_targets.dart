part of '../planetarium_providers.dart';

// Mosaic plan provider

/// Current mosaic plan state
class MosaicPlanState {
  final MosaicPlan? plan;
  final PlanetariumMosaicConfig? config;
  final bool isEditing;

  const MosaicPlanState({this.plan, this.config, this.isEditing = false});

  MosaicPlanState copyWith({
    MosaicPlan? plan,
    PlanetariumMosaicConfig? config,
    bool? isEditing,
  }) {
    return MosaicPlanState(
      plan: plan ?? this.plan,
      config: config ?? this.config,
      isEditing: isEditing ?? this.isEditing,
    );
  }
}

class MosaicPlanNotifier extends StateNotifier<MosaicPlanState> {
  final Ref _ref;

  MosaicPlanNotifier(this._ref) : super(const MosaicPlanState());

  void createMosaic({
    required CelestialCoordinate center,
    required double totalWidth,
    required double totalHeight,
  }) {
    final equipment = _ref.read(equipmentFOVProvider);
    final fov = equipment.fov;

    if (fov == null) return;

    final config = PlanetariumMosaicConfig(
      center: center,
      totalWidth: totalWidth,
      totalHeight: totalHeight,
      panelFovWidth: fov.$1,
      panelFovHeight: fov.$2,
      rotation: equipment.rotation,
    );

    final plan = MosaicPlanner.generateMosaic(config);

    state = MosaicPlanState(plan: plan, config: config, isEditing: true);
  }

  void createRectangularMosaic({
    required CelestialCoordinate center,
    required int rows,
    required int columns,
  }) {
    final equipment = _ref.read(equipmentFOVProvider);
    final fov = equipment.fov;

    if (fov == null) return;

    final plan = MosaicPlanner.generateRectangularMosaic(
      center: center,
      rows: rows,
      columns: columns,
      panelFovWidth: fov.$1,
      panelFovHeight: fov.$2,
      rotation: equipment.rotation,
    );

    state = MosaicPlanState(plan: plan, config: plan.config, isEditing: true);
  }

  void updateOverlap(double horizontal, double vertical) {
    if (state.config == null) return;

    final newConfig = state.config!.copyWith(
      overlap: MosaicOverlap(horizontal: horizontal, vertical: vertical),
    );

    final plan = MosaicPlanner.generateMosaic(newConfig);

    state = state.copyWith(plan: plan, config: newConfig);
  }

  void updateRotation(double rotation) {
    if (state.config == null) return;

    final newConfig = state.config!.copyWith(rotation: rotation);
    final plan = MosaicPlanner.generateMosaic(newConfig);

    state = state.copyWith(plan: plan, config: newConfig);
  }

  void optimizeCaptureOrder({bool snakePattern = true}) {
    state.plan?.optimizeCaptureOrder(snakePattern: snakePattern);
    state = state.copyWith(plan: state.plan);
  }

  void clearMosaic() {
    state = const MosaicPlanState();
  }

  String exportToJson() {
    if (state.plan == null) return '{}';
    return MosaicExporter.toJson(state.plan!);
  }

  String exportToCsv() {
    if (state.plan == null) return '';
    return MosaicExporter.toCsv(state.plan!);
  }
}

final mosaicPlanProvider =
    StateNotifierProvider<MosaicPlanNotifier, MosaicPlanState>((ref) {
      return MosaicPlanNotifier(ref);
    });

// Best targets provider

/// A target the "Best Targets Tonight" panel is willing to recommend, together
/// with the evidence for the recommendation.
class TonightTarget {
  final DeepSkyObject object;

  /// Rise / transit / set against the [kTonightMinAltitudeDeg] floor.
  final ObjectVisibility visibility;

  /// Hours above that floor INSIDE tonight's darkness window.
  final double hoursInDarkness;

  /// Highest altitude reached while it is dark, degrees, and when.
  final double peakAltitudeDeg;
  final DateTime? peakTime;

  /// The ranking key, 0-100 — see [TonightRanking.score]. It blends the app's
  /// night score with a catalog-fit term, so it is NOT the planner's score.
  final double score;

  const TonightTarget({
    required this.object,
    required this.visibility,
    required this.hoursInDarkness,
    required this.peakAltitudeDeg,
    required this.peakTime,
    required this.score,
  });
}

/// Tonight's best imaging targets, ranked by [rankTonightTargets] — usable
/// hours inside the darkness window scored with the app's own night scorer.
///
/// Anchored on the night DATE rather than the current instant so the list does
/// not flicker as the clock ticks.
///
/// Null with no site on record: what is up tonight, and for how long, is a
/// question about a place. An empty list would read as "nothing is up".
final bestTargetsProvider = FutureProvider<List<TonightTarget>?>((ref) async {
  final site = ref.watch(observerLocationProvider).site;
  if (site == null) return null;
  final dsos = await ref.watch(loadedDsosProvider.future);
  // The night in progress, so this list and the sidebar's Info tab (which reads
  // selectedObjectVisibilityProvider) describe the SAME night.
  final nightDate = ref.watch(_currentNightDateProvider);

  // Ranking the full ~12k-DSO catalog against the whole darkness window is
  // heavy; run it in an isolate so the first read (e.g. the first time the side
  // panel opens) doesn't block/freeze the UI thread. Only the coordinate arrays
  // are sent across (cheap) — not the DSO objects. Twilight and the moon are
  // derived inside the isolate from the site + night date, so this provider
  // does NOT depend on any per-minute provider that would re-run it.
  final args = _BestTargetsArgs(
    raDeg: [for (final d in dsos) d.coordinates.raDegrees],
    decDeg: [for (final d in dsos) d.coordinates.dec],
    magnitudes: [for (final d in dsos) d.magnitude],
    sizesArcMin: [for (final d in dsos) d.sizeArcMin],
    objectTypes: [for (final d in dsos) d.type.index],
    fov: ref.watch(equipmentFOVProvider).fov,
    latitudeDeg: site.latitude,
    longitudeDeg: site.longitude,
    nightDate: nightDate,
  );
  final ranked = await compute(_rankTonightTargetsOffThread, args);
  return [
    for (final r in ranked)
      TonightTarget(
        object: dsos[r.index],
        visibility: r.visibility,
        hoursInDarkness: r.hoursInDarkness,
        peakAltitudeDeg: r.peakAltitudeDeg,
        peakTime: r.peakTime,
        score: r.score,
      ),
  ];
});

/// Inputs for the off-thread best-targets computation. Only primitives + plain
/// coordinate lists so the payload is cheap to send to the isolate.
class _BestTargetsArgs {
  final List<double> raDeg;
  final List<double> decDeg;
  final List<double?> magnitudes;
  final List<double?> sizesArcMin;
  final List<int?> objectTypes;
  final (double width, double height)? fov;
  final double latitudeDeg;
  final double longitudeDeg;

  /// The DATE of the night being planned, not an instant within it.
  ///
  /// [AstronomyCalculations.calculateObjectVisibility] scans local noon of this
  /// date to the following noon. Passing astronomical dusk here instead put the
  /// whole list a night late at every site where dusk falls after local
  /// midnight (mid-summer, or the west edge of a timezone), so every transit
  /// time was one sidereal day (~4 min) off and the sidebar's own Info tab
  /// disagreed with its Best Targets card for the same object.
  final DateTime nightDate;

  const _BestTargetsArgs({
    required this.raDeg,
    required this.decDeg,
    required this.magnitudes,
    required this.sizesArcMin,
    required this.objectTypes,
    required this.fov,
    required this.latitudeDeg,
    required this.longitudeDeg,
    required this.nightDate,
  });
}

/// Isolate entry point for [rankTonightTargets].
List<TonightRanking> _rankTonightTargetsOffThread(_BestTargetsArgs a) {
  return rankTonightTargets(
    raDeg: a.raDeg,
    decDeg: a.decDeg,
    magnitudes: a.magnitudes,
    sizesArcMin: a.sizesArcMin,
    objectTypes: a.objectTypes,
    fovWidthDeg: a.fov?.$1,
    fovHeightDeg: a.fov?.$2,
    latitudeDeg: a.latitudeDeg,
    longitudeDeg: a.longitudeDeg,
    nightDate: a.nightDate,
  );
}
