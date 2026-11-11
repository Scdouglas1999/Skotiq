import '../api_route.dart';

enum SessionApi implements ApiEndpoint {
  startPolarAlignment(
    ApiRoute.post(
      '/api/polar-alignment/start',
      resource: ApiResource.system,
      sessionOwner: true,
    ),
  ),
  startAllSkyPolarAlignment(
    ApiRoute.post(
      '/api/polar-alignment/all-sky/start',
      resource: ApiResource.system,
      sessionOwner: true,
    ),
  ),
  stopPolarAlignment(
    ApiRoute.post(
      '/api/polar-alignment/stop',
      resource: ApiResource.system,
      sessionOwner: true,
    ),
  ),
  getSessionImages(
    ApiRoute.get(
      '/api/sessions/<sessionId>/images',
      resource: ApiResource.system,
    ),
  ),
  getAllImages(ApiRoute.get('/api/images', resource: ApiResource.system)),
  getRecentImages(
    ApiRoute.get('/api/images/recent', resource: ApiResource.system),
  ),
  getStandaloneImages(
    ApiRoute.get('/api/images/standalone', resource: ApiResource.system),
  ),
  backfillThumbnails(
    ApiRoute.post(
      '/api/images/backfill-thumbnails',
      resource: ApiResource.system,
      scope: ApiScope.admin,
      rate: ApiRateTier.highRisk,
      audit: 'image_backfill_thumbnails',
    ),
  ),
  createImage(ApiRoute.post('/api/images', resource: ApiResource.system)),
  getImageById(
    ApiRoute.get('/api/images/<imageId>', resource: ApiResource.system),
  ),
  updateImage(
    ApiRoute.put('/api/images/<imageId>', resource: ApiResource.system),
  ),
  getImageThumbnail(
    ApiRoute.get(
      '/api/images/<imageId>/thumbnail',
      resource: ApiResource.system,
    ),
  ),
  regenerateImageThumbnail(
    ApiRoute.post(
      '/api/images/<imageId>/regenerate-thumbnail',
      resource: ApiResource.system,
      audit: 'image_regenerate_thumbnail',
    ),
  ),
  downloadImage(
    ApiRoute.get(
      '/api/images/<imageId>/download',
      resource: ApiResource.system,
      timeout: ApiTimeout.slowRead,
      bucket: ApiBucket.imageDownload,
    ),
  ),
  exportSessionJson(
    ApiRoute.get(
      '/api/sessions/<sessionId>/export/json',
      resource: ApiResource.system,
      timeout: ApiTimeout.slowRead,
    ),
  ),
  exportSessionCsv(
    ApiRoute.get(
      '/api/sessions/<sessionId>/export/csv',
      resource: ApiResource.system,
      timeout: ApiTimeout.slowRead,
    ),
  ),
  exportSessionHtml(
    ApiRoute.get(
      '/api/sessions/<sessionId>/export/html',
      resource: ApiResource.system,
      timeout: ApiTimeout.slowRead,
    ),
  ),
  exportSession(
    ApiRoute.get(
      '/api/sessions/<sessionId>/export/<format>',
      resource: ApiResource.system,
      timeout: ApiTimeout.slowRead,
    ),
  );

  const SessionApi(this.route);

  @override
  final ApiRoute route;
}
