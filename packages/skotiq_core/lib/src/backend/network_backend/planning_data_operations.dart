part of '../network_backend.dart';

/// Remote-client access to the host's planner/scheduler DATA tables
/// (`integration_goals`, `target_constraints`, `horizon_profiles`,
/// `projects`, `project_targets`).
///
/// On a slave these tables live ONLY in the host DB — the slave's local
/// SQLite is empty — so the candidate loader, integration-goal editor,
/// constraint editor, project list, and campaign-progress roll-up all read
/// nothing and (worse) the autopilot gates with zero constraints/horizons.
/// These methods mirror the host's rows over REST. They are NOT part of the
/// abstract [SkotiqBackend] surface — only a slave calls them, behind an
/// `is NetworkBackend` branch in the corresponding service/provider.
mixin _NetworkBackendPlanningDataOperations on _NetworkBackendTransport {
  // Integration goals

  /// GET /api/integration-goals?targetId= — every goal, or the goals for one
  /// target when [targetId] is supplied.
  Future<List<IntegrationGoal>> getIntegrationGoals({int? targetId}) async {
    final response = await _get('integration-goals', {
      if (targetId != null) 'targetId': targetId.toString(),
    });
    return _listFrom(response, 'goals', IntegrationGoal.fromJson);
  }

  /// GET /api/integration-goals/captured-count?targetId=&filter= — the host's
  /// accepted-light frame count for one (target, filter) pair. This MUST come
  /// from the host's `captured_images`, never the slave's empty local DB.
  Future<int> getCapturedFrameCount({
    required int targetId,
    required String filter,
  }) async {
    final response = await _get('integration-goals/captured-count', {
      'targetId': targetId.toString(),
      'filter': filter,
    });
    return _requiredPlanningInt(
      response,
      'count',
      'GET /api/integration-goals/captured-count',
    );
  }

  /// POST /api/integration-goals — upsert a goal on the host and return its id.
  Future<int> upsertIntegrationGoal(IntegrationGoal goal) async {
    final response = await _post('integration-goals', goal.toJson());
    return _requiredPlanningInt(response, 'id', 'POST /api/integration-goals');
  }

  /// DELETE /api/integration-goals?id= — delete a single goal on the host.
  Future<void> deleteIntegrationGoal(int goalId) async {
    await _delete('integration-goals?id=$goalId');
  }

  /// DELETE /api/integration-goals?targetId= — delete all goals for a target.
  Future<void> deleteIntegrationGoalsForTarget(int targetId) async {
    await _delete('integration-goals?targetId=$targetId');
  }

  /// DELETE /api/integration-goals?all=true — delete every goal on the host.
  Future<void> deleteAllIntegrationGoals() async {
    await _delete('integration-goals?all=true');
  }

  // Target constraints

  /// GET /api/target-constraints?targetId= — every constraint, or the
  /// constraints for one target.
  Future<List<TargetConstraint>> getTargetConstraints({int? targetId}) async {
    final response = await _get('target-constraints', {
      if (targetId != null) 'targetId': targetId.toString(),
    });
    return _listFrom(response, 'constraints', TargetConstraint.fromJson);
  }

  /// POST /api/target-constraints — insert a constraint on the host; returns id.
  Future<int> insertTargetConstraint(TargetConstraint constraint) async {
    final response = await _post('target-constraints', constraint.toJson());
    return _requiredPlanningInt(response, 'id', 'POST /api/target-constraints');
  }

  /// POST /api/target-constraints/update — update an existing constraint.
  Future<void> updateTargetConstraint(TargetConstraint constraint) async {
    await _post('target-constraints/update', constraint.toJson());
  }

  /// POST /api/target-constraints/set-enabled — toggle a constraint.
  Future<void> setTargetConstraintEnabled(int id, bool enabled) async {
    await _post('target-constraints/set-enabled', {
      'id': id,
      'enabled': enabled,
    });
  }

  /// DELETE /api/target-constraints?id= — delete a single constraint.
  Future<void> deleteTargetConstraint(int id) async {
    await _delete('target-constraints?id=$id');
  }

  /// DELETE /api/target-constraints?targetId= — delete all for a target.
  Future<void> deleteTargetConstraintsForTarget(int targetId) async {
    await _delete('target-constraints?targetId=$targetId');
  }

  /// DELETE /api/target-constraints?all=true — delete every constraint.
  Future<void> deleteAllTargetConstraints() async {
    await _delete('target-constraints?all=true');
  }

  // Scheduler queue membership

  /// GET /api/scheduler/removed-targets — the ids the host's operator has taken
  /// out of the scheduler queue. A slave that could not see these ran its
  /// autopilot over targets the operator had removed, because a goal-less
  /// target is otherwise a perfectly eligible free-form candidate.
  Future<Set<int>> getSchedulerQueueRemovedTargets() async {
    final response = await _get('scheduler/removed-targets');
    final ids = response['targetIds'];
    if (ids is! List) {
      throw const FormatException(
        'GET /api/scheduler/removed-targets returned no `targetIds` list',
      );
    }
    return ids.whereType<num>().map((n) => n.toInt()).toSet();
  }

  /// POST /api/scheduler/removed-targets — remove one target from the queue.
  Future<void> removeSchedulerQueueTarget(int targetId) async {
    await _post('scheduler/removed-targets', {'targetId': targetId});
  }

  /// POST /api/scheduler/removed-targets — empty the queue.
  Future<void> clearSchedulerQueue() async {
    await _post('scheduler/removed-targets', {'all': true});
  }

  /// DELETE /api/scheduler/removed-targets?targetId= — put one target back.
  Future<void> readmitSchedulerQueueTarget(int targetId) async {
    await _delete('scheduler/removed-targets?targetId=$targetId');
  }

  // Horizon profiles

  /// GET /api/horizon-profiles — every custom horizon profile.
  Future<List<HorizonProfile>> getHorizonProfiles() async {
    final response = await _get('horizon-profiles');
    return _listFrom(response, 'profiles', HorizonProfile.fromJson);
  }

  // Projects (multi-night campaigns)

  /// GET /api/projects — every project, most-recently-updated first.
  Future<List<Project>> getProjects() async {
    final response = await _get('projects');
    return _listFrom(response, 'projects', Project.fromJson);
  }

  /// GET /api/projects/targets?projectId= — the membership rows for a project.
  Future<List<ProjectTarget>> getProjectTargets(int projectId) async {
    final response = await _get('projects/targets', {
      'projectId': projectId.toString(),
    });
    return _listFrom(response, 'targets', ProjectTarget.fromJson);
  }

  /// GET /api/projects/progress?projectId= — the server-computed
  /// accrued-vs-remaining campaign roll-up (derived from the host's
  /// `captured_images` + goals, never a slave-side recompute).
  Future<CampaignProgress> getProjectProgress(int projectId) async {
    final response = await _get('projects/progress', {
      'projectId': projectId.toString(),
    });
    return CampaignProgress.fromJson(response);
  }

  // Helpers

  List<T> _listFrom<T>(
    Map<String, dynamic> response,
    String key,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    return _rowsFromJson(response[key], fromJson);
  }

  int _requiredPlanningInt(
    Map<String, dynamic> response,
    String key,
    String request,
  ) {
    final value = response[key];
    if (value is! num) {
      throw FormatException('$request returned no numeric `$key` field');
    }
    return value.toInt();
  }
}
