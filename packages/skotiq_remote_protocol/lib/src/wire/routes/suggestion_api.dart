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
  );

  const SuggestionApi(this.route);

  @override
  final ApiRoute route;
}
