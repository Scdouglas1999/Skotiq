part of '../planetarium_providers.dart';

/// A target the "Best Targets Tonight" panel is willing to recommend, together
/// with the evidence for the recommendation.
class TonightTarget {
  final DeepSkyObject object;

  /// Rise / transit / set against the site's altitude floor.
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

/// The app's target scorer, for Best Targets Tonight. The planetarium cannot
/// reach the native sequencer the scorer runs in, so the app supplies it
/// (`skotiq_app/lib/startup/location_sync_service.dart`); until then the
/// list is not ranked.
final planetariumNightScorerProvider = StateProvider<NightScorer?>(
  (ref) => null,
);

/// Tonight's best imaging targets, ranked by [rankTonightTargets] — usable
/// hours inside the darkness window scored with the app's own night scorer.
///
/// Anchored on the night DATE rather than the current instant so the list does
/// not flicker as the clock ticks.
///
/// Null with no site on record, or before the app has supplied its scorer:
/// what is up tonight, and for how long, is a question about a place. An
/// empty list would read as "nothing is up".
final bestTargetsProvider = FutureProvider<List<TonightTarget>?>((ref) async {
  final site = ref.watch(observerLocationProvider).site;
  if (site == null) return null;
  final scorer = ref.watch(planetariumNightScorerProvider);
  if (scorer == null) return null;
  final dsos = await ref.watch(loadedDsosProvider.future);
  // The night in progress, so this list and the sidebar's Info tab (which reads
  // selectedObjectVisibilityProvider) describe the SAME night.
  final nightDate = ref.watch(_currentNightDateProvider);
  final fov = ref.watch(equipmentFOVProvider).fov;

  final ranked = await rankTonightTargets(
    raDeg: [for (final d in dsos) d.coordinates.raDegrees],
    decDeg: [for (final d in dsos) d.coordinates.dec],
    magnitudes: [for (final d in dsos) d.magnitude],
    sizesArcMin: [for (final d in dsos) d.sizeArcMin],
    objectTypes: [for (final d in dsos) d.type.index],
    fovWidthDeg: fov?.$1,
    fovHeightDeg: fov?.$2,
    latitudeDeg: site.latitude,
    longitudeDeg: site.longitude,
    nightDate: nightDate,
    floor: ref.watch(planetariumAltitudeFloorProvider),
    scorer: scorer,
  );
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
