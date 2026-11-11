import 'package:skotiq_core/skotiq_core.dart';

/// Projects, integration goals, target constraints and the scheduler queue
/// kept in a linked imaging host's database.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostPlanningData {
  Future<CampaignProgress> getProjectProgress(int projectId);

  Future<List<Project>> getProjects();

  Future<List<ProjectTarget>> getProjectTargets(int projectId);

  Future<void> clearSchedulerQueue();

  Future<Set<int>> getSchedulerQueueRemovedTargets();

  Future<void> readmitSchedulerQueueTarget(int targetId);

  Future<void> removeSchedulerQueueTarget(int targetId);

  Future<void> deleteAllTargetConstraints();

  Future<void> deleteTargetConstraint(int id);

  Future<void> deleteTargetConstraintsForTarget(int targetId);

  Future<List<TargetConstraint>> getTargetConstraints({int? targetId});

  Future<int> insertTargetConstraint(TargetConstraint constraint);

  Future<void> setTargetConstraintEnabled(int id, bool enabled);

  Future<void> updateTargetConstraint(TargetConstraint constraint);

  Future<void> deleteAllIntegrationGoals();

  Future<void> deleteIntegrationGoal(int goalId);

  Future<void> deleteIntegrationGoalsForTarget(int targetId);

  Future<int> getCapturedFrameCount({
    required int targetId,
    required String filter,
  });

  Future<List<IntegrationGoal>> getIntegrationGoals({int? targetId});

  Future<int> upsertIntegrationGoal(IntegrationGoal goal);

  Future<Map<String, dynamic>> controlScheduler(
    String action, {
    bool confirmWarnings = false,
  });

  Future<List<HorizonProfile>> getHorizonProfiles();

  Future<Map<String, String>> getSmartNightSettings();

  Future<Map<String, dynamic>> updateSchedulerConfig(
    Map<String, dynamic> config,
  );

  Future<void> updateSmartNightSettings(Map<String, String> settings);

  Future<Map<String, dynamic>> getSchedulerState();

  Future<SchedulerDecision> getSchedulerPreview();

  Future<List<TargetSuggestion>> fetchRankedTonightSuggestions(
    TargetSuggestionConfig config,
  );

  Future<Map<String, dynamic>> getSuggestionsForTonight({
    double? minAltitude,
    double? minScore,
    int? maxResults,
    String? sortMode,
    bool? prioritizeIncomplete,
    List<String>? objectTypes,
  });

  Future<Map<String, dynamic>> planetariumCatalogSearch(String query);
}
