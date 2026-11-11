import '../api_route.dart';

enum RunWatchApi implements ApiEndpoint {
  snapshot(
    ApiRoute.get('/api/run-watch/snapshot', resource: ApiResource.system),
  ),
  frameThumbnail(
    ApiRoute.get(
      '/api/run-watch/frame-thumbnail',
      resource: ApiResource.system,
    ),
  ),
  eventStream(
    ApiRoute.get(
      '/api/run-watch/events',
      resource: ApiResource.system,
      timeout: ApiTimeout.openEnded,
      queryToken: true,
    ),
  );

  const RunWatchApi(this.route);

  @override
  final ApiRoute route;
}
