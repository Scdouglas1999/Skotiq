/// Skotiq Core - services + utilities barrel.
///
/// Re-exports the business-logic services (device, imaging, scheduler, science,
/// notification, calibration, …) and the shared pure-Dart utilities. Prefer
/// this import in code that drives core behaviour without needing the full
/// provider/database/model surface.
library;

export 'src/services/scheduler/target_progress_service.dart';
export 'src/services/catalog_target_resolver.dart';
export 'src/services/target_library_service.dart'
    show TargetLibraryService, targetLibraryServiceProvider;

// Services
export 'src/services/device_service.dart';
export 'src/services/camera_warmup_controller.dart' show CameraWarmupOutcome;
export 'src/services/device_exceptions.dart';
export 'src/utils/device_id.dart' show isValidDeviceIdFormat;
// Single source of truth for device-identity logic: parsing, canonicalization,
// matching, and id-pattern friendly-name fallback.
export 'src/utils/device_id.dart'
    show
        DeviceId,
        DeviceDriverKind,
        canonicalGuiderId,
        isPhd2DeviceId,
        deviceIdsMatch,
        friendlyNameFromDeviceId,
        kPhd2CanonicalId;
export 'src/services/phd2_status_poll.dart';
export 'src/services/device_matching_service.dart';
export 'src/services/imaging_service.dart';
export 'src/services/thumbnail_sidecar_service.dart';
export 'src/services/plate_solve_service.dart';
export 'src/services/first_light/first_light_orchestrator.dart';
export 'src/services/polar_alignment_service.dart';
export 'src/services/centering_service.dart';
export 'src/services/profile_service.dart';
export 'src/services/sequence_repository.dart';
export 'src/services/sequence_file_service.dart';
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
export 'src/services/wcs_overlay.dart';
export 'src/services/wcs/gnomonic_projection.dart';
export 'src/services/hips/healpix_nested.dart';
export 'src/services/catalog_overlay_service.dart';
export 'src/services/annotation_service.dart';
export 'src/services/scheduler_service.dart';
export 'src/services/scheduler/scheduler_engine.dart';
export 'src/services/scheduler/integration_goal_service.dart'
    hide
        integrationGoalsSchemaSql,
        integrationGoalsTargetIndexSql,
        targetConstraintsSchemaSql,
        targetConstraintsTargetIndexSql,
        horizonProfilesSchemaSql;
export 'src/services/scheduler/target_constraint_service.dart';
// Two HorizonProfile classes exist in the codebase:
//   * settings_provider.dart::HorizonProfile  - legacy 8-point compass profile
//     stored as JSON in app_settings.horizon_profile_json
//   * services/scheduler/horizon_profile.dart::HorizonProfile  - newer
//     samples-based profile persisted in the horizon_profiles drift table
// The legacy one is still referenced by target_suggestion_service.dart via a
// `show` import; we hide it from the barrel so the scheduler's profile is the
// canonical public class.
export 'src/services/scheduler/horizon_profile.dart';
export 'src/services/scheduler/sky_calculations.dart';
// Multi-Night & Forecast Planning (Roadmap #5) — services.
//   * project_service.dart           - Project/membership CRUD + derived
//     CampaignProgress roll-up over the raw projects / project_targets tables.
//     The schema DDL constants are hidden from the barrel (mirroring the
//     scheduler stack); scheduler_provider.dart imports them directly via the
//     src path to ensure the planner tables exist alongside the scheduler ones.
//   * forecast_planning_service.dart - pure, I/O-free N-night clear-dark-hours
//     scorer fed already-fetched hourly cloud data + project target candidates.
export 'src/services/planning/project_service.dart'
    hide
        projectsSchemaSql,
        projectTargetsSchemaSql,
        projectTargetsProjectIndexSql,
        projectTargetsTargetIndexSql;
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
export 'src/services/host_mutation_event_hub.dart';

// Comprehensive notification routing.
//   * NotificationRouter dispatcher (event-stream → transports) + the per-
//     transport implementations across in-app / mobile push / email / webhook /
//     Pushover / Telegram / Discord / MQTT.
export 'src/services/notification/notification_router.dart';
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
export 'src/services/home_assistant/ha_discovery_payloads.dart';
export 'src/services/critical_alert_player.dart';
export 'src/services/session_export_service.dart';
export 'src/services/session_report_service.dart';
// Per-target / per-run notes journal + sequence diff.
export 'src/services/notes_service.dart';
export 'src/services/sequence_diff_service.dart';
export 'src/services/campaign_rollup_service.dart';
export 'src/services/mosaic_service.dart';
// Mosaic M2 — durable mosaic project orchestration (plan -> integrate -> stitch).
export 'src/services/mosaic_project_service.dart';
export 'src/services/framing_image_cache_service.dart';
export 'src/services/session_service.dart';
export 'src/services/quick_start_service.dart';
export 'src/services/calibration_service.dart';
export 'src/services/frame_quality_assessment_service.dart';
// Adaptive sky-conditions target-swap composer + dashboard
// snapshot decoder.
export 'src/services/adaptive_swap_service.dart';
// Frame-Failure Forensics (per-rejection cause classification).
export 'src/services/forensics_service.dart';
// Replay Debug (retrospective decision-tree scrubber).
export 'src/services/replay_debug_service.dart';
export 'src/services/session_optimizer_service.dart';
export 'src/services/smart_night/exposure_calculator.dart';
export 'src/services/smart_night/guide_rms_collector.dart';
export 'src/services/smart_night/hardware_specs_service.dart';
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
export 'src/services/science/nearest_neighbour_matching.dart';
export 'src/services/science/science_backend.dart';
export 'src/services/science/default_science_backend.dart';
export 'src/services/science/science_processing_service.dart';
export 'src/services/science/science_status.dart';
export 'src/services/science/science_insights_engine.dart';
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
export 'src/services/dark_library_service.dart';
export 'src/services/dark_library_coverage_service.dart';
export 'src/services/live_stacking_service.dart';
export 'src/services/live_stack_master_library.dart';
// Broadcast endpoint for EAA / outreach live-stack viewing.
export 'src/services/live_stacking_broadcast_service.dart';
// Stack-and-Share Loop (components C6/C8): orchestrator + share/export service.
export 'src/services/stack_and_share_service.dart';
export 'src/services/stack_share_export_service.dart';
// Post-session (offline/batch) integration: archival masters + multi-night
// accumulation + master-flat library.
export 'src/services/post_session_seam.dart';
export 'src/services/post_session_integration_service.dart';
export 'src/services/master_accumulation_service.dart';
export 'src/services/flat_library_service.dart';
// Smart Morning Report (v42): multi-night project intelligence + scheduler
// deficit loop.
export 'src/services/smart_project_service.dart';
// Smart Morning Report (v42): Night Doctor diagnostics + report computation.
export 'src/services/night_analysis_service.dart'
    show NightAnalysisService, nightAnalysisServiceProvider;
// Smart Morning Report (v42): catalog-powered finishing — SPCC colour
// calibration + the master annotation layer.
export 'src/services/color_calibration_service.dart';
export 'src/services/master_annotation_service.dart';
export 'src/services/project_tracking_service.dart';
export 'src/services/calibration/defect_map_service.dart';
// Calibration Library Manager (v46): unified browse / tag / auto-match over
// dark_library, flat_library, and defect_maps + the calibration_tags layer.
export 'src/services/calibration/fits_header_reader.dart';
export 'src/services/calibration_library_service.dart';
export 'src/services/calibration_backlog_service.dart';
export 'src/services/disk_space_service.dart';
export 'src/services/disk_space_guard.dart';
export 'src/services/safe_rig_service.dart';

// Utilities
export 'src/utils/coordinate_parser.dart';
export 'src/utils/coordinate_format.dart';
export 'src/utils/dither_settle_presets.dart';
