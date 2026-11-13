/// The Riverpod state layer of skotiq_core.
///
/// Exports only files under `src/providers/`.
library;

export 'src/providers/mount_site_provider.dart';
export 'src/providers/target_progress_provider.dart';
export 'src/providers/app_version_provider.dart';
export 'src/providers/focuser_backlash_calibration_provider.dart';
export 'src/providers/focuser_backlash_provider.dart';
export 'src/providers/database_provider.dart';
export 'src/providers/host_settings/host_settings_providers.dart';
export 'src/providers/equipment_provider.dart';
export 'src/providers/unified_discovery_provider.dart';
export 'src/providers/event_provider.dart';
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
export 'src/providers/sequence/run_config_sync.dart'
    show runConfigSyncProvider, RunConfigSync;
export 'src/providers/sequence_stats_provider.dart';
// The one wording for a target dropped by its own end_when.
export 'src/providers/sequence/run_dither_event.dart';
// Sequencer events, typed once at the Dart boundary.
export 'src/providers/sequence/sequencer_run_event.dart';
export 'src/providers/sequence/plan_run_end.dart';
export 'src/providers/sequence/plan_timer_provider.dart';
// The one vocabulary for an exposure node's per-frame progress line.
// Whether a finished run's report interrupts the operator or waits for them.
export 'src/providers/sequence/session_report_presentation.dart';
// The one channel only exposure-shaped progress can write.
export 'src/providers/sequence/node_exposure_tally.dart';
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
export 'src/providers/settings_provider.dart';
export 'src/providers/clock_provider.dart';
export 'src/providers/profiles_provider.dart';
export 'src/providers/armed_start_provider.dart';
export 'src/providers/host_scheduled_start_provider.dart';
export 'src/providers/host_end_of_night_provider.dart';
export 'src/providers/profile_activation_writethrough.dart';
export 'src/providers/focus_model_profile_data_provider.dart';
export 'src/providers/guiding_provider.dart';
export 'src/providers/backend_provider.dart';
export 'src/providers/remote_session_sync_provider.dart';
export 'src/providers/host_link_provider.dart';
export 'src/providers/remote_launch_provider.dart';
export 'src/providers/linked_rig_provider.dart';
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
export 'src/providers/runtime_mirror/channels/auxiliary_device_channels.dart';
export 'src/providers/runtime_mirror/channels/centering_channels.dart';
export 'src/providers/runtime_mirror/channels/cooler_reading_channel.dart';
export 'src/providers/runtime_mirror/channels/end_of_night_channel.dart';
export 'src/providers/runtime_mirror/channels/current_frame_channel.dart';
export 'src/providers/runtime_mirror/channels/device_slot_channel.dart';
export 'src/providers/runtime_mirror/channels/environment_channel.dart';
export 'src/providers/runtime_mirror/channels/frame_solve_channel.dart';
export 'src/providers/runtime_mirror/channels/framing_geometry_channel.dart';
export 'src/providers/runtime_mirror/channels/framing_target_channel.dart';
export 'src/providers/runtime_mirror/channels/guider_status_channel.dart';
export 'src/providers/runtime_mirror/channels/open_plan_channel.dart';
export 'src/providers/runtime_mirror/channels/live_broadcast_channel.dart';
export 'src/providers/runtime_mirror/channels/manual_action_channel.dart';
export 'src/providers/runtime_mirror/channels/notice_acks_channel.dart';
export 'src/providers/runtime_mirror/channels/manual_loop_channel.dart';
export 'src/providers/runtime_mirror/channels/meridian_flip_channel.dart';
export 'src/providers/runtime_mirror/channels/plate_solve_channel.dart';
export 'src/providers/runtime_mirror/channels/run_record_channel.dart';
export 'src/providers/runtime_mirror/channels/scheduled_start_channel.dart';
export 'src/providers/runtime_mirror/channels/sequence_run_channel.dart';
export 'src/providers/runtime_mirror/channels/session_frames_channel.dart';
// Hot-plug device-detection event bridge.
export 'src/providers/hotplug_event_bridge_provider.dart';
export 'src/providers/depthlock_provider.dart';
export 'src/providers/annotation_settings_provider.dart';
export 'src/providers/filter_offset_provider.dart';
export 'src/providers/camera_presets_provider.dart';
export 'src/providers/weather_providers.dart';
export 'src/providers/camera_sensor_specs_provider.dart';
export 'src/providers/capability_provider.dart';
export 'src/providers/equipment/device_capability_provider.dart';
export 'src/providers/meridian_countdown_provider.dart';
export 'src/providers/meridian_flip_provider.dart';
export 'src/providers/flat_wizard_provider.dart';
export 'src/providers/flat_wizard_output.dart';
export 'src/providers/ui_notification_provider.dart';
export 'src/providers/operation_progress_provider.dart';
export 'src/providers/current_screen_provider.dart';
export 'src/providers/polar_alignment_provider.dart';
export 'src/providers/template_snippet_provider.dart';
export 'src/providers/target_suggestion_provider.dart';
export 'src/providers/suggestion_filter_provider.dart';
export 'src/providers/transient_alert_provider.dart';
export 'src/providers/critical_alert_provider.dart';
export 'src/providers/mount_guard_provider.dart';
export 'src/providers/catalog_download_source_provider.dart';
export 'src/providers/device_connection_progress_provider.dart';
// Recovery Mode — providers for the recovery state machine
// (currentRecoveryProvider, recoveryHistoryProvider, recoveryControlProvider,
// recoveryEventBridgeProvider, recoveryAudibleBridgeProvider,
// recoveryPushBridgeProvider).
export 'src/providers/recovery_provider.dart';
// Mobile session replay scrubber provider + types.
export 'src/providers/session_replay_provider.dart';
export 'src/providers/auto_stretch_provider.dart';
export 'src/providers/glance_mode_provider.dart';
export 'src/providers/science_provider.dart';
export 'src/providers/science_status_provider.dart';
export 'src/providers/autofocus_progress_provider.dart';
export 'src/providers/autofocus_preview_feeder.dart';
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
export 'src/providers/async_scope.dart';
export 'src/providers/thumbnail_sidecar_provider.dart';
export 'src/providers/first_light_provider.dart';
export 'src/providers/catalog_overlay_provider.dart';
export 'src/providers/current_frame_analysis_provider.dart';
export 'src/providers/frame_record_updates.dart';
export 'src/providers/frame_watch_settings_provider.dart';
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
export 'src/providers/sky_atlas_provider.dart';
export 'src/providers/constellation_provider.dart';
export 'src/providers/transient_detections_provider.dart';
export 'src/providers/hardware_presets_provider.dart';
export 'src/providers/plugin_enablement_provider.dart';
export 'src/providers/end_of_night_calibration/eon_providers.dart';
export 'src/providers/annotation_service_provider.dart';
export 'src/providers/device_service_providers.dart';
export 'src/providers/backup_service_provider.dart';
export 'src/providers/calibration_backlog_service_provider.dart';
export 'src/providers/calibration_library_service_providers.dart';
export 'src/providers/calibration_master_builder_provider.dart';
export 'src/providers/calibration_service_providers.dart';
export 'src/providers/capture_preview_loader_provider.dart';
export 'src/providers/centering_service_providers.dart';
export 'src/providers/color_calibration_service_provider.dart';
export 'src/providers/imaging_service_providers.dart';
export 'src/providers/darkroom_build_jobs_provider.dart';
export 'src/providers/output_locations_provider.dart';
export 'src/providers/darkroom_build_service_provider.dart';
export 'src/providers/darkroom_state_store_provider.dart';
export 'src/providers/device_commands_provider.dart';
export 'src/providers/transients/difference_image_seam_provider.dart';
export 'src/providers/end_of_night_calibration/eon_trigger_provider.dart';
export 'src/providers/error_service_provider.dart';
export 'src/providers/flat_library_service_provider.dart';
export 'src/providers/flat_wizard_service_provider.dart';
export 'src/providers/focus_model_service_providers.dart';
export 'src/providers/science/frame_auto_grader_provider.dart';
export 'src/providers/scheduler/integration_goal_service_provider.dart';
export 'src/providers/predictive_af_service_providers.dart';
export 'src/providers/live_stack_master_library_provider.dart';
export 'src/providers/live_stacking_broadcast_service_providers.dart';
export 'src/providers/live_stacking_service_provider.dart';
export 'src/providers/logging_service_provider.dart';
export 'src/providers/master_accumulation_service_provider.dart';
export 'src/providers/master_annotation_service_provider.dart';
export 'src/providers/mosaic_project_service_provider.dart';
export 'src/providers/mount_home_watcher_provider.dart';
export 'src/providers/mount_slew_watcher_providers.dart';
export 'src/providers/night_analysis_service_provider.dart';
export 'src/providers/night_end/night_end_settings_providers.dart';
export 'src/providers/night_end/night_end_runner_provider.dart';
export 'src/providers/notification_service_provider.dart';
export 'src/providers/open_plan_service_provider.dart';
export 'src/providers/science/photometric_catalog_service_provider.dart';
export 'src/providers/science/photometric_transform_service_provider.dart';
export 'src/providers/plate_solve_service_provider.dart';
export 'src/providers/plugin_management_service_provider.dart';
export 'src/providers/post_session_integration_service_provider.dart';
export 'src/providers/post_session_seam_provider.dart';
export 'src/providers/profile_service_provider.dart';
export 'src/providers/planning/project_service_provider.dart';
export 'src/providers/sample_sequence_service_providers.dart';
export 'src/providers/scheduler/scheduler_queue_service_provider.dart';
export 'src/providers/science/default_science_backend_provider.dart';
export 'src/providers/science/science_camera_auto_config_provider.dart';
export 'src/providers/science/science_processing_service_provider.dart';
export 'src/providers/science/science_report_exporter_provider.dart';
export 'src/providers/science/science_reprocess_service_provider.dart';
export 'src/providers/sequence_file_service_provider.dart';
export 'src/providers/sequence_repository_provider.dart';
export 'src/providers/sesame_name_resolver_provider.dart';
export 'src/providers/end_of_night_calibration/eon_deferral_provider.dart';
export 'src/providers/sky_atlas/sky_atlas_seam_provider.dart';
export 'src/providers/smart_notification_service_provider.dart';
export 'src/providers/smart_project_service_provider.dart';
export 'src/providers/snippet_file_service_provider.dart';
export 'src/providers/stack_and_share_service_provider.dart';
export 'src/providers/stack_light_selector_provider.dart';
export 'src/providers/stack_share_export_service_provider.dart';
export 'src/providers/sync/sync_service_provider.dart';
export 'src/providers/scheduler/target_constraint_service_provider.dart';
export 'src/providers/target_library_service_provider.dart';
export 'src/providers/transient_alert_service_provider.dart';
export 'src/providers/darkroom_autopilot/dawn_autopilot_providers.dart';
export 'src/providers/darkroom_delivery/delivery_providers.dart';
export 'src/providers/darkroom_pass/pass_providers.dart';
export 'src/providers/darkroom_processing_options_provider.dart';
export 'src/providers/darkroom_autopilot/guided_build_delivery_provider.dart';
