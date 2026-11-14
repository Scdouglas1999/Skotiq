import '../api_route.dart';

enum SchedulerApi implements ApiEndpoint {
  previewDecision(
    ApiRoute.get('/api/scheduler/preview', resource: ApiResource.system),
  ),
  getState(ApiRoute.get('/api/scheduler/state', resource: ApiResource.system)),
  control(
    ApiRoute.post('/api/scheduler/control', resource: ApiResource.system),
  ),
  updateConfig(
    ApiRoute.post('/api/scheduler/config', resource: ApiResource.system),
  ),
  calculateAltitude(
    ApiRoute.get('/api/scheduler/altitude', resource: ApiResource.system),
  ),
  calculateTransitTime(
    ApiRoute.get('/api/scheduler/transit-time', resource: ApiResource.system),
  ),
  calculateRiseSet(
    ApiRoute.get('/api/scheduler/rise-set', resource: ApiResource.system),
  ),
  calculateHoursAbove(
    ApiRoute.get(
      '/api/scheduler/hours-above-horizon',
      resource: ApiResource.system,
    ),
  ),
  optimizeTargets(
    ApiRoute.post(
      '/api/scheduler/optimize-targets',
      resource: ApiResource.system,
    ),
  ),
  getTwilightTimes(
    ApiRoute.get('/api/scheduler/twilight-times', resource: ApiResource.system),
  ),
  getMoonInfo(
    ApiRoute.get('/api/scheduler/moon-info', resource: ApiResource.system),
  );

  const SchedulerApi(this.route);

  @override
  final ApiRoute route;
}
