// Riverpod surface for the planetarium's sky-survey imagery layer: the user
// toggle, the field-of-view gate, and the survey it streams.
//
// The layer itself reuses the shared HiPS pipeline in skotiq_core (fetcher,
// bounded LRU cache, debounced loader, resident-snapshot notifier — the same
// providers the framing screen drives, so there is one tile-cache implementation
// and one instance alive at a time; the providers are `autoDispose`, so leaving
// the screen releases the decoded tiles and the HTTP client rather than holding
// them for a screen that is gone). Nothing here duplicates that; this file only
// decides *whether* the layer runs.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
// Both packages declare a `SurveySource`: skotiq_core's names the HiPS /
// cutout surveys the framing stack addresses (the one meant here), while the
// planetarium's names its own single-image survey-preview sources. Hide the
// latter so the reference is unambiguous rather than prefixed at every use.
import 'package:skotiq_planetarium/skotiq_planetarium.dart' hide SurveySource;

/// Widest field of view, in degrees, at which the sky-imagery layer will fetch
/// and draw survey tiles.
///
/// The star chart is the better view above this, and tiles fetched there are
/// wasted bandwidth on a connection an observatory often does not have. Below
/// it the HYG catalogue thins out fast — ~2.9 stars per square degree, so a
/// 1.5-degree field carries around fifteen — and imagery becomes the only way
/// to show what is there. 8 degrees is also comfortably wider than any normal
/// imaging field, so a user framing a target is always inside the imagery band.
///
/// It bounds the network too: at 8 degrees on a typical canvas the LOD rule
/// selects Norder 4-5, a few dozen tiles rather than a pyramid crawl.
const double kPlanetariumSkyImageryMaxFovDegrees = 8.0;

/// The survey the planetarium streams imagery from.
///
/// DSS2 red is the one all-sky optical survey in [HipsSurveyRegistry] with a
/// live-verified direct HiPS base URL, and it is the framing screen's default,
/// so the two screens share cached tiles rather than each warming a separate
/// pyramid. Surveys whose base URL must be resolved at runtime are not
/// tile-capable through this path and are deliberately not offered — the layer
/// refuses to fabricate a URL.
const SurveySource kPlanetariumSkyImagerySurvey = SurveySource.dss2Red;

/// User toggle for the planetarium's sky-survey imagery layer.
///
/// Off by default. Imagery costs network, and the app's normal deployment is an
/// observatory laptop on an isolated LAN where every request fails, so reaching
/// for the network the first time the planetarium opens would fail for most
/// users. Session-scoped [StateProvider], exactly like the planetarium's other
/// layer toggles (FOV rings, deep stars, night vision).
final planetariumSkyImageryEnabledProvider =
    StateProvider<bool>((ref) => false);

/// Whether the imagery layer should be *mounted*: the user turned it on and the
/// survey has a verified HiPS pyramid.
///
/// Deliberately NOT gated on the field of view. The layer holds the shared
/// `autoDispose` loader alive, so folding it away on every zoom-out would drop
/// the tile cache and re-download the same pyramid the moment the user zoomed
/// back in — which is exactly what someone does when they pull back to navigate
/// and then return to their target. Mounted-but-idle costs nothing: with
/// [planetariumSkyImageryWithinFovProvider] false the layer requests no tiles
/// and paints nothing.
final planetariumSkyImageryActiveProvider = Provider<bool>((ref) {
  if (!ref.watch(planetariumSkyImageryEnabledProvider)) return false;
  return hipsSurveyIsTileCapable(kPlanetariumSkyImagerySurvey);
});

/// Whether the view is zoomed in far enough for imagery to be worth fetching.
///
/// This is the gate that actually stops the network traffic: above
/// [kPlanetariumSkyImageryMaxFovDegrees] the star chart is the better view, so
/// the layer requests nothing and draws nothing. Separated from
/// [planetariumSkyImageryActiveProvider] so crossing the threshold does not tear
/// down the tile cache.
final planetariumSkyImageryWithinFovProvider = Provider<bool>((ref) {
  final fov = ref.watch(
    skyViewStateProvider.select((state) => state.fieldOfView),
  );
  return fov.isFinite && fov <= kPlanetariumSkyImageryMaxFovDegrees;
});

/// Whether imagery is on screen *right now* — the signal the sky view uses to
/// decide whether to stop painting its opaque background gradient.
///
/// It reports "the layer has imagery", not "the layer is mounted": while the
/// pyramid is loading — or forever, offline — this stays false, the sky view
/// keeps its own background, and the user sees the ordinary star chart.
///
/// Short-circuits before touching [hipsResidentTilesProvider] when the layer is
/// inactive, so a session with the layer off never instantiates the loader, its
/// HTTP client or its tile cache.
final planetariumSkyImageryVisibleProvider = Provider<bool>((ref) {
  if (!ref.watch(planetariumSkyImageryActiveProvider)) return false;
  if (!ref.watch(planetariumSkyImageryWithinFovProvider)) return false;
  return ref.watch(
    hipsResidentTilesProvider.select((snapshot) => snapshot.hasAnyImagery),
  );
});
