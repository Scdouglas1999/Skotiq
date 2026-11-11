import '../api_route.dart';

enum BroadcastApi implements ApiEndpoint {
  info(
    ApiRoute.get(
      '/api/broadcast/info',
      resource: ApiResource.system,
      scope: ApiScope.public,
    ),
  ),
  liveStack(
    ApiRoute.get(
      '/api/broadcast/live-stack',
      resource: ApiResource.system,
      scope: ApiScope.public,
    ),
  ),
  sse(
    ApiRoute.get(
      '/api/broadcast/sse',
      resource: ApiResource.system,
      scope: ApiScope.public,
      timeout: ApiTimeout.openEnded,
    ),
  ),
  page(
    ApiRoute.get(
      '/broadcast',
      resource: ApiResource.system,
      scope: ApiScope.public,
    ),
  );

  const BroadcastApi(this.route);

  @override
  final ApiRoute route;
}
