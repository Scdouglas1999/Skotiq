import '../api_route.dart';

enum PostSessionApi implements ApiEndpoint {
  getSettings(
    ApiRoute.get('/api/post-session/settings', resource: ApiResource.system),
  ),
  updateSettings(
    ApiRoute.post('/api/post-session/settings', resource: ApiResource.system),
  ),
  integrateSession(
    ApiRoute.post('/api/post-session/integrate', resource: ApiResource.system),
  ),
  drizzleIntegrate(
    ApiRoute.post('/api/post-session/drizzle', resource: ApiResource.system),
  ),
  analyzeNight(
    ApiRoute.post(
      '/api/post-session/analyze-night',
      resource: ApiResource.system,
    ),
  ),
  buildMasterFlat(
    ApiRoute.post(
      '/api/post-session/build-master-flat',
      resource: ApiResource.system,
    ),
  ),
  colorCalibrate(
    ApiRoute.post(
      '/api/post-session/color-calibrate',
      resource: ApiResource.system,
    ),
  ),
  detectStars(
    ApiRoute.post(
      '/api/post-session/detect-stars',
      resource: ApiResource.system,
    ),
  ),
  extractBackground(
    ApiRoute.post(
      '/api/post-session/extract-background',
      resource: ApiResource.system,
    ),
  ),
  combineChannels(
    ApiRoute.post(
      '/api/post-session/combine-channels',
      resource: ApiResource.system,
    ),
  ),
  masterAccumulate(
    ApiRoute.post(
      '/api/post-session/master-accumulate',
      resource: ApiResource.system,
    ),
  );

  const PostSessionApi(this.route);

  @override
  final ApiRoute route;
}
