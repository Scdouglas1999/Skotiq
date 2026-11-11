import '../api_route.dart';

enum CalibrationLibraryApi implements ApiEndpoint {
  list(
    ApiRoute.get('/api/calibration-library', resource: ApiResource.calibration),
  ),
  backlog(
    ApiRoute.get(
      '/api/calibration-library/backlog',
      resource: ApiResource.calibration,
    ),
  ),
  match(
    ApiRoute.post(
      '/api/calibration-library/match',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  accept(
    ApiRoute.post(
      '/api/calibration-library/accept',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  publish(
    ApiRoute.post(
      '/api/calibration-library/publish',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  retract(
    ApiRoute.post(
      '/api/calibration-library/retract',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  setTags(
    ApiRoute.put(
      '/api/calibration-library/<type>/<id>/tags',
      resource: ApiResource.calibration,
      rate: ApiRateTier.control,
    ),
  ),
  download(
    ApiRoute.get(
      '/api/calibration-library/<type>/<id>/file',
      resource: ApiResource.calibration,
      timeout: ApiTimeout.slowRead,
      bucket: ApiBucket.imageDownload,
    ),
  ),
  delete(
    ApiRoute.delete(
      '/api/calibration-library/<type>/<id>',
      resource: ApiResource.calibration,
      scope: ApiScope.admin,
      rate: ApiRateTier.control,
    ),
  );

  const CalibrationLibraryApi(this.route);

  @override
  final ApiRoute route;
}
