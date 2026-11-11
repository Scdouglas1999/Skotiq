import '../api_route.dart';

enum TransientApi implements ApiEndpoint {
  getActiveTransients(
    ApiRoute.get('/api/transients', resource: ApiResource.system),
  ),
  getSettings(
    ApiRoute.get('/api/transients/settings', resource: ApiResource.system),
  ),
  updateSettings(
    ApiRoute.post('/api/transients/settings', resource: ApiResource.system),
  ),
  getQueued(
    ApiRoute.get('/api/transients/queued', resource: ApiResource.system),
  ),
  getStates(
    ApiRoute.get('/api/transients/states', resource: ApiResource.system),
  ),
  clearStates(
    ApiRoute.delete('/api/transients/states', resource: ApiResource.system),
  ),
  queueTransient(
    ApiRoute.post('/api/transients/<id>/queue', resource: ApiResource.system),
  ),
  dismissTransient(
    ApiRoute.post('/api/transients/<id>/dismiss', resource: ApiResource.system),
  ),
  updateState(
    ApiRoute.post('/api/transients/<id>/state', resource: ApiResource.system),
  ),
  refreshAlerts(
    ApiRoute.post('/api/transients/refresh', resource: ApiResource.system),
  );

  const TransientApi(this.route);

  @override
  final ApiRoute route;
}
