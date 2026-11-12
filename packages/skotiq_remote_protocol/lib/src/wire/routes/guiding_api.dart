import '../api_route.dart';

enum GuidingApi implements ApiEndpoint {
  phd2IsRunning(
    ApiRoute.get('/api/phd2/running', resource: ApiResource.guiding),
  ),
  phd2Probe(ApiRoute.get('/api/phd2/probe', resource: ApiResource.guiding)),
  phd2Connect(
    ApiRoute.post(
      '/api/phd2/connect',
      resource: ApiResource.guiding,
      rate: ApiRateTier.control,
    ),
  ),
  phd2Disconnect(
    ApiRoute.post(
      '/api/phd2/disconnect',
      resource: ApiResource.guiding,
      rate: ApiRateTier.control,
    ),
  ),
  phd2ClearCalibration(
    ApiRoute.post(
      '/api/phd2/clear-calibration',
      resource: ApiResource.guiding,
      rate: ApiRateTier.control,
    ),
  ),
  phd2FlipCalibration(
    ApiRoute.post(
      '/api/phd2/flip-calibration',
      resource: ApiResource.guiding,
      rate: ApiRateTier.control,
    ),
  ),
  phd2GetAlgoParamNames(
    ApiRoute.get('/api/phd2/algo-params', resource: ApiResource.guiding),
  ),
  phd2GetAlgoParam(
    ApiRoute.get('/api/phd2/algo-param', resource: ApiResource.guiding),
  ),
  phd2SetAlgoParam(
    ApiRoute.post(
      '/api/phd2/algo-param',
      resource: ApiResource.guiding,
      rate: ApiRateTier.control,
    ),
  ),
  guiderStartGuiding(
    ApiRoute.post(
      '/api/guider/start-guiding',
      resource: ApiResource.guiding,
      rate: ApiRateTier.control,
    ),
  ),
  guiderStopGuiding(
    ApiRoute.post(
      '/api/guider/stop-guiding',
      resource: ApiResource.guiding,
      rate: ApiRateTier.control,
    ),
  ),
  guiderDither(
    ApiRoute.post(
      '/api/guider/dither',
      resource: ApiResource.guiding,
      rate: ApiRateTier.control,
    ),
  ),
  guiderLoop(
    ApiRoute.post(
      '/api/guider/loop',
      resource: ApiResource.guiding,
      rate: ApiRateTier.control,
    ),
  ),
  guiderSetPaused(
    ApiRoute.post(
      '/api/guider/pause',
      resource: ApiResource.guiding,
      rate: ApiRateTier.control,
    ),
  ),
  guiderFindStar(
    ApiRoute.post(
      '/api/guider/find-star',
      resource: ApiResource.guiding,
      rate: ApiRateTier.control,
    ),
  ),
  guiderSetLockPosition(
    ApiRoute.post(
      '/api/guider/set-lock-position',
      resource: ApiResource.guiding,
      rate: ApiRateTier.control,
    ),
  ),
  guiderGetLockPosition(
    ApiRoute.get('/api/guider/lock-position', resource: ApiResource.guiding),
  ),
  guiderDeselectStar(
    ApiRoute.post(
      '/api/guider/deselect-star',
      resource: ApiResource.guiding,
      rate: ApiRateTier.control,
    ),
  ),
  guiderGetStarImage(
    ApiRoute.get('/api/guider/star-image', resource: ApiResource.guiding),
  ),
  guiderGetStatus(
    ApiRoute.get('/api/guider/status', resource: ApiResource.guiding),
  ),
  guiderGetCalibration(
    ApiRoute.get('/api/guider/calibration', resource: ApiResource.guiding),
  ),
  builtinGuiderGetConfig(
    ApiRoute.get('/api/builtin-guider/config', resource: ApiResource.guiding),
  ),
  builtinGuiderSetConfig(
    ApiRoute.post(
      '/api/builtin-guider/config',
      resource: ApiResource.guiding,
      rate: ApiRateTier.control,
    ),
  );

  const GuidingApi(this.route);

  @override
  final ApiRoute route;
}
