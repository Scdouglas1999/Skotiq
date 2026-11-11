import '../api_route.dart';

enum RuntimeStateApi implements ApiEndpoint {
  getState(ApiRoute.get('/api/runtime/state', resource: ApiResource.system)),
  report(ApiRoute.post('/api/runtime/state', resource: ApiResource.system)),
  recentEvents(
    ApiRoute.get('/api/runtime/recent-events', resource: ApiResource.system),
  ),
  nightHistory(
    ApiRoute.get('/api/runtime/night-history', resource: ApiResource.system),
  ),
  startManualLoop(
    ApiRoute.post('/api/runtime/manual-loop', resource: ApiResource.system),
  ),
  stopManualLoop(
    ApiRoute.post(
      '/api/runtime/manual-loop/stop',
      resource: ApiResource.system,
    ),
  );

  const RuntimeStateApi(this.route);

  @override
  final ApiRoute route;
}
