import '../api_route.dart';

enum DeviceDiscoveryApi implements ApiEndpoint {
  /// What the last discovery through this API found, without discovering.
  getDevices(ApiRoute.get('/api/devices', resource: ApiResource.system)),

  /// Discover the host's devices now: a scan the user asked for.
  discoverDevices(
    ApiRoute.post(
      '/api/devices/discover',
      resource: ApiResource.devices,
      rate: ApiRateTier.control,
    ),
  ),
  discoverIndiAtAddress(
    ApiRoute.get('/api/devices/discover-indi', resource: ApiResource.devices),
  ),
  discoverAlpacaAtAddress(
    ApiRoute.get('/api/devices/discover-alpaca', resource: ApiResource.devices),
  ),
  getConnectedDevices(
    ApiRoute.get('/api/devices/connected', resource: ApiResource.devices),
  ),
  rescanDevices(
    ApiRoute.post(
      '/api/devices/rescan',
      resource: ApiResource.devices,
      rate: ApiRateTier.control,
    ),
  );

  const DeviceDiscoveryApi(this.route);

  @override
  final ApiRoute route;
}
