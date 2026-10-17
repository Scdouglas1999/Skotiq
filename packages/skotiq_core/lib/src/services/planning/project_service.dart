import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/network_backend.dart';
import '../../database/database.dart' as db;
import '../../models/planning/project.dart';
import '../../models/planning/project_progress.dart';
import '../../providers/backend_provider.dart';
import '../../providers/database_provider.dart';
import '../scheduler/integration_goal_service.dart';

/// SQL schema for the multi-night planner's `projects` and `project_targets`
/// tables.
///
/// These are managed outside Drift's `@DriftDatabase` declaration (which would
/// require a codegen pass) by issuing raw `CREATE TABLE IF NOT EXISTS`
/// statements on first access — the dominant v27+ scheduler-stack convention
/// (`integration_goals`, `target_constraints`, `horizon_profiles`,
/// `stacked_results`). The canonical schema lives in
/// `database.dart`'s `_createProjectsTables()` (migration v40); the DDL is
/// duplicated here verbatim so a fresh test database constructed without
/// running the migration still works. The two MUST stay identical.
const _projectsSchema = '''
CREATE TABLE IF NOT EXISTS projects(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  description TEXT,
  color_argb INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''';

const _projectTargetsSchema = '''
CREATE TABLE IF NOT EXISTS project_targets(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  target_id INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
  priority_override INTEGER,
  added_at INTEGER NOT NULL,
  UNIQUE(project_id, target_id)
)
''';

const _projectTargetsProjectIndex =
    'CREATE INDEX IF NOT EXISTS idx_project_targets_project '
    'ON project_targets (project_id)';
const _projectTargetsTargetIndex =
    'CREATE INDEX IF NOT EXISTS idx_project_targets_target '
    'ON project_targets (target_id)';

/// Persistence + business-logic for multi-night planning projects.
///
/// A [Project] groups several targets into one campaign; this service owns the
/// CRUD for projects and their target memberships, and derives a
/// project-scoped [CampaignProgress] roll-up on demand by reusing
/// [IntegrationGoalService]'s accrued-from-history primitives
/// ([IntegrationGoalService.capturedFrameCount]). Accrued progress is NEVER
/// denormalized onto the `projects` / `project_targets` tables — it is always
/// derived from `captured_images` (the single source of truth) so it cannot
/// drift out of sync when a frame is rejected, deleted, or re-graded.
///
/// The `projects` / `project_targets` tables are created with raw DDL and are
/// invisible to Drift's reactive `watch()` graph, so this class exposes a
/// manual broadcast [watchChanges] stream that every mutation method fires —
/// mirroring [IntegrationGoalService.watchAll]. The UI layer listens to it to
/// invalidate derived providers.
class ProjectService {
  final db.SkotiqDatabase _db;
  final IntegrationGoalService _goalService;

  bool _schemaEnsured = false;

  // Manual change-notification channel for the raw `projects` /
  // `project_targets` tables: Drift's reactive `watch()` only fires for tables
  // it knows about via codegen, and these tables are created out-of-band with
  // raw SQL. Every mutation method below calls `_notifyMutated()` so listeners
  // of [watchChanges] see the change immediately.
  final StreamController<void> _mutations = StreamController<void>.broadcast();

  /// Non-null on a remote SLAVE: the `projects` / `project_targets` tables and
  /// the campaign roll-up live in the HOST DB, so reads route over
  /// `/api/projects*`. Null on the host (FfiBackend) / tests — local path
  /// unchanged.
  final NetworkBackend? _remote;

  ProjectService(this._db, this._goalService, {NetworkBackend? remote})
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

  /// Idempotently create the planner tables on first access. Defensive: the
  /// v40 migration normally creates them, but a fresh test database built with
  /// `SkotiqDatabase.forTesting` may skip migrations, and re-running the
  /// DDL on an existing schema is a no-op (`IF NOT EXISTS`).
  Future<void> _ensureSchema() async {
    if (_schemaEnsured) return;
    await _db.customStatement(_projectsSchema);
    await _db.customStatement(_projectTargetsSchema);
    await _db.customStatement(_projectTargetsProjectIndex);
    await _db.customStatement(_projectTargetsTargetIndex);
    _schemaEnsured = true;
  }

  /// Current wall-clock time in Unix seconds (UTC), the storage convention for
  /// the scheduler-stack raw tables.
  static int _nowUnix() =>
      DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

  // Project CRUD

  /// Create a new project. Sets `created_at` / `updated_at` to now, fires the
  /// change stream, and returns the new row id.
  Future<int> createProject({
    required String name,
    String? description,
    int? colorArgb,
  }) async {
    _assertLocalWrite('createProject');
    await _ensureSchema();
    final now = _nowUnix();
    final id = await _db.customInsert(
      'INSERT INTO projects (name, description, color_argb, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?)',
      variables: [
        Variable.withString(name),
        description == null
            ? const Variable<String>(null)
            : Variable.withString(description),
        colorArgb == null
            ? const Variable<int>(null)
            : Variable.withInt(colorArgb),
        Variable.withInt(now),
        Variable.withInt(now),
      ],
    );
    _notifyMutated();
    return id;
  }

  /// Persist edits to an existing project. Bumps `updated_at` to now (the
  /// passed [project.updatedAt] is ignored — the store is authoritative for the
  /// mutation timestamp). Requires a non-null [Project.id].
  Future<void> updateProject(Project project) async {
    _assertLocalWrite('updateProject');
    await _ensureSchema();
    final id = project.id;
    if (id == null) {
      throw ArgumentError.value(
        project,
        'project',
        'updateProject requires a persisted project with a non-null id',
      );
    }
    await _db.customStatement(
      'UPDATE projects SET name = ?, description = ?, color_argb = ?, updated_at = ? '
      'WHERE id = ?',
      [project.name, project.description, project.colorArgb, _nowUnix(), id],
    );
    _notifyMutated();
  }

  /// Delete a project. The `project_targets` `ON DELETE CASCADE` foreign key
  /// removes all membership rows automatically (foreign-key enforcement is
  /// enabled in the database's `beforeOpen`).
  Future<void> deleteProject(int id) async {
    _assertLocalWrite('deleteProject');
    await _ensureSchema();
    await _db.customStatement('DELETE FROM projects WHERE id = ?', [id]);
    _notifyMutated();
  }

  /// All projects, most-recently-updated first.
  Future<List<Project>> listProjects() async {
    final remote = _remote;
    if (remote != null) {
      return remote.getProjects();
    }
    await _ensureSchema();
    final rows = await _db
        .customSelect(
          'SELECT id, name, description, color_argb, created_at, updated_at '
          'FROM projects ORDER BY updated_at DESC, id DESC',
        )
        .get();
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
    await _ensureSchema();
    final row = await _db
        .customSelect(
          'SELECT id, name, description, color_argb, created_at, updated_at '
          'FROM projects WHERE id = ?',
          variables: [Variable.withInt(id)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    return _rowToProject(row);
  }

  // Membership

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
    await _ensureSchema();
    await _db.customInsert(
      'INSERT OR IGNORE INTO project_targets '
      '(project_id, target_id, priority_override, added_at) VALUES (?, ?, ?, ?)',
      variables: [
        Variable.withInt(projectId),
        Variable.withInt(targetId),
        priorityOverride == null
            ? const Variable<int>(null)
            : Variable.withInt(priorityOverride),
        Variable.withInt(_nowUnix()),
      ],
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
    await _ensureSchema();
    await _db.customStatement(
      'DELETE FROM project_targets WHERE project_id = ? AND target_id = ?',
      [projectId, targetId],
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
    await _ensureSchema();
    await _db.customStatement(
      'UPDATE project_targets SET priority_override = ? '
      'WHERE project_id = ? AND target_id = ?',
      [priorityOverride, projectId, targetId],
    );
    _notifyMutated();
  }

  /// All memberships for a project, oldest-added first (stable display order).
  Future<List<ProjectTarget>> listTargets(int projectId) async {
    final remote = _remote;
    if (remote != null) {
      return remote.getProjectTargets(projectId);
    }
    await _ensureSchema();
    final rows = await _db
        .customSelect(
          'SELECT id, project_id, target_id, priority_override, added_at '
          'FROM project_targets WHERE project_id = ? ORDER BY added_at ASC, id ASC',
          variables: [Variable.withInt(projectId)],
        )
        .get();
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
    await _ensureSchema();
    final rows = await _db
        .customSelect(
          'SELECT target_id FROM project_targets WHERE project_id = ? '
          'ORDER BY added_at ASC, id ASC',
          variables: [Variable.withInt(projectId)],
        )
        .get();
    return rows.map((r) => r.read<int>('target_id')).toList();
  }

  // Progress derivation

  /// Build the project-scoped accrued-vs-remaining roll-up.
  ///
  /// For each member target this loads its name/RA/dec from `targets` and its
  /// per-filter [integration goals][IntegrationGoalService.listForTarget], then
  /// derives accrued frames per filter from `captured_images` via
  /// [IntegrationGoalService.capturedFrameCount] (the single accrued-from-
  /// history primitive — never a denormalized tally). The result assembles into
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
    await _ensureSchema();
    final project = await getProject(projectId);
    if (project == null) {
      throw StateError('Project $projectId not found');
    }

    final memberships = await listTargets(projectId);
    final targetProgress = <ProjectTargetProgress>[];

    for (final membership in memberships) {
      final targetId = membership.targetId;
      final targetRow = await _db
          .customSelect(
            'SELECT name, ra, dec FROM targets WHERE id = ?',
            variables: [Variable.withInt(targetId)],
          )
          .getSingleOrNull();
      if (targetRow == null) {
        throw StateError(
          'Project $projectId references target $targetId, which no longer '
          'exists in the catalog',
        );
      }

      final goals = await _goalService.listForTarget(targetId);
      final lines = <FilterProgressLine>[];
      for (final goal in goals) {
        final captured = await _goalService.capturedFrameCount(
          targetId: targetId,
          filter: goal.filter,
        );
        lines.add(
          FilterProgressLine(
            filter: goal.filter,
            exposureSeconds: goal.exposureSeconds,
            goalFrames: goal.frameCount,
            capturedFrames: captured,
          ),
        );
      }

      targetProgress.add(
        ProjectTargetProgress(
          targetId: targetId,
          targetName: targetRow.read<String>('name'),
          raHours: targetRow.read<double>('ra'),
          decDegrees: targetRow.read<double>('dec'),
          filters: lines,
        ),
      );
    }

    return CampaignProgress(project: project, targets: targetProgress);
  }

  /// Fires once on every mutation the service performs (create/update/delete of
  /// a project, and add/remove/override of a membership). A UI invalidation
  /// hook — consumers re-run [listProjects] / [buildProgress] on each event.
  Stream<void> watchChanges() => _mutations.stream;

  // Row mappers

  Project _rowToProject(QueryRow row) {
    return Project.fromRow(
      id: row.read<int>('id'),
      name: row.read<String>('name'),
      description: row.readNullable<String>('description'),
      colorArgb: row.readNullable<int>('color_argb'),
      createdAtUnix: row.read<int>('created_at'),
      updatedAtUnix: row.read<int>('updated_at'),
    );
  }

  ProjectTarget _rowToProjectTarget(QueryRow row) {
    return ProjectTarget.fromRow(
      id: row.read<int>('id'),
      projectId: row.read<int>('project_id'),
      targetId: row.read<int>('target_id'),
      priorityOverride: row.readNullable<int>('priority_override'),
      addedAtUnix: row.read<int>('added_at'),
    );
  }
}

/// DDL strings exported so other call sites (e.g. a future scheduler engine
/// init that ensures every planner table exists in one place) can reuse them.
const String projectsSchemaSql = _projectsSchema;
const String projectTargetsSchemaSql = _projectTargetsSchema;
const String projectTargetsProjectIndexSql = _projectTargetsProjectIndex;
const String projectTargetsTargetIndexSql = _projectTargetsTargetIndex;

final projectServiceProvider = Provider<ProjectService>((ref) {
  final backend = ref.watch(backendProvider);
  final service = ProjectService(
    ref.watch(databaseProvider),
    ref.watch(integrationGoalServiceProvider),
    remote: backend is NetworkBackend ? backend : null,
  );
  ref.onDispose(() => service.dispose());
  return service;
});
