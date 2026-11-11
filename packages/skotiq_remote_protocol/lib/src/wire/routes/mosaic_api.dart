import '../api_route.dart';

enum MosaicApi implements ApiEndpoint {
  generatePanels(
    ApiRoute.post(
      '/api/mosaic/generate-panels',
      resource: ApiResource.mosaic,
      rate: ApiRateTier.control,
    ),
  ),
  generateSequence(
    ApiRoute.post(
      '/api/mosaic/generate-sequence',
      resource: ApiResource.mosaic,
      rate: ApiRateTier.control,
    ),
  ),
  calculateArea(
    ApiRoute.post(
      '/api/mosaic/calculate-area',
      resource: ApiResource.mosaic,
      rate: ApiRateTier.control,
    ),
  ),
  validateMosaic(
    ApiRoute.post(
      '/api/mosaic/validate',
      resource: ApiResource.mosaic,
      rate: ApiRateTier.control,
    ),
  ),
  estimateTime(
    ApiRoute.post(
      '/api/mosaic/estimate-time',
      resource: ApiResource.mosaic,
      rate: ApiRateTier.control,
    ),
  ),
  recommendExposure(
    ApiRoute.get(
      '/api/mosaic/recommended-exposure',
      resource: ApiResource.mosaic,
    ),
  ),
  listCollaborative(
    ApiRoute.get('/api/mosaic/collaborative', resource: ApiResource.mosaic),
  ),
  joinCollaborativeMosaic(
    ApiRoute.post(
      '/api/mosaic/collaborative/<mosaicId>/join',
      resource: ApiResource.mosaic,
      rate: ApiRateTier.control,
    ),
  ),
  getCollaborative(
    ApiRoute.get(
      '/api/mosaic/collaborative/<mosaicId>',
      resource: ApiResource.mosaic,
    ),
  ),
  publishCollaborative(
    ApiRoute.post(
      '/api/mosaic/projects/<projectId>/publish',
      resource: ApiResource.mosaic,
      rate: ApiRateTier.control,
    ),
  ),
  joinCollaborative(
    ApiRoute.post(
      '/api/mosaic/projects/<projectId>/join',
      resource: ApiResource.mosaic,
      rate: ApiRateTier.control,
    ),
  ),
  collaborativeStatus(
    ApiRoute.get(
      '/api/mosaic/projects/<projectId>/status',
      resource: ApiResource.mosaic,
    ),
  ),
  claimPanel(
    ApiRoute.post(
      '/api/mosaic/projects/<projectId>/panels/<panelIndex>/claim',
      resource: ApiResource.mosaic,
      rate: ApiRateTier.control,
    ),
  ),
  releasePanel(
    ApiRoute.post(
      '/api/mosaic/projects/<projectId>/panels/<panelIndex>/release',
      resource: ApiResource.mosaic,
      rate: ApiRateTier.control,
    ),
  ),
  forceReleasePanel(
    ApiRoute.post(
      '/api/mosaic/projects/<projectId>/panels/<panelIndex>/force-release',
      resource: ApiResource.mosaic,
      rate: ApiRateTier.highRisk,
      audit: 'mosaic_force_release',
    ),
  ),
  uploadPanel(
    ApiRoute.post(
      '/api/mosaic/projects/<projectId>/panels/<panelIndex>/upload',
      resource: ApiResource.mosaic,
      rate: ApiRateTier.highRisk,
      audit: 'mosaic_panel_upload',
    ),
  ),
  assembleMosaic(
    ApiRoute.post(
      '/api/mosaic/projects/<projectId>/assemble',
      resource: ApiResource.mosaic,
      rate: ApiRateTier.highRisk,
      audit: 'mosaic_assemble',
    ),
  ),
  downloadCollaborativeOutput(
    ApiRoute.post(
      '/api/mosaic/projects/<projectId>/output',
      resource: ApiResource.mosaic,
      rate: ApiRateTier.highRisk,
      audit: 'mosaic_output_download',
    ),
  );

  const MosaicApi(this.route);

  @override
  final ApiRoute route;
}
