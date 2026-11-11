import '../api_route.dart';

enum EquipmentApi implements ApiEndpoint {
  cameraStatus(
    ApiRoute.get('/api/equipment/camera/status', resource: ApiResource.system),
  ),
  mountStatus(
    ApiRoute.get('/api/equipment/mount/status', resource: ApiResource.system),
  ),
  focuserStatus(
    ApiRoute.get('/api/equipment/focuser/status', resource: ApiResource.system),
  ),
  filterWheelStatus(
    ApiRoute.get(
      '/api/equipment/filter-wheel/status',
      resource: ApiResource.system,
    ),
  ),
  rotatorStatus(
    ApiRoute.get('/api/equipment/rotator/status', resource: ApiResource.system),
  ),
  cameraCapabilities(
    ApiRoute.get(
      '/api/equipment/camera/capabilities',
      resource: ApiResource.system,
    ),
  ),
  mountCapabilities(
    ApiRoute.get(
      '/api/equipment/mount/capabilities',
      resource: ApiResource.system,
    ),
  ),
  focuserCapabilities(
    ApiRoute.get(
      '/api/equipment/focuser/capabilities',
      resource: ApiResource.system,
    ),
  ),
  filterWheelCapabilities(
    ApiRoute.get(
      '/api/equipment/filter-wheel/capabilities',
      resource: ApiResource.system,
    ),
  ),
  rotatorCapabilities(
    ApiRoute.get(
      '/api/equipment/rotator/capabilities',
      resource: ApiResource.system,
    ),
  ),
  deviceQuirks(
    ApiRoute.get('/api/equipment/quirks', resource: ApiResource.system),
  ),
  startDeviceHeartbeat(
    ApiRoute.post('/api/device/heartbeat/start', resource: ApiResource.system),
  ),
  stopDeviceHeartbeat(
    ApiRoute.post('/api/device/heartbeat/stop', resource: ApiResource.system),
  ),
  getDeviceHealth(
    ApiRoute.get('/api/device/health/<deviceId>', resource: ApiResource.system),
  );

  const EquipmentApi(this.route);

  @override
  final ApiRoute route;
}
