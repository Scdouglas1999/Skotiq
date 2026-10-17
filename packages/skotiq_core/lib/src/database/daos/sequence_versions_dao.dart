import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/sequence_versions.dart';

part 'sequence_versions_dao.g.dart';

/// DAO for sequence version history (append / list / load / restore source).
@DriftAccessor(tables: [SequenceVersions])
class SequenceVersionsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$SequenceVersionsDaoMixin {
  SequenceVersionsDao(super.db);

  /// How many versions to retain per sequence. Older versions beyond this
  /// count are pruned on every [appendVersion] so history stays bounded.
  static const int maxVersionsPerSequence = 20;

  /// Append a new version snapshot for [sequenceId], then prune the sequence's
  /// history down to [maxVersionsPerSequence] newest rows. Returns the new
  /// row id.
  ///
  /// Wrapped in a transaction so the insert + prune are atomic — a concurrent
  /// reader never sees the list temporarily over the cap, and a crash mid-call
  /// cannot leave the table both un-appended and partially pruned.
  Future<int> appendVersion({
    required int sequenceId,
    required String snapshotJson,
    String? label,
  }) {
    return transaction(() async {
      final newId = await into(sequenceVersions).insert(
        SequenceVersionsCompanion.insert(
          sequenceId: sequenceId,
          snapshotJson: snapshotJson,
          label: Value(label),
        ),
      );
      await _pruneToCap(sequenceId);
      return newId;
    });
  }

  /// Delete every version of [sequenceId] except the newest
  /// [maxVersionsPerSequence] by `createdAt` (ties broken by `id`).
  Future<void> _pruneToCap(int sequenceId) async {
    final survivors =
        await (select(sequenceVersions)
              ..where((v) => v.sequenceId.equals(sequenceId))
              ..orderBy([
                (v) => OrderingTerm.desc(v.createdAt),
                (v) => OrderingTerm.desc(v.id),
              ])
              ..limit(maxVersionsPerSequence))
            .get();
    if (survivors.length < maxVersionsPerSequence) return;
    final keepIds = survivors.map((v) => v.id).toList();
    await (delete(sequenceVersions)..where(
          (v) => v.sequenceId.equals(sequenceId) & v.id.isNotIn(keepIds),
        ))
        .go();
  }

  /// All versions for a sequence, newest first.
  Future<List<SequenceVersion>> listVersions(int sequenceId) {
    return (select(sequenceVersions)
          ..where((v) => v.sequenceId.equals(sequenceId))
          ..orderBy([
            (v) => OrderingTerm.desc(v.createdAt),
            (v) => OrderingTerm.desc(v.id),
          ]))
        .get();
  }

  /// Reactive variant of [listVersions] for the version-history panel.
  Stream<List<SequenceVersion>> watchVersions(int sequenceId) {
    return (select(sequenceVersions)
          ..where((v) => v.sequenceId.equals(sequenceId))
          ..orderBy([
            (v) => OrderingTerm.desc(v.createdAt),
            (v) => OrderingTerm.desc(v.id),
          ]))
        .watch();
  }

  /// Load a single version by row id (e.g. the one the user picked to
  /// restore). Null when the row no longer exists.
  Future<SequenceVersion?> loadVersion(int id) {
    return (select(
      sequenceVersions,
    )..where((v) => v.id.equals(id))).getSingleOrNull();
  }

  /// Count of stored versions for a sequence — drives the "N versions" badge
  /// without fetching every snapshot blob.
  Future<int> versionCount(int sequenceId) async {
    final countExpr = sequenceVersions.id.count();
    final query = selectOnly(sequenceVersions)
      ..addColumns([countExpr])
      ..where(sequenceVersions.sequenceId.equals(sequenceId));
    final row = await query.getSingle();
    return row.read(countExpr) ?? 0;
  }
}
