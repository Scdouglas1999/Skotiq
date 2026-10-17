import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/database_provider.dart';
import '../database.dart';
import '../tables/living_sky_retention.dart';

part 'living_sky_retention_dao.g.dart';

/// Data access for [LivingSkyRetention] — the Wave 3 per-pillar retention
/// bookkeeping ("where did the last prune get to").
///
/// One row per [LivingSkyRetentionScope]. A maintenance sweep reads its marker
/// with [getMarker], does its incremental work from the high-water, then
/// records progress with [recordPrune] (a keyed upsert that only touches the
/// fields the sweep advanced). This keeps each pillar's pruning incremental and
/// cheap on the constrained appliance target instead of re-scanning all-time
/// history on every maintenance pass.
@DriftAccessor(tables: [LivingSkyRetention])
class LivingSkyRetentionDao extends DatabaseAccessor<SkotiqDatabase>
    with _$LivingSkyRetentionDaoMixin {
  LivingSkyRetentionDao(super.db);

  /// The retention marker for [scope], or null when that sweep has never run.
  Future<LivingSkyRetentionRow?> getMarker(String scope) {
    return (select(
      livingSkyRetention,
    )..where((r) => r.scope.equals(scope))).getSingleOrNull();
  }

  /// Record one maintenance pass for [scope]. Keyed update-or-insert on the
  /// unique [LivingSkyRetention.scope]; only the provided high-waters are
  /// advanced. [reclaimed] is *added* to the running [LivingSkyRetention.prunedCount]
  /// (pass 0 / omit for a no-op sweep that only advances the marker).
  Future<void> recordPrune(
    String scope, {
    DateTime? lastPrunedAt,
    int? lastPrunedId,
    int reclaimed = 0,
    String? note,
  }) {
    return transaction(() async {
      final existing = await getMarker(scope);
      final now = DateTime.now();
      if (existing != null) {
        await (update(
          livingSkyRetention,
        )..where((r) => r.id.equals(existing.id))).write(
          LivingSkyRetentionCompanion(
            lastPrunedAt: lastPrunedAt == null
                ? const Value.absent()
                : Value(lastPrunedAt),
            lastPrunedId: lastPrunedId == null
                ? const Value.absent()
                : Value(lastPrunedId),
            prunedCount: Value(existing.prunedCount + reclaimed),
            note: note == null ? const Value.absent() : Value(note),
            updatedAt: Value(now),
          ),
        );
        return;
      }
      await into(livingSkyRetention).insert(
        LivingSkyRetentionCompanion.insert(
          scope: scope,
          lastPrunedAt: Value(lastPrunedAt),
          lastPrunedId: Value(lastPrunedId),
          prunedCount: Value(reclaimed),
          note: Value(note),
          updatedAt: Value(now),
        ),
      );
    });
  }
}

/// Riverpod provider for [LivingSkyRetentionDao].
final livingSkyRetentionDaoProvider = Provider<LivingSkyRetentionDao>((ref) {
  return LivingSkyRetentionDao(ref.watch(databaseProvider));
});
