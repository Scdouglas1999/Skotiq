import '../api_route.dart';

enum TargetApi implements ApiEndpoint {
  getAllTargets(ApiRoute.get('/api/targets', resource: ApiResource.system)),
  getFavoriteTargets(
    ApiRoute.get('/api/targets/favorites', resource: ApiResource.system),
  ),
  searchTargets(
    ApiRoute.get('/api/targets/search', resource: ApiResource.system),
  ),
  getTargetsByType(
    ApiRoute.get('/api/targets/by-type', resource: ApiResource.system),
  ),
  getTargetsByPriority(
    ApiRoute.get('/api/targets/by-priority', resource: ApiResource.system),
  ),
  getTargetById(
    ApiRoute.get('/api/targets/<id>', resource: ApiResource.system),
  ),
  createTarget(ApiRoute.post('/api/targets', resource: ApiResource.system)),
  updateTarget(ApiRoute.put('/api/targets/<id>', resource: ApiResource.system)),
  deleteTarget(
    ApiRoute.delete('/api/targets/<id>', resource: ApiResource.system),
  ),
  toggleFavorite(
    ApiRoute.post('/api/targets/<id>/favorite', resource: ApiResource.system),
  ),
  updateProgress(
    ApiRoute.put('/api/targets/<id>/progress', resource: ApiResource.system),
  );

  const TargetApi(this.route);

  @override
  final ApiRoute route;
}
