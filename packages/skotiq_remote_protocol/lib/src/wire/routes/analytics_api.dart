import '../api_route.dart';

enum AnalyticsApi implements ApiEndpoint {
  getAllSessions(ApiRoute.get('/api/sessions', resource: ApiResource.system)),
  getActiveSession(
    ApiRoute.get('/api/sessions/active', resource: ApiResource.system),
  ),
  getRecentSessions(
    ApiRoute.get('/api/sessions/recent', resource: ApiResource.system),
  ),
  getSessionById(
    ApiRoute.get('/api/sessions/<id>', resource: ApiResource.system),
  ),
  getSessionStats(
    ApiRoute.get('/api/sessions/<id>/stats', resource: ApiResource.system),
  ),
  getSessionPsfTiles(
    ApiRoute.get('/api/sessions/<id>/psf-tiles', resource: ApiResource.system),
  ),
  getSessionResiduals(
    ApiRoute.get('/api/sessions/<id>/residuals', resource: ApiResource.system),
  ),
  getSessionsForTarget(
    ApiRoute.get(
      '/api/sessions/target/<targetId>',
      resource: ApiResource.system,
    ),
  ),
  createSession(ApiRoute.post('/api/sessions', resource: ApiResource.system)),
  updateSession(
    ApiRoute.put('/api/sessions/<id>', resource: ApiResource.system),
  ),
  endSession(
    ApiRoute.post('/api/sessions/<id>/end', resource: ApiResource.system),
  ),
  deleteSession(
    ApiRoute.delete('/api/sessions/<id>', resource: ApiResource.system),
  ),
  getAnalyticsSummary(
    ApiRoute.get('/api/analytics/summary', resource: ApiResource.system),
  ),
  getTotalIntegrationTime(
    ApiRoute.get(
      '/api/analytics/integration-time',
      resource: ApiResource.system,
    ),
  ),
  getUntrackedTargetsCount(
    ApiRoute.get(
      '/api/analytics/untracked-targets/count',
      resource: ApiResource.system,
    ),
  ),
  removeUntrackedTargets(
    ApiRoute.post(
      '/api/analytics/untracked-targets/remove',
      resource: ApiResource.system,
    ),
  ),
  getTargetStatistics(
    ApiRoute.get(
      '/api/analytics/target-statistics/<targetId>',
      resource: ApiResource.system,
    ),
  );

  const AnalyticsApi(this.route);

  @override
  final ApiRoute route;
}
