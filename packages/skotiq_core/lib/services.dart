/// Services of skotiq_core: the logic that works on backends, the database and files.
///
/// Exports only files under `src/services/`.
library;

export 'src/services/focuser_backlash/effective_focuser_backlash.dart';
export 'src/services/camera_warmup_controller.dart' show CameraWarmupOutcome;
export 'src/services/scheduler/target_progress_service.dart';
export 'src/services/built_in_catalogs.dart';
export 'src/services/catalog_target_resolver.dart';
export 'src/services/target_library_service.dart' show TargetLibraryService;
export 'src/services/sequence_rollup.dart';
export 'src/services/linked_rig/linked_rig_store.dart';
export 'src/services/linked_rig/rig_link_service.dart';
export 'src/services/host_mutation_event_hub.dart';
export 'src/services/catalog_lookup/simbad_provider.dart';
export 'src/services/sesame_name_resolver.dart';
export 'src/services/catalog_lookup/exoplanet_provider.dart';
export 'src/services/catalog_lookup/gaia_provider.dart';
export 'src/services/device_commands.dart';
export 'src/services/device_service.dart';
export 'src/services/mount_home_watcher.dart';
export 'src/services/mount_slew_watcher.dart';
export 'src/services/device_exceptions.dart';
export 'src/services/phd2_status_poll.dart';
export 'src/services/phd2_probe.dart'
    show Phd2ProbeOutcome, Phd2ProbeResult, normalizePhd2ProbeHost, probePhd2;
export 'src/services/device_matching_service.dart';
export 'src/services/local_imaging_records.dart'
    show
        LocalImagingRecords,
        imagingRecordsProvider,
        SolvedFrameFoldHook,
        applyAtlasFoldDedup;
export 'src/services/imaging_service.dart';
export 'src/services/capture_preview_loader.dart' show CapturePreviewPublisher, capturedImageDataFromResult;
export 'src/services/stretch_pipeline_service.dart';
export 'src/services/thumbnail_sidecar_service.dart';
export 'src/services/plate_solve_service.dart';
export 'src/services/first_light/first_light_orchestrator.dart';
export 'src/services/centering_service.dart';
export 'src/services/profile_service.dart';
export 'src/services/sequence_repository.dart';
export 'src/services/local_sequence_repository.dart';
export 'src/services/remote_sequence_repository.dart';
export 'src/services/sequence_file_service.dart';
export 'src/services/open_plan_service.dart';
export 'src/services/snippet_file_service.dart';
export 'src/services/sample_sequence_service.dart';
export 'src/services/import/sequence_importer.dart';
export 'src/services/import/nina_sequence_parser.dart';
export 'src/services/import/sgp_sequence_parser.dart';
export 'src/services/import/canonical_node_mapper.dart';
export 'src/services/import/csv_parser.dart';
export 'src/services/import/telescopius_csv_importer.dart';
export 'src/services/import/observing_list_json_importer.dart';
export 'src/services/import/astrobin_importer.dart';
export 'src/services/import/ics_calendar_importer.dart';
export 'src/services/import/generic_csv_importer.dart';
export 'src/services/import/target_library_importer.dart';
export 'src/services/wcs/gnomonic_projection.dart';
export 'src/services/wcs/master_wcs.dart';
export 'src/services/wcs/wcs_sip_codec.dart';
export 'src/services/wcs/plate_solve_data_from_result.dart';
export 'src/services/hips/healpix_nested.dart';
export 'src/services/catalog_overlay_service.dart';
export 'src/services/annotation_service.dart';
export 'src/services/annotation_export.dart';
export 'src/services/scheduler/scheduler_engine.dart';
export 'src/services/scheduler/integration_goal_service.dart';
export 'src/services/scheduler/target_constraint_service.dart';
export 'src/services/scheduler/scheduler_queue_service.dart';
export 'src/services/scheduler/horizon_profile.dart';
export 'src/services/scheduler/horizon_profile_store.dart';
// The single rejection-reason ladder shared by the engine's decision record
// and the queue row's STATUS chip.
export 'src/services/scheduler/rejection_labels.dart';
// Multi-Night & Forecast Planning (Roadmap #5) — services + Riverpod wiring.
//   * project_service.dart           - Project/membership CRUD + derived
//     CampaignProgress roll-up over the projects / project_targets tables.
//   * forecast_planning_service.dart - pure, I/O-free N-night clear-dark-hours
//     scorer fed already-fetched hourly cloud data + project target candidates.
//   * planning_provider.dart         - active-project selection, project list /
//     progress, and the week-ahead forecast providers (forecast fetch lives at
//     this provider layer, per the scheduler-stack convention).
export 'src/services/planning/project_service.dart';
export 'src/services/planning/forecast_planning_service.dart';
export 'src/services/focus_model_service.dart';
// Predictive autofocus persisted per-filter learning + drift detection.
export 'src/services/predictive_af_service.dart';
export 'src/services/logging_service.dart';
export 'src/services/diagnostic_dump_service.dart';
export 'src/services/error_service.dart';
export 'src/services/flat_wizard_service.dart';
export 'src/services/sky_brightness_tracker.dart';
export 'src/services/flat_exposure_calculator.dart';
export 'src/services/flat_exposure_follower.dart';
export 'src/services/backup_service.dart';
export 'src/services/auto_save_service.dart';
// Cloud backup/sync — bundle-based push/pull of configuration across
// machines via WebDAV (Nextcloud / generic). Reuses BackupService bundles.
export 'src/services/sync/sync_target.dart';
export 'src/services/sync/webdav_sync_target.dart';
export 'src/services/sync/s3_sync_target.dart';
export 'src/services/sync/sync_service.dart';
// Plugin management (upload/enable/disable/uninstall)
export 'src/services/plugin_management_service.dart';
export 'src/services/notification_service.dart';
export 'src/services/push_notification_service.dart';
export 'src/services/notification/event_classifier.dart';
export 'src/services/notification/notification_presentation.dart';
export 'src/services/notification/notification_router.dart';
export 'src/services/notification/notification_signature.dart';
export 'src/services/notification/notification_template.dart';
export 'src/services/notification/secrets_store.dart';
export 'src/services/notification/transports/notification_transport.dart';
export 'src/services/notification/transports/discord_transport.dart';
export 'src/services/notification/transports/email_transport.dart';
export 'src/services/notification/transports/in_app_transport.dart';
export 'src/services/notification/transports/mqtt_transport.dart';
export 'src/services/notification/transports/pushover_transport.dart';
export 'src/services/notification/transports/system_push_transport.dart';
export 'src/services/notification/transports/telegram_transport.dart';
export 'src/services/notification/transports/webhook_transport.dart';
// v4 couch-grade remote — Home Assistant MQTT auto-discovery.
//   * Observatory surfaces as one HA device (sensors + binary sensors,
//     optional pause/abort controls) over the notification transport's
//     MQTT broker.
export 'src/services/home_assistant/home_assistant_discovery_config.dart';
export 'src/services/home_assistant/home_assistant_discovery_service.dart';
export 'src/services/home_assistant/home_assistant_host_settings.dart';
export 'src/services/home_assistant/ha_discovery_payloads.dart';
export 'src/services/critical_alert_player.dart';
export 'src/services/session_export_service.dart';
export 'src/services/session_report_service.dart';
export 'src/services/notes_service.dart';
export 'src/services/optical_train_limits.dart';
export 'src/services/sequence_diff_service.dart';
export 'src/services/campaign_rollup_service.dart';
export 'src/services/mosaic_service.dart';
// Mosaic M2 — durable mosaic project orchestration (plan -> integrate -> stitch).
export 'src/services/mosaic_project_service.dart';
// Distributed collaborative mosaics (publish/claim/upload/assemble over the
// hub).
export 'src/services/mosaic/collaborative_mosaic_service.dart';
// Unattended owner auto-assembly / participant auto-download poller.
export 'src/services/mosaic/collaborative_mosaic_poller.dart';
// Persisted consent gating a panel-master upload.
export 'src/services/mosaic/mosaic_upload_consent.dart';
export 'src/services/framing_image_cache_service.dart';
export 'src/services/session_service.dart';
export 'src/services/quick_start_service.dart';
export 'src/services/calibration_service.dart';
export 'src/services/frame_quality_assessment_service.dart';
export 'src/services/frame_quality_score.dart';
// Adaptive sky-conditions target-swap composer + dashboard
// snapshot decoder.
export 'src/services/adaptive_swap_service.dart';
export 'src/services/forensics_service.dart';
export 'src/services/replay_debug_service.dart';
export 'src/services/session_optimizer_service.dart';
export 'src/services/smart_night/exposure_calculator.dart';
export 'src/services/smart_night/guide_rms_collector.dart';
export 'src/services/smart_night/hardware_specs_service.dart';
export 'src/services/sensor_specs/camera_sensor_database.dart';
export 'src/services/sensor_specs/camera_sensor_entry.dart';
export 'src/services/sensor_specs/camera_sensor_spec_resolver.dart';
export 'src/services/sensor_specs/camera_sensor_specs.dart';
export 'src/services/sensor_specs/curated_camera_sensors.dart';
export 'src/services/sensor_specs/published_figure.dart';
export 'src/services/smart_night/dark_library_coverage.dart';
export 'src/services/smart_night/smart_night_draft_service.dart';
// Smart Night auto-builder (the one-click "plan tonight").
export 'src/services/smart_night_service.dart';
// Conversational sequence builder (LLM-driven sequence planning).
export 'src/services/conversational_builder/llm_provider.dart';
export 'src/services/conversational_builder/llm_settings.dart';
export 'src/services/conversational_builder/conversational_builder_service.dart';
export 'src/services/conversational_builder/conversational_history_service.dart';
export 'src/services/conversational_builder/system_prompt_builder.dart';
export 'src/services/optical_train_diagnostics_service.dart';
export 'src/services/equipment_health_service.dart';
// USB disconnect log (production source for
// DeviceHealthSnapshot.disconnectCountLast24h).
export 'src/services/usb_disconnect_log.dart';
export 'src/services/session_handoff_service.dart';
export 'src/services/weather/weather_radar_service.dart';
export 'src/services/weather/cloud_motion_analyzer.dart';
export 'src/services/weather/weather_alert_service.dart';
export 'src/services/smart_notification_service.dart';
export 'src/services/target_suggestion_service.dart';
export 'src/services/transient_alert_service.dart';
export 'src/services/sequence_time_estimator.dart';
export 'src/services/pre_session_simulator.dart';
export 'src/services/plan_timer.dart';
export 'src/services/science/astrometric_residuals.dart';
export 'src/services/science/nearest_neighbour_matching.dart';
export 'src/services/science/science_backend.dart';
export 'src/services/science/default_science_backend.dart';
export 'src/services/science/science_processing_service.dart';
export 'src/services/science/science_reprocess_service.dart';
export 'src/services/science/science_status.dart';
export 'src/services/science/science_insights_engine.dart';
export 'src/services/science/sub_exposure_noise.dart';
// Night Narrator — stateful/temporal sibling of the insights engine. The app
// only needs the public event value type + evidence codecs and the Riverpod
// providers (feed streams + keepalive service). The engine/context/detector
// machinery is internal; core tests reach it via `package:skotiq_core/src/…`.
export 'src/services/science/narrator/narrator_event.dart';
export 'src/services/science/science_report_exporter.dart';
export 'src/services/science/fits_header_writer.dart';
export 'src/services/science/frame_grade_rules.dart';
export 'src/services/science/frame_auto_grader.dart';
export 'src/services/science/photometric_transform_service.dart';
export 'src/services/science/aavso_export_service.dart';
export 'src/services/science/mpc_export_service.dart';
export 'src/services/science/period_analysis_service.dart';
export 'src/services/science/science_camera_auto_config.dart';
export 'src/services/science/photometric_catalog_service.dart';
export 'src/services/science/photometric_bands.dart';
export 'src/services/calibration_master_builder.dart';
export 'src/services/dark_library_service.dart';
export 'src/services/end_of_night_calibration/eon_plan.dart';
export 'src/services/end_of_night_calibration/eon_service.dart';
export 'src/services/end_of_night_calibration/eon_settings.dart';
export 'src/services/end_of_night_calibration/eon_deferral.dart';
export 'src/services/end_of_night_calibration/eon_trigger.dart';
export 'src/services/dark_library_coverage_service.dart';
export 'src/services/live_stacking_service.dart';
export 'src/services/live_stack_master_library.dart';
// Broadcast endpoint for EAA / outreach live-stack viewing.
export 'src/services/live_stacking_broadcast_service.dart';
// Stack-and-Share Loop (components C6/C8): orchestrator + share/export service.
export 'src/services/stack_and_share_service.dart';
export 'src/services/stack_light_selector.dart' show NoLightsToStackException, StackLightSelector;
export 'src/services/stack_share_export_service.dart';
// Post-session (offline/batch) integration: archival masters + multi-night
// accumulation + master-flat library.
export 'src/services/post_session_seam.dart';
export 'src/services/darkroom_build_jobs.dart';
export 'src/services/output_locations.dart';
export 'src/services/darkroom_state_store.dart';
export 'src/services/night_end/night_end_coordinator.dart';
export 'src/services/night_end/night_end_run.dart';
export 'src/services/night_end/night_end_runner.dart';
export 'src/services/night_end/night_end_settings.dart';
export 'src/services/darkroom_build_service.dart';
export 'src/services/post_session_integration_service.dart';
export 'src/services/master_accumulation_service.dart';
export 'src/services/flat_library_service.dart';
// Smart Morning Report (v42): multi-night project intelligence + scheduler
// deficit loop.
export 'src/services/smart_project_service.dart';
// Smart Morning Report (v42): Night Doctor diagnostics + report computation.
export 'src/services/night_analysis_service.dart' show NightAnalysisService;
// Smart Morning Report (v42): catalog-powered finishing — SPCC colour
// calibration + the master annotation layer.
export 'src/services/color_calibration_service.dart';
export 'src/services/master_annotation_service.dart';
export 'src/services/sky_atlas/sky_atlas_models.dart';
export 'src/services/sky_atlas/sky_atlas_seam.dart';
export 'src/services/sky_atlas/sky_atlas_service.dart';
export 'src/services/constellation/constellation_models.dart';
export 'src/services/coimaging/coimaging_session_service.dart';
export 'src/services/constellation/constellation_client.dart';
export 'src/services/constellation/constellation_service.dart';
export 'src/services/constellation/hub_credentials.dart';
export 'src/services/transients/transient_candidate.dart';
export 'src/services/transients/difference_image_seam.dart';
export 'src/services/transients/first_light_service.dart';
export 'src/services/transients/transient_report_service.dart';
export 'src/services/transients/transient_submission_service.dart';
export 'src/services/transients/transient_alert_mapper.dart';
// Darkroom delivery (Phase B): the three transports, the journal-driven retry
// engine, and the peer manifest the paired desktop pulls.
export 'src/services/darkroom_delivery/darkroom_delivery.dart';
// Dawn autopilot (Phase B): the durable job that drafts, renders, reports and
// delivers the night after the integration half has produced its masters.
export 'src/services/darkroom_autopilot/darkroom_autopilot.dart';
export 'src/services/darkroom_pass/darkroom_pass.dart';
export 'src/services/project_tracking_service.dart';
export 'src/services/calibration/dark_selection.dart';
export 'src/services/calibration/defect_map_service.dart';
export 'src/services/calibration/fits_header_reader.dart';
export 'src/services/calibration_library_service.dart';
export 'src/services/calibration_backlog_service.dart';
export 'src/services/calibration/shared_calibration_client.dart';
export 'src/services/calibration/shared_calibration_library.dart';
export 'src/services/disk_space_service.dart';
export 'src/services/disk_space_guard.dart';
export 'src/services/safe_rig_service.dart';
export 'src/services/safety_config_service.dart';
export 'src/services/smart_night/camera_capture_defaults.dart';
export 'src/services/hips/hips_tile_loader.dart';
export 'src/services/hips/hips_tile_selection.dart';
export 'src/services/hips/hips_tile_cache.dart';
export 'src/services/stacking_engine_seam.dart';
export 'src/services/hips/hips_tile_fetcher.dart';
export 'src/services/science/narrator/narrator_detectors.dart';
export 'src/services/hardware_presets/hardware_presets_service.dart';
