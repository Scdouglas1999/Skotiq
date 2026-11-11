import '../api_route.dart';

enum SyncApi implements ApiEndpoint {
  getStatus(
    ApiRoute.get(
      '/api/sync/status',
      resource: ApiResource.backup,
      scope: ApiScope.admin,
    ),
  ),
  pushNow(
    ApiRoute.post(
      '/api/sync/push',
      resource: ApiResource.backup,
      scope: ApiScope.admin,
    ),
  );

  const SyncApi(this.route);

  @override
  final ApiRoute route;
}
