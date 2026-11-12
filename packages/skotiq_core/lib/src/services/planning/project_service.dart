import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/database.dart' as db;
import '../../models/planning/project.dart';
import '../../models/planning/project_progress.dart';
import '../../providers/backend_provider.dart';
import '../../providers/database_provider.dart';
import '../project_tracking_service.dart';
import '../scheduler/integration_goal_service.dart';
import '../../backend/remote_host.dart';

/// Persistence + business-logic for multi-night planning projects.
///
/// A [Project] groups several targets into one campaign; this service owns the
/// CRUD for projects and their target memberships, and derives a
/// project-scoped [CampaignProgress] roll-up on demand from the target's
/// accepted frames and goals (`TargetGoal`, the rule Analytics uses too).
/// Accrued progress is NEVER
/// denormalized onto the `projects` / `project_targets` tables — it is always
/// derived from `captured_images` (the single source of truth) so it cannot
/// drift out of sync when a frame is rejected, deleted, or re-graded.
///
/// Every mutation method fires the broadcast [watchChanges] stream, mirroring
/// [IntegrationGoalService.watchAll]. The UI layer listens to it to
/// invalidate derived providers.
class ProjectService {
  final db.SkotiqDatabase _db;
  final IntegrationGoalService _goalService;

  final StreamController<void> _mutations = StreamController<void>.broadcast();

  /// Non-null on a remote SLAVE: the `projects` / `project_targets` tables and
  /// the campaign roll-up live in the HOST DB, so reads route over
  /// `/api/projects*`. Null on the host (FfiBackend) / tests — local path
  /// unchanged.
  final HostPlanningData? _remote;

  ProjectService(this._db, this._goalService, {HostPlanningData? remote})
    : _remote = remote;

  void _notifyMutated() {
    if (!_mutations.isClosed) _mutations.add(null);
  }

  /// Project CRUD is host-owned: a slave reads projects/progress over REST but
  /// cannot mutate the campaign (no project-write endpoint exists, and writing
  /// to the slave's throwaway local DB would silently lose the edit). Mutating
  /// methods call this so the attempt fails loud on a slave instead of writing
  /// to nowhere — the editor UIs gate creation host-only.
  void _assertLocalWrite(String op) {
    if (_remote != null) {
      throw StateError(
        'ProjectService.$op is not available on a remote client — projects are '
        'managed on the imaging host.',
      );
    }
  }

  Future<void> dispose() async {
    await _mutations.close();
  }

  /// Current wall-clock time in Unix seconds (UTC), as these tables store it.
  static int _nowUnix() =>
      DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

  /// Create a new project. Sets `created_at` / `updated_at` to now, fires the
  /// change stream, and returns the new row id.
  Future<int> createProject({
    required String name,
    String? description,
    int? colorArgb,
  }) async {
    _assertLocalWrite('createProject');
    final now = _nowUnix();
    final id = await _db.planningDao.insertProject(
      db.ProjectsCompanion.insert(
        name: name,
        description: Value(description),
        colorArgb: Value(colorArgb),
        createdAt: now,
        updatedAt: now,
      ),
    );
    _notifyMutated();
    return id;
  }

  /// Persist edits to an existing project. Bumps `updated_at` to now (the
  /// passed [project.updatedAt] is ignored — the store is authoritative for the
  /// mutation timestamp). Requires a non-null [Project.id].
  Future<void> updateProject(Project project) async {
    _assertLocalWrite('updateProject');
    final id = project.id;
    if (id == null) {
      throw ArgumentError.value(
        project,
        'project',
        'updateProject requires a persisted project with a non-null id',
      );
    }
    await _db.planningDao.updateProject(
      id,
      db.ProjectsCompanion(
        name: Value(project.name),
        description: Value(project.description),
        colorArgb: Value(project.colorArgb),
        updatedAt: Value(_nowUnix()),
      ),
    );
    _notifyMutated();
  }

  /// Delete a project. The `project_targets` `ON DELETE CASCADE` foreign key
  /// removes all membership rows automatically (foreign-key enforcement is
  /// enabled in the database's `beforeOpen`).
  Future<void> deleteProject(int id) async {
    _assertLocalWrite('deleteProject');
    await _db.planningDao.deleteProject(id);
    _notifyMutated();
  }

  /// All projects, most-recently-updated first.
  Future<List<Project>> listProjects() async {
    final remote = _remote;
    if (remote != null) {
      return remote.getProjects();
    }
    final rows = await _db.planningDao.allProjects();
    return rows.map(_rowToProject).toList();
  }

  /// Look up a single project by id, or `null` if it does not exist.
  Future<Project?> getProject(int id) async {
    final remote = _remote;
    if (remote != null) {
      final projects = await remote.getProjects();
      for (final p in projects) {
        if (p.id == id) return p;
      }
      return null;
    }
    final row = await _db.planningDao.project(id);
    return row == null ? null : _rowToProject(row);
  }

  /// Attach [targetId] to [projectId]. Idempotent: the `UNIQUE(project_id,
  /// target_id)` constraint plus `INSERT OR IGNORE` means re-adding an existing
  /// member is a no-op (the original `added_at` and any prior priority override
  /// are preserved). Sets `added_at` to now on first insert.
  Future<void> addTarget({
    required int projectId,
    required int targetId,
    int? priorityOverride,
  }) async {
    _assertLocalWrite('addTarget');
    await _db.planningDao.addProjectTarget(
      db.ProjectTargetsCompanion.insert(
        projectId: projectId,
        targetId: targetId,
        priorityOverride: Value(priorityOverride),
        addedAt: _nowUnix(),
      ),
    );
    _notifyMutated();
  }

  /// Detach [targetId] from [projectId]. No-op if the membership does not
  /// exist.
  Future<void> removeTarget({
    required int projectId,
    required int targetId,
  }) async {
    _assertLocalWrite('removeTarget');
    await _db.planningDao.removeProjectTarget(
      projectId: projectId,
      targetId: targetId,
    );
    _notifyMutated();
  }

  /// Set (or clear, with `null`) the per-project priority override for a
  /// membership. Clearing means the scheduler falls back to the target's own
  /// global priority.
  Future<void> setPriorityOverride({
    required int projectId,
    required int targetId,
    int? priorityOverride,
  }) async {
    _assertLocalWrite('setPriorityOverride');
    await _db.planningDao.setProjectTargetPriority(
      projectId: projectId,
      targetId: targetId,
      priorityOverride: priorityOverride,
    );
    _notifyMutated();
  }

  /// All memberships for a project, oldest-added first (stable display order).
  Future<List<ProjectTarget>> listTargets(int projectId) async {
    final remote = _remote;
    if (remote != null) {
      return remote.getProjectTargets(projectId);
    }
    final rows = await _db.planningDao.projectTargetsOf(projectId);
    return rows.map(_rowToProjectTarget).toList();
  }

  /// The bare target ids attached to a project — used by the scheduler
  /// candidate loader to filter the candidate set to the active project.
  Future<List<int>> targetIdsForProject(int projectId) async {
    final remote = _remote;
    if (remote != null) {
      final targets = await remote.getProjectTargets(projectId);
      return targets.map((t) => t.targetId).toList();
    }
    final rows = await _db.planningDao.projectTargetsOf(projectId);
    return rows.map((r) => r.targetId).toList();
  }

  /// Build the project-scoped accrued-vs-remaining roll-up.
  ///
  /// For each member target this loads its name/RA/dec from `targets` and its
  /// per-filter [integration goals][IntegrationGoalService.listForTarget], then
  /// derives each goal's accepted frames and seconds from `captured_images`
  /// ([acceptedPerGoal], never a denormalized tally). The result assembles into
  /// [FilterProgressLine] / [ProjectTargetProgress] / [CampaignProgress].
  ///
  /// Throws [StateError] if [projectId] does not exist (fail-loud, matching
  /// `CampaignRollupService.buildForTarget`). A member target row that has been
  /// deleted out from under the membership likewise throws — a dangling
  /// membership is a data-integrity error, not something to silently skip.
  Future<CampaignProgress> buildProgress(int projectId) async {
    final remote = _remote;
    if (remote != null) {
      // The roll-up is derived from the host's captured_images + goals; the
      // slave's local DB is empty, so compute it host-side and mirror it.
      return remote.getProjectProgress(projectId);
    }
    final project = await getProject(projectId);
    if (project == null) {
      throw StateError('Project $projectId not found');
    }

    final memberships = await listTargets(projectId);
    final targetProgress = <ProjectTargetProgress>[];

    for (final membership in memberships) {
      final targetId = membership.targetId;
      final targetRow = await _db.targetsDao.getTargetById(targetId);
      if (targetRow == null) {
        throw StateError(
          'Project $projectId references target $targetId, which no longer '
          'exists in the catalog',
        );
      }

      final goals = await _goalService.listForTarget(targetId);
      final accepted = acceptedLightsByFilter(
        await _db.imagesDao.getImagesForTarget(targetId),
      );
      final done = acceptedPerGoal(accepted, goals);
      final lines = [
        for (final (i, goal) in goals.indexed)
          FilterProgressLine(
            filter: goal.filter,
            exposureSeconds: goal.exposureSeconds,
            goalFrames: goal.frameCount,
            capturedFrames: done[i].frames,
            capturedSeconds: done[i].seconds,
          ),
      ];
      final goal = TargetGoal.of(
        accepted: accepted,
        goals: goals,
        oldTotalGoalSecs: targetRow.goalIntegrationSecs,
      );
      targetProgress.add(
        ProjectTargetProgress(
          targetId: targetId,
          targetName: targetRow.name,
          raHours: targetRow.ra,
          decDegrees: targetRow.dec,
          filters: lines,
          allFiltersGoalSeconds: goal.allFilters ? goal.goalSecs : null,
          allFiltersAccruedSeconds: goal.allFilters ? goal.doneSecs : 0.0,
        ),
      );
    }

    return CampaignProgress(project: project, targets: targetProgress);
  }

  /// Fires once on every mutation the service performs (create/update/delete of
  /// a project, and add/remove/override of a membership). A UI invalidation
  /// hook — consumers re-run [listProjects] / [buildProgress] on each event.
  Stream<void> watchChanges() => _mutations.stream;

  Project _rowToProject(db.ProjectRow row) {
    return Project.fromRow(
      id: row.id,
      name: row.name,
      description: row.description,
      colorArgb: row.colorArgb,
      createdAtUnix: row.createdAt,
      updatedAtUnix: row.updatedAt,
    );
  }

  ProjectTarget _rowToProjectTarget(db.ProjectTargetRow row) {
    return ProjectTarget.fromRow(
      id: row.id,
      projectId: row.projectId,
      targetId: row.targetId,
      priorityOverride: row.priorityOverride,
      addedAtUnix: row.addedAt,
    );
  }
}

final projectServiceProvider = Provider<ProjectService>((ref) {
  final backend = ref.watch(backendProvider);
  final service = ProjectService(
    ref.watch(databaseProvider),
    ref.watch(integrationGoalServiceProvider),
    remote: backend.remoteHost?.planning,
  );
  ref.onDispose(() => service.dispose());
  return service;
});
