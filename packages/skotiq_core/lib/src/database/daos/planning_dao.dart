import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/captured_images.dart';
import '../tables/targets.dart';

part 'planning_dao.g.dart';

/// A catalog target as the scheduler ranks it: [priority] is the project's
/// override when the target is loaded through a project that sets one.
typedef SchedulerTargetRow = ({
  int id,
  String name,
  double ra,
  double dec,
  int priority,
  String? objectType,
  String? notes,
});

/// Reads and writes for the planning and scheduling tables: integration
/// goals, target constraints, horizon profiles, the scheduler queue's removed
/// targets, and projects with their member targets.
@DriftAccessor(
  include: {'../schema/planning.drift'},
  tables: [Targets, CapturedImages],
)
class PlanningDao extends DatabaseAccessor<SkotiqDatabase>
    with _$PlanningDaoMixin {
  PlanningDao(super.db);

  // Integration goals

  Future<int?> integrationGoalId({
    required int targetId,
    required String filter,
    required double exposureSeconds,
  }) async {
    final row =
        await (select(integrationGoals)..where(
              (g) =>
                  g.targetId.equals(targetId) &
                  g.filter.equals(filter) &
                  g.exposureSeconds.equals(exposureSeconds),
            ))
            .getSingleOrNull();
    return row?.id;
  }

  Future<int> insertIntegrationGoal(IntegrationGoalsCompanion goal) =>
      into(integrationGoals).insert(goal);

  Future<void> updateIntegrationGoal(
    int id, {
    required int frameCount,
    required int priority,
  }) => (update(integrationGoals)..where((g) => g.id.equals(id))).write(
    IntegrationGoalsCompanion(
      frameCount: Value(frameCount),
      priority: Value(priority),
    ),
  );

  Future<void> deleteIntegrationGoal(int id) =>
      (delete(integrationGoals)..where((g) => g.id.equals(id))).go();

  Future<void> deleteIntegrationGoalsForTarget(int targetId) => (delete(
    integrationGoals,
  )..where((g) => g.targetId.equals(targetId))).go();

  Future<void> deleteAllIntegrationGoals() => delete(integrationGoals).go();

  Future<List<IntegrationGoalRow>> allIntegrationGoals() =>
      select(integrationGoals).get();

  /// A target's goals, highest priority first, then by filter name.
  Future<List<IntegrationGoalRow>> integrationGoalsForTarget(int targetId) =>
      (select(integrationGoals)
            ..where((g) => g.targetId.equals(targetId))
            ..orderBy([
              (g) => OrderingTerm.desc(g.priority),
              (g) => OrderingTerm.asc(g.filter),
            ]))
          .get();

  /// Accepted light frames on record for a target in a filter. The filter
  /// name is compared without case, because a goal typed as "Lum" has to
  /// count frames the wheel reported as "lum".
  Future<int> acceptedLightFrameCount({
    required int targetId,
    required String filter,
  }) async {
    final count = capturedImages.id.count();
    final query = selectOnly(capturedImages)
      ..addColumns([count])
      ..where(
        capturedImages.targetId.equals(targetId) &
            capturedImages.frameType.equals('light') &
            capturedImages.isAccepted.equals(true) &
            capturedImages.filter.lower().equalsExp(
              Variable.withString(filter).lower(),
            ),
      );
    return (await query.getSingle()).read(count) ?? 0;
  }

  // Target constraints

  Future<int> insertTargetConstraint(TargetConstraintsCompanion constraint) =>
      into(targetConstraints).insert(constraint);

  Future<void> updateTargetConstraint(
    int id, {
    required String kind,
    required String payloadJson,
    required bool enabled,
  }) => (update(targetConstraints)..where((c) => c.id.equals(id))).write(
    TargetConstraintsCompanion(
      kind: Value(kind),
      payloadJson: Value(payloadJson),
      enabled: Value(enabled ? 1 : 0),
    ),
  );

  Future<void> setTargetConstraintEnabled(int id, bool enabled) =>
      (update(targetConstraints)..where((c) => c.id.equals(id))).write(
        TargetConstraintsCompanion(enabled: Value(enabled ? 1 : 0)),
      );

  Future<void> deleteTargetConstraint(int id) =>
      (delete(targetConstraints)..where((c) => c.id.equals(id))).go();

  Future<void> deleteTargetConstraintsForTarget(int targetId) => (delete(
    targetConstraints,
  )..where((c) => c.targetId.equals(targetId))).go();

  Future<void> deleteAllTargetConstraints() => delete(targetConstraints).go();

  Future<List<TargetConstraintRow>> allTargetConstraints() =>
      select(targetConstraints).get();

  Future<List<TargetConstraintRow>> enabledTargetConstraints() =>
      (select(targetConstraints)..where((c) => c.enabled.equals(1))).get();

  Future<List<TargetConstraintRow>> targetConstraintsForTarget(int targetId) =>
      (select(
        targetConstraints,
      )..where((c) => c.targetId.equals(targetId))).get();

  // Horizon profiles

  Future<List<HorizonProfileRow>> allHorizonProfiles() =>
      select(horizonProfiles).get();

  // Scheduler queue

  /// Records [targetId] as removed from the scheduler queue. Selected from
  /// `targets` so an id that is no longer in the catalog is a no-op rather
  /// than a foreign-key failure.
  Future<void> removeFromSchedulerQueue(int targetId, int removedAtSeconds) =>
      _removeFromSchedulerQueue(removedAtSeconds, targets.id.equals(targetId));

  /// Records every target in the catalog right now as removed.
  Future<void> removeAllFromSchedulerQueue(int removedAtSeconds) =>
      _removeFromSchedulerQueue(removedAtSeconds, null);

  Future<void> _removeFromSchedulerQueue(
    int removedAtSeconds,
    Expression<bool>? which,
  ) {
    final removedAt = Variable.withInt(removedAtSeconds);
    final catalog = selectOnly(targets)..addColumns([targets.id, removedAt]);
    if (which != null) catalog.where(which);
    return into(schedulerRemovedTargets).insertFromSelect(
      catalog,
      columns: {
        schedulerRemovedTargets.targetId: targets.id,
        schedulerRemovedTargets.removedAt: removedAt,
      },
      mode: InsertMode.insertOrReplace,
    );
  }

  Future<void> readmitToSchedulerQueue(int targetId) => (delete(
    schedulerRemovedTargets,
  )..where((r) => r.targetId.equals(targetId))).go();

  Future<Set<int>> schedulerRemovedTargetIds() async {
    final rows = await select(schedulerRemovedTargets).get();
    return {for (final row in rows) row.targetId};
  }

  // Projects

  Future<int> insertProject(ProjectsCompanion project) =>
      into(projects).insert(project);

  Future<void> updateProject(int id, ProjectsCompanion changes) =>
      (update(projects)..where((p) => p.id.equals(id))).write(changes);

  Future<void> deleteProject(int id) =>
      (delete(projects)..where((p) => p.id.equals(id))).go();

  /// All projects, most recently updated first.
  Future<List<ProjectRow>> allProjects() =>
      (select(projects)..orderBy([
            (p) => OrderingTerm.desc(p.updatedAt),
            (p) => OrderingTerm.desc(p.id),
          ]))
          .get();

  Future<ProjectRow?> project(int id) =>
      (select(projects)..where((p) => p.id.equals(id))).getSingleOrNull();

  /// Adds a member; a target that is already a member keeps its row.
  Future<void> addProjectTarget(ProjectTargetsCompanion membership) =>
      into(projectTargets).insert(membership, mode: InsertMode.insertOrIgnore);

  Future<void> removeProjectTarget({
    required int projectId,
    required int targetId,
  }) =>
      (delete(projectTargets)..where(
            (m) => m.projectId.equals(projectId) & m.targetId.equals(targetId),
          ))
          .go();

  Future<void> setProjectTargetPriority({
    required int projectId,
    required int targetId,
    required int? priorityOverride,
  }) =>
      (update(projectTargets)..where(
            (m) => m.projectId.equals(projectId) & m.targetId.equals(targetId),
          ))
          .write(
            ProjectTargetsCompanion(priorityOverride: Value(priorityOverride)),
          );

  /// A project's members, oldest first.
  Future<List<ProjectTargetRow>> projectTargetsOf(int projectId) =>
      (select(projectTargets)
            ..where((m) => m.projectId.equals(projectId))
            ..orderBy([
              (m) => OrderingTerm.asc(m.addedAt),
              (m) => OrderingTerm.asc(m.id),
            ]))
          .get();

  // Scheduler candidates

  /// The targets the scheduler considers, highest priority first then by
  /// name: the whole catalog, or with [projectId] that project's members
  /// ranked by their per-project priority where one is set.
  Future<List<SchedulerTargetRow>> schedulerTargets({int? projectId}) async {
    if (projectId == null) {
      final rows =
          await (select(targets)..orderBy([
                (t) => OrderingTerm.desc(t.priority),
                (t) => OrderingTerm.asc(t.name),
              ]))
              .get();
      return [
        for (final t in rows)
          (
            id: t.id,
            name: t.name,
            ra: t.ra,
            dec: t.dec,
            priority: t.priority,
            objectType: t.objectType,
            notes: t.notes,
          ),
      ];
    }
    final priority = coalesce<int>([
      projectTargets.priorityOverride,
      targets.priority,
    ]);
    final query =
        select(targets).join([
            innerJoin(
              projectTargets,
              projectTargets.targetId.equalsExp(targets.id),
            ),
          ])
          ..addColumns([priority])
          ..where(projectTargets.projectId.equals(projectId))
          ..orderBy([
            OrderingTerm.desc(priority),
            OrderingTerm.asc(targets.name),
          ]);
    final rows = await query.get();
    return [
      for (final row in rows)
        (
          id: row.readTable(targets).id,
          name: row.readTable(targets).name,
          ra: row.readTable(targets).ra,
          dec: row.readTable(targets).dec,
          priority: row.read(priority)!,
          objectType: row.readTable(targets).objectType,
          notes: row.readTable(targets).notes,
        ),
    ];
  }
}
