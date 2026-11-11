import 'package:skotiq_core/skotiq_core.dart';

/// [HostPlanning] on a linked host.
final class RemoteHostPlanning implements HostPlanning {
  RemoteHostPlanning(this._host);

  final NetworkBackend _host;

  @override
  Future<List<HorizonProfile>> getHorizonProfiles() =>
      _host.getHorizonProfiles();

  @override
  Future<List<ProjectTarget>> getProjectTargets(int projectId) =>
      _host.getProjectTargets(projectId);

  @override
  Future<List<TargetConstraint>> getTargetConstraints({int? targetId}) =>
      _host.getTargetConstraints(targetId: targetId);

  @override
  Future<Map<String, dynamic>> getSchedulerState() => _host.getSchedulerState();

  @override
  Future<SchedulerDecision> getSchedulerPreview() =>
      _host.getSchedulerPreview();

  @override
  Future<List<TargetSuggestion>> fetchRankedTonightSuggestions(
    TargetSuggestionConfig config,
  ) => _host.fetchRankedTonightSuggestions(config);

  @override
  Future<Map<String, dynamic>> getSuggestionsForTonight({
    double? minAltitude,
    double? minScore,
    int? maxResults,
    String? sortMode,
    bool? prioritizeIncomplete,
    List<String>? objectTypes,
  }) => _host.getSuggestionsForTonight(
    minAltitude: minAltitude,
    minScore: minScore,
    maxResults: maxResults,
    sortMode: sortMode,
    prioritizeIncomplete: prioritizeIncomplete,
    objectTypes: objectTypes,
  );

  @override
  Future<Map<String, dynamic>> planetariumCatalogSearch(String query) =>
      _host.planetariumCatalogSearch(query);
}
