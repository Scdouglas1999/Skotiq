import '../api_route.dart';

enum PlanetariumApi implements ApiEndpoint {
  getMountPosition(
    ApiRoute.get(
      '/api/planetarium/mount-position',
      resource: ApiResource.system,
    ),
  ),
  getFovConfig(
    ApiRoute.get('/api/planetarium/fov-config', resource: ApiResource.system),
  ),
  slewTo(
    ApiRoute.post(
      '/api/planetarium/slew-to',
      resource: ApiResource.system,
      rate: ApiRateTier.highRisk,
      audit: 'planetarium_slew_to',
      sessionOwner: true,
    ),
  ),
  centerOn(
    ApiRoute.post(
      '/api/planetarium/center-on',
      resource: ApiResource.system,
      rate: ApiRateTier.highRisk,
      audit: 'planetarium_center_on',
      sessionOwner: true,
    ),
  ),
  syncTo(
    ApiRoute.post(
      '/api/planetarium/sync-to',
      resource: ApiResource.system,
      rate: ApiRateTier.highRisk,
      audit: 'planetarium_sync_to',
      sessionOwner: true,
    ),
  ),
  catalogSearch(
    ApiRoute.get(
      '/api/planetarium/catalog/search',
      resource: ApiResource.system,
    ),
  ),
  catalogRegion(
    ApiRoute.get(
      '/api/planetarium/catalog/region',
      resource: ApiResource.system,
    ),
  ),
  getCatalogObject(
    ApiRoute.get(
      '/api/planetarium/catalog/object/<objectId>',
      resource: ApiResource.system,
    ),
  ),
  getSubscribeInfo(
    ApiRoute.get(
      '/api/planetarium/subscribe-info',
      resource: ApiResource.system,
    ),
  ),
  getLocation(
    ApiRoute.get('/api/planetarium/location', resource: ApiResource.system),
  ),
  getObservingLists(
    ApiRoute.get('/api/observing-lists', resource: ApiResource.system),
  ),
  getObservingListItems(
    ApiRoute.get('/api/observing-lists/items', resource: ApiResource.system),
  ),
  getListedCatalogIds(
    ApiRoute.get(
      '/api/observing-lists/listed-catalog-ids',
      resource: ApiResource.system,
    ),
  ),
  getListsContaining(
    ApiRoute.get(
      '/api/observing-lists/containing',
      resource: ApiResource.system,
    ),
  ),
  createObservingList(
    ApiRoute.post('/api/observing-lists', resource: ApiResource.system),
  ),
  updateObservingList(
    ApiRoute.post('/api/observing-lists/update', resource: ApiResource.system),
  ),
  deleteObservingList(
    ApiRoute.delete('/api/observing-lists', resource: ApiResource.system),
  ),
  duplicateObservingList(
    ApiRoute.post(
      '/api/observing-lists/duplicate',
      resource: ApiResource.system,
    ),
  ),
  addObservingListItem(
    ApiRoute.post('/api/observing-lists/items', resource: ApiResource.system),
  ),
  removeObservingListItem(
    ApiRoute.delete('/api/observing-lists/items', resource: ApiResource.system),
  ),
  updateObservingListItemNotes(
    ApiRoute.post(
      '/api/observing-lists/items/update-notes',
      resource: ApiResource.system,
    ),
  );

  const PlanetariumApi(this.route);

  @override
  final ApiRoute route;
}
