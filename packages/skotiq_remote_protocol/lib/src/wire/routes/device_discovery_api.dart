import '../api_route.dart';

enum DeviceDiscoveryApi implements ApiEndpoint {
  getDevices(ApiRoute.get('/api/devices', resource: ApiResource.system)),
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
