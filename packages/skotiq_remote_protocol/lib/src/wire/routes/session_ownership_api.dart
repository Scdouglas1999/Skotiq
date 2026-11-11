import '../api_route.dart';

enum SessionOwnershipApi implements ApiEndpoint {
  getOwner(ApiRoute.get('/api/session/owner', resource: ApiResource.system)),
  getStatus(ApiRoute.get('/api/session/status', resource: ApiResource.system)),
  claim(ApiRoute.post('/api/session/claim', resource: ApiResource.system)),
  takeOver(
    ApiRoute.post('/api/session/take-over', resource: ApiResource.system),
  ),
  release(ApiRoute.post('/api/session/release', resource: ApiResource.system));

  const SessionOwnershipApi(this.route);

  @override
  final ApiRoute route;
}
