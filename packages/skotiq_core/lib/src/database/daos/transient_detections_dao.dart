import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/database_provider.dart';
import '../database.dart';
import '../tables/transient_detections.dart';

part 'transient_detections_dao.g.dart';

/// Data access for [TransientDetections] — the Pillar B ("First Light")
/// difference-imaging transient log.
///
/// Feeds read **newest-first**: a fresh detection is the one a user wants to
/// triage. Dismissed rows are kept (never deleted) so the difference pipeline
/// can suppress a residual a human has already judged an artefact rather than
/// re-announcing it every clear night — [dismissedTileSignatures] exposes that
/// suppression set.
@DriftAccessor(tables: [TransientDetections])
class TransientDetectionsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$TransientDetectionsDaoMixin {
  TransientDetectionsDao(super.db);

  /// Insert one detection row, returning its assigned id.
  Future<int> insertDetection(TransientDetectionsCompanion detection) {
    return into(transientDetections).insert(detection);
  }

  /// Insert a batch of detections from a single scan in one transaction.
  Future<void> insertDetections(
    List<TransientDetectionsCompanion> detections,
  ) async {
    if (detections.isEmpty) return;
    await batch((b) => b.insertAll(transientDetections, detections));
  }

  /// All detections for a session, newest-first.
  Future<List<TransientDetectionRow>> detectionsForSession(int sessionId) {
    return (select(transientDetections)
          ..where((t) => t.sessionId.equals(sessionId))
          ..orderBy([(t) => OrderingTerm.desc(t.detectedAt)]))
        .get();
  }

  /// Reactive newest-first feed for a session.
  Stream<List<TransientDetectionRow>> watchDetectionsForSession(int sessionId) {
    return (select(transientDetections)
          ..where((t) => t.sessionId.equals(sessionId))
          ..orderBy([(t) => OrderingTerm.desc(t.detectedAt)]))
        .watch();
  }

  /// Every detection (across sessions), newest-first — backs the standalone
  /// transient gallery and the export hub's candidate snapshot.
  Future<List<TransientDetectionRow>> allDetections() {
    return (select(
      transientDetections,
    )..orderBy([(t) => OrderingTerm.desc(t.detectedAt)])).get();
  }

  /// Reactive variant of [allDetections].
  Stream<List<TransientDetectionRow>> watchAllDetections() {
    return (select(
      transientDetections,
    )..orderBy([(t) => OrderingTerm.desc(t.detectedAt)])).watch();
  }

  /// The most-recent [limit] detections across sessions, newest-first — the
  /// bounded feed/REST read that replaces the all-time [watchAllDetections]
  /// scan on the night-companion surface. Backed by `idx_transient_detections_detected`
  /// so the order-by + limit is an index range, not a full sort of all history.
  Stream<List<TransientDetectionRow>> watchRecentDetections({int limit = 200}) {
    return customSelect(
      'SELECT * FROM transient_detections '
      'ORDER BY detected_at DESC LIMIT ?',
      variables: [Variable<int>(limit)],
      readsFrom: {transientDetections},
    ).watch().map(_mapSkippingUndecodable);
  }

  /// Map raw result rows to [TransientDetectionRow]s, dropping any row that
  /// cannot be decoded instead of failing the whole read.
  ///
  /// SQLite's type affinity permits a TEXT value in an INTEGER column, so a
  /// single row written by an external tool with e.g. `tile_id = 'tile-042'`
  /// made the generated mapper throw `FormatException: Invalid radix-10
  /// number` — and that killed the entire First Light candidate feed, not just
  /// the bad row. Worse, a drift stream query that has thrown stays thrown for
  /// the life of the process: its cached query stream replays the failure to
  /// every later subscriber, so the surface could not recover even after the
  /// offending value was corrected (verified in-process — an in-app UPDATE plus
  /// `ref.invalidate` still read back the same error).
  ///
  /// One corrupt row must cost that row, not the feature.
  List<TransientDetectionRow> _mapSkippingUndecodable(List<QueryRow> rows) {
    final out = <TransientDetectionRow>[];
    for (final row in rows) {
      try {
        out.add(transientDetections.map(row.data));
      } catch (error) {
        // No logger is wired into the DAO layer; surface it on the debug
        // console rather than vanishing the row silently.
        // ignore: avoid_print
        print(
          'transient_detections: skipping undecodable row '
          '${row.data['id']}: $error',
        );
      }
    }
    return out;
  }

  /// Future variant of [watchRecentDetections] for the REST snapshot, with an
  /// [offset] for paging older history on demand.
  Future<List<TransientDetectionRow>> recentDetections({
    int limit = 200,
    int offset = 0,
  }) async {
    // Same undecodable-row tolerance as the watch variant — see
    // [_mapSkippingUndecodable].
    final rows = await customSelect(
      'SELECT * FROM transient_detections '
      'ORDER BY detected_at DESC LIMIT ? OFFSET ?',
      variables: [Variable<int>(limit), Variable<int>(offset)],
      readsFrom: {transientDetections},
    ).get();
    return _mapSkippingUndecodable(rows);
  }

  /// A single detection by id, or null if it has been removed.
  Future<TransientDetectionRow?> detectionById(int id) {
    return (select(
      transientDetections,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Coarse `(tileId, rounded-ra, rounded-dec)` signatures of dismissed
  /// detections. The difference pipeline matches a new residual against this
  /// set (within a small positional tolerance, done in the service) to skip
  /// re-announcing a residual a human has already dismissed as an artefact.
  Future<List<TransientDetectionRow>> dismissedDetections() {
    return (select(
      transientDetections,
    )..where((t) => t.dismissed.equals(true))).get();
  }

  /// Dismissed detections scoped to the tiles a frame actually covers. The
  /// per-frame suppression check only needs the dismissed signatures on the
  /// handful of [tileIds] the current solve touched, so the read is an index
  /// seek on `idx_transient_detections_dismissed (dismissed, tile_id)` rather
  /// than an all-time scan. Returns empty for an empty [tileIds] (nothing to
  /// suppress against).
  Future<List<TransientDetectionRow>> dismissedDetectionsForTiles(
    Iterable<int> tileIds,
  ) {
    final ids = tileIds.toList(growable: false);
    if (ids.isEmpty) return Future.value(const <TransientDetectionRow>[]);
    return (select(
      transientDetections,
    )..where((t) => t.dismissed.equals(true) & t.tileId.isIn(ids))).get();
  }

  /// Confirmed discoveries: reviewed AND not dismissed, newest-first. The
  /// dismissed guard keeps triaged artefacts out of the curated submit list.
  /// Backed by `idx_transient_detections_confirmed
  /// (reviewed, dismissed, detected_at)`.
  Future<List<TransientDetectionRow>> confirmedDetections({int? limit}) {
    final q = select(transientDetections)
      ..where((t) => t.reviewed.equals(true) & t.dismissed.equals(false))
      ..orderBy([(t) => OrderingTerm.desc(t.detectedAt)]);
    if (limit != null) q.limit(limit);
    return q.get();
  }

  /// Prune the append-only transient log so it does not grow unbounded across a
  /// multi-season run. Deletes triaged-artefact history — rows that are
  /// [TransientDetections.dismissed] (a human already judged them noise) OR
  /// reviewed-but-not-a-named-discovery — older than [olderThan]. Unreviewed
  /// rows and confirmed named discoveries are always kept (a possible transient
  /// must never be silently reclaimed). Returns the number of rows deleted so
  /// the caller can record it against the retention marker.
  Future<int> pruneDetections({
    required DateTime olderThan,
    bool keepUnreviewedUnnamed = true,
  }) {
    return (delete(transientDetections)..where((t) {
          final aged = t.detectedAt.isSmallerThanValue(olderThan);
          // Always reclaimable: an explicitly dismissed artefact.
          var reclaimable = t.dismissed.equals(true);
          if (!keepUnreviewedUnnamed) {
            // Also reclaim reviewed rows that resolved to a catalog object
            // (not a novel discovery) — kept by default to be conservative.
            reclaimable =
                reclaimable |
                (t.reviewed.equals(true) & t.catalogMatch.isNotNull());
          }
          return aged & reclaimable;
        }))
        .go();
  }

  /// All detections whose sky position falls within [radiusDeg] of
  /// ([raDeg], [decDeg]), oldest-first — the cross-night history of a single
  /// physical transient. The same source re-detected on three nights produces
  /// three rows (one per frame); grouping them by position is what turns three
  /// unrelated cards into one Δmag-vs-time light curve and makes
  /// "Confirmed (seen 3 nights)" meaningful.
  ///
  /// A coarse RA/Dec bounding box (cheap, index-friendly on
  /// `idx_transient_detections_tile` / the lat band) prefilters in SQL; the
  /// caller refines to a true angular separation. The RA box is widened by
  /// `1/cos(dec)` so it stays correct away from the equator (skipped near the
  /// poles where the term blows up — the box just degrades to all-RA there,
  /// still correct, just less selective).
  Future<List<TransientDetectionRow>> detectionsNear(
    double raDeg,
    double decDeg, {
    double radiusDeg = 0.02,
  }) {
    final cosDec = math.cos(decDeg * math.pi / 180.0);
    final raPad = cosDec.abs() < 1e-3 ? 180.0 : radiusDeg / cosDec.abs();
    final raLo = raDeg - raPad;
    final raHi = raDeg + raPad;
    final decLo = decDeg - radiusDeg;
    final decHi = decDeg + radiusDeg;
    return (select(transientDetections)
          ..where(
            (t) =>
                t.decDeg.isBiggerOrEqualValue(decLo) &
                t.decDeg.isSmallerOrEqualValue(decHi) &
                t.raDeg.isBiggerOrEqualValue(raLo) &
                t.raDeg.isSmallerOrEqualValue(raHi),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.detectedAt)]))
        .get();
  }

  /// Mark a detection reviewed; [dismissed] flags it as a triaged artefact.
  Future<void> markReviewed(int id, {bool dismissed = false}) async {
    await (update(transientDetections)..where((t) => t.id.equals(id))).write(
      TransientDetectionsCompanion(
        reviewed: const Value(true),
        dismissed: Value(dismissed),
      ),
    );
  }
}

/// Riverpod provider for [TransientDetectionsDao].
final transientDetectionsDaoProvider = Provider<TransientDetectionsDao>((ref) {
  return TransientDetectionsDao(ref.watch(databaseProvider));
});
