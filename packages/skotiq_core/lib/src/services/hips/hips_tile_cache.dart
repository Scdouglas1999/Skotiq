import 'dart:collection';
import 'dart:ui' as ui;

import '../../models/hips/hips_tile_id.dart';

/// Component C4 — bounded LRU cache of decoded HiPS image tiles.
///
/// The framing tile layer paints decoded [ui.Image] tiles directly into the
/// framing canvas (see `FramingSurveyImagePainter`). Decoded RGBA images are
/// large and GPU-backed, so an unbounded map of them would balloon native
/// memory and starve the engine's own raster cache. This cache keeps the set
/// of resident tiles bounded by **two independent limits** — a maximum entry
/// count and an approximate decoded-byte budget — and evicts the
/// least-recently-used tiles, disposing their [ui.Image] handles, whenever
/// inserting a new tile would exceed either limit.
///
/// ## Why both an entry cap and a byte budget
/// HiPS tiles are uniform per survey (typically 512x512), but a cache shared
/// across surveys, Allsky thumbnails, and mixed tile widths sees a wide range
/// of decoded sizes. An entry-count cap alone cannot bound memory when tiles
/// are large; a byte budget alone cannot bound the bookkeeping/atlas churn
/// when tiles are tiny. Enforcing both keeps memory *and* draw-call counts in
/// hand regardless of the survey's tile geometry.
///
/// ## LRU semantics
/// Recency is tracked by insertion order in a [LinkedHashMap]: the first key
/// is the least-recently-used, the last is the most-recently-used. Every
/// [get] that hits, and every [put], moves the entry to the
/// most-recently-used end ("touch on access"). Eviction always removes from
/// the LRU end until both limits are satisfied.
///
/// ## Ownership of [ui.Image]
/// A [ui.Image] is a disposable native resource. This cache **takes ownership**
/// of every image handed to [put]: when an entry is evicted, replaced, or the
/// cache is [clear]ed/[dispose]d, the cache calls [ui.Image.dispose] on the
/// image it dropped. Callers that paint a cached image hold a borrowed
/// reference that is valid only until the image is evicted, so painters must
/// read images through a [snapshot] taken at the start of a frame and never
/// retain a cached [ui.Image] across frames. Because a fresh snapshot is taken
/// each frame and eviction only happens on [put]/[clear]/[dispose] (never
/// concurrently mid-paint on Dart's single isolate), an image referenced by a
/// live snapshot cannot be disposed out from under the painter within that
/// frame.
///
/// This type is **pure Dart + `dart:ui`** — it has no dependency on the Flutter
/// widget layer and performs no I/O or decoding itself; it is solely the
/// residency/eviction policy over already-decoded tiles produced by the
/// fetch/decode pipeline.
class HipsTileCache {
  /// Hard upper bound on the number of resident decoded tiles.
  ///
  /// Must be at least 1: a cache that can hold nothing is a programming error,
  /// not a degraded mode, so the constructor rejects it rather than silently
  /// behaving as a pass-through.
  final int maxEntries;

  /// Approximate upper bound, in bytes, on the total decoded size of resident
  /// tiles. Each tile's contribution is estimated as `width * height * 4`
  /// (RGBA8888), which is the residency cost the engine pays for a decoded
  /// image regardless of the compressed source size.
  ///
  /// Must be large enough to hold at least one maximally-sized tile in
  /// practice; the cache never refuses an insert (a single tile is always
  /// admitted even if it alone exceeds the budget — see [put]) but it will
  /// evict everything else to make room. Must be positive.
  final int maxBytes;

  /// Most-recently-used-ordered store. Iteration order is LRU→MRU; the last
  /// inserted/touched key is the MRU. Encapsulated so the only mutations are
  /// the touch/evict operations defined here.
  final LinkedHashMap<HipsTileId, _CacheEntry> _entries =
      LinkedHashMap<HipsTileId, _CacheEntry>();

  /// Running sum of `_entries.values.map((e) => e.estimatedBytes)`. Maintained
  /// incrementally so [put]/eviction stay O(1) amortised instead of re-summing
  /// the whole map on every mutation.
  int _currentBytes = 0;

  /// Whether [dispose] has been called. After disposal the cache holds no
  /// images and rejects further mutation, surfacing use-after-dispose as a
  /// [StateError] rather than silently corrupting accounting.
  bool _disposed = false;

  /// Creates a cache bounded by [maxEntries] resident tiles and [maxBytes]
  /// approximate decoded bytes.
  ///
  /// Both limits must be strictly positive; passing a non-positive limit is a
  /// configuration bug and throws [ArgumentError] rather than degrading to an
  /// unbounded or do-nothing cache.
  HipsTileCache({required this.maxEntries, required this.maxBytes}) {
    if (maxEntries < 1) {
      throw ArgumentError.value(
        maxEntries,
        'maxEntries',
        'must be >= 1; a cache that can hold no tiles is invalid',
      );
    }
    if (maxBytes < 1) {
      throw ArgumentError.value(
        maxBytes,
        'maxBytes',
        'must be >= 1; a cache with no byte budget is invalid',
      );
    }
  }

  /// Number of tiles currently resident.
  int get length => _entries.length;

  /// Whether the cache currently holds no tiles.
  bool get isEmpty => _entries.isEmpty;

  /// Whether the cache currently holds at least one tile.
  bool get isNotEmpty => _entries.isNotEmpty;

  /// Approximate total decoded bytes of all resident tiles. Always equals the
  /// sum of every resident tile's `width * height * 4`.
  int get currentBytes => _currentBytes;

  /// The resident keys in LRU→MRU order (least-recently-used first). Primarily
  /// for tests and diagnostics; the returned iterable is a snapshot list and
  /// is safe to iterate while the cache mutates.
  List<HipsTileId> get keysByRecency {
    _assertNotDisposed();
    return List<HipsTileId>.unmodifiable(_entries.keys);
  }

  /// Whether a tile is resident **without** affecting recency.
  ///
  /// Use this for de-duplicating in-flight fetch requests: checking
  /// presence must not promote a tile to MRU, otherwise a flurry of
  /// "is it loaded yet?" probes would keep stale tiles alive.
  bool contains(HipsTileId id) {
    _assertNotDisposed();
    return _entries.containsKey(id);
  }

  /// Returns the decoded image for [id], promoting it to most-recently-used,
  /// or `null` if it is not resident.
  ///
  /// The returned [ui.Image] is **borrowed**: it remains owned by the cache
  /// and may be disposed by a later eviction. Do not call [ui.Image.dispose]
  /// on it and do not retain it past the current frame.
  ui.Image? get(HipsTileId id) {
    _assertNotDisposed();
    final entry = _entries.remove(id);
    if (entry == null) {
      return null;
    }
    // Re-insert at the MRU end to record the access.
    _entries[id] = entry;
    return entry.image;
  }

  /// Inserts or replaces the decoded [image] for [id], promoting it to
  /// most-recently-used, then evicts LRU tiles until both bounds hold.
  ///
  /// The cache **takes ownership** of [image]. If an image was already stored
  /// under [id] and it is a *different* instance, the previous image is
  /// disposed (a no-op replace with the identical instance is tolerated and
  /// leaves the single owned reference intact). After this call the new image
  /// is owned by the cache; the caller must not dispose it.
  ///
  /// A single tile is always admitted even if its own estimated size exceeds
  /// [maxBytes] — refusing to cache a tile the caller needs to paint would
  /// produce a blank tile, which violates the never-blank invariant. In that
  /// degenerate case every other tile is evicted and the oversized tile is the
  /// sole resident; it will itself be evicted on the next [put].
  void put(HipsTileId id, ui.Image image) {
    _assertNotDisposed();

    final estimated = _estimateBytes(image);

    final existing = _entries.remove(id);
    if (existing != null) {
      _currentBytes -= existing.estimatedBytes;
      if (!identical(existing.image, image)) {
        existing.image.dispose();
      }
    }

    _entries[id] = _CacheEntry(image: image, estimatedBytes: estimated);
    _currentBytes += estimated;

    _evictToBounds();
  }

  /// Removes [id] if present, disposing its image, and returns whether a tile
  /// was removed. Does not affect the recency of other entries.
  bool remove(HipsTileId id) {
    _assertNotDisposed();
    final entry = _entries.remove(id);
    if (entry == null) {
      return false;
    }
    _currentBytes -= entry.estimatedBytes;
    entry.image.dispose();
    return true;
  }

  /// Evicts and disposes every resident tile, leaving an empty but usable
  /// cache. Used when switching surveys, where no prior-survey tile is ever a
  /// valid lower-LOD fallback.
  void clear() {
    _assertNotDisposed();
    _disposeAllEntries();
  }

  /// Returns an immutable, point-in-time view of the resident tiles for a
  /// painter to read during a single frame, **without** disturbing recency.
  ///
  /// Snapshotting must not reorder the LRU — painting a frame is a read, not a
  /// usage signal that should keep tiles alive (LOD selection drives which
  /// tiles are worth keeping, via [get] on the fetch path). The returned map
  /// is unmodifiable and detached from later cache mutations: entries it
  /// references stay valid for the duration of the frame because eviction only
  /// occurs on the synchronous [put]/[remove]/[clear]/[dispose] paths, none of
  /// which can interleave with a paint pass on the single Dart isolate.
  HipsTileCacheSnapshot snapshot() {
    _assertNotDisposed();
    return HipsTileCacheSnapshot._(
      Map<HipsTileId, ui.Image>.unmodifiable(<HipsTileId, ui.Image>{
        for (final entry in _entries.entries) entry.key: entry.value.image,
      }),
    );
  }

  /// Permanently disposes the cache and every resident image. After disposal
  /// all operations except [isDisposed] throw [StateError].
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposeAllEntries();
    _disposed = true;
  }

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  // internals

  /// Evicts least-recently-used tiles until both [maxEntries] and [maxBytes]
  /// are satisfied, while keeping at least one tile resident so a freshly
  /// inserted oversized tile is never evicted by its own insertion.
  void _evictToBounds() {
    while (_entries.length > 1 &&
        (_entries.length > maxEntries || _currentBytes > maxBytes)) {
      final lruKey = _entries.keys.first;
      final evicted = _entries.remove(lruKey)!;
      _currentBytes -= evicted.estimatedBytes;
      evicted.image.dispose();
    }
  }

  void _disposeAllEntries() {
    for (final entry in _entries.values) {
      entry.image.dispose();
    }
    _entries.clear();
    _currentBytes = 0;
  }

  static int _estimateBytes(ui.Image image) {
    // RGBA8888 residency cost. width/height are logical decoded pixels.
    return image.width * image.height * 4;
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError('HipsTileCache has been disposed and cannot be used');
    }
  }
}

/// An immutable, point-in-time view of the tiles resident in a [HipsTileCache],
/// handed to a painter so it can composite without touching the live cache.
///
/// The wrapped map is unmodifiable; the [ui.Image] values are borrowed from the
/// cache and valid for the frame the snapshot was taken in (see
/// [HipsTileCache.snapshot]).
class HipsTileCacheSnapshot {
  final Map<HipsTileId, ui.Image> _images;

  const HipsTileCacheSnapshot._(this._images);

  /// An empty snapshot, useful as an initial value before any tile loads.
  static const HipsTileCacheSnapshot empty = HipsTileCacheSnapshot._(
    <HipsTileId, ui.Image>{},
  );

  /// Number of tiles in the snapshot.
  int get length => _images.length;

  /// Whether the snapshot contains no tiles.
  bool get isEmpty => _images.isEmpty;

  /// Whether the snapshot contains at least one tile.
  bool get isNotEmpty => _images.isNotEmpty;

  /// The decoded image for [id] in this snapshot, or `null` if absent.
  ui.Image? operator [](HipsTileId id) => _images[id];

  /// Whether [id] is present in this snapshot.
  bool contains(HipsTileId id) => _images.containsKey(id);

  /// The tile ids present in this snapshot.
  Iterable<HipsTileId> get ids => _images.keys;

  /// The (id, image) pairs present in this snapshot.
  Iterable<MapEntry<HipsTileId, ui.Image>> get entries => _images.entries;
}

/// A single resident tile: its decoded image plus the cached byte estimate so
/// eviction accounting never re-reads [ui.Image] dimensions (which can vary in
/// cost across engine versions) and stays consistent with what was added.
class _CacheEntry {
  final ui.Image image;
  final int estimatedBytes;

  const _CacheEntry({required this.image, required this.estimatedBytes});
}
