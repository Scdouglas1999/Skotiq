import '../api_route.dart';

enum FramingApi implements ApiEndpoint {
  slewToTarget(
    ApiRoute.post(
      '/api/framing/slew-to-target',
      resource: ApiResource.framing,
      rate: ApiRateTier.highRisk,
      audit: 'framing_slew_to_target',
      sessionOwner: true,
    ),
  ),
  centerOnTarget(
    ApiRoute.post(
      '/api/framing/center-on-target',
      resource: ApiResource.framing,
      rate: ApiRateTier.highRisk,
      audit: 'framing_center_on_target',
      sessionOwner: true,
    ),
  ),
  syncMount(
    ApiRoute.post(
      '/api/framing/sync',
      resource: ApiResource.framing,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  getCurrentPosition(
    ApiRoute.get(
      '/api/framing/current-position',
      resource: ApiResource.framing,
    ),
  ),
  rotateTo(
    ApiRoute.post(
      '/api/framing/rotate-to',
      resource: ApiResource.framing,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  abortSlew(
    ApiRoute.post(
      '/api/framing/abort-slew',
      resource: ApiResource.framing,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  parkMount(
    ApiRoute.post(
      '/api/framing/park',
      resource: ApiResource.framing,
      rate: ApiRateTier.highRisk,
      audit: 'framing_park',
      sessionOwner: true,
    ),
  ),
  unparkMount(
    ApiRoute.post(
      '/api/framing/unpark',
      resource: ApiResource.framing,
      rate: ApiRateTier.highRisk,
      audit: 'framing_unpark',
      sessionOwner: true,
    ),
  ),
  setTarget(
    ApiRoute.post(
      '/api/framing/set-target',
      resource: ApiResource.framing,
      rate: ApiRateTier.control,
    ),
  ),
  saveFraming(
    ApiRoute.post(
      '/api/framing/save',
      resource: ApiResource.framing,
      rate: ApiRateTier.control,
    ),
  );

  const FramingApi(this.route);

  @override
  final ApiRoute route;
}
