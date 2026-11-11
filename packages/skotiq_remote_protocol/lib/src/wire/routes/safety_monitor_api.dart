import '../api_route.dart';

enum SafetyMonitorApi implements ApiEndpoint {
  safetyStatus(
    ApiRoute.get('/api/safety/status', resource: ApiResource.safety),
  ),
  getSafetySettings(
    ApiRoute.get('/api/safety/settings', resource: ApiResource.safety),
  ),
  updateSafetySettings(
    ApiRoute.post(
      '/api/safety/settings',
      resource: ApiResource.safety,
      rate: ApiRateTier.control,
    ),
  ),
  acknowledgeUnsafe(
    ApiRoute.post(
      '/api/safety/acknowledge',
      resource: ApiResource.safety,
      rate: ApiRateTier.control,
    ),
  ),
  cancelAcknowledgement(
    ApiRoute.post(
      '/api/safety/cancel-acknowledgement',
      resource: ApiResource.safety,
      rate: ApiRateTier.control,
    ),
  );

  const SafetyMonitorApi(this.route);

  @override
  final ApiRoute route;
}
