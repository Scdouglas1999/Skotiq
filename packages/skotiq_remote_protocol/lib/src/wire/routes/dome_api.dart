import '../api_route.dart';

enum DomeApi implements ApiEndpoint {
  open(
    ApiRoute.post(
      '/api/dome/open',
      resource: ApiResource.dome,
      rate: ApiRateTier.highRisk,
      audit: 'dome_open',
      sessionOwner: true,
    ),
  ),
  close(
    ApiRoute.post(
      '/api/dome/close',
      resource: ApiResource.dome,
      rate: ApiRateTier.highRisk,
      audit: 'dome_close',
      sessionOwner: true,
    ),
  ),
  slew(
    ApiRoute.post(
      '/api/dome/slew',
      resource: ApiResource.dome,
      rate: ApiRateTier.highRisk,
      audit: 'dome_slew',
      sessionOwner: true,
    ),
  ),
  domeSync(
    ApiRoute.post(
      '/api/dome/sync',
      resource: ApiResource.dome,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  park(
    ApiRoute.post(
      '/api/dome/park',
      resource: ApiResource.dome,
      rate: ApiRateTier.highRisk,
      audit: 'dome_park',
      sessionOwner: true,
    ),
  ),
  home(
    ApiRoute.post(
      '/api/dome/home',
      resource: ApiResource.dome,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  halt(
    ApiRoute.post(
      '/api/dome/halt',
      resource: ApiResource.dome,
      rate: ApiRateTier.control,
      sessionOwner: true,
    ),
  ),
  status(ApiRoute.get('/api/dome/status', resource: ApiResource.dome)),
  capabilities(
    ApiRoute.get('/api/dome/capabilities', resource: ApiResource.dome),
  );

  const DomeApi(this.route);

  @override
  final ApiRoute route;
}
