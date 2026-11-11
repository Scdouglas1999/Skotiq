import '../api_route.dart';

enum StackingApi implements ApiEndpoint {
  start(ApiRoute.post('/api/stacking/start', resource: ApiResource.system)),
  addFrame(
    ApiRoute.post('/api/stacking/add-frame', resource: ApiResource.system),
  ),
  updateConfig(
    ApiRoute.post('/api/stacking/config', resource: ApiResource.system),
  ),
  reset(ApiRoute.post('/api/stacking/reset', resource: ApiResource.system)),
  stop(ApiRoute.post('/api/stacking/stop', resource: ApiResource.system)),
  status(ApiRoute.get('/api/stacking/status', resource: ApiResource.system)),
  stats(ApiRoute.get('/api/stacking/stats', resource: ApiResource.system)),
  result(ApiRoute.get('/api/stacking/result', resource: ApiResource.system)),
  preview(ApiRoute.get('/api/stacking/preview', resource: ApiResource.system)),
  savedResults(
    ApiRoute.get('/api/stacking/results', resource: ApiResource.system),
  ),
  savedResultPreview(
    ApiRoute.get(
      '/api/stacking/results/<resultId>/preview',
      resource: ApiResource.system,
    ),
  ),
  savedResult(
    ApiRoute.get(
      '/api/stacking/results/<resultId>',
      resource: ApiResource.system,
    ),
  );

  const StackingApi(this.route);

  @override
  final ApiRoute route;
}
