import '../api_route.dart';

enum CoImagingApi implements ApiEndpoint {
  listSessions(
    ApiRoute.get('/api/coimaging/sessions', resource: ApiResource.coimaging),
  ),
  createSession(
    ApiRoute.post(
      '/api/coimaging/sessions',
      resource: ApiResource.coimaging,
      rate: ApiRateTier.control,
    ),
  ),
  getSession(
    ApiRoute.get(
      '/api/coimaging/sessions/<sessionId>',
      resource: ApiResource.coimaging,
    ),
  ),
  joinSession(
    ApiRoute.post(
      '/api/coimaging/sessions/<sessionId>/join',
      resource: ApiResource.coimaging,
      rate: ApiRateTier.control,
    ),
  ),
  leaveSession(
    ApiRoute.post(
      '/api/coimaging/sessions/<sessionId>/leave',
      resource: ApiResource.coimaging,
      rate: ApiRateTier.control,
    ),
  ),
  closeSession(
    ApiRoute.post(
      '/api/coimaging/sessions/<sessionId>/close',
      resource: ApiResource.coimaging,
      rate: ApiRateTier.control,
    ),
  ),
  contribute(
    ApiRoute.post(
      '/api/coimaging/sessions/<sessionId>/contribute',
      resource: ApiResource.coimaging,
      rate: ApiRateTier.highRisk,
      audit: 'coimaging_sub_contribute',
    ),
  ),
  framingOffset(
    ApiRoute.get(
      '/api/coimaging/sessions/<sessionId>/framing-offset',
      resource: ApiResource.coimaging,
    ),
  ),
  subComplete(
    ApiRoute.post(
      '/api/coimaging/sessions/<sessionId>/sub-complete',
      resource: ApiResource.coimaging,
      rate: ApiRateTier.highRisk,
      audit: 'coimaging_sub_contribute',
    ),
  ),
  autoBaton(
    ApiRoute.post(
      '/api/coimaging/sessions/<sessionId>/baton/auto',
      resource: ApiResource.coimaging,
      rate: ApiRateTier.control,
    ),
  ),
  claimBaton(
    ApiRoute.post(
      '/api/coimaging/sessions/<sessionId>/baton/claim',
      resource: ApiResource.coimaging,
      rate: ApiRateTier.control,
    ),
  ),
  releaseBaton(
    ApiRoute.post(
      '/api/coimaging/sessions/<sessionId>/baton/release',
      resource: ApiResource.coimaging,
      rate: ApiRateTier.control,
    ),
  );

  const CoImagingApi(this.route);

  @override
  final ApiRoute route;
}
