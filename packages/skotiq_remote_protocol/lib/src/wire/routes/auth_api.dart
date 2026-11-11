import '../api_route.dart';

enum AuthApi implements ApiEndpoint {
  wsTicketIssue(ApiRoute.post('/api/ws/ticket', resource: ApiResource.system)),
  cookieIssue(ApiRoute.post('/api/auth/cookie', resource: ApiResource.system)),
  csrfFetch(ApiRoute.get('/api/auth/csrf', resource: ApiResource.system)),
  logout(ApiRoute.post('/api/auth/logout', resource: ApiResource.system));

  const AuthApi(this.route);

  @override
  final ApiRoute route;
}
