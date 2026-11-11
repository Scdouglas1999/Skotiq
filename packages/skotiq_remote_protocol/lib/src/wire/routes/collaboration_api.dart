import '../api_route.dart';

enum CollaborationApi implements ApiEndpoint {
  state(
    ApiRoute.get(
      '/api/collaboration/state',
      resource: ApiResource.constellation,
    ),
  ),
  join(
    ApiRoute.post(
      '/api/collaboration/viewers/join',
      resource: ApiResource.constellation,
      rate: ApiRateTier.control,
    ),
  ),
  leave(
    ApiRoute.post(
      '/api/collaboration/viewers/leave',
      resource: ApiResource.constellation,
      rate: ApiRateTier.control,
    ),
  ),
  preview(
    ApiRoute.post(
      '/api/collaboration/preview',
      resource: ApiResource.constellation,
      rate: ApiRateTier.control,
    ),
  ),
  chat(
    ApiRoute.post(
      '/api/collaboration/chat',
      resource: ApiResource.constellation,
      rate: ApiRateTier.control,
    ),
  ),
  annotation(
    ApiRoute.post(
      '/api/collaboration/annotations',
      resource: ApiResource.constellation,
      rate: ApiRateTier.control,
    ),
  ),
  getSessionHandoff(
    ApiRoute.get(
      '/api/session-handoff',
      resource: ApiResource.system,
      scope: ApiScope.admin,
    ),
  ),
  setSessionHandoff(
    ApiRoute.post(
      '/api/session-handoff',
      resource: ApiResource.system,
      scope: ApiScope.admin,
    ),
  ),
  clearSessionHandoff(
    ApiRoute.delete(
      '/api/session-handoff',
      resource: ApiResource.system,
      scope: ApiScope.admin,
    ),
  );

  const CollaborationApi(this.route);

  @override
  final ApiRoute route;
}
