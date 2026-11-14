import '../api_route.dart';

enum StaticFileApi implements ApiEndpoint {
  root(ApiRoute.get('/', resource: ApiResource.system, scope: ApiScope.public)),
  favicon(
    ApiRoute.get(
      '/favicon.ico',
      resource: ApiResource.system,
      scope: ApiScope.public,
    ),
  ),
  dashboardIndexDashboard(
    ApiRoute.get(
      '/dashboard',
      resource: ApiResource.system,
      scope: ApiScope.public,
    ),
  ),
  dashboardIndexSlash(
    ApiRoute.get(
      '/dashboard/',
      resource: ApiResource.system,
      scope: ApiScope.public,
    ),
  ),
  dashboardFile(
    ApiRoute.get(
      '/dashboard/<path|.*>',
      resource: ApiResource.system,
      scope: ApiScope.public,
    ),
  ),
  runWatchIndexRunWatch(
    ApiRoute.get(
      '/run-watch',
      resource: ApiResource.system,
      scope: ApiScope.public,
    ),
  ),
  runWatchIndexSlash(
    ApiRoute.get(
      '/run-watch/',
      resource: ApiResource.system,
      scope: ApiScope.public,
    ),
  ),
  runWatchFile(
    ApiRoute.get(
      '/run-watch/<path|.*>',
      resource: ApiResource.system,
      scope: ApiScope.public,
    ),
  );

  const StaticFileApi(this.route);

  @override
  final ApiRoute route;
}
