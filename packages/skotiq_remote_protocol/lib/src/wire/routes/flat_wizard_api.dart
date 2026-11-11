import '../api_route.dart';

enum FlatWizardApi implements ApiEndpoint {
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
