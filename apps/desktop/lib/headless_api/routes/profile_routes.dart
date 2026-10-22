/// Declarative route table for profile + settings + location endpoints.
///
/// Counterpart to `handlers/profile_handlers.dart`. Three logical
/// surfaces that share a handler class because they all read/write the
/// settings DAO: equipment profiles, app settings, and observer
/// location.
library;

import '../handlers/profile_handlers.dart';
import 'headless_route.dart';

/// Build the declarative route table for [ProfileHandlers].
List<HeadlessRoute> buildProfileRoutes(ProfileHandlers h) => <HeadlessRoute>[
  // Profiles
  HeadlessRoute(HttpMethod.get, '/api/profiles', h.handleGetProfiles),
  HeadlessRoute(HttpMethod.post, '/api/profiles', h.handleSaveProfile),
  // Literal single-segment POST. Registered BEFORE the parametric
  // '/api/profiles/<profileId>/...' routes so a profileId can never swallow
  // the literal 'reorder' segment (shelf_router matches in registration
  // order).
  HeadlessRoute(
    HttpMethod.post,
    '/api/profiles/reorder',
    h.handleReorderProfiles,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/profiles/default/clear',
    h.handleClearDefaultProfile,
  ),
  HeadlessRoute(
    HttpMethod.delete,
    '/api/profiles/<profileId>',
    h.handleDeleteProfile,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/profiles/<profileId>/load',
    h.handleLoadProfile,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/profiles/<profileId>/default',
    h.handleSetDefaultProfile,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/profiles/active',
    h.handleGetActiveProfile,
  ),

  // Settings
  HeadlessRoute(HttpMethod.get, '/api/settings', h.handleGetSettings),
  HeadlessRoute(HttpMethod.post, '/api/settings', h.handleUpdateSettings),
  HeadlessRoute(
    HttpMethod.get,
    '/api/settings/store',
    h.handleGetSettingsStore,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/settings/store',
    h.handleUpdateSettingsStore,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/settings/meridian-flip',
    h.handleGetMeridianFlipSettings,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/settings/meridian-flip',
    h.handleUpdateMeridianFlipSettings,
  ),
  HeadlessRoute(
    HttpMethod.get,
    '/api/settings/home-assistant',
    h.handleGetHomeAssistantSettings,
  ),
  HeadlessRoute(
    HttpMethod.post,
    '/api/settings/home-assistant',
    h.handleUpdateHomeAssistantSettings,
  ),
  HeadlessRoute(HttpMethod.get, '/api/settings/location', h.handleGetLocation),
  HeadlessRoute(HttpMethod.post, '/api/settings/location', h.handleSetLocation),
  HeadlessRoute(
    HttpMethod.get,
    '/api/location',
    h.handleGetLocationFromInternet,
  ),
];
