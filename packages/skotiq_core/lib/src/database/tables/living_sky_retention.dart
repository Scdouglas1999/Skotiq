import 'package:drift/drift.dart';

/// Retention bookkeeping for the age/size-bounded maintenance sweeps over
/// unbounded append-only state (per-tile sidecars and the cutout/delta cache,
/// the `transient_detections` log, swarm `.nst`/`.fits` blobs).
///
/// One row per [scope] (a stable string key — see [LivingSkyRetentionScope]),
/// keyed unique so a sweep upserts its progress and resumes from the
/// high-water instead of re-scanning all history. The columns are generic (a
/// timestamp high-water, an int high-water, a free-form note) so every sweep
/// records its own kind of progress without a bespoke table.
///
/// Additive and FK-free: a retention marker must survive the deletion of
/// anything it tracks, which is the point of the sweep.
@DataClassName('LivingSkyRetentionRow')
@TableIndex(
  name: 'idx_living_sky_retention_scope',
  unique: true,
  columns: {#scope},
)
class LivingSkyRetention extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Stable sweep key — one of [LivingSkyRetentionScope]'s constants.
  TextColumn get scope => text()();

  /// Timestamp high-water the sweep has pruned up to (null = never run).
  DateTimeColumn get lastPrunedAt => dateTime().nullable()();

  /// Monotonic id high-water the sweep has considered (null = never run).
  IntColumn get lastPrunedId => integer().nullable()();

  /// Running count of records reclaimed across all runs of this sweep.
  IntColumn get prunedCount => integer().withDefault(const Constant(0))();

  /// Free-form note the sweep owns (e.g. bytes reclaimed, retention window).
  TextColumn get note => text().nullable()();

  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// Stable [LivingSkyRetention.scope] keys, one per Wave 3 sweep. Kept as
/// constants (not an enum) so a forward-compatible reader/writer degrades
/// gracefully and a new sweep can be added without a schema change.
abstract final class LivingSkyRetentionScope {
  /// Pillar B — `transient_detections` age-out of dismissed/artefact rows.
  static const String transientDetections = 'transient_detections';

  /// Pillar A — `<atlasRoot>/cache` cutout/delta LRU sweep.
  static const String atlasCache = 'atlas_cache';

  /// Pillar C — `<atlasRoot>/swarm` pull/delta blob sweep.
  static const String swarmBlobs = 'swarm_blobs';
}
