import '../api_route.dart';

enum UpdateApi implements ApiEndpoint {
  checkForUpdate(
    ApiRoute.post(
      '/api/system/update/check',
      resource: ApiResource.system,
      scope: ApiScope.admin,
      rate: ApiRateTier.control,
    ),
  ),
  getStatus(
    ApiRoute.get('/api/system/update/status', resource: ApiResource.system),
  ),
  download(
    ApiRoute.post(
      '/api/system/update/download',
      resource: ApiResource.system,
      scope: ApiScope.admin,
      rate: ApiRateTier.control,
      audit: 'update_download',
    ),
  ),
  apply(
    ApiRoute.post(
      '/api/system/update/apply',
      resource: ApiResource.system,
      scope: ApiScope.admin,
      rate: ApiRateTier.highRisk,
      audit: 'update_apply',
    ),
  ),
  abort(
    ApiRoute.post(
      '/api/system/update/abort',
      resource: ApiResource.system,
      scope: ApiScope.admin,
      rate: ApiRateTier.control,
    ),
  ),
  rollback(
    ApiRoute.post(
      '/api/system/update/rollback',
      resource: ApiResource.system,
      scope: ApiScope.admin,
      rate: ApiRateTier.highRisk,
      audit: 'update_rollback',
    ),
  ),
  getStaged(
    ApiRoute.get('/api/system/update/staged', resource: ApiResource.system),
  ),
  discardStaged(
    ApiRoute.delete(
      '/api/system/update/staged',
      resource: ApiResource.system,
      scope: ApiScope.admin,
      rate: ApiRateTier.highRisk,
      audit: 'update_discard_staged',
    ),
  );

  const UpdateApi(this.route);

  @override
  final ApiRoute route;
}
