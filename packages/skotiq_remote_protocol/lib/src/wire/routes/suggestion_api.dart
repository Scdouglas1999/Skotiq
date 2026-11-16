import '../api_route.dart';

enum SuggestionApi implements ApiEndpoint {
  getSuggestionsForTonight(
    ApiRoute.get('/api/suggestions/tonight', resource: ApiResource.system),
  ),
  getRankedSuggestions(
    ApiRoute.get('/api/suggestions/ranked', resource: ApiResource.system),
  ),
  getConfig(
    ApiRoute.get('/api/suggestions/config', resource: ApiResource.system),
  ),
  getTargetScore(
    ApiRoute.get(
      '/api/suggestions/score/<targetId>',
      resource: ApiResource.system,
    ),
  ),

  /// A TargetScheduler step's targets ranked now by the host's scorer.
  scoreTargetsNow(
    ApiRoute.post(
      '/api/suggestions/score-now',
      resource: ApiResource.system,
      scope: ApiScope.view,
      timeout: ApiTimeout.read,
      bucket: ApiBucket.read,
    ),
  ),

  /// Catalog positions scored over a night by the host's scorer.
  scoreTargetsForNight(
    ApiRoute.post(
      '/api/suggestions/score-night',
      resource: ApiResource.system,
      scope: ApiScope.view,
      timeout: ApiTimeout.read,
      bucket: ApiBucket.read,
      maxBodyBytes: ApiBodyLimit.scoring,
    ),
  );

  const SuggestionApi(this.route);

  @override
  final ApiRoute route;
}
