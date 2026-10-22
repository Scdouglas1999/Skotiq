/// Skotiq Core - Riverpod providers barrel.
///
/// Re-exports the provider/notifier wiring that the UI watches and overrides.
/// Providers depend on the model, service, database, and backend layers, so
/// this is the broadest of the narrow barrels; prefer it in widget/state code
/// that needs the DI handles but not every other core symbol.
library;

export 'src/providers/target_progress_provider.dart';

// Providers
export 'src/providers/app_version_provider.dart';
export 'src/providers/database_provider.dart';
export 'src/providers/equipment_provider.dart';
export 'src/providers/unified_discovery_provider.dart';
export 'src/providers/device_backend_selection_provider.dart';
export 'src/providers/event_provider.dart';
// framing_provider exposes the UI-facing FramingMosaicConfig /
// FramingMosaicPanel (grid-based: columns/rows/overlapPercent). The
// service-layer MosaicConfig / MosaicPanel in mosaic_service.dart
// (geometry-flavored: centerRa/panelWidthArcmin/...) live under their
// canonical names and are now safe to re-export from the barrel.
export 'src/providers/framing_provider.dart';
// framingImageCacheServiceProvider is the canonical DI handle for the survey
// snapshot cache; export it so framing UI (action rail, screen) can resolve
// and override the same instance the framing notifier uses.
export 'src/providers/framing_image_cache_provider.dart';
// HiPS framing tile-layer Riverpod wiring: fetcher/cache/loader DI handles,
// the resident-tiles snapshot the framing painter watches, and the feature flag
// gating the GPU-composited tiled survey background. Renders inside the framing
// path (not the planetarium renderer).
export 'src/providers/hips_framing_provider.dart';
export 'src/providers/imaging_provider.dart';
export 'src/providers/imaging_viewer_state_provider.dart';
export 'src/providers/sequence_provider.dart';
export 'src/providers/sequence/remote_sequence_editor_sync.dart';
export 'src/providers/sequence_stats_provider.dart';
// Thumbnail — inline frame thumbnails in the sequence tree.
export 'src/providers/sequence/exposure_node_thumbnails_provider.dart';
// Plugin-node dispatcher abstraction. The app entry
// point overrides this provider with the real PluginNodeExecutor
// (from skotiq_plugins) via `pluginNodeDispatcherOverride()`.
export 'src/providers/plugin_node_dispatcher.dart';
export 'src/providers/session_report_provider.dart';
export 'src/providers/secondary_rig_provider.dart';
export 'src/providers/campaign_rollup_provider.dart';
export 'src/providers/import_provider.dart';
export 'src/providers/session_provider.dart';
// Hide settings_provider's legacy HorizonProfile so the scheduler's
// samples-based HorizonProfile (services/scheduler/horizon_profile.dart) wins
// at the barrel. Direct importers of settings_provider.dart still see it.
export 'src/providers/settings_provider.dart' hide HorizonProfile;
export 'src/providers/clock_provider.dart';
export 'src/providers/profiles_provider.dart';
export 'src/providers/equipment_fov_provider.dart';
export 'src/providers/focus_model_profile_data_provider.dart';
export 'src/providers/guiding_provider.dart';
export 'src/providers/backend_provider.dart';
export 'src/providers/remote_session_sync_provider.dart';
export 'src/providers/remote_sync_events.dart';
export 'src/providers/remote_sync_handler.dart';
export 'src/providers/host_mutation_event_provider.dart';
export 'src/providers/host_local_sync_provider.dart';
// Runtime state the imaging host shares with linked clients.
export 'src/providers/runtime_mirror/runtime_mirror_channel.dart';
export 'src/providers/runtime_mirror/runtime_mirror_channels.dart';
export 'src/providers/runtime_mirror/host_runtime_mirror.dart';
export 'src/providers/runtime_mirror/client_runtime_mirror.dart';
export 'src/providers/runtime_mirror/channels/autofocus_result_channel.dart';
export 'src/providers/runtime_mirror/channels/autofocus_run_channel.dart';
export 'src/providers/runtime_mirror/channels/centering_channels.dart';
export 'src/providers/runtime_mirror/channels/cooler_reading_channel.dart';
export 'src/providers/runtime_mirror/channels/current_frame_channel.dart';
export 'src/providers/runtime_mirror/channels/environment_channel.dart';
export 'src/providers/runtime_mirror/channels/meridian_flip_channel.dart';
export 'src/providers/runtime_mirror/channels/plate_solve_channel.dart';
export 'src/providers/runtime_mirror/channels/sequence_run_channel.dart';
// Hot-plug device-detection event bridge.
export 'src/providers/hotplug_event_bridge_provider.dart';
export 'src/providers/simbad_provider.dart';
export 'src/providers/exoplanet_provider.dart';
export 'src/providers/gaia_provider.dart';
export 'src/providers/annotation_settings_provider.dart';
export 'src/providers/annotation_presets_provider.dart'
    hide AnnotationPreset, annotationPresetsProvider, AnnotationPresetsNotifier;
export 'src/providers/tutorial_provider.dart';
export 'src/providers/filter_offset_provider.dart';
export 'src/providers/camera_presets_provider.dart';
export 'src/providers/weather_providers.dart';
export 'src/providers/capability_provider.dart';
export 'src/providers/equipment/device_capability_provider.dart';
export 'src/providers/meridian_countdown_provider.dart';
export 'src/providers/meridian_flip_provider.dart';
export 'src/providers/flat_wizard_provider.dart';
export 'src/providers/ui_notification_provider.dart';
export 'src/providers/operation_progress_provider.dart';
export 'src/providers/current_screen_provider.dart';
export 'src/providers/polar_alignment_provider.dart';
export 'src/providers/template_snippet_provider.dart';
export 'src/providers/target_suggestion_provider.dart';
export 'src/providers/suggestion_filter_provider.dart';
export 'src/providers/transient_alert_provider.dart';
export 'src/providers/critical_alert_provider.dart';
export 'src/providers/device_connection_progress_provider.dart';
// Recovery Mode — providers for the recovery state machine
// (currentRecoveryProvider, recoveryHistoryProvider, recoveryControlProvider,
// recoveryEventBridgeProvider, recoveryAudibleBridgeProvider,
// recoveryPushBridgeProvider).
export 'src/providers/recovery_provider.dart';
// Mobile session replay scrubber provider + types.
export 'src/providers/session_replay_provider.dart';
export 'src/providers/auto_stretch_provider.dart';
export 'src/providers/science_provider.dart';
export 'src/providers/science_status_provider.dart';
export 'src/providers/autofocus_progress_provider.dart';
export 'src/providers/push_notification_provider.dart';
export 'src/providers/dark_library_provider.dart';
export 'src/providers/live_stacking_provider.dart';
// Stack-and-Share Loop (component C7): orchestrator state + result viewer.
export 'src/providers/stack_and_share_provider.dart';
export 'src/providers/project_tracking_provider.dart';
export 'src/providers/equipment_health_provider.dart';
export 'src/providers/device_heartbeat_health_provider.dart';
export 'src/providers/device_last_contact_provider.dart';
export 'src/providers/optical_train_diagnostics_provider.dart';
export 'src/providers/session_handoff_provider.dart';
export 'src/providers/session_optimizer_provider.dart';
export 'src/providers/web_server_provider.dart';
export 'src/providers/observation_log_provider.dart';
export 'src/providers/observing_list_provider.dart';
export 'src/providers/imaging_history_provider.dart';
export 'src/providers/live_validation_provider.dart';
export 'src/providers/period_analysis_provider.dart';
export 'src/providers/photometric_transform_provider.dart';
export 'src/providers/defect_map_provider.dart';
export 'src/providers/plate_solver_provider.dart';
export 'src/providers/readiness_provider.dart';
export 'src/providers/onboarding_provider.dart';
// Quick Wins Bundle — next-use prompt selection wiring. Exposes
// nextUsePromptProvider (the step the dashboard card surfaces), the pure
// selectNextUseStep decision, the completed/dismissed action providers, and
// the next_use.<id> screen-id helpers used to persist dismissals.
export 'src/providers/next_use_prompt_provider.dart';
export 'src/providers/disk_space_provider.dart';
export 'src/providers/thumbnail_sidecar_provider.dart';
export 'src/providers/first_light_provider.dart';
export 'src/providers/catalog_overlay_provider.dart';
export 'src/providers/scheduler_provider.dart';
export 'src/providers/planning_provider.dart';
export 'src/providers/notification_router_provider.dart';
export 'src/providers/home_assistant_provider.dart';
export 'src/providers/notes_provider.dart';
export 'src/providers/forensics_provider.dart';
export 'src/providers/replay_debug_provider.dart';
export 'src/providers/smart_night_draft_provider.dart';
export 'src/providers/conversational_builder_provider.dart';
export 'src/providers/usb_disconnect_log_provider.dart';
export 'src/providers/narrator_provider.dart';
