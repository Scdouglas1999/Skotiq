// Component C7 — Riverpod wiring for the Flutter-side GPU HiPS framing tile
// layer.
//
// This file is the *dependency-injection seam* between the framing screen's
// render path and the pure HiPS pipeline assembled in components C4–C6:
//
//   * C5 [HipsTileFetcher] — the HTTP + off-UI-thread decode edge.
//   * C4 [HipsTileCache]    — the bounded LRU of decoded [ui.Image] tiles.
//   * C6 [HipsTileLoader]   — the debounce/dedup/cancel orchestrator that turns
//                             a stream of fast-changing framing viewports into a
//                             small, ordered, non-thrashing set of resident
//                             tiles and exposes a versioned [HipsResidentSnapshot]
//                             the painter composites.
//
// It exposes exactly the provider surface the framing tile widget watches, and
// nothing more. Every provider is overridable so widget/golden tests inject a
// `MockClient`-backed fetcher (and therefore never touch the network), exactly
// the way `framingImageCacheServiceProvider` is overridden today.
//
// ## Platform independence (hard requirement)
//
// None of this touches the planetarium renderer. The HiPS tiles are a
// Flutter-side, GPU-composited layer inside the framing render path
// (`framing_canvas` + the survey-image painter family), so HiPS framing works
// independently of the planetarium screen — the framing background is its own
// render path.
//
// ## Ownership and lifetime
//
// The cache and fetcher are *owned by the loader*: [HipsTileLoader.dispose]
// disposes the cache (and the fetcher, because the loader is constructed with
// `ownsFetcher: true`). To avoid a double-dispose, [hipsTileCacheProvider] and
// [hipsTileFetcherProvider] create their instances but do **not** register their
// own `onDispose` — they hand the single owned reference to the loader, and the
// autoDispose loader provider disposes the loader (and through it the cache +
// fetcher) when the last listener goes away. Tests that override the cache or
// fetcher therefore still get correct single-ownership disposal through the
// loader.
//
// ## Tile failures
//
// The loader surfaces every genuine (non-cancellation) tile failure to its
// injected [HipsTileLoaderErrorSink] (defaulting to `dart:developer` logging)
// *and* records it in [HipsResidentSnapshot.failures], so a missing tile is
// distinguishable from an empty one. Cancellations — the expected outcome of a
// superseded pan/zoom generation — are dropped quietly.

import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/framing_plate_scale.dart';
import '../models/hips/hips_properties.dart';
import '../models/hips/hips_survey_registry.dart';
import '../services/hips/hips_tile_cache.dart';
import '../services/hips/hips_tile_fetcher.dart';
import '../services/hips/hips_tile_loader.dart';
import 'framing_provider.dart' show FramingTarget, SurveySource;

// Tunable residency budget

/// Default bounds for the framing tile [HipsTileCache].
///
/// A framing view at a typical preview FOV resolves to a few dozen visible
/// tiles at the selected Norder plus their coarser parents and an Allsky base.
/// 256 entries / 256 MiB comfortably holds a deep-zoom view plus the coarse
/// LOD ancestors that keep panning seam-free, while bounding native GPU memory
/// so the engine's own raster cache is not starved.
const int kHipsFramingCacheMaxEntries = 256;

/// Default decoded-byte budget for the framing tile cache (256 MiB).
///
/// A 512x512 RGBA tile costs ~1 MiB resident; 256 MiB therefore admits a few
/// hundred resident tiles before the entry cap binds, which is the right order
/// for a multi-order pyramid view with coarse fallbacks held under the sharp
/// layer.
const int kHipsFramingCacheMaxBytes = 256 * 1024 * 1024;

// C5 — fetcher provider

/// Canonical DI handle for the HiPS [HipsTileFetcher] (component C5).
///
/// Production resolves a real fetcher (its own [http.Client] + the default
/// timeout / size cap). Tests override it with a `MockClient`-backed fetcher so
/// no real network request is made.
///
/// The instance is **handed to the loader, which owns its disposal** (see the
/// file header): this provider intentionally does not `ref.onDispose` the
/// fetcher, so the fetcher's HTTP client is closed exactly once, by
/// [HipsTileLoader.dispose]. It is `autoDispose` so a fresh fetcher is built for
/// each framing-tile session and torn down (through the loader) when the screen
/// is left.
final hipsTileFetcherProvider = Provider.autoDispose<HipsTileFetcher>(
  (ref) => HipsTileFetcher(),
);

// C4 — cache provider

/// Canonical DI handle for the bounded LRU [HipsTileCache] (component C4).
///
/// Bounded by [kHipsFramingCacheMaxEntries] and [kHipsFramingCacheMaxBytes] in
/// production; tests may override with a tighter cache to exercise eviction.
///
/// Like [hipsTileFetcherProvider], the cache is **owned by the loader**: it is
/// disposed exactly once by [HipsTileLoader.dispose]. This provider therefore
/// does not register its own `onDispose`; doing so would double-dispose the
/// cache (and its [ui.Image] handles).
final hipsTileCacheProvider = Provider.autoDispose<HipsTileCache>(
  (ref) => HipsTileCache(
    maxEntries: kHipsFramingCacheMaxEntries,
    maxBytes: kHipsFramingCacheMaxBytes,
  ),
);

// C6 — debounce clock provider (test seam)

/// The [HipsLoaderClock] the loader debounces its recomputes on.
///
/// Production resolves the real `dart:async` [Timer]-backed clock (the loader's
/// own default). Tests override this with a manually-advanced clock so a widget
/// test can drive the debounce deterministically and, critically, never leak a
/// pending real [Timer] past the widget tree's disposal (which trips
/// flutter_test's pending-timer assertion). It is `autoDispose` so it shares the
/// loader's lifetime.
///
/// ```dart
/// hipsLoaderClockProvider.overrideWithValue(ManualLoaderClock())
/// ```
final hipsLoaderClockProvider = Provider.autoDispose<HipsLoaderClock>(
  (ref) => const HipsRealLoaderClock(),
);

// C6 — loader provider

/// Canonical DI handle for the HiPS tile orchestrator (component C6).
///
/// Builds a [HipsTileLoader] from the C4 cache and C5 fetcher and registers an
/// `onDispose` that disposes the loader — which in turn disposes the cache and
/// the fetcher (single ownership; see the file header). `autoDispose` so the
/// whole pipeline is torn down when the framing tile layer is no longer
/// watched, releasing decoded tiles and the HTTP client promptly.
///
/// The loader is the [ChangeNotifier] the resident-tiles notifier listens to;
/// it is not watched directly by widgets (they watch
/// [hipsResidentTilesProvider]). Tests override the fetcher/cache via their
/// providers and read the loader here to drive it deterministically.
final hipsTileLoaderProvider = Provider.autoDispose<HipsTileLoader>((ref) {
  final cache = ref.watch(hipsTileCacheProvider);
  final fetcher = ref.watch(hipsTileFetcherProvider);
  final clock = ref.watch(hipsLoaderClockProvider);

  final loader = HipsTileLoader(
    cache: cache,
    fetcher: fetcher,
    // The debounce clock is injected via its provider so widget/golden tests can
    // drive the debounce deterministically (and never leak a real pending Timer
    // past tree disposal). Production resolves the real Timer-backed clock.
    clock: clock,
    // The loader owns both: its dispose() disposes the cache and the fetcher.
    ownsFetcher: true,
  );

  ref.onDispose(loader.dispose);
  return loader;
});

// Shared survey `properties` resolution

/// The single source of truth for a survey's HiPS `properties` document.
///
/// A HiPS view needs the survey `properties` (order range + tile width +
/// preferred format + attribution credit) for two consumers:
///   * the tile layer / loader — to drive LOD selection and tile addressing, and
///   * the attribution badge — to render the survey's `obs_copyright` credit.
///
/// Fetched ONCE per survey through the shared [hipsTileFetcherProvider]. Keyed
/// by [SurveySource] and `autoDispose`: a survey switch resolves the new survey
/// once, pan/zoom do not change the family key so they never re-fetch, and the
/// future is disposed when the framing tile layer is left.
///
/// It throws (surfacing the error into the [AsyncValue]) for a survey with no
/// verified HiPS base URL; callers gate on [hipsFramingActiveProvider] /
/// [hipsSurveyIsTileCapable] first, so in practice it is only read for a survey
/// [HipsSurveyAddress.forSurvey] can resolve. A failed or cancelled fetch lands
/// in the error state and is logged; consumers fall back to the canvas
/// snapshot rather than rendering a fabricated value.
final framingHipsPropertiesProvider = FutureProvider.autoDispose
    .family<HipsProperties, SurveySource>((ref, source) async {
      final address = HipsSurveyAddress.forSurvey(source);
      final fetcher = ref.watch(hipsTileFetcherProvider);
      final token = HipsFetchToken();
      ref.onDispose(token.cancel);
      try {
        return await fetcher.fetchProperties(address.baseUrl, token: token);
      } on HipsFetchCancelledException {
        // Expected when the provider is disposed (survey switch / screen left);
        // rethrow so the future completes as cancelled rather than as a bogus
        // success, and so a stale listener does not see a fabricated value.
        rethrow;
      } on HipsFetchException catch (e, st) {
        // Surface the failure: log it and let it propagate into the AsyncValue's
        // error state. Consumers treat an errored/absent properties value as "no
        // metadata" and fall back to the canvas snapshot. No silent blank, no
        // fabricated value.
        developer.log(
          'HiPS framing properties fetch failed for ${source.name}: ${e.message}',
          name: 'HipsFramingProvider',
          level: 900, // WARNING
          error: e,
          stackTrace: st,
        );
        rethrow;
      }
    });

// Feature flag

/// User-facing feature flag for the HiPS framing tile layer, defaulting to
/// **on** for tile-capable surveys.
///
/// The raw user toggle behind the framing canvas's "HiPS Tiles" control chip,
/// session-scoped like the Grid / Labels chips. Whether the layer is actually
/// active is [hipsFramingActiveProvider], which also requires a verified HiPS
/// pyramid: keeping the two separate preserves the toggle's value while a
/// non-tile-capable survey is selected.
final hipsFramingEnabledProvider = StateProvider<bool>((ref) => true);

/// Whether the HiPS tile layer should be active for [source].
///
/// True only when the survey has a **live-verified** direct HiPS base URL in
/// [HipsSurveyRegistry]. The unverified surveys expose only a canonical HiPS id
/// (their base URL must be resolved at runtime), and resolving that is out of
/// scope for this provider — so for them the framing layer falls back to the
/// existing single-cutout survey background rather than fabricating a URL. The
/// DSS2 surveys (the framing default) are verified and therefore tile-capable.
///
/// This is a pure capability check; it does not consult the user toggle. Use
/// [hipsFramingActiveProvider] for the combined decision.
bool hipsSurveyIsTileCapable(SurveySource source) =>
    HipsSurveyRegistry.entryFor(source).hasVerifiedBaseUrl;

/// Family selector: whether the HiPS tile layer is active for a given survey.
///
/// Combines the user toggle ([hipsFramingEnabledProvider]) with the survey
/// capability gate ([hipsSurveyIsTileCapable]). The framing widget watches this
/// for the currently-selected [SurveySource] to decide whether to mount the
/// tile painter (active) or rely solely on the existing single survey snapshot
/// (inactive). Exposed as a family keyed by [SurveySource] so the framing
/// screen can pass `framingProvider.surveySource` straight through without this
/// file taking a dependency on the framing notifier's live state.
final hipsFramingActiveProvider = Provider.family<bool, SurveySource>((
  ref,
  source,
) {
  final enabled = ref.watch(hipsFramingEnabledProvider);
  return enabled && hipsSurveyIsTileCapable(source);
});

// Resident-tiles notifier + provider

/// Resolved survey addressing for a framing tile session: the verified base URL
/// plus the canonical HiPS id the cache/tile-ids are keyed by.
///
/// Built from a [SurveySource] via [HipsSurveyRegistry]; throws (a feature) when
/// the survey has no verified base URL, because requesting tiles for a survey we
/// cannot reach is a programming error the caller must guard against via
/// [hipsSurveyIsTileCapable] / [hipsFramingActiveProvider] first.
class HipsSurveyAddress {
  /// Verified direct HiPS pyramid base URL (never fabricated).
  final String baseUrl;

  /// Canonical CDS HiPS id, used to key the cache and tile ids so selection and
  /// cache agree.
  final String surveyId;

  const HipsSurveyAddress({required this.baseUrl, required this.surveyId});

  /// Resolves the address for [source], or throws [StateError] if the survey
  /// has no verified base URL (resolve-at-runtime surveys are not tile-capable
  /// through this provider).
  factory HipsSurveyAddress.forSurvey(SurveySource source) {
    final entry = HipsSurveyRegistry.entryFor(source);
    final baseUrl = entry.baseUrl;
    if (!entry.hasVerifiedBaseUrl || baseUrl == null) {
      throw StateError(
        'SurveySource.$source has no verified HiPS base URL; the framing tile '
        'layer must not be activated for it (guard with '
        'hipsSurveyIsTileCapable / hipsFramingActiveProvider).',
      );
    }
    return HipsSurveyAddress(baseUrl: baseUrl, surveyId: entry.hipsId);
  }
}

/// Owns the C6 [HipsTileLoader] and republishes its versioned
/// [HipsResidentSnapshot] as Riverpod state so widgets `ref.watch` the snapshot
/// and rebuild only when a new one is published (a cheap version bump in the
/// loader → one state push here).
///
/// The widget drives this via [requestViewport] on every framing-state /
/// canvas-geometry change (pan/zoom/rotate/target/survey). This notifier does
/// **not** itself read the framing notifier or the canvas size, because the
/// canvas size and the resolved [FramingPlateScale] live in the widget layer
/// (the framing canvas measures itself with a `LayoutBuilder` and resolves the
/// plate scale per frame). Pushing the viewport from the widget keeps this
/// provider free of any widget-layer dependency and makes it trivially testable.
///
/// Survey switches are handled by [setSurvey], which hard-resets the loader
/// (clearing the cache — no prior-survey tile is ever a valid fallback for a
/// different survey) and re-resolves the base URL.
class HipsResidentTilesNotifier extends StateNotifier<HipsResidentSnapshot> {
  final HipsTileLoader _loader;
  VoidCallback? _loaderListener;

  /// The survey this notifier is currently addressing, or `null` until
  /// [setSurvey] is first called. Requesting a viewport before a survey is set
  /// is a programming error and throws.
  HipsSurveyAddress? _address;

  HipsResidentTilesNotifier(this._loader) : super(_loader.snapshot) {
    // Mirror the loader's snapshot into Riverpod state on every notify. The
    // loader bumps its version and notifies on every meaningful change (a tile
    // arrived, the Allsky base loaded, a failure was recorded, the view moved),
    // so this is the single bridge from the ChangeNotifier world to Riverpod.
    void listener() {
      if (!mounted) return;
      state = _loader.snapshot;
    }

    _loaderListener = listener;
    _loader.addListener(listener);
  }

  /// The underlying loader, for diagnostics and tests (e.g. asserting the
  /// debounce/dedup behaviour). Widgets should watch the snapshot via the
  /// provider rather than reach through here.
  HipsTileLoader get loader => _loader;

  /// The currently-addressed survey, or `null` before [setSurvey].
  HipsSurveyAddress? get address => _address;

  /// Switches the active survey, hard-resetting the loader.
  ///
  /// A survey switch invalidates every resident tile (a DSS2-red tile is not a
  /// valid coarse fallback for a DSS2-blue view), so this clears the cache and
  /// publishes an empty snapshot before the next [requestViewport] streams the
  /// new survey in. Re-setting the same survey is a no-op so a rebuild that
  /// re-supplies the current survey does not flash the view blank.
  void setSurvey(SurveySource source) {
    final next = HipsSurveyAddress.forSurvey(source);
    final current = _address;
    if (current != null &&
        current.surveyId == next.surveyId &&
        current.baseUrl == next.baseUrl) {
      return;
    }
    _address = next;
    _loader.clearSurvey();
  }

  /// Requests tiles for the current framing view.
  ///
  /// Called by the widget on layout / gesture / target changes. [plateScale],
  /// [canvasSize], [zoom], [pan] and [rotationDegrees] are exactly the geometry
  /// the framing background painter and the FOV/mosaic overlays use, so the
  /// tiles register to the overlays at every zoom (the registration guarantee
  /// is upheld by routing this identical geometry through the loader → C3
  /// selection). [props] is the parsed survey metadata (order range + tile
  /// width) driving LOD selection; the framing screen fetches it once per survey
  /// via the fetcher and passes it through here.
  ///
  /// The loader debounces, deduplicates and cancels internally, so the widget
  /// may call this on every gesture delta without thrashing the network.
  ///
  /// Throws [StateError] if no survey has been set via [setSurvey] yet — a tile
  /// request without a resolved base URL is a wiring bug, surfaced rather than
  /// silently dropped.
  void requestViewport({
    required FramingPlateScale plateScale,
    required FramingTarget target,
    required ui.Size canvasSize,
    required double zoom,
    required ui.Offset pan,
    required double rotationDegrees,
    required HipsTileFormat format,
    required HipsProperties props,
  }) {
    final address = _address;
    if (address == null) {
      throw StateError(
        'requestViewport called before setSurvey: the HiPS framing tile layer '
        'has no resolved survey base URL. Call setSurvey(source) first.',
      );
    }

    _loader.requestTiles(
      HipsViewport(
        plateScale: plateScale,
        target: target,
        canvasSize: canvasSize,
        zoom: zoom,
        pan: pan,
        rotationDegrees: rotationDegrees,
        baseUrl: address.baseUrl,
        surveyId: address.surveyId,
        format: format,
        props: props,
      ),
    );
  }

  /// Forces any pending debounced recompute to run immediately. Useful when a
  /// gesture ends and the caller wants the final view loaded without waiting out
  /// the trailing debounce window. Delegates to [HipsTileLoader.flushPending].
  void flushPending() => _loader.flushPending();

  @override
  void dispose() {
    final listener = _loaderListener;
    if (listener != null) {
      _loader.removeListener(listener);
      _loaderListener = null;
    }
    // The loader itself is owned and disposed by hipsTileLoaderProvider's
    // onDispose, not here — this notifier only borrows it. Disposing it here
    // too would double-dispose the cache/fetcher.
    super.dispose();
  }
}

/// The versioned resident-tile snapshot the framing tile widget watches.
///
/// The painter compares [HipsResidentSnapshot.version] in `shouldRepaint` — a
/// cheap integer compare — and walks the primary/fallback tile lists to
/// composite. The widget drives the loader through the notifier
/// ([HipsResidentTilesNotifier.requestViewport] / `setSurvey`).
///
/// `autoDispose`: when the framing tile layer is no longer watched, the
/// notifier is disposed (detaching its listener) and the loader provider it
/// depends on is torn down with it, disposing the cache + fetcher.
final hipsResidentTilesProvider =
    StateNotifierProvider.autoDispose<
      HipsResidentTilesNotifier,
      HipsResidentSnapshot
    >((ref) {
      final loader = ref.watch(hipsTileLoaderProvider);
      return HipsResidentTilesNotifier(loader);
    });
