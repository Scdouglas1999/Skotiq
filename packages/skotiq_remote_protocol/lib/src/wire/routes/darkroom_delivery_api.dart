import '../api_route.dart';

enum DarkroomDeliveryApi implements ApiEndpoint {
  getDeliveryManifest(
    ApiRoute.get(
      '/api/darkroom/delivery/manifest/<jobId>',
      resource: ApiResource.darkroom,
      scope: ApiScope.control,
    ),
  ),
  downloadDeliveryArtifact(
    ApiRoute.get(
      '/api/darkroom/delivery/artifact/<jobId>/<artifactId>',
      resource: ApiResource.darkroom,
      scope: ApiScope.control,
      audit: 'darkroom_artifact_download',
    ),
  ),
  acknowledgeDelivery(
    ApiRoute.post(
      '/api/darkroom/delivery/ack/<jobId>',
      resource: ApiResource.darkroom,
      rate: ApiRateTier.control,
    ),
  );

  const DarkroomDeliveryApi(this.route);

  @override
  final ApiRoute route;
}
