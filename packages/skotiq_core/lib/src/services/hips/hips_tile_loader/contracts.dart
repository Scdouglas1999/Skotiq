part of '../hips_tile_loader.dart';

/// The complete framing-view state one tile recompute is driven from.
///
/// This is exactly the set of inputs [HipsTileSelection.computeVisibleTiles]
/// needs, plus the survey addressing ([baseUrl], [surveyId], [format], [props])
/// the fetch layer needs. It is an immutable value so the loader can compare a
/// new viewport against the last one to skip a no-op recompute (a frame where
/// nothing relevant changed), and so a generation can capture the exact viewport
/// it was computed for.
///
/// [surveyId] is the cache/key identity of the survey (the canonical CDS HiPS
/// id, e.g. `CDS/P/DSS2/red`) and MUST match the `surveyId` passed to
/// [HipsTileSelection.computeVisibleTiles] so tile ids agree between selection
/// and cache. [baseUrl] is the already-resolved pyramid root the fetch layer
/// appends tile paths to.
@immutable
class HipsViewport {
  /// The shared framing plate scale (registration source of truth).
  final FramingPlateScale plateScale;

  /// The framing target the canvas centre corresponds to.
  final FramingTarget target;

  /// Logical canvas size in pixels.
  final ui.Size canvasSize;

  /// Current zoom factor (the same value the framing overlays use).
  final double zoom;

  /// Current pan offset in logical pixels.
  final ui.Offset pan;

  /// Current field rotation in degrees.
  final double rotationDegrees;

  /// Survey pyramid base URL (already resolved; never fabricated here).
  final String baseUrl;

  /// Canonical survey id used to key the cache and tile ids.
  final String surveyId;

  /// Tile encoding to fetch (the survey's preferred format unless overridden).
  final HipsTileFormat format;

  /// Parsed survey metadata (order range + tile width drive LOD selection).
  final HipsProperties props;

  const HipsViewport({
    required this.plateScale,
    required this.target,
    required this.canvasSize,
    required this.zoom,
    required this.pan,
    required this.rotationDegrees,
    required this.baseUrl,
    required this.surveyId,
    required this.format,
    required this.props,
  });

  /// Whether two viewports would produce an identical tile recompute.
  ///
  /// Compares only the fields the recompute depends on. Two viewports that
  /// differ in nothing relevant skip the recompute entirely, so holding a
  /// gesture stationary (a stream of identical deltas) does not re-run selection
  /// or re-issue fetches.
  bool sameRecomputeInputs(HipsViewport other) {
    return identical(this, other) ||
        (plateScale == other.plateScale &&
            target.raHours == other.target.raHours &&
            target.decDegrees == other.target.decDegrees &&
            canvasSize == other.canvasSize &&
            zoom == other.zoom &&
            pan == other.pan &&
            rotationDegrees == other.rotationDegrees &&
            baseUrl == other.baseUrl &&
            surveyId == other.surveyId &&
            format == other.format &&
            props == other.props);
  }

  @override
  String toString() =>
      'HipsViewport($surveyId @ ${target.raHours}h '
      '${target.decDegrees}deg, zoom=$zoom, pan=$pan, rot=$rotationDegrees, '
      'canvas=$canvasSize)';
}

/// A failed tile fetch recorded for diagnostics / an error banner.
///
/// Cancellations are never recorded here (they are expected and dropped); only
/// genuine HTTP/decode failures land in [HipsResidentSnapshot.failures].
@immutable
class HipsTileFailure {
  /// The tile (or Allsky pseudo-id) that failed.
  final HipsTileId id;

  /// The surfaced fetch exception.
  final HipsFetchException error;

  const HipsTileFailure(this.id, this.error);

  @override
  String toString() => 'HipsTileFailure($id: ${error.message})';
}

/// An immutable, monotonically-versioned description of what the painter should
/// draw *this frame*, produced by the loader on every meaningful change.
///
/// The painter reads [version] to know whether anything changed since its last
/// paint (a cheap integer compare in `shouldRepaint`), then walks
/// [primaryTiles] / [fallbackTiles] to composite. The actual decoded images are
/// borrowed from [cacheSnapshot] (a C4 point-in-time view) so the painter never
/// touches the live cache mid-frame.
///
/// ## Two tile lists, one never-blank guarantee
///   * [primaryTiles] are the tiles at the *selected* Norder for the current
///     scale — the sharp layer the painter draws on top.
///   * [fallbackTiles] are coarser ancestors (the coarsest resident ancestor of
///     each not-yet-loaded sharp tile), each sampled at the sub-cell the sharp
///     tile occupies within the ancestor and warped onto the sharp tile's mesh,
///     drawn *under* the primary layer so a region whose high-order tile is still
///     streaming shows a (softer) correctly-registered coarse tile instead of
///     black. The Allsky base ([allsky]) is the coarsest layer under both.
///
/// Both lists are ordered the way C3 returns them (ascending Npix) so draw order
/// is deterministic across frames. A tile appears in a list only when its image
/// is actually resident in [cacheSnapshot]; the painter never has to null-check
/// against the cache.
@immutable
class HipsResidentSnapshot {
  /// Monotonic version; strictly increases on every published snapshot.
  final int version;

  /// The selected Norder for this view (the resolution the primary layer is at).
  final int selectedNorder;

  /// The sharp, current-LOD visible tiles (each backed by a resident image),
  /// with their projected meshes, in ascending Npix order.
  final List<HipsVisibleTile> primaryTiles;

  /// Coarser resident ancestors drawn under [primaryTiles] so the view is never
  /// blank while the sharp layer streams in, in ascending child-Npix order. Each
  /// carries the child's screen mesh plus the ancestor sub-cell to sample, so the
  /// painter warps only the correct sub-region of the coarse image onto the
  /// child footprint (never the whole ancestor image squashed into the child).
  final List<HipsFallbackTile> fallbackTiles;

  /// The Allsky thumbnail for [selectedNorder]'s root order, when resident, else
  /// `null`. Drawn as the coarsest base layer under everything.
  final ui.Image? allsky;

  /// Point-in-time C4 cache view the tile images are borrowed from. Valid for
  /// the frame this snapshot is consumed in (see [HipsTileCache.snapshot]).
  final HipsTileCacheSnapshot cacheSnapshot;

  /// The complete visible-tile set (the C3 output) for the selected Norder,
  /// including tiles whose image has not loaded yet — the painter uses this to
  /// know the full mosaic footprint (and to draw the FOV-registered geometry
  /// even for not-yet-resident tiles using fallbacks).
  final HipsVisibleTileSet? visibleSet;

  /// Genuine fetch failures since the last successful recompute (never includes
  /// cancellations). Empty in the steady state.
  final List<HipsTileFailure> failures;

  const HipsResidentSnapshot({
    required this.version,
    required this.selectedNorder,
    required this.primaryTiles,
    required this.fallbackTiles,
    required this.allsky,
    required this.cacheSnapshot,
    required this.visibleSet,
    required this.failures,
  });

  /// The initial empty snapshot before any tiles load.
  static const HipsResidentSnapshot empty = HipsResidentSnapshot(
    version: 0,
    selectedNorder: -1,
    primaryTiles: <HipsVisibleTile>[],
    fallbackTiles: <HipsFallbackTile>[],
    allsky: null,
    cacheSnapshot: HipsTileCacheSnapshot.empty,
    visibleSet: null,
    failures: <HipsTileFailure>[],
  );

  /// Whether there is any imagery at all to paint (primary, fallback, or
  /// Allsky). When false the painter should fall back to the existing single
  /// survey snapshot / starfield (the never-blank guarantee at the outermost
  /// level).
  bool get hasAnyImagery =>
      primaryTiles.isNotEmpty || fallbackTiles.isNotEmpty || allsky != null;

  @override
  String toString() =>
      'HipsResidentSnapshot(v$version, Norder$selectedNorder, '
      '${primaryTiles.length} primary, ${fallbackTiles.length} fallback, '
      'allsky=${allsky != null}, ${failures.length} failures)';
}

/// Sink for surfaced (non-cancellation) tile fetch errors.
///
/// The loader reports every genuine failure here as well as recording it in
/// the snapshot. The default implementation logs via `dart:developer`; tests
/// inject a capturing sink.
abstract class HipsTileLoaderErrorSink {
  /// Reports a surfaced tile fetch failure (never a cancellation).
  void onTileError(HipsTileFailure failure);
}

/// Default error sink: logs each failure via `dart:developer`.
class _DevLogErrorSink implements HipsTileLoaderErrorSink {
  const _DevLogErrorSink();

  @override
  void onTileError(HipsTileFailure failure) {
    developer.log(
      'HiPS tile fetch failed: ${failure.error.message} '
      '(url=${failure.error.requestUrl})',
      name: 'HipsTileLoader',
      level: 900, // WARNING
      error: failure.error,
    );
  }
}

/// A cancelable one-shot delay, abstracted so tests drive the debounce without a
/// real wall-clock wait.
///
/// The production implementation wraps `dart:async`'s [Timer]; the test
/// implementation lets the test advance time explicitly. A scheduled callback
/// fires at most once and not at all if [cancel] is called first.
abstract class HipsLoaderTimer {
  /// Cancels the pending callback if it has not fired yet.
  void cancel();

  /// Whether the callback is still pending (scheduled and not yet fired or
  /// cancelled).
  bool get isActive;
}

/// Schedules debounce callbacks. Injected so tests substitute a fake clock.
abstract class HipsLoaderClock {
  /// Schedules [callback] to run after [delay], returning a handle to cancel it.
  HipsLoaderTimer schedule(Duration delay, void Function() callback);
}

/// Production clock backed by `dart:async` [Timer].
///
/// Public so the C7 [hipsLoaderClockProvider] can resolve it as the production
/// default while tests override that provider with a manually-advanced clock.
class HipsRealLoaderClock implements HipsLoaderClock {
  /// Creates the production timer-backed clock.
  const HipsRealLoaderClock();

  @override
  HipsLoaderTimer schedule(Duration delay, void Function() callback) {
    return _RealLoaderTimer(Timer(delay, callback));
  }
}

class _RealLoaderTimer implements HipsLoaderTimer {
  final Timer _timer;
  _RealLoaderTimer(this._timer);

  @override
  void cancel() => _timer.cancel();

  @override
  bool get isActive => _timer.isActive;
}
