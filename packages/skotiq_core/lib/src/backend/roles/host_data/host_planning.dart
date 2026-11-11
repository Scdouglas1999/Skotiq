import 'package:skotiq_core/skotiq_core.dart';

/// Planning data of a linked imaging host: horizon profiles, project targets, target constraints, the scheduler and tonight's suggestions.
abstract interface class HostPlanning {
  /// GET /api/horizon-profiles — every custom horizon profile.
  Future<List<HorizonProfile>> getHorizonProfiles();

  /// GET /api/projects/targets?projectId= — the membership rows for a project.
  Future<List<ProjectTarget>> getProjectTargets(int projectId);

  /// GET /api/target-constraints?targetId= — every constraint, or the
  /// constraints for one target.
  Future<List<TargetConstraint>> getTargetConstraints({int? targetId});

  /// Get the imaging host's complete unattended-scheduler state.
  Future<Map<String, dynamic>> getSchedulerState();

  /// Remote-only: fetch the host's live autopilot preview decision so the
  /// slave's scheduler banner mirrors the real host pick instead of recomputing
  /// against its empty local catalog (which always yields "nothing eligible").
  /// Not part of the abstract backend — only a NetworkBackend slave calls this.
  Future<SchedulerDecision> getSchedulerPreview();

  /// Tonight's ranking as the host computes it for its own Plan screen:
  /// catalog candidates, the host's optics and horizon, and target progress.
  ///
  /// GET /api/suggestions/ranked
  Future<List<TargetSuggestion>> fetchRankedTonightSuggestions(
    TargetSuggestionConfig config,
  );

  /// Get target suggestions for tonight
  Future<Map<String, dynamic>> getSuggestionsForTonight({
    double? minAltitude,
    double? minScore,
    int? maxResults,
    String? sortMode,
    bool? prioritizeIncomplete,
    List<String>? objectTypes,
  });

  /// Search catalog for objects
  Future<Map<String, dynamic>> planetariumCatalogSearch(String query);
}
