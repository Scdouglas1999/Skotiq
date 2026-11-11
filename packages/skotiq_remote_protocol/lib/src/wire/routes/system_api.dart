import '../api_route.dart';

enum SystemApi implements ApiEndpoint {
  info(
    ApiRoute.get(
      '/api/info',
      resource: ApiResource.info,
      scope: ApiScope.public,
    ),
  ),
  status(ApiRoute.get('/api/status', resource: ApiResource.info)),
  selfTest(
    ApiRoute.get(
      '/api/self-test',
      resource: ApiResource.system,
      scope: ApiScope.admin,
    ),
  ),
  version(ApiRoute.get('/api/system/version', resource: ApiResource.system)),
  diskSpace(
    ApiRoute.get('/api/system/disk-space', resource: ApiResource.system),
  ),
  openApiSpec(ApiRoute.get('/api/openapi.json', resource: ApiResource.info)),
  pairPage(
    ApiRoute.get('/pair', resource: ApiResource.system, scope: ApiScope.public),
  );

  const SystemApi(this.route);

  @override
  final ApiRoute route;
}
