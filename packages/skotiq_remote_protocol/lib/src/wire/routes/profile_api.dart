import '../api_route.dart';

enum ProfileApi implements ApiEndpoint {
  getProfiles(ApiRoute.get('/api/profiles', resource: ApiResource.system)),
  saveProfile(ApiRoute.post('/api/profiles', resource: ApiResource.system)),
  reorderProfiles(
    ApiRoute.post('/api/profiles/reorder', resource: ApiResource.system),
  ),
  clearDefaultProfile(
    ApiRoute.post('/api/profiles/default/clear', resource: ApiResource.system),
  ),
  deleteProfile(
    ApiRoute.delete('/api/profiles/<profileId>', resource: ApiResource.system),
  ),
  loadProfile(
    ApiRoute.post(
      '/api/profiles/<profileId>/load',
      resource: ApiResource.system,
    ),
  ),
  setDefaultProfile(
    ApiRoute.post(
      '/api/profiles/<profileId>/default',
      resource: ApiResource.system,
    ),
  ),
  getActiveProfile(
    ApiRoute.get('/api/profiles/active', resource: ApiResource.system),
  ),
  getSettings(
    ApiRoute.get(
      '/api/settings',
      resource: ApiResource.system,
      scope: ApiScope.control,
    ),
  ),
  updateSettings(ApiRoute.post('/api/settings', resource: ApiResource.system)),
  getSettingsStore(
    ApiRoute.get(
      '/api/settings/store',
      resource: ApiResource.settings,
      scope: ApiScope.control,
    ),
  ),
  updateSettingsStore(
    ApiRoute.post('/api/settings/store', resource: ApiResource.settings),
  ),
  getMeridianFlipSettings(
    ApiRoute.get(
      '/api/settings/meridian-flip',
      resource: ApiResource.settings,
      scope: ApiScope.control,
    ),
  ),
  updateMeridianFlipSettings(
    ApiRoute.post(
      '/api/settings/meridian-flip',
      resource: ApiResource.settings,
    ),
  ),
  getHomeAssistantSettings(
    ApiRoute.get(
      '/api/settings/home-assistant',
      resource: ApiResource.settings,
      scope: ApiScope.admin,
    ),
  ),
  updateHomeAssistantSettings(
    ApiRoute.post(
      '/api/settings/home-assistant',
      resource: ApiResource.settings,
      scope: ApiScope.admin,
    ),
  ),
  getLocation(
    ApiRoute.get(
      '/api/settings/location',
      resource: ApiResource.settings,
      scope: ApiScope.control,
    ),
  ),
  setLocation(
    ApiRoute.post('/api/settings/location', resource: ApiResource.settings),
  ),
  getLocationFromInternet(
    ApiRoute.get('/api/location', resource: ApiResource.system),
  );

  const ProfileApi(this.route);

  @override
  final ApiRoute route;
}
