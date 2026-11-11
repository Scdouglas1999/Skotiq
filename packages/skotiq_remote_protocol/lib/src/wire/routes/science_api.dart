import '../api_route.dart';

enum ScienceApi implements ApiEndpoint {
  getSessionBundle(
    ApiRoute.get(
      '/api/science/session/<sessionId>/bundle',
      resource: ApiResource.system,
      timeout: ApiTimeout.slowRead,
    ),
  ),
  postSessionBundle(
    ApiRoute.post(
      '/api/science/session/<sessionId>/bundle',
      resource: ApiResource.system,
      scope: ApiScope.view,
    ),
  ),
  startSessionReprocess(
    ApiRoute.post(
      '/api/science/session/<sessionId>/reprocess',
      resource: ApiResource.system,
    ),
  ),
  getSessionReprocess(
    ApiRoute.get(
      '/api/science/session/<sessionId>/reprocess',
      resource: ApiResource.system,
    ),
  ),
  getSessionlessBundle(
    ApiRoute.get(
      '/api/science/sessionless/recent',
      resource: ApiResource.system,
    ),
  ),
  getScienceSettings(
    ApiRoute.get('/api/science/settings', resource: ApiResource.system),
  ),
  updateScienceSettings(
    ApiRoute.post('/api/science/settings', resource: ApiResource.system),
  ),
  getSmartNightSettings(
    ApiRoute.get('/api/smart-night/settings', resource: ApiResource.system),
  ),
  updateSmartNightSettings(
    ApiRoute.post('/api/smart-night/settings', resource: ApiResource.system),
  ),
  getSessionConfig(
    ApiRoute.get(
      '/api/science/session/<sessionId>/config',
      resource: ApiResource.system,
    ),
  ),
  updateSessionConfig(
    ApiRoute.post(
      '/api/science/session/<sessionId>/config',
      resource: ApiResource.system,
    ),
  ),
  getPhotometricTransforms(
    ApiRoute.get('/api/science/transforms', resource: ApiResource.system),
  ),
  matchPhotometricCalibrationStars(
    ApiRoute.post(
      '/api/science/calibration/image/<imageId>/match-stars',
      resource: ApiResource.system,
    ),
  ),
  computePhotometricTransform(
    ApiRoute.post(
      '/api/science/calibration/compute-transform',
      resource: ApiResource.system,
    ),
  ),
  savePhotometricTransform(
    ApiRoute.post(
      '/api/science/calibration/save-transform',
      resource: ApiResource.system,
    ),
  ),
  generateLineRatios(
    ApiRoute.post(
      '/api/science/session/<sessionId>/generate-line-ratios',
      resource: ApiResource.system,
    ),
  ),
  exportAavso(
    ApiRoute.post(
      '/api/science/session/<sessionId>/export/aavso',
      resource: ApiResource.system,
    ),
  ),
  generateObservationReport(
    ApiRoute.get(
      '/api/science/session/<sessionId>/report/pdf',
      resource: ApiResource.system,
      timeout: ApiTimeout.slowRead,
    ),
  );

  const ScienceApi(this.route);

  @override
  final ApiRoute route;
}
