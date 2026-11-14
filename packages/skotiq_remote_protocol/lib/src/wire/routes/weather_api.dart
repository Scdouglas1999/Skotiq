import '../api_route.dart';

enum WeatherApi implements ApiEndpoint {
  getRadarData(
    ApiRoute.get('/api/weather/radar', resource: ApiResource.safety),
  ),
  getForecast(
    ApiRoute.get('/api/weather/forecast', resource: ApiResource.safety),
  ),
  getAlerts(ApiRoute.get('/api/weather/alerts', resource: ApiResource.safety)),
  getCloudCover(
    ApiRoute.get('/api/weather/cloud-cover', resource: ApiResource.safety),
  ),
  getSettings(
    ApiRoute.get('/api/weather/settings', resource: ApiResource.safety),
  ),
  updateSettings(
    ApiRoute.post('/api/weather/settings', resource: ApiResource.safety),
  ),
  checkSafeImaging(
    ApiRoute.get('/api/weather/safe-imaging', resource: ApiResource.safety),
  ),
  getCurrent(
    ApiRoute.get('/api/weather/current', resource: ApiResource.safety),
  ),
  clearCache(
    ApiRoute.post('/api/weather/clear-cache', resource: ApiResource.safety),
  );

  const WeatherApi(this.route);

  @override
  final ApiRoute route;
}
