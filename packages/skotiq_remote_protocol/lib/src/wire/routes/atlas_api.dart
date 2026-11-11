import '../api_route.dart';

enum AtlasApi implements ApiEndpoint {
  getRegions(ApiRoute.get('/api/atlas/regions', resource: ApiResource.system)),
  createRegion(
    ApiRoute.post('/api/atlas/regions', resource: ApiResource.system),
  ),
  getCoverage(
    ApiRoute.get('/api/atlas/coverage', resource: ApiResource.system),
  ),
  getRegion(
    ApiRoute.get('/api/atlas/region/<id>', resource: ApiResource.system),
  ),
  getRegionCutout(
    ApiRoute.get('/api/atlas/region/<id>/cutout', resource: ApiResource.system),
  ),
  getRegionTimeline(
    ApiRoute.get(
      '/api/atlas/region/<id>/timeline',
      resource: ApiResource.system,
    ),
  );

  const AtlasApi(this.route);

  @override
  final ApiRoute route;
}
