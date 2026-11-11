import '../api_route.dart';

enum ImagingApi implements ApiEndpoint {
  plateSolve(
    ApiRoute.post(
      '/api/plate-solve',
      resource: ApiResource.system,
      sessionOwner: true,
    ),
  ),
  getFitsDimensions(
    ApiRoute.get('/api/imaging/fits-dimensions', resource: ApiResource.system),
  ),
  detectPlateSolvers(
    ApiRoute.get('/api/plate-solver/detect', resource: ApiResource.system),
  ),
  verifyPlateSolver(
    ApiRoute.post('/api/plate-solver/verify', resource: ApiResource.system),
  ),
  getPlateSolverConfig(
    ApiRoute.get('/api/plate-solver/config', resource: ApiResource.system),
  ),
  setPlateSolverConfig(
    ApiRoute.post('/api/plate-solver/config', resource: ApiResource.system),
  ),
  getImageStats(
    ApiRoute.post(
      '/api/imaging/stats',
      resource: ApiResource.system,
      maxBodyBytes: ApiBodyLimit.image,
    ),
  ),
  autoStretchImage(
    ApiRoute.post(
      '/api/imaging/stretch',
      resource: ApiResource.system,
      maxBodyBytes: ApiBodyLimit.image,
    ),
  ),
  getStarCrops(
    ApiRoute.get('/api/imaging/star-crops', resource: ApiResource.system),
  ),
  debayerImage(
    ApiRoute.post(
      '/api/imaging/debayer',
      resource: ApiResource.system,
      maxBodyBytes: ApiBodyLimit.image,
    ),
  ),
  getLastRawImageData(
    ApiRoute.get(
      '/api/imaging/raw-data',
      resource: ApiResource.system,
      bucket: ApiBucket.imageDownload,
    ),
  ),
  saveFitsFile(
    ApiRoute.post(
      '/api/imaging/save-fits',
      resource: ApiResource.system,
      maxBodyBytes: ApiBodyLimit.image,
    ),
  ),
  saveFitsFromLastCapture(
    ApiRoute.post(
      '/api/imaging/save-fits-from-capture',
      resource: ApiResource.system,
    ),
  ),
  calibrateImageFile(
    ApiRoute.post('/api/imaging/calibrate-file', resource: ApiResource.system),
  ),
  clearDeviceImage(
    ApiRoute.delete(
      '/api/imaging/device-image/<deviceId>',
      resource: ApiResource.system,
    ),
  );

  const ImagingApi(this.route);

  @override
  final ApiRoute route;
}
