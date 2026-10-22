/// Barrel export for the per-domain declarative route tables.
///
/// Pattern: every handler class in `handlers/*.dart` has a sibling
/// `routes/<name>_routes.dart` that exports a top-level
/// `List<HeadlessRoute> build<Name>Routes(<HandlerType> h)` function.
/// [HeadlessApiServer.start] concatenates the lists and feeds them
/// to [registerRoutes]. See `routes/headless_route.dart` for the
/// design rationale behind the typed-list form.
library;

export 'routes/analytics_routes.dart';
export 'routes/auth_routes.dart';
export 'routes/auxiliary_routes.dart';
export 'routes/backup_routes.dart';
export 'routes/sync_routes.dart';
export 'routes/runtime_state_routes.dart';
export 'routes/broadcast_routes.dart';
export 'routes/calibration_routes.dart';
export 'routes/calibration_library_routes.dart';
export 'routes/catalog_routes.dart';
export 'routes/collaboration_routes.dart';
export 'routes/db_read_routes.dart';
export 'routes/device_discovery_routes.dart';
export 'routes/device_routes.dart';
export 'routes/dome_routes.dart';
export 'routes/equipment_routes.dart';
export 'routes/filesystem_routes.dart';
export 'routes/flat_wizard_routes.dart';
export 'routes/focus_model_routes.dart';
export 'routes/framing_routes.dart';
export 'routes/guiding_routes.dart';
export 'routes/headless_route.dart';
export 'routes/imaging_routes.dart';
export 'routes/job_routes.dart';
export 'routes/coimaging_routes.dart';
export 'routes/log_routes.dart';
export 'routes/mosaic_routes.dart';
export 'routes/pairing_routes.dart';
export 'routes/planetarium_routes.dart';
export 'routes/push_routes.dart';
export 'routes/plugin_routes.dart';
export 'routes/profile_routes.dart';
export 'routes/run_watch_routes.dart';
export 'routes/narrator_routes.dart';
export 'routes/safety_monitor_routes.dart';
export 'routes/scheduler_routes.dart';
export 'routes/planning_data_routes.dart';
export 'routes/science_routes.dart';
export 'routes/sequence_management_routes.dart';
export 'routes/replay_debug_routes.dart';
export 'routes/sequencer_routes.dart';
export 'routes/stacking_routes.dart';
export 'routes/darkroom_delivery_routes.dart';
export 'routes/depthlock_routes.dart';
export 'routes/post_session_routes.dart';
export 'routes/session_ownership_routes.dart';
export 'routes/session_routes.dart';
export 'routes/static_file_routes.dart';
export 'routes/suggestion_routes.dart';
export 'routes/system_routes.dart';
export 'routes/target_routes.dart';
export 'routes/transient_routes.dart';
export 'routes/first_light_routes.dart';
export 'routes/atlas_routes.dart';
export 'routes/update_routes.dart';
export 'routes/weather_routes.dart';
export 'routes/webrtc_live_view_routes.dart';
export 'routes/websocket_routes.dart';
