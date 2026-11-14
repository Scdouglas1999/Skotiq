import '../api_route.dart';

enum PushApi implements ApiEndpoint {
  registerToken(
    ApiRoute.post('/api/push/register-token', resource: ApiResource.system),
  ),
  deleteToken(ApiRoute.delete('/api/push/token', resource: ApiResource.system)),
  getPreferences(
    ApiRoute.get('/api/push/preferences', resource: ApiResource.system),
  ),
  putPreferences(
    ApiRoute.put('/api/push/preferences', resource: ApiResource.system),
  ),
  getTargets(ApiRoute.get('/api/push/targets', resource: ApiResource.system));

  const PushApi(this.route);

  @override
  final ApiRoute route;
}
