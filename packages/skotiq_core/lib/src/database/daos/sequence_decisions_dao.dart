import 'package:drift/drift.dart';

import '../database.dart';

part 'sequence_decisions_dao.g.dart';

/// Reads and writes for the replay decision log (`sequence_decisions`).
@DriftAccessor(include: {'../schema/run_records.drift'})
class SequenceDecisionsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$SequenceDecisionsDaoMixin {
  SequenceDecisionsDao(super.db);

  /// Returns the new row's id.
  Future<int> insertDecision(SequenceDecisionsCompanion decision) =>
      into(sequenceDecisions).insert(decision);

  Future<int> deleteForRun(int sequenceRunId) => (delete(
    sequenceDecisions,
  )..where((d) => d.sequenceRunId.equals(sequenceRunId))).go();

  Future<int> deleteAll() => delete(sequenceDecisions).go();

  Future<int> deleteOlderThan(int timestampUnixMs) => (delete(
    sequenceDecisions,
  )..where((d) => d.timestampUnixMs.isSmallerThanValue(timestampUnixMs))).go();

  /// A run's decisions in the order they were made, optionally only those of
  /// one [category] (a `DecisionCategory` wire key).
  Future<List<SequenceDecisionRow>> decisionsForRun(
    int sequenceRunId, {
    String? category,
  }) {
    final query = select(sequenceDecisions)
      ..where((d) => d.sequenceRunId.equals(sequenceRunId))
      ..orderBy([
        (d) => OrderingTerm.asc(d.timestampUnixMs),
        (d) => OrderingTerm.asc(d.id),
      ]);
    if (category != null) {
      query.where((d) => d.category.equals(category));
    }
    return query.get();
  }

  Future<int> countAll() => _count(null);

  Future<int> countForRun(int sequenceRunId) => _count(sequenceRunId);

  Future<int> _count(int? sequenceRunId) async {
    final count = sequenceDecisions.id.count();
    final query = selectOnly(sequenceDecisions)..addColumns([count]);
    if (sequenceRunId != null) {
      query.where(sequenceDecisions.sequenceRunId.equals(sequenceRunId));
    }
    return (await query.getSingle()).read(count) ?? 0;
  }
}
