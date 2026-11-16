import 'package:drift/drift.dart';

import '../stores/host_records.dart';
import '../database.dart';
import '../tables/targets.dart';
import '../../models/darkroom/target_standing.dart';

part 'targets_dao.g.dart';

@DriftAccessor(tables: [Targets])
class TargetsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$TargetsDaoMixin
    implements TargetLibrary {
  TargetsDao(super.db);

  /// Saved targets the cleanup in Plan > Targets may remove: unused by
  /// [targetStanding] (nothing was captured for them), and nothing else the
  /// user set up refers to them: not a favorite, no integration goal, no
  /// imaging session and in no group.
  Future<List<int>> _untrackedTargetIds() async {
    Future<Set<int>> referencing(String table) async => {
      for (final row in await customSelect(
        'SELECT DISTINCT target_id FROM $table WHERE target_id IS NOT NULL',
      ).get())
        row.read<int>('target_id'),
    };
    final frames = <int, int>{
      for (final row in await customSelect(
        'SELECT target_id, COUNT(*) AS n FROM captured_images '
        'WHERE target_id IS NOT NULL GROUP BY target_id',
      ).get())
        row.read<int>('target_id'): row.read<int>('n'),
    };
    final planned = {
      ...await referencing('imaging_sessions'),
      ...await referencing('integration_goals'),
      ...await referencing('project_targets'),
    };
    return [
      for (final t in await getAllTargets())
        if (targetStanding(
                  TargetCaptures(frames: frames[t.id] ?? 0),
                  const ProjectRule(),
                ) ==
                TargetStanding.unused &&
            !t.isFavorite &&
            t.goalIntegrationSecs <= 0 &&
            t.capturedSubs == 0 &&
            t.totalIntegrationSecs == 0 &&
            !planned.contains(t.id))
          t.id,
    ];
  }

  /// How many saved targets [deleteUntrackedTargets] would remove.
  @override
  Future<int> countUntrackedTargets() async =>
      (await _untrackedTargetIds()).length;

  /// Permanently deletes the saved targets nothing was captured for and
  /// nothing refers to; returns how many. Callers confirm with the user
  /// first.
  @override
  Future<int> deleteUntrackedTargets() async {
    final ids = await _untrackedTargetIds();
    if (ids.isEmpty) return 0;
    return (delete(targets)..where((t) => t.id.isIn(ids))).go();
  }

  @override
  Future<List<DbTarget>> getAllTargets() => select(targets).get();

  @override
  Stream<List<DbTarget>> watchAllTargets() => select(targets).watch();

  Future<List<DbTarget>> getFavoriteTargets() {
    return (select(targets)..where((t) => t.isFavorite.equals(true))).get();
  }

  @override
  Stream<List<DbTarget>> watchFavoriteTargets() {
    return (select(targets)..where((t) => t.isFavorite.equals(true))).watch();
  }

  Future<DbTarget?> getTargetById(int id) {
    return (select(targets)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Get target by catalog ID (e.g., M42, NGC7000)
  Future<DbTarget?> getTargetByCatalogId(String catalogId) {
    return (select(
      targets,
    )..where((t) => t.catalogId.equals(catalogId))).getSingleOrNull();
  }

  /// Search targets by name
  Future<List<DbTarget>> searchTargets(String query) {
    return (select(
          targets,
        )..where((t) => t.name.like('%$query%') | t.catalogId.like('%$query%')))
        .get();
  }

  Future<List<DbTarget>> getTargetsByType(String objectType) {
    return (select(
      targets,
    )..where((t) => t.objectType.equals(objectType))).get();
  }

  Future<int> createTarget(TargetsCompanion target) {
    return into(targets).insert(target);
  }

  /// `targets.id` for the object a sequence's Target node images, creating the
  /// row the first time that object is actually imaged.
  ///
  /// A Target node built by hand in the sequencer carries no `catalogTargetId`,
  /// so every frame it produced was written with `target_id` NULL: the Session
  /// Report filed a whole night under "Untargeted", per-target integration
  /// goals could never complete, and project tracking counted nothing —
  /// while the FITS `OBJECT` card and the file name both named the target.
  ///
  /// Matched on trimmed, case-insensitive name so re-running the same sequence
  /// keeps accumulating against one row instead of forking a new one per night.
  /// Coordinates are only used when the row has to be created; an existing
  /// row's coordinates are left alone (the library entry, or the planner, owns
  /// them).
  Future<int> findOrCreateByName({
    required String name,
    required double raHours,
    required double decDegrees,
  }) async {
    final trimmed = name.trim();
    final existing =
        await (select(targets)
              ..where((t) => t.name.lower().equals(trimmed.toLowerCase()))
              ..limit(1))
            .getSingleOrNull();
    if (existing != null) return existing.id;

    return createTarget(
      TargetsCompanion.insert(name: trimmed, ra: raHours, dec: decDegrees),
    );
  }

  Future<bool> updateTarget(DbTarget target) {
    return update(targets).replace(target);
  }

  Future<int> deleteTarget(int id) {
    return (delete(targets)..where((t) => t.id.equals(id))).go();
  }

  Future<void> toggleFavorite(int id) async {
    await (update(targets)..where((t) => t.id.equals(id))).write(
      TargetsCompanion.custom(
        isFavorite: targets.isFavorite.caseMatch(
          when: {const Constant(true): const Constant(false)},
          orElse: const Constant(true),
        ),
        updatedAt: Variable(DateTime.now()),
      ),
    );
  }

  Future<void> updateProgress(
    int id, {
    int? capturedSubs,
    double? totalIntegrationSecs,
    double? goalIntegrationSecs,
    String? filterProgress,
  }) async {
    final updates = TargetsCompanion(
      capturedSubs: capturedSubs != null
          ? Value(capturedSubs)
          : const Value.absent(),
      totalIntegrationSecs: totalIntegrationSecs != null
          ? Value(totalIntegrationSecs)
          : const Value.absent(),
      goalIntegrationSecs: goalIntegrationSecs != null
          ? Value(goalIntegrationSecs)
          : const Value.absent(),
      filterProgress: filterProgress != null
          ? Value(filterProgress)
          : const Value.absent(),
      updatedAt: Value(DateTime.now()),
    );

    await (update(targets)..where((t) => t.id.equals(id))).write(updates);
  }

  Future<List<DbTarget>> getTargetsByPriority() {
    return (select(
      targets,
    )..orderBy([(t) => OrderingTerm.desc(t.priority)])).get();
  }
}
