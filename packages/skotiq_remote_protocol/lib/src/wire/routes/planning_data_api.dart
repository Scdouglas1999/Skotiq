import '../api_route.dart';

enum PlanningDataApi implements ApiEndpoint {
  getIntegrationGoals(
    ApiRoute.get('/api/integration-goals', resource: ApiResource.system),
  ),
  getCapturedFrameCount(
    ApiRoute.get(
      '/api/integration-goals/captured-count',
      resource: ApiResource.system,
    ),
  ),
  upsertIntegrationGoal(
    ApiRoute.post('/api/integration-goals', resource: ApiResource.system),
  ),
  deleteIntegrationGoal(
    ApiRoute.delete('/api/integration-goals', resource: ApiResource.system),
  ),
  getTargetConstraints(
    ApiRoute.get('/api/target-constraints', resource: ApiResource.system),
  ),
  insertTargetConstraint(
    ApiRoute.post('/api/target-constraints', resource: ApiResource.system),
  ),
  updateTargetConstraint(
    ApiRoute.post(
      '/api/target-constraints/update',
      resource: ApiResource.system,
    ),
  ),
  setTargetConstraintEnabled(
    ApiRoute.post(
      '/api/target-constraints/set-enabled',
      resource: ApiResource.system,
    ),
  ),
  deleteTargetConstraint(
    ApiRoute.delete('/api/target-constraints', resource: ApiResource.system),
  ),
  getSchedulerRemovedTargets(
    ApiRoute.get(
      '/api/scheduler/removed-targets',
      resource: ApiResource.system,
    ),
  ),
  removeSchedulerTarget(
    ApiRoute.post(
      '/api/scheduler/removed-targets',
      resource: ApiResource.system,
    ),
  ),
  readmitSchedulerTarget(
    ApiRoute.delete(
      '/api/scheduler/removed-targets',
      resource: ApiResource.system,
    ),
  ),
  getHorizonProfiles(
    ApiRoute.get('/api/horizon-profiles', resource: ApiResource.system),
  ),
  getProjects(ApiRoute.get('/api/projects', resource: ApiResource.system)),
  getProjectTargets(
    ApiRoute.get('/api/projects/targets', resource: ApiResource.system),
  ),
  getProjectProgress(
    ApiRoute.get('/api/projects/progress', resource: ApiResource.system),
  );

  const PlanningDataApi(this.route);

  @override
  final ApiRoute route;
}
