import 'package:drift/drift.dart';

import '../database.dart';

part 'frame_forensics_dao.g.dart';

/// Reads and writes for `frame_forensics`: why a frame was rejected.
@DriftAccessor(include: {'../schema/run_records.drift'})
class FrameForensicsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$FrameForensicsDaoMixin {
  FrameForensicsDao(super.db);

  Future<void> insertRecord(FrameForensicsCompanion record) =>
      into(frameForensics).insert(record);

  /// A session's newest [limit] records, newest first.
  Future<List<FrameForensicsRow>> recentForSession(
    String sessionId,
    int limit,
  ) =>
      (select(frameForensics)
            ..where((f) => f.sessionId.equals(sessionId))
            ..orderBy([(f) => OrderingTerm.desc(f.createdAt)])
            ..limit(limit))
          .get();

  /// A run's records, oldest first.
  Future<List<FrameForensicsRow>> forSequenceRun(int sequenceRunId) =>
      (select(frameForensics)
            ..where((f) => f.sequenceRunId.equals(sequenceRunId))
            ..orderBy([(f) => OrderingTerm.asc(f.createdAt)]))
          .get();

  Future<FrameForensicsRow?> newestForCapturedImage(int capturedImageId) =>
      (select(frameForensics)
            ..where((f) => f.capturedImageId.equals(capturedImageId))
            ..orderBy([(f) => OrderingTerm.desc(f.createdAt)])
            ..limit(1))
          .getSingleOrNull();

  /// The newest [limit] records with [likelyCause] (a `LikelyCause` label),
  /// newest first, optionally only those of one run.
  Future<List<FrameForensicsRow>> byCause(
    String likelyCause, {
    int? sequenceRunId,
    required int limit,
  }) {
    final query = select(frameForensics)
      ..where((f) => f.likelyCause.equals(likelyCause))
      ..orderBy([(f) => OrderingTerm.desc(f.createdAt)])
      ..limit(limit);
    if (sequenceRunId != null) {
      query.where((f) => f.sequenceRunId.equals(sequenceRunId));
    }
    return query.get();
  }
}
