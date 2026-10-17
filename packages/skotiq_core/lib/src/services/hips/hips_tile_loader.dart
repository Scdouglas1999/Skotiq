// Component C6 — HiPS framing tile loader / orchestrator.
//
// This is the *scheduler* that turns a stream of fast-changing framing
// viewports (pan/zoom/rotate gestures, target switches) into a small, ordered,
// non-thrashing set of decoded tiles for the framing painter to composite — and
// the [ChangeNotifier] the painter listens to for "the resident tile set
// changed, repaint".
//
// It sits squarely between the pure-geometry brain (C3 [HipsTileSelection]),
// the residency policy (C4 [HipsTileCache]) and the network/decode edge (C5
// [HipsTileFetcher]). It owns none of their jobs; it *sequences* them so the
// framing background streams in smoothly without ever blocking the UI thread,
// re-fetching on every gesture delta, or flashing blank.
//
// ## What it guarantees (the anti-jank contract, by item)
//
//  1. **Off-UI-thread fetch + decode.** Every fetch/decode goes through C5,
//     whose `instantiateImageCodec` work runs on the engine's IO/raster worker
//     threads. C6 only `await`s those futures and inserts the finished
//     [ui.Image] into the C4 cache; it performs no per-pixel CPU work and never
//     blocks a frame. The painter reads a pre-built immutable [snapshot] and
//     paints — it never awaits the loader.
//
//  2. **Bounded LRU cache.** All decoded tiles live in the injected
// [HipsTileCache], which evicts by entry-count and byte-budget. C6
//     never holds a decoded image outside the cache (except the transient local
//     in a fetch continuation, which is handed to the cache or disposed in the
//     same synchronous step).
//
//  3. **Debounce + dedup + cancel.** [requestTiles] coalesces a burst of
//     viewport updates into one trailing recompute via an injectable
//     [HipsLoaderClock] (so tests drive it deterministically with no real
//     delay). In-flight fetches are de-duplicated by [HipsTileId] through a
//     shared-[Future] map: two viewports that both need the same tile share one
//     network request. Each recompute opens a new *generation* with its own C5
//     [HipsFetchToken]; when a newer viewport supersedes it, the old
//     generation's token is cancelled so its in-flight requests abort promptly
//     instead of thrashing the socket pool and landing stale tiles in the cache.
//
//  4. **Level-of-detail with a never-blank fallback.** Each recompute selects
//     the [HipsTileSelection.selectNorder] for the current scale and requests
//     those tiles, but it *also* immediately exposes whatever coarser imagery is
//     already resident — the survey [HipsTileId] of each tile's parent
//     (`ipix >> 2`, one order up) and the Allsky thumbnail — through the
//     [snapshot], so the painter always has *something* to draw under the
//     streaming high-order tiles. The loader fetches the Allsky map first (the
//     instantly-available whole-sky coarse LOD) and pre-fetches parents so a
//     freshly-zoomed region is covered by a coarse tile within one round-trip.
//
//  5. **Seam-free mosaicing** is C3's job (shared HEALPix boundary sky points);
//     C6 preserves it by requesting the exact tile-id set C3 returns and never
//     substituting a different tessellation.
//
//  6. **GPU compositing** is the painter's job; C6 only delivers [ui.Image]s.
//
//  7. **Registration to the FOV/mosaic overlay** is guaranteed by routing every
//     viewport through the *same* [FramingPlateScale]/[FramingSkyProjection] C3
//     and the framing overlays use; C6 passes the viewport straight through to
//     [HipsTileSelection.computeVisibleTiles] without re-deriving any geometry.
//
// ## Failure handling
//
// A fetch failure is surfaced, not swallowed: failed tiles are recorded in the
// snapshot's [HipsResidentSnapshot.failures] and re-thrown to an injected
// [HipsTileLoaderErrorSink] (defaulting to `dart:developer` logging) so a
// developer/operator sees them, while the never-blank coarse fallback keeps the
// view usable. A *cancellation* ([HipsFetchCancelledException]) is the expected
// outcome of a superseded generation and is dropped quietly — it is not an error
// the user should see.
//
// Pure Dart + `dart:ui` + `dart:async`: no Flutter widget layer, no Riverpod, no
// direct `dart:io`. Fully unit-testable with a fake clock, a `MockClient`-backed
// C5 fetcher, and a real C4 cache.

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ChangeNotifier, immutable;

import '../../models/framing_plate_scale.dart';
import '../../models/hips/hips_properties.dart';
import '../../models/hips/hips_tile_id.dart';
import '../../providers/framing_provider.dart' show FramingTarget;
import 'hips_tile_cache.dart';
import 'hips_tile_fetcher.dart';
import 'hips_tile_selection.dart';

part 'hips_tile_loader/contracts.dart';

/// The tile-request orchestrator (component C6).
///
/// Construct one per framing tile layer, feed it viewports via [requestTiles] as
/// the framing state changes, listen to it as a [ChangeNotifier], and read
/// [snapshot] in the painter. Call [dispose] when the layer is torn down.
///
/// The loader owns the injected [HipsTileCache] and [HipsTileFetcher]: it
/// disposes both on [dispose] (the cache's images and the fetcher's HTTP
/// client). Inject a shared fetcher you own by passing `ownsFetcher: false`.
class HipsTileLoader extends ChangeNotifier {
  /// Default debounce window. Long enough to coalesce a gesture's per-frame
  /// deltas (a 60 Hz pan emits ~16 ms apart) into one recompute after the
  /// gesture pauses, short enough to feel immediate.
  static const Duration defaultDebounce = Duration(milliseconds: 90);

  /// Maximum number of primary (selected-Norder) tile fetches issued per
  /// generation. A pathological zoom-out at a deep order could otherwise ask for
  /// thousands of tiles; capping keeps the per-generation request burst bounded
  /// (the LOD rule normally keeps the visible count to a few dozen, so this only
  /// guards the degenerate case). The cap is applied after C3's deterministic
  /// ordering so the *same* nearest tiles are always chosen.
  static const int defaultMaxPrimaryFetchesPerGeneration = 64;

  final HipsTileCache _cache;
  final HipsTileFetcher _fetcher;
  final bool _ownsFetcher;
  final HipsLoaderClock _clock;
  final HipsTileLoaderErrorSink _errorSink;
  final Duration _debounce;
  final int _subdivisions;
  final int _maxPrimaryFetches;

  /// Tile ids with a fetch currently in flight, so a later generation that also
  /// needs a tile does not issue a duplicate request (dedup). The presence of a
  /// key *is* the dedup signal — the fetch continuation removes its own key on
  /// completion, so the set stays bounded by the number of concurrently
  /// outstanding requests.
  final Set<HipsTileId> _inFlightTiles = <HipsTileId>{};

  /// Orders with an Allsky fetch currently in flight, deduped like tiles.
  final Set<int> _inFlightAllsky = <int>{};

  /// Decoded Allsky images by order, owned by the loader (disposed on
  /// [dispose]/[clearSurvey]). The Allsky is not a HEALPix tile so it lives
  /// outside the C4 cache, but it is bounded (one per order, a handful at most).
  final Map<int, ui.Image> _allskyByOrder = <int, ui.Image>{};

  /// The pending debounce timer, if a recompute is scheduled.
  HipsLoaderTimer? _pendingTimer;

  /// The viewport the pending/last recompute should run for.
  HipsViewport? _pendingViewport;

  /// The viewport the most recent recompute actually ran for (to skip no-ops).
  HipsViewport? _lastComputedViewport;

  /// The current generation token. Each recompute supersedes the previous by
  /// cancelling [_currentToken] and minting a fresh one; in-flight fetches from
  /// the old generation abort, and their late completions are ignored because
  /// they check [_generation] against the value captured when they started.
  HipsFetchToken _currentToken = HipsFetchToken();

  /// Monotonic generation counter. A fetch continuation only mutates state if
  /// its captured generation still equals this (i.e. it was not superseded).
  int _generation = 0;

  /// Monotonic snapshot version, surfaced via [HipsResidentSnapshot.version].
  int _snapshotVersion = 0;

  /// The current published snapshot.
  HipsResidentSnapshot _snapshot = HipsResidentSnapshot.empty;

  /// Failures accumulated for the current generation (reset on a new recompute).
  final List<HipsTileFailure> _failures = <HipsTileFailure>[];

  bool _disposed = false;

  /// Creates a loader.
  ///
  /// [cache] and [fetcher] are the injected C4/C5 components (real ones in
  /// production, test doubles in unit tests). [clock] defaults to a real
  /// [Timer]-backed clock; tests inject a fake. [errorSink] defaults to
  /// `dart:developer` logging. [debounce] is the trailing recompute window.
  /// [subdivisions] is forwarded to [HipsTileSelection.computeVisibleTiles].
  ///
  /// When [ownsFetcher] is true (the default) the loader [dispose]s the fetcher;
  /// pass false to share a fetcher whose lifetime you manage.
  HipsTileLoader({
    required HipsTileCache cache,
    required HipsTileFetcher fetcher,
    HipsLoaderClock clock = const HipsRealLoaderClock(),
    HipsTileLoaderErrorSink errorSink = const _DevLogErrorSink(),
    Duration debounce = defaultDebounce,
    int subdivisions = HipsTileSelection.defaultSubdivisions,
    int maxPrimaryFetchesPerGeneration = defaultMaxPrimaryFetchesPerGeneration,
    bool ownsFetcher = true,
  }) : _cache = cache,
       _fetcher = fetcher,
       _ownsFetcher = ownsFetcher,
       _clock = clock,
       _errorSink = errorSink,
       _debounce = debounce,
       _subdivisions = subdivisions,
       _maxPrimaryFetches = maxPrimaryFetchesPerGeneration {
    if (debounce < Duration.zero) {
      throw ArgumentError.value(
        debounce,
        'debounce',
        'must be a non-negative duration',
      );
    }
    if (subdivisions < 1) {
      throw ArgumentError.value(subdivisions, 'subdivisions', 'must be >= 1');
    }
    if (maxPrimaryFetchesPerGeneration < 1) {
      throw ArgumentError.value(
        maxPrimaryFetchesPerGeneration,
        'maxPrimaryFetchesPerGeneration',
        'must be >= 1',
      );
    }
  }

  /// The current resident snapshot for the painter. Always non-null; starts at
  /// [HipsResidentSnapshot.empty].
  HipsResidentSnapshot get snapshot => _snapshot;

  /// The current generation counter (diagnostics / tests).
  int get generation => _generation;

  /// Whether a debounced recompute is currently pending.
  bool get hasPendingRecompute => _pendingTimer?.isActive ?? false;

  /// Requests tiles for [viewport], debouncing the recompute.
  ///
  /// Called on every framing-state change (pan/zoom/rotate/target). The actual
  /// recompute (selection + fetch scheduling) is deferred by the debounce window
  /// and runs once for the *latest* viewport when the burst settles. A viewport
  /// identical (in recompute-relevant fields) to the last computed one is a
  /// no-op: it neither reschedules nor recomputes, so a held gesture emitting
  /// repeated identical deltas does not thrash.
  ///
  /// Calling [requestTiles] while a timer is pending replaces the pending
  /// viewport with the newer one and restarts the timer (trailing debounce):
  /// only the final viewport of a burst is computed.
  void requestTiles(HipsViewport viewport) {
    _assertNotDisposed();

    // No-op if nothing relevant changed since the last completed recompute and
    // nothing is pending — avoids re-running selection for a stationary view.
    final last = _lastComputedViewport;
    if (last != null &&
        last.sameRecomputeInputs(viewport) &&
        !(_pendingTimer?.isActive ?? false)) {
      return;
    }

    _pendingViewport = viewport;
    _pendingTimer?.cancel();

    if (_debounce == Duration.zero) {
      // Zero-debounce path still defers to a microtask-free immediate run so the
      // call site never re-enters the loader synchronously mid-gesture.
      _pendingTimer = _clock.schedule(Duration.zero, _runPendingRecompute);
    } else {
      _pendingTimer = _clock.schedule(_debounce, _runPendingRecompute);
    }
  }

  /// Forces the pending recompute to run immediately (skipping the remaining
  /// debounce), if one is pending. Useful when a gesture *ends* and the caller
  /// wants the final view loaded without waiting out the trailing window.
  void flushPending() {
    _assertNotDisposed();
    if (_pendingTimer?.isActive ?? false) {
      _pendingTimer!.cancel();
      _runPendingRecompute();
    }
  }

  /// Clears all imagery for a survey switch: cancels in-flight work, empties the
  /// C4 cache and the Allsky maps, and publishes an empty snapshot. No
  /// prior-survey tile is ever a valid fallback for a different survey, so this
  /// is a hard reset rather than an eviction pass.
  void clearSurvey() {
    _assertNotDisposed();
    _supersedeGeneration();
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingViewport = null;
    _lastComputedViewport = null;
    _cache.clear();
    _disposeAllsky();
    _failures.clear();
    _publishSnapshot(
      selectedNorder: -1,
      primaryTiles: const <HipsVisibleTile>[],
      fallbackTiles: const <HipsFallbackTile>[],
      allsky: null,
      visibleSet: null,
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _currentToken.cancel();
    _disposeAllsky();
    _cache.dispose();
    if (_ownsFetcher) {
      _fetcher.dispose();
    }
    super.dispose();
  }

  // Recompute orchestration

  /// Runs the recompute for [_pendingViewport]: opens a new generation,
  /// computes the visible set, republishes the resident snapshot
  /// immediately (so coarse fallbacks paint without waiting for the network),
  /// then schedules the Allsky-first + parent-fallback + primary fetches.
  void _runPendingRecompute() {
    if (_disposed) return;
    final viewport = _pendingViewport;
    if (viewport == null) return;

    // The timer has fired; it is no longer pending.
    _pendingTimer = null;
    _lastComputedViewport = viewport;

    // Supersede any prior generation: cancel its token (aborting its in-flight
    // fetches) and mint a fresh one for this generation.
    _supersedeGeneration();
    final int gen = _generation;
    final HipsFetchToken token = _currentToken;

    // Fresh failure ledger for this generation.
    _failures.clear();

    // C3: which tiles, where. This is pure/deterministic and cheap; any
    // geometric miswiring throws here (a feature) rather than painting wrong.
    final HipsVisibleTileSet visibleSet = HipsTileSelection.computeVisibleTiles(
      viewport.plateScale,
      viewport.target,
      viewport.canvasSize,
      viewport.zoom,
      HipsTileSelection.selectNorder(
        viewport.plateScale.pixelsPerDegree(viewport.canvasSize, viewport.zoom),
        viewport.props,
      ),
      viewport.props,
      subdivisions: _subdivisions,
      pan: viewport.pan,
      rotationDegrees: viewport.rotationDegrees,
      surveyId: viewport.surveyId,
    );

    // Publish immediately with whatever is already resident as primary +
    // coarse fallback, so a repaint shows coarse imagery this frame (never
    // blank) even before any new fetch returns.
    _republishResidentForView(visibleSet, viewport);

    // Kick off the Allsky-first strategy, then parent prefetch, then primary
    // tile fetches. All share [token] so superseding cancels the whole batch.
    _scheduleAllsky(viewport, visibleSet.norder, gen, token);
    _schedulePrimaryAndParents(viewport, visibleSet, gen, token);
  }

  /// Cancels the current generation's token and advances the generation
  /// counter, minting a fresh token for the next generation.
  void _supersedeGeneration() {
    _currentToken.cancel();
    _generation++;
    _currentToken = HipsFetchToken();
  }

  /// Recomputes which resident tiles are primary vs. fallback for [visibleSet]
  /// and publishes a snapshot. Pure cache reads — no fetching.
  void _republishResidentForView(
    HipsVisibleTileSet visibleSet,
    HipsViewport viewport,
  ) {
    final HipsTileCacheSnapshot cacheSnap = _cache.snapshot();

    final primary = <HipsVisibleTile>[];
    final fallback = <HipsFallbackTile>[];

    for (final tile in visibleSet.tiles) {
      if (cacheSnap.contains(tile.id)) {
        primary.add(tile);
      } else {
        // The sharp tile is not resident yet: use the coarsest *resident*
        // ancestor (parent, grandparent, ...), sampled at the sub-cell the sharp
        // tile occupies within it, drawn on the sharp tile's mesh so the region
        // is covered (with correctly-registered coarse imagery), not blank.
        final HipsFallbackTile? coarse = _coarsestResidentAncestor(
          tile,
          viewport,
          cacheSnap,
        );
        if (coarse != null) {
          fallback.add(coarse);
        }
      }
    }

    _publishSnapshot(
      selectedNorder: visibleSet.norder,
      primaryTiles: primary,
      fallbackTiles: fallback,
      // The Allsky base is fetched at the survey's published Allsky order (the
      // conventional whole-sky order, NOT hips_order_min — see
      // HipsProperties.allskyOrder), so it is keyed by that order.
      allsky: _allskyByOrder[viewport.props.allskyOrder],
      visibleSet: visibleSet,
    );
  }

  /// Walks up the HEALPix pyramid (`ipix >> 2` per level) from [tile] until it
  /// finds a resident ancestor in [cacheSnap], returning a [HipsFallbackTile]
  /// that pairs the sharp tile's mesh with the ancestor's id AND the sub-cell the
  /// sharp tile occupies within that ancestor — so the painter samples only that
  /// sub-region of the coarse image (correctly registered), not the whole
  /// ancestor image squashed across the child footprint. Returns `null` if no
  /// ancestor down to the survey's min order is resident.
  HipsFallbackTile? _coarsestResidentAncestor(
    HipsVisibleTile tile,
    HipsViewport viewport,
    HipsTileCacheSnapshot cacheSnap,
  ) {
    var order = tile.id.norder - 1;
    var npix = tile.id.npix >> 2;
    final int minOrder = viewport.props.hipsOrderMin;
    while (order >= minOrder && order >= 0) {
      final ancestorId = HipsTileId(
        survey: viewport.surveyId,
        norder: order,
        npix: npix,
      );
      if (cacheSnap.contains(ancestorId)) {
        // Build the fallback: the sharp tile's mesh, the resident ancestor id,
        // and the descendant sub-cell of the sharp tile within the ancestor so
        // the painter samples the matching sub-rect of the coarse image.
        return HipsFallbackTile.fromDescent(
          ancestorId: ancestorId,
          childNorder: tile.id.norder,
          childNpix: tile.id.npix,
          childMesh: tile.mesh,
        );
      }
      order--;
      npix >>= 2;
    }
    return null;
  }

  /// Fetches the Allsky thumbnail for the selected order's *root* if it is not
  /// already resident or in flight. The Allsky is the instantly-available
  /// whole-sky coarse LOD; it is fetched first so the very first frame after a
  /// target/survey change has a base layer.
  ///
  /// We fetch the Allsky at the survey's published Allsky order
  /// ([HipsProperties.allskyOrder], the conventional whole-sky order 3 clamped to
  /// the survey range), which covers the entire sphere in one small image, rather
  /// than per selected order — that is the canonical never-blank base layer. It
  /// is deliberately NOT `hips_order_min`: real surveys (CDS DSS) declare
  /// `hips_order_min = 0` yet only publish `Norder3/Allsky.jpg`, so fetching at
  /// the min order would 404 and the base layer would never load.
  void _scheduleAllsky(
    HipsViewport viewport,
    int selectedNorder,
    int gen,
    HipsFetchToken token,
  ) {
    final int allskyOrder = viewport.props.allskyOrder;
    if (_allskyByOrder.containsKey(allskyOrder)) {
      return; // Already resident.
    }
    if (_inFlightAllsky.contains(allskyOrder)) {
      return; // Already being fetched (dedup).
    }

    // Mark in-flight *before* launching so a synchronous re-entry within this
    // generation cannot issue a duplicate request.
    _inFlightAllsky.add(allskyOrder);
    unawaited(() async {
      try {
        final image = await _fetcher.fetchAllsky(
          viewport.baseUrl,
          allskyOrder,
          viewport.format,
          token: token,
        );
        // If this generation was superseded while the Allsky was in flight,
        // drop the image (do not let stale survey imagery linger across a
        // survey switch). A pan/zoom within the same survey keeps the same
        // Allsky valid, so only discard on an actual generation change that
        // outlived the fetch AND a survey change; the Allsky is survey-global,
        // so we keep it as long as the loader was not disposed/cleared.
        if (_disposed) {
          image.dispose();
          return;
        }
        // Keep the Allsky even across generations within the same survey: it is
        // a valid base layer for any view of this survey. Only a survey switch
        // (clearSurvey) discards it.
        final existing = _allskyByOrder[allskyOrder];
        if (existing != null && !identical(existing, image)) {
          // A concurrent fetch already populated it; keep the first, dispose
          // the duplicate.
          image.dispose();
        } else {
          _allskyByOrder[allskyOrder] = image;
        }
        _onCoarseLayerArrived(gen);
      } on HipsFetchCancelledException {
        // Expected on supersession; drop quietly.
      } on HipsFetchException catch (e) {
        _recordFailure(
          HipsTileId(survey: viewport.surveyId, norder: allskyOrder, npix: 0),
          e,
          gen,
        );
      } finally {
        // Unregister so the in-flight set stays bounded.
        _inFlightAllsky.remove(allskyOrder);
      }
    }());
  }

  /// Schedules the parent (one-order-up) prefetch and the primary
  /// selected-order fetches for [visibleSet].
  ///
  /// Order of operations matters for "never blank": parents are coarser and
  /// fewer, so requesting them first means a freshly-zoomed region is covered by
  /// a parent tile within roughly one round-trip while the (more numerous) sharp
  /// tiles stream in behind it.
  void _schedulePrimaryAndParents(
    HipsViewport viewport,
    HipsVisibleTileSet visibleSet,
    int gen,
    HipsFetchToken token,
  ) {
    final selectedNorder = visibleSet.norder;
    final int minOrder = viewport.props.hipsOrderMin;

    // Parent prefetch: the distinct set of one-order-up parents of the visible
    // tiles, only when the parent order is within the published range. Deduped
    // by the in-flight map and the cache-resident check inside _fetchTile.
    if (selectedNorder - 1 >= minOrder && selectedNorder - 1 >= 0) {
      final parentOrder = selectedNorder - 1;
      final seenParents = <int>{};
      for (final tile in visibleSet.tiles) {
        final parentNpix = tile.id.npix >> 2;
        if (!seenParents.add(parentNpix)) continue;
        final parentId = HipsTileId(
          survey: viewport.surveyId,
          norder: parentOrder,
          npix: parentNpix,
        );
        _fetchTile(parentId, viewport, gen, token);
      }
    }

    // Primary fetches: the selected-order tiles, capped to a bounded burst.
    var issued = 0;
    for (final tile in visibleSet.tiles) {
      if (issued >= _maxPrimaryFetches) break;
      _fetchTile(tile.id, viewport, gen, token);
      issued++;
    }
  }

  /// Fetches a single tile if it is not already resident or in flight (dedup),
  /// inserts it into the C4 cache on success, and republishes the snapshot so
  /// the painter picks it up. Cancellations are dropped; other failures are
  /// recorded + surfaced.
  void _fetchTile(
    HipsTileId id,
    HipsViewport viewport,
    int gen,
    HipsFetchToken token,
  ) {
    // Dedup against the cache (already decoded) and in-flight set (being
    // fetched). [HipsTileCache.contains] does not disturb LRU recency.
    if (_cache.contains(id)) {
      return;
    }
    if (_inFlightTiles.contains(id)) {
      return;
    }

    // Mark in-flight before launching so concurrent scheduling within the same
    // generation never double-issues this tile.
    _inFlightTiles.add(id);
    unawaited(() async {
      try {
        final image = await _fetcher.fetchTile(
          id,
          viewport.baseUrl,
          viewport.format,
          token: token,
        );
        if (_disposed) {
          image.dispose();
          return;
        }
        if (gen != _generation) {
          // Superseded after the fetch resolved but before we stored it. The
          // tile is still valid imagery for this survey, so cache it (it may be
          // visible in the current view too) rather than discard a paid-for
          // download — the cache's LRU will evict it if it is not used.
          _cache.put(id, image);
          return;
        }
        _cache.put(id, image);
        _onTileArrived(gen);
      } on HipsFetchCancelledException {
        // Expected on supersession; drop quietly.
      } on HipsFetchException catch (e) {
        _recordFailure(id, e, gen);
      } finally {
        _inFlightTiles.remove(id);
      }
    }());
  }

  /// Called when a primary/parent tile lands in the cache. Republishes the
  /// resident snapshot for the *current* view if this generation is still
  /// active, so the painter promotes the tile from fallback to primary.
  void _onTileArrived(int gen) {
    if (_disposed) return;
    if (gen != _generation) return;
    final viewport = _lastComputedViewport;
    if (viewport == null) return;
    // Recompute resident classification cheaply against the existing visible set
    // (the geometry has not changed; only residency has).
    final visibleSet = _snapshot.visibleSet;
    if (visibleSet == null || visibleSet.norder != _snapshot.selectedNorder) {
      // Defensive: recompute geometry if the snapshot lacks a matching set.
      _republishFromCurrentViewport(viewport);
      return;
    }
    _republishResidentForView(visibleSet, viewport);
  }

  /// Called when the Allsky base layer arrives. Republishes so the painter shows
  /// the whole-sky base immediately under the (still streaming) tiles.
  void _onCoarseLayerArrived(int gen) {
    if (_disposed) return;
    if (gen != _generation) return;
    final viewport = _lastComputedViewport;
    final visibleSet = _snapshot.visibleSet;
    if (viewport == null || visibleSet == null) {
      // Still publish the Allsky alone as the base layer.
      _publishSnapshot(
        selectedNorder: _snapshot.selectedNorder,
        primaryTiles: _snapshot.primaryTiles,
        fallbackTiles: _snapshot.fallbackTiles,
        allsky: _allskyByOrder[viewport?.props.allskyOrder ?? -1],
        visibleSet: visibleSet,
      );
      return;
    }
    _republishResidentForView(visibleSet, viewport);
  }

  /// Recomputes the visible set from scratch for [viewport] and republishes.
  /// Used when an arrival cannot reuse a cached visible set.
  void _republishFromCurrentViewport(HipsViewport viewport) {
    final visibleSet = HipsTileSelection.computeVisibleTiles(
      viewport.plateScale,
      viewport.target,
      viewport.canvasSize,
      viewport.zoom,
      HipsTileSelection.selectNorder(
        viewport.plateScale.pixelsPerDegree(viewport.canvasSize, viewport.zoom),
        viewport.props,
      ),
      viewport.props,
      subdivisions: _subdivisions,
      pan: viewport.pan,
      rotationDegrees: viewport.rotationDegrees,
      surveyId: viewport.surveyId,
    );
    _republishResidentForView(visibleSet, viewport);
  }

  /// Records a genuine (non-cancellation) failure: appends it to the generation
  /// ledger, surfaces it to the error sink, and republishes so the snapshot's
  /// failures list reflects it.
  void _recordFailure(HipsTileId id, HipsFetchException error, int gen) {
    if (_disposed) return;
    final failure = HipsTileFailure(id, error);
    _errorSink.onTileError(failure);
    if (gen != _generation) {
      // Superseded generation's failure: still surfaced to the sink above, but
      // do not pollute the current snapshot's failure list.
      return;
    }
    _failures.add(failure);
    // Republish to expose the failure to a UI banner without changing imagery.
    _publishSnapshot(
      selectedNorder: _snapshot.selectedNorder,
      primaryTiles: _snapshot.primaryTiles,
      fallbackTiles: _snapshot.fallbackTiles,
      allsky: _snapshot.allsky,
      visibleSet: _snapshot.visibleSet,
    );
  }

  /// Builds and publishes a new snapshot, bumping the version and notifying
  /// listeners. Takes a fresh cache snapshot so the painter's borrowed images
  /// are valid for the frame.
  void _publishSnapshot({
    required int selectedNorder,
    required List<HipsVisibleTile> primaryTiles,
    required List<HipsFallbackTile> fallbackTiles,
    required ui.Image? allsky,
    required HipsVisibleTileSet? visibleSet,
  }) {
    if (_disposed) return;
    _snapshotVersion++;
    _snapshot = HipsResidentSnapshot(
      version: _snapshotVersion,
      selectedNorder: selectedNorder,
      primaryTiles: List<HipsVisibleTile>.unmodifiable(primaryTiles),
      fallbackTiles: List<HipsFallbackTile>.unmodifiable(fallbackTiles),
      allsky: allsky,
      cacheSnapshot: _cache.isDisposed
          ? HipsTileCacheSnapshot.empty
          : _cache.snapshot(),
      visibleSet: visibleSet,
      failures: List<HipsTileFailure>.unmodifiable(_failures),
    );
    notifyListeners();
  }

  void _disposeAllsky() {
    for (final image in _allskyByOrder.values) {
      image.dispose();
    }
    _allskyByOrder.clear();
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError('HipsTileLoader has been disposed and cannot be used');
    }
  }
}
