import '../api_route.dart';

enum FlatWizardApi implements ApiEndpoint {
  run(
    ApiRoute.post(
      '/api/flat-wizard/run',
      resource: ApiResource.system,
      rate: ApiRateTier.control,
    ),
  ),
  cancelRun(
    ApiRoute.post(
      '/api/flat-wizard/cancel',
      resource: ApiResource.system,
      rate: ApiRateTier.control,
    ),
  ),
  runState(ApiRoute.get('/api/flat-wizard/state', resource: ApiResource.system)),
  preview(
    ApiRoute.get(
      '/api/flat-wizard/preview',
      resource: ApiResource.system,
      timeout: ApiTimeout.slowRead,
    ),
  ),
  calibrateFilter(
    ApiRoute.post('/api/flat-wizard/calibrate', resource: ApiResource.system),
  ),
  calibrateMultipleFilters(
    ApiRoute.post(
      '/api/flat-wizard/calibrate-multi',
      resource: ApiResource.system,
    ),
  ),
  generateSequence(
    ApiRoute.post(
      '/api/flat-wizard/generate-sequence',
      resource: ApiResource.system,
    ),
  ),
  quickCalibrate(
    ApiRoute.post(
      '/api/flat-wizard/quick-calibrate',
      resource: ApiResource.system,
    ),
  );

  const FlatWizardApi(this.route);

  @override
  final ApiRoute route;
}
