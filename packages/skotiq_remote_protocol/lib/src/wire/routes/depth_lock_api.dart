import '../api_route.dart';

enum DepthLockApi implements ApiEndpoint {
  getStatus(
    ApiRoute.get('/api/depthlock/status', resource: ApiResource.sequencer),
  ),
  listGoals(
    ApiRoute.get('/api/depthlock/goals', resource: ApiResource.sequencer),
  ),
  createGoal(
    ApiRoute.post('/api/depthlock/goals', resource: ApiResource.sequencer),
  ),
  inspectReference(
    ApiRoute.post(
      '/api/depthlock/reference/inspect',
      resource: ApiResource.sequencer,
    ),
  ),
  skyRectangle(
    ApiRoute.post(
      '/api/depthlock/reference/sky-rectangle',
      resource: ApiResource.sequencer,
    ),
  ),
  checkMeasurement(
    ApiRoute.post(
      '/api/depthlock/measurement/check',
      resource: ApiResource.sequencer,
    ),
  ),
  suggestFloor(
    ApiRoute.post(
      '/api/depthlock/measurement/suggest-floor',
      resource: ApiResource.sequencer,
    ),
  ),
  setPreferences(
    ApiRoute.post(
      '/api/depthlock/goals/<goalId>/preferences',
      resource: ApiResource.sequencer,
    ),
  ),
  ingestFrame(
    ApiRoute.post(
      '/api/depthlock/goals/<goalId>/ingest',
      resource: ApiResource.sequencer,
    ),
  ),
  replayGoal(
    ApiRoute.post(
      '/api/depthlock/goals/<goalId>/replay',
      resource: ApiResource.sequencer,
    ),
  ),
  goalCurve(
    ApiRoute.get(
      '/api/depthlock/goals/<goalId>/curve',
      resource: ApiResource.sequencer,
    ),
  ),
  getGoal(
    ApiRoute.get(
      '/api/depthlock/goals/<goalId>',
      resource: ApiResource.sequencer,
    ),
  ),
  reviseGoal(
    ApiRoute.put(
      '/api/depthlock/goals/<goalId>',
      resource: ApiResource.sequencer,
    ),
  ),
  removeGoal(
    ApiRoute.delete(
      '/api/depthlock/goals/<goalId>',
      resource: ApiResource.sequencer,
    ),
  );

  const DepthLockApi(this.route);

  @override
  final ApiRoute route;
}
