import 'package:drift/drift.dart';

import '../database.dart';

part 'conversational_builds_dao.g.dart';

/// Reads and writes for the conversational-build history.
@DriftAccessor(include: {'../schema/run_records.drift'})
class ConversationalBuildsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$ConversationalBuildsDaoMixin {
  ConversationalBuildsDao(super.db);

  Future<void> insertBuild(ConversationalBuildsCompanion build) =>
      into(conversationalBuilds).insert(build);

  /// Returns how many rows were updated (0 when the id is unknown).
  Future<int> setAcceptedSequence(String id, String sequenceId) =>
      (update(conversationalBuilds)..where((b) => b.id.equals(id))).write(
        ConversationalBuildsCompanion(acceptedSequenceId: Value(sequenceId)),
      );

  Future<int> deleteBuild(String id) =>
      (delete(conversationalBuilds)..where((b) => b.id.equals(id))).go();

  /// The newest [limit] builds, newest first.
  Future<List<ConversationalBuildRow>> recentBuilds(int limit) =>
      (select(conversationalBuilds)
            ..orderBy([(b) => OrderingTerm.desc(b.createdAt)])
            ..limit(limit))
          .get();
}
