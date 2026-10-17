import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/sequences.dart';

part 'sequence_checkpoints_dao.g.dart';

@DriftAccessor(tables: [SequenceCheckpoints, Sequences])
class SequenceCheckpointsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$SequenceCheckpointsDaoMixin {
  SequenceCheckpointsDao(super.db);

  /// Save or update a checkpoint for a sequence
  /// Uses upsert to ensure only one checkpoint per sequence
  Future<void> saveCheckpoint(SequenceCheckpointsCompanion checkpoint) async {
    await into(sequenceCheckpoints).insertOnConflictUpdate(checkpoint);
  }

  /// Get the latest checkpoint for a sequence
  Future<SequenceCheckpoint?> getCheckpoint(int sequenceId) {
    return (select(
      sequenceCheckpoints,
    )..where((c) => c.sequenceId.equals(sequenceId))).getSingleOrNull();
  }

  /// Watch checkpoint for a sequence
  Stream<SequenceCheckpoint?> watchCheckpoint(int sequenceId) {
    return (select(
      sequenceCheckpoints,
    )..where((c) => c.sequenceId.equals(sequenceId))).watchSingleOrNull();
  }

  /// Delete checkpoint for a sequence (after successful completion)
  Future<int> deleteCheckpoint(int sequenceId) {
    return (delete(
      sequenceCheckpoints,
    )..where((c) => c.sequenceId.equals(sequenceId))).go();
  }

  /// Update checkpoint progress
  Future<void> updateProgress({
    required int sequenceId,
    required int completedFrames,
    required int totalFrames,
    required int currentTargetIndex,
  }) {
    return (update(
      sequenceCheckpoints,
    )..where((c) => c.sequenceId.equals(sequenceId))).write(
      SequenceCheckpointsCompanion(
        completedFrames: Value(completedFrames),
        totalFrames: Value(totalFrames),
        currentTargetIndex: Value(currentTargetIndex),
        checkpointedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Update current node in execution
  Future<void> updateCurrentNode({
    required int sequenceId,
    required String currentNodeId,
    String? stateJson,
  }) {
    return (update(
      sequenceCheckpoints,
    )..where((c) => c.sequenceId.equals(sequenceId))).write(
      SequenceCheckpointsCompanion(
        currentNodeId: Value(currentNodeId),
        stateJson: Value(stateJson ?? '{}'),
        checkpointedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Get all checkpoints (for debugging/admin purposes)
  Future<List<SequenceCheckpoint>> getAllCheckpoints() {
    return (select(
      sequenceCheckpoints,
    )..orderBy([(c) => OrderingTerm.desc(c.checkpointedAt)])).get();
  }

  /// Delete all checkpoints (cleanup/reset operation)
  Future<int> deleteAllCheckpoints() {
    return delete(sequenceCheckpoints).go();
  }

  /// Check if a sequence has an active checkpoint
  Future<bool> hasCheckpoint(int sequenceId) async {
    final checkpoint = await getCheckpoint(sequenceId);
    return checkpoint != null;
  }
}
