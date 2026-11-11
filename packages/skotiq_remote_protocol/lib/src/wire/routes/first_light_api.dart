import '../api_route.dart';

enum FirstLightApi implements ApiEndpoint {
  getCandidates(
    ApiRoute.get('/api/firstlight/candidates', resource: ApiResource.system),
  ),
  getNear(ApiRoute.get('/api/firstlight/near', resource: ApiResource.system)),
  getCrop(
    ApiRoute.get(
      '/api/firstlight/<id>/crops/<stage>',
      resource: ApiResource.system,
    ),
  ),
  review(
    ApiRoute.post('/api/firstlight/<id>/review', resource: ApiResource.system),
  ),
  dismiss(
    ApiRoute.post('/api/firstlight/<id>/dismiss', resource: ApiResource.system),
  ),
  submitTns(
    ApiRoute.post(
      '/api/firstlight/<id>/submit/tns',
      resource: ApiResource.system,
    ),
  ),
  exportAavso(
    ApiRoute.post(
      '/api/firstlight/<id>/export/aavso',
      resource: ApiResource.system,
    ),
  ),
  exportMpc(
    ApiRoute.post(
      '/api/firstlight/<id>/export/mpc',
      resource: ApiResource.system,
    ),
  );

  const FirstLightApi(this.route);

  @override
  final ApiRoute route;
}
