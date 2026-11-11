/// Every route of the remote API, in the order the host matches them.
library;

import 'api_route.dart';
import 'api_route_index.dart';
import 'routes/analytics_api.dart';
import 'routes/atlas_api.dart';
import 'routes/auth_api.dart';
import 'routes/auxiliary_api.dart';
import 'routes/backup_api.dart';
import 'routes/broadcast_api.dart';
import 'routes/calibration_api.dart';
import 'routes/calibration_library_api.dart';
import 'routes/catalog_api.dart';
import 'routes/co_imaging_api.dart';
import 'routes/collaboration_api.dart';
import 'routes/darkroom_delivery_api.dart';
import 'routes/db_read_api.dart';
import 'routes/depth_lock_api.dart';
import 'routes/device_api.dart';
import 'routes/device_discovery_api.dart';
import 'routes/dome_api.dart';
import 'routes/equipment_api.dart';
import 'routes/file_system_api.dart';
import 'routes/first_light_api.dart';
import 'routes/flat_wizard_api.dart';
import 'routes/focus_model_api.dart';
import 'routes/framing_api.dart';
import 'routes/guiding_api.dart';
import 'routes/imaging_api.dart';
import 'routes/job_api.dart';
import 'routes/log_api.dart';
import 'routes/mosaic_api.dart';
import 'routes/narrator_api.dart';
import 'routes/pairing_api.dart';
import 'routes/planetarium_api.dart';
import 'routes/planning_data_api.dart';
import 'routes/plugin_api.dart';
import 'routes/post_session_api.dart';
import 'routes/profile_api.dart';
import 'routes/push_api.dart';
import 'routes/replay_debug_api.dart';
import 'routes/run_watch_api.dart';
import 'routes/runtime_state_api.dart';
import 'routes/safety_monitor_api.dart';
import 'routes/scheduler_api.dart';
import 'routes/science_api.dart';
import 'routes/sequence_management_api.dart';
import 'routes/sequencer_api.dart';
import 'routes/session_api.dart';
import 'routes/session_ownership_api.dart';
import 'routes/stacking_api.dart';
import 'routes/static_file_api.dart';
import 'routes/suggestion_api.dart';
import 'routes/sync_api.dart';
import 'routes/system_api.dart';
import 'routes/target_api.dart';
import 'routes/transient_api.dart';
import 'routes/update_api.dart';
import 'routes/weather_api.dart';
import 'routes/web_rtc_live_view_api.dart';
import 'routes/web_socket_api.dart';

/// The API areas in match order. A request goes to the first route, in this
/// order and then in each area's declaration order, whose method and path
/// match, so a literal path must come before a parameter that would also
/// accept it.
const List<List<ApiEndpoint>> apiRouteGroups = [
  SystemApi.values,
  PairingApi.values,
  PushApi.values,
  AuthApi.values,
  CollaborationApi.values,
  DeviceDiscoveryApi.values,
  DeviceApi.values,
  GuidingApi.values,
  ImagingApi.values,
  SequencerApi.values,
  ReplayDebugApi.values,
  EquipmentApi.values,
  ProfileApi.values,
  SessionApi.values,
  TargetApi.values,
  SequenceManagementApi.values,
  FlatWizardApi.values,
  MosaicApi.values,
  CoImagingApi.values,
  AnalyticsApi.values,
  WeatherApi.values,
  FileSystemApi.values,
  ScienceApi.values,
  SuggestionApi.values,
  TransientApi.values,
  FirstLightApi.values,
  AtlasApi.values,
  BackupApi.values,
  SyncApi.values,
  RuntimeStateApi.values,
  FramingApi.values,
  PlanetariumApi.values,
  DomeApi.values,
  NarratorApi.values,
  SafetyMonitorApi.values,
  AuxiliaryApi.values,
  SchedulerApi.values,
  PlanningDataApi.values,
  FocusModelApi.values,
  StackingApi.values,
  PostSessionApi.values,
  DarkroomDeliveryApi.values,
  DepthLockApi.values,
  JobApi.values,
  SessionOwnershipApi.values,
  UpdateApi.values,
  RunWatchApi.values,
  BroadcastApi.values,
  LogApi.values,
  CalibrationApi.values,
  CalibrationLibraryApi.values,
  CatalogApi.values,
  DbReadApi.values,
  PluginApi.values,
  WebRtcLiveViewApi.values,
  StaticFileApi.values,
  WebSocketApi.values,
];

final List<ApiEndpoint> apiEndpoints = List.unmodifiable([
  for (final group in apiRouteGroups) ...group,
]);

/// The index over [apiEndpoints], for asking which route a method and path
/// belong to.
final ApiRouteIndex apiRouteIndex = ApiRouteIndex([
  for (final endpoint in apiEndpoints) endpoint.route,
]);

/// The `METHOD /path` list `GET /api/info` advertises: the API routes and
/// the WebSocket upgrades, without the browser pages.
final List<String> advertisedApiEndpoints = List.unmodifiable([
  for (final endpoint in apiEndpoints)
    if (endpoint.route.method == ApiMethod.ws ||
        endpoint.route.path.startsWith('/api/'))
      endpoint.route.signature,
]);

/// The paths served without a token, sorted. A page root (`/dashboard`)
/// stands for everything under it.
final List<String> publicApiPaths = () {
  final paths = {
    for (final endpoint in apiEndpoints)
      if (endpoint.route.scope == ApiScope.public) endpoint.route.path,
  };
  return List<String>.unmodifiable(
    paths
        .where(
          (path) => !paths.any(
            (root) => root != '/' && path != root && path.startsWith('$root/'),
          ),
        )
        .toList()
      ..sort(),
  );
}();
