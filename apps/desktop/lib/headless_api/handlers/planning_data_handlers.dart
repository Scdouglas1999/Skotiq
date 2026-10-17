import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Host endpoints serving the planner/scheduler DATA tables to remote slaves.
///
/// On a slave (remote client) the `integration_goals`, `target_constraints`,
/// `horizon_profiles`, `projects`, and `project_targets` tables live ONLY on
/// the host — the slave's local SQLite is empty. Without these endpoints the
/// slave's candidate loader gates with zero constraints/horizons, its goal &
/// constraint editors render blank (and write to a throwaway DB), and the
/// Planner's Projects tab is empty. These handlers read the same host-side
/// services the desktop app uses (so the host path is unchanged) and serialize
/// the rows over REST.
class PlanningDataHandlers {
  final ProviderContainer container;

  PlanningDataHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'PlanningDataHandlers');

  IntegrationGoalService get _goalService =>
      container.read(integrationGoalServiceProvider);

  TargetConstraintService get _constraintService =>
      container.read(targetConstraintServiceProvider);

  ProjectService get _projectService => container.read(projectServiceProvider);

  SchedulerQueueService get _queueService =>
      container.read(schedulerQueueServiceProvider);

  int? _intParam(Request request, String key) =>
      optionalQueryInt(request.url.queryParameters, key, min: 1);

  // Integration goals

  /// GET /api/integration-goals?targetId=
  Future<Response> handleGetIntegrationGoals(Request request) async {
    _logInfo('[API] GET /api/integration-goals');
    final targetId = _intParam(request, 'targetId');
    try {
      final goals = targetId != null
          ? await _goalService.listForTarget(targetId)
          : await _goalService.listAll();
      return jsonOk({'goals': goals.map((g) => g.toJson()).toList()});
    } catch (e) {
      return jsonInternalServerError({'error': 'Failed to list goals: $e'});
    }
  }

  /// GET /api/integration-goals/captured-count?targetId=&filter=
  Future<Response> handleGetCapturedFrameCount(Request request) async {
    _logInfo('[API] GET /api/integration-goals/captured-count');
    final targetId = requireQueryInt(
      request.url.queryParameters,
      'targetId',
      min: 1,
    );
    final filter = request.url.queryParameters['filter']?.trim();
    if (filter == null || filter.isEmpty) {
      return jsonBadRequest({'error': 'Missing targetId or filter'});
    }
    try {
      final count = await _goalService.capturedFrameCount(
        targetId: targetId,
        filter: filter,
      );
      return jsonOk({'count': count});
    } catch (e) {
      return jsonInternalServerError({'error': 'Failed to count frames: $e'});
    }
  }

  /// POST /api/integration-goals — upsert.
  Future<Response> handleUpsertIntegrationGoal(Request request) async {
    _logInfo('[API] POST /api/integration-goals');
    final body = await readJsonObject(request);
    // IntegrationGoal.fromJson is documented as a TOLERANT decoder (every field
    // defaults) because it backs the host->slave mirror. Fed request data
    // directly it accepted `{"targetId": N}` and persisted a goal the scheduler
    // then scores with filter "", exposureSeconds 0.0, frameCount 0 and a 1970
    // timestamp. Validate the fields that make a goal meaningful first.
    final targetId = requireInt(body, 'targetId', min: 1);
    requireString(body, 'filter', maxLength: 64);
    requireDouble(body, 'exposureSeconds', min: 0.000001);
    requireInt(body, 'frameCount', min: 1);
    // And pre-check the FK the way analytics_handlers does: without this a
    // nonexistent targetId surfaced as a 500 that echoed the raw
    // "SqliteException(787): FOREIGN KEY constraint failed" to the caller.
    final db = container.read(databaseProvider);
    if (await db.targetsDao.getTargetById(targetId) == null) {
      throw BadRequestError(
        field: 'targetId',
        expected: 'an existing target id',
      );
    }
    final goal = IntegrationGoal.fromJson(body);
    final id = await _goalService.upsert(goal);
    return jsonOk({'id': id});
  }

  /// DELETE /api/integration-goals?id=|targetId=|all=true
  Future<Response> handleDeleteIntegrationGoal(Request request) async {
    _logInfo('[API] DELETE /api/integration-goals');
    final query = request.url.queryParameters;
    final deleteAll = optionalQueryBool(query, 'all') ?? false;
    final targetId = _intParam(request, 'targetId');
    final id = _intParam(request, 'id');
    final selectorCount = [
      deleteAll,
      targetId != null,
      id != null,
    ].where((selected) => selected).length;
    if (selectorCount != 1) {
      throw BadRequestError(
        field: 'id',
        expected: 'exactly one of id, targetId, or all=true',
        message: 'Specify exactly one of id, targetId, or all=true',
      );
    }
    try {
      if (deleteAll) {
        await _goalService.deleteAll();
        return jsonOk({'success': true});
      }
      if (targetId != null) {
        await _goalService.deleteForTarget(targetId);
        return jsonOk({'success': true});
      }
      await _goalService.delete(id!);
      return jsonOk({'success': true});
    } catch (e) {
      return jsonInternalServerError({'error': 'Failed to delete goal: $e'});
    }
  }

  // Scheduler queue membership

  /// GET /api/scheduler/removed-targets
  Future<Response> handleGetSchedulerRemovedTargets(Request request) async {
    _logInfo('[API] GET /api/scheduler/removed-targets');
    try {
      final ids = await _queueService.removedTargetIds();
      return jsonOk({'targetIds': ids.toList()..sort()});
    } catch (e) {
      return jsonInternalServerError({
        'error': 'Failed to list removed targets: $e',
      });
    }
  }

  /// POST /api/scheduler/removed-targets — `{"targetId": N}` removes one
  /// target from the queue, `{"all": true}` empties it.
  Future<Response> handleRemoveSchedulerTarget(Request request) async {
    _logInfo('[API] POST /api/scheduler/removed-targets');
    final body = await readJsonObject(request);
    final removeAll = optionalBool(body, 'all') ?? false;
    final targetId = removeAll ? null : requireInt(body, 'targetId', min: 1);
    if (targetId != null) {
      // Same FK pre-check the goal upsert does: a nonexistent id would
      // otherwise surface as a raw SQLite foreign-key 500.
      final db = container.read(databaseProvider);
      if (await db.targetsDao.getTargetById(targetId) == null) {
        throw BadRequestError(
          field: 'targetId',
          expected: 'an existing target id',
        );
      }
    }
    try {
      if (removeAll) {
        await _queueService.removeAll();
      } else {
        await _queueService.remove(targetId!);
      }
      return jsonOk({'success': true});
    } catch (e) {
      return jsonInternalServerError({
        'error': 'Failed to remove target from the scheduler queue: $e',
      });
    }
  }

  /// DELETE /api/scheduler/removed-targets?targetId= — put one target back.
  Future<Response> handleReadmitSchedulerTarget(Request request) async {
    _logInfo('[API] DELETE /api/scheduler/removed-targets');
    final targetId = requireQueryInt(
      request.url.queryParameters,
      'targetId',
      min: 1,
    );
    try {
      await _queueService.readmit(targetId);
      return jsonOk({'success': true});
    } catch (e) {
      return jsonInternalServerError({
        'error': 'Failed to readmit target into the scheduler queue: $e',
      });
    }
  }

  // Target constraints

  /// GET /api/target-constraints?targetId=
  Future<Response> handleGetTargetConstraints(Request request) async {
    _logInfo('[API] GET /api/target-constraints');
    final targetId = _intParam(request, 'targetId');
    try {
      final constraints = targetId != null
          ? await _constraintService.listForTarget(targetId)
          : await _constraintService.listAll();
      return jsonOk({
        'constraints': constraints.map((c) => c.toJson()).toList(),
      });
    } catch (e) {
      return jsonInternalServerError({
        'error': 'Failed to list constraints: $e',
      });
    }
  }

  /// POST /api/target-constraints — insert.
  Future<Response> handleInsertTargetConstraint(Request request) async {
    _logInfo('[API] POST /api/target-constraints');
    final body = await readJsonObject(request);
    _requireValidConstraintKind(body);
    final constraint = TargetConstraint.fromJson(body);
    final id = await _constraintService.insert(constraint);
    return jsonOk({'id': id});
  }

  /// Validate `kind` before handing the body to `TargetConstraint.fromJson`.
  /// `fromRow`'s StateError is the right response to a corrupt DB row, but for
  /// request input it surfaces as a 500 (server fault) when a missing or
  /// misspelled kind is really a 400 (client error).
  void _requireValidConstraintKind(Map<String, dynamic> body) {
    final kindName = body['kind'];
    final validKinds = TargetConstraintKind.values.map((k) => k.name).toList();
    if (kindName is! String || !validKinds.contains(kindName)) {
      throw BadRequestError(
        field: 'kind',
        expected: validKinds.join(' | '),
        message: 'Missing or unknown constraint kind',
      );
    }
  }

  /// POST /api/target-constraints/update — update in place.
  Future<Response> handleUpdateTargetConstraint(Request request) async {
    _logInfo('[API] POST /api/target-constraints/update');
    final body = await readJsonObject(request);
    _requireValidConstraintKind(body);
    final constraint = TargetConstraint.fromJson(body);
    await _constraintService.update(constraint);
    return jsonOk({'success': true});
  }

  /// POST /api/target-constraints/set-enabled — toggle.
  Future<Response> handleSetTargetConstraintEnabled(Request request) async {
    _logInfo('[API] POST /api/target-constraints/set-enabled');
    final body = await readJsonObject(request);
    final id = requireInt(body, 'id');
    final enabled = requireBool(body, 'enabled');
    await _constraintService.setEnabled(id, enabled);
    return jsonOk({'success': true});
  }

  /// DELETE /api/target-constraints?id=|targetId=|all=true
  Future<Response> handleDeleteTargetConstraint(Request request) async {
    _logInfo('[API] DELETE /api/target-constraints');
    final query = request.url.queryParameters;
    final deleteAll = optionalQueryBool(query, 'all') ?? false;
    final targetId = _intParam(request, 'targetId');
    final id = _intParam(request, 'id');
    final selectorCount = [
      deleteAll,
      targetId != null,
      id != null,
    ].where((selected) => selected).length;
    if (selectorCount != 1) {
      throw BadRequestError(
        field: 'id',
        expected: 'exactly one of id, targetId, or all=true',
        message: 'Specify exactly one of id, targetId, or all=true',
      );
    }
    try {
      if (deleteAll) {
        await _constraintService.deleteAll();
        return jsonOk({'success': true});
      }
      if (targetId != null) {
        await _constraintService.deleteForTarget(targetId);
        return jsonOk({'success': true});
      }
      await _constraintService.delete(id!);
      return jsonOk({'success': true});
    } catch (e) {
      return jsonInternalServerError({
        'error': 'Failed to delete constraint: $e',
      });
    }
  }

  // Horizon profiles

  /// GET /api/horizon-profiles
  Future<Response> handleGetHorizonProfiles(Request request) async {
    _logInfo('[API] GET /api/horizon-profiles');
    try {
      final db = container.read(databaseProvider);
      // Ensure the table exists before reading (mirrors the loader's defensive
      // DDL — a host that has never opened the scheduler UI may not have it).
      // DDL inlined because the canonical constant is hidden from the barrel;
      // it is `CREATE TABLE IF NOT EXISTS`, so this is a no-op on an existing
      // schema and stays identical to ProjectService/IntegrationGoalService.
      await db.customStatement(
        'CREATE TABLE IF NOT EXISTS horizon_profiles ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'name TEXT NOT NULL, '
        'samples_json TEXT NOT NULL)',
      );
      final rows = await db
          .customSelect('SELECT id, name, samples_json FROM horizon_profiles')
          .get();
      final profiles = rows
          .map(
            (row) => HorizonProfile.fromRow(
              id: row.read<int>('id'),
              name: row.read<String>('name'),
              samplesJson: row.read<String>('samples_json'),
            ),
          )
          .toList();
      return jsonOk({'profiles': profiles.map((p) => p.toJson()).toList()});
    } catch (e) {
      return jsonInternalServerError({
        'error': 'Failed to list horizon profiles: $e',
      });
    }
  }

  // Projects

  /// GET /api/projects
  Future<Response> handleGetProjects(Request request) async {
    _logInfo('[API] GET /api/projects');
    try {
      final projects = await _projectService.listProjects();
      return jsonOk({'projects': projects.map((p) => p.toJson()).toList()});
    } catch (e) {
      return jsonInternalServerError({'error': 'Failed to list projects: $e'});
    }
  }

  /// GET /api/projects/targets?projectId=
  Future<Response> handleGetProjectTargets(Request request) async {
    _logInfo('[API] GET /api/projects/targets');
    final projectId = requireQueryInt(
      request.url.queryParameters,
      'projectId',
      min: 1,
    );
    try {
      final targets = await _projectService.listTargets(projectId);
      return jsonOk({'targets': targets.map((t) => t.toJson()).toList()});
    } catch (e) {
      return jsonInternalServerError({
        'error': 'Failed to list project targets: $e',
      });
    }
  }

  /// GET /api/projects/progress?projectId=
  Future<Response> handleGetProjectProgress(Request request) async {
    _logInfo('[API] GET /api/projects/progress');
    final projectId = requireQueryInt(
      request.url.queryParameters,
      'projectId',
      min: 1,
    );
    try {
      final progress = await _projectService.buildProgress(projectId);
      return jsonOk(progress.toJson());
    } catch (e) {
      return jsonInternalServerError({
        'error': 'Failed to build project progress: $e',
      });
    }
  }
}
