import '../api_route.dart';

enum AuxiliaryApi implements ApiEndpoint {
  switchStatus(
    ApiRoute.get('/api/switch/status', resource: ApiResource.switchGear),
  ),
  switchSet(
    ApiRoute.post(
      '/api/switch/set',
      resource: ApiResource.switchGear,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  coverStatus(ApiRoute.get('/api/cover/status', resource: ApiResource.cover)),
  coverOpen(
    ApiRoute.post(
      '/api/cover/open',
      resource: ApiResource.cover,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  coverClose(
    ApiRoute.post(
      '/api/cover/close',
      resource: ApiResource.cover,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  coverBrightness(
    ApiRoute.post(
      '/api/cover/brightness',
      resource: ApiResource.cover,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  calibratorOn(
    ApiRoute.post(
      '/api/cover/calibrator-on',
      resource: ApiResource.cover,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  calibratorOff(
    ApiRoute.post(
      '/api/cover/calibrator-off',
      resource: ApiResource.cover,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  );

  const AuxiliaryApi(this.route);

  @override
  final ApiRoute route;
}
