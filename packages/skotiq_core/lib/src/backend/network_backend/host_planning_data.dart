part of '../network_backend.dart';

/// Projects, integration goals, target constraints and the scheduler queue
/// kept in a linked imaging host's database, and the host's target scorer.
mixin HostPlanningData on NetworkBackendTransport implements TargetScoring {
  /// GET /api/projects/progress?projectId= — the server-computed
  /// accrued-vs-remaining campaign roll-up (derived from the host's
  /// `captured_images` + goals, never a slave-side recompute).
  Future<CampaignProgress> getProjectProgress(int projectId) async {
    final response = await _get(
      PlanningDataApi.getProjectProgress,
      query: {'projectId': projectId.toString()},
    );
    return CampaignProgress.fromJson(response);
  }

  /// GET /api/projects — every project, most-recently-updated first.
  Future<List<Project>> getProjects() async {
    final response = await _get(PlanningDataApi.getProjects);
    return _listFrom(response, 'projects', Project.fromJson);
  }

  /// GET /api/projects/targets?projectId= — the membership rows for a project.
  Future<List<ProjectTarget>> getProjectTargets(int projectId) async {
    final response = await _get(
      PlanningDataApi.getProjectTargets,
      query: {'projectId': projectId.toString()},
    );
    return _listFrom(response, 'targets', ProjectTarget.fromJson);
  }

  /// POST /api/scheduler/removed-targets — empty the queue.
  Future<void> clearSchedulerQueue() async {
    await _post(PlanningDataApi.removeSchedulerTarget, body: {'all': true});
  }

  /// GET /api/scheduler/removed-targets — the ids the host's operator has taken
  /// out of the scheduler queue. A slave that could not see these ran its
  /// autopilot over targets the operator had removed, because a goal-less
  /// target is otherwise a perfectly eligible free-form candidate.
  Future<Set<int>> getSchedulerQueueRemovedTargets() async {
    final response = await _get(PlanningDataApi.getSchedulerRemovedTargets);
    final ids = response['targetIds'];
    if (ids is! List) {
      throw const FormatException(
        'GET /api/scheduler/removed-targets returned no `targetIds` list',
      );
    }
    return ids.whereType<num>().map((n) => n.toInt()).toSet();
  }

  /// DELETE /api/scheduler/removed-targets?targetId= — put one target back.
  Future<void> readmitSchedulerQueueTarget(int targetId) async {
    await _delete(
      PlanningDataApi.readmitSchedulerTarget,
      query: {'targetId': targetId},
    );
  }

  /// POST /api/scheduler/removed-targets — remove one target from the queue.
  Future<void> removeSchedulerQueueTarget(int targetId) async {
    await _post(
      PlanningDataApi.removeSchedulerTarget,
      body: {'targetId': targetId},
    );
  }

  /// DELETE /api/target-constraints?all=true — delete every constraint.
  Future<void> deleteAllTargetConstraints() async {
    await _delete(
      PlanningDataApi.deleteTargetConstraint,
      query: {'all': 'true'},
    );
  }

  /// DELETE /api/target-constraints?id= — delete a single constraint.
  Future<void> deleteTargetConstraint(int id) async {
    await _delete(PlanningDataApi.deleteTargetConstraint, query: {'id': id});
  }

  /// DELETE /api/target-constraints?targetId= — delete all for a target.
  Future<void> deleteTargetConstraintsForTarget(int targetId) async {
    await _delete(
      PlanningDataApi.deleteTargetConstraint,
      query: {'targetId': targetId},
    );
  }

  /// GET /api/target-constraints?targetId= — every constraint, or the
  /// constraints for one target.
  Future<List<TargetConstraint>> getTargetConstraints({int? targetId}) async {
    final response = await _get(
      PlanningDataApi.getTargetConstraints,
      query: {if (targetId != null) 'targetId': targetId.toString()},
    );
    return _listFrom(response, 'constraints', TargetConstraint.fromJson);
  }

  /// POST /api/target-constraints — insert a constraint on the host; returns id.
  Future<int> insertTargetConstraint(TargetConstraint constraint) async {
    final response = await _post(
      PlanningDataApi.insertTargetConstraint,
      body: constraint.toJson(),
    );
    return _requiredPlanningInt(response, 'id', 'POST /api/target-constraints');
  }

  /// POST /api/target-constraints/set-enabled — toggle a constraint.
  Future<void> setTargetConstraintEnabled(int id, bool enabled) async {
    await _post(
      PlanningDataApi.setTargetConstraintEnabled,
      body: {'id': id, 'enabled': enabled},
    );
  }

  /// POST /api/target-constraints/update — update an existing constraint.
  Future<void> updateTargetConstraint(TargetConstraint constraint) async {
    await _post(
      PlanningDataApi.updateTargetConstraint,
      body: constraint.toJson(),
    );
  }

  /// DELETE /api/integration-goals?all=true — delete every goal on the host.
  Future<void> deleteAllIntegrationGoals() async {
    await _delete(
      PlanningDataApi.deleteIntegrationGoal,
      query: {'all': 'true'},
    );
  }

  /// DELETE /api/integration-goals?id= — delete a single goal on the host.
  Future<void> deleteIntegrationGoal(int goalId) async {
    await _delete(PlanningDataApi.deleteIntegrationGoal, query: {'id': goalId});
  }

  /// DELETE /api/integration-goals?targetId= — delete all goals for a target.
  Future<void> deleteIntegrationGoalsForTarget(int targetId) async {
    await _delete(
      PlanningDataApi.deleteIntegrationGoal,
      query: {'targetId': targetId},
    );
  }

  /// GET /api/integration-goals/captured-count?targetId=&filter= — the host's
  /// accepted-light frame count for one (target, filter) pair. This MUST come
  /// from the host's `captured_images`, never the slave's empty local DB.
  Future<int> getCapturedFrameCount({
    required int targetId,
    required String filter,
  }) async {
    final response = await _get(
      PlanningDataApi.getCapturedFrameCount,
      query: {'targetId': targetId.toString(), 'filter': filter},
    );
    return _requiredPlanningInt(
      response,
      'count',
      'GET /api/integration-goals/captured-count',
    );
  }

  /// GET /api/integration-goals?targetId= — every goal, or the goals for one
  /// target when [targetId] is supplied.
  Future<List<IntegrationGoal>> getIntegrationGoals({int? targetId}) async {
    final response = await _get(
      PlanningDataApi.getIntegrationGoals,
      query: {if (targetId != null) 'targetId': targetId.toString()},
    );
    return _listFrom(response, 'goals', IntegrationGoal.fromJson);
  }

  /// POST /api/integration-goals — upsert a goal on the host and return its id.
  Future<int> upsertIntegrationGoal(IntegrationGoal goal) async {
    final response = await _post(
      PlanningDataApi.upsertIntegrationGoal,
      body: goal.toJson(),
    );
    return _requiredPlanningInt(response, 'id', 'POST /api/integration-goals');
  }

  /// GET /api/horizon-profiles — every custom horizon profile.
  Future<List<HorizonProfile>> getHorizonProfiles() async {
    final response = await _get(PlanningDataApi.getHorizonProfiles);
    return _listFrom(response, 'profiles', HorizonProfile.fromJson);
  }

  /// Run a lifecycle command against the imaging host's scheduler engine.
  Future<Map<String, dynamic>> controlScheduler(
    String action, {
    bool confirmWarnings = false,
  }) async {
    return _post(
      SchedulerApi.control,
      body: {'action': action, if (confirmWarnings) 'confirmWarnings': true},
    );
  }

  /// Persist and apply scheduler scoring configuration on the imaging host.
  Future<Map<String, dynamic>> updateSchedulerConfig(
    Map<String, dynamic> config,
  ) async {
    return _post(SchedulerApi.updateConfig, body: config);
  }

  /// Get the imaging host's complete unattended-scheduler state.
  Future<Map<String, dynamic>> getSchedulerState() async {
    return _get(SchedulerApi.getState);
  }

  Future<Map<String, dynamic>> planetariumCatalogSearch(String query) async {
    return await _get(PlanetariumApi.catalogSearch, query: {'query': query});
  }

  /// Remote-only: fetch the host's live autopilot preview decision so the
  /// slave's scheduler banner mirrors the real host pick instead of recomputing
  /// against its empty local catalog (which always yields "nothing eligible").
  /// Not part of the abstract backend — only a NetworkBackend slave calls this.
  Future<SchedulerDecision> getSchedulerPreview() async {
    final response = await _get(SchedulerApi.previewDecision);
    return SchedulerDecision.fromJson(Map<String, dynamic>.from(response));
  }

  /// Tonight's ranking as the host computes it for its own Plan screen:
  /// catalog candidates, the host's optics and horizon, and target progress.
  ///
  /// GET /api/suggestions/ranked
  Future<List<TargetSuggestion>> fetchRankedTonightSuggestions(
    TargetSuggestionConfig config,
  ) async {
    final params = <String, dynamic>{
      'minScore': config.minScore.toString(),
      'sortMode': config.sortMode.name,
      'prioritizeIncomplete': config.prioritizeIncomplete.toString(),
      if (config.maxMoonDistance != null)
        'maxMoonDistance': config.maxMoonDistance.toString(),
      if (config.preferredObjectTypes.isNotEmpty)
        'objectTypes': config.preferredObjectTypes.join(','),
    };
    final response = await _get(
      SuggestionApi.getRankedSuggestions,
      query: params,
    );
    return _sessionScienceObjectList(
      response,
      'suggestions',
      'GET /api/suggestions/ranked',
    ).map(TargetSuggestion.fromJson).toList(growable: false);
  }

  Future<Map<String, dynamic>> getSuggestionsForTonight({
    double? minScore,
    int? maxResults,
    String? sortMode,
    bool? prioritizeIncomplete,
    List<String>? objectTypes,
  }) async {
    final params = <String, dynamic>{};
    if (minScore != null) params['minScore'] = minScore.toString();
    if (maxResults != null) params['maxResults'] = maxResults.toString();
    if (sortMode != null) params['sortMode'] = sortMode;
    if (prioritizeIncomplete != null) {
      params['prioritizeIncomplete'] = prioritizeIncomplete.toString();
    }
    if (objectTypes != null && objectTypes.isNotEmpty) {
      params['objectTypes'] = objectTypes.join(',');
    }
    final response = await _get(
      SuggestionApi.getSuggestionsForTonight,
      query: params.isEmpty ? null : params,
    );
    return response;
  }
}

extension _HostPlanningDataNumbers on NetworkBackendTransport {
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

extension _HostPlanningDataLists on NetworkBackendTransport {
  List<T> _listFrom<T>(
    Map<String, dynamic> response,
    String key,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    return _rowsFromJson(response[key], fromJson);
  }

  /// POST /api/suggestions/score-now
  @override
  Future<List<ApiTargetScoreNow>> rankSchedulerTargets({
    required double latitudeDeg,
    required double longitudeDeg,
    required int nowUnixMs,
    required List<ApiSchedulerTarget> targets,
    required ApiScoringWeights weights,
    required List<ApiFloorSample> floor,
  }) async {
    final response = await _post(
      SuggestionApi.scoreTargetsNow,
      body: TargetScoringWire.rankRequest(
        latitudeDeg: latitudeDeg,
        longitudeDeg: longitudeDeg,
        nowUnixMs: nowUnixMs,
        targets: targets,
        weights: weights,
        floor: floor,
      ),
    );
    return TargetScoringWire.readRankResponse(
      response['scores'] as List<dynamic>,
    );
  }

  /// POST /api/suggestions/score-night
  @override
  Future<List<ApiNightScore>> scoreTargetsForNight({
    required ApiNightSky sky,
    required List<ApiNightTarget> targets,
    required ApiScoringWeights weights,
  }) async {
    final response = await _post(
      SuggestionApi.scoreTargetsForNight,
      body: TargetScoringWire.nightRequest(
        sky: sky,
        targets: targets,
        weights: weights,
      ),
    );
    return TargetScoringWire.readNightResponse(
      response['scores'] as List<dynamic>,
    );
  }
}
