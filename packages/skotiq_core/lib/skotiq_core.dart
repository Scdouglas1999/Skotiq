/// Skotiq Core - Shared business logic.
///
/// This is the aggregate barrel: it re-exports every public symbol in the
/// package and is retained for backward compatibility. It stays exhaustive so
/// existing `package:skotiq_core/skotiq_core.dart` imports keep
/// resolving everything.
///
/// NEW imports should prefer the narrower, layer-scoped barrels to keep their
/// dependency surface small:
///   * skotiq_core_models.dart    - pure domain/value types
///   * skotiq_core_backend.dart   - backend interface + wire models
///   * skotiq_core_database.dart  - drift database + DAOs
///   * skotiq_core_services.dart  - business-logic services + utilities
///   * skotiq_core_providers.dart - Riverpod providers / DI wiring
library;

// Database - hide entity names that collide with domain-model classes of the
// same name. The drift row types for `CapturedImage` / `EquipmentProfile` are
// still reachable through this barrel via the `DbCapturedImage` /
// `DbEquipmentProfile` typedef aliases re-exported below
export 'src/database/database.dart'
    hide Target, Sequence, SequenceNode, CapturedImage, EquipmentProfile;
export 'src/database/database_aliases.dart';
// Aliases for class names hidden from the barrel due to symbol collisions
// (legacy HorizonProfile vs scheduler HorizonProfile; tutorial-step
// FirstNightWizard model vs skotiq_app FirstNightWizard widget).
export 'src/legacy_aliases.dart';
export 'src/database/integrity_check.dart';
export 'src/database/integration_stage_marker.dart';
export 'src/database/session_orphan_sweep.dart';
export 'src/database/single_instance_lock.dart';
export 'src/database/sqlite_busy.dart';

// DAOs
export 'src/database/daos/equipment_profiles_dao.dart';
export 'src/database/daos/targets_dao.dart';
export 'src/database/daos/sessions_dao.dart';
export 'src/database/daos/images_dao.dart';
export 'src/database/daos/sequences_dao.dart';
export 'src/database/daos/sequence_checkpoints_dao.dart';
export 'src/database/daos/settings_dao.dart';
export 'src/database/daos/weather_settings_dao.dart';
export 'src/database/daos/flat_history_dao.dart';
export 'src/database/daos/tutorial_progress_dao.dart';
export 'src/database/daos/tutorial_dao.dart';
export 'src/database/daos/polar_alignment_history_dao.dart';
export 'src/database/daos/science_dao.dart';
export 'src/database/daos/dark_library_dao.dart';
// Stack-and-Share Loop (component C3): persisted stacked-result provenance.
export 'src/database/daos/stacked_results_dao.dart';
export 'src/database/daos/observation_logs_dao.dart';
export 'src/database/daos/observing_lists_dao.dart';
export 'src/database/daos/sequence_runs_dao.dart';

// Data models (domain models, distinct from DB entities)
// TrackingRate is re-exported from equipment_models.dart (canonical source: device_capabilities.dart)
export 'src/models/equipment/equipment_models.dart';
export 'src/models/equipment/unified_device.dart';
export 'src/models/equipment/discovery_state.dart';
export 'src/models/mount_site_reconciliation.dart';
export 'src/models/equipment_profile.dart';
export 'src/models/equipment_profile_remote_mapping.dart';
export 'src/models/equipment_profile_validation.dart';
export 'src/models/settings/app_settings.dart';
export 'src/models/errors/server_error.dart';
export 'src/models/imaging/imaging_models.dart';
export 'src/models/imaging/camera_preset.dart';
export 'src/models/imaging/auto_stretch_settings.dart';
// Stack-and-Share Loop (component C7): config, progress, result, export models.
export 'src/models/imaging/stack_and_share_models.dart';
// Post-session integration: advanced settings model + integrated-master models.
export 'src/models/imaging/integration_settings.dart';
export 'src/models/imaging/integrated_master.dart';
export 'src/models/imaging/narrowband_composite.dart';
// Durable mosaic projects + panels (Mosaic M2, v45). The DURABLE per-panel
// record is MosaicProjectPanel — distinct from the capture-geometry MosaicPanel
// value object in services/mosaic_service.dart (which keeps the bare name).
export 'src/models/imaging/mosaic_project.dart';
// Smart Morning Report (v42): Night Doctor report + finding value types.
export 'src/models/imaging/night_report.dart';
// Smart Morning Report (v42): marginal-SNR integration curve + subset
// recommendation (api_analyze_night), and the catalog-powered finishing value
// types — star photometry (api_detect_stars_photometry), colour calibration
// (api_color_calibrate), and the annotation layer.
export 'src/models/imaging/integration_curve.dart';
export 'src/models/imaging/star_photometry.dart';
export 'src/models/imaging/color_calibration_result.dart';
// Mosaic M2: panel-mosaic stitch result (api_stitch_mosaic).
export 'src/models/imaging/mosaic_stitch_result.dart';
export 'src/models/imaging/annotation.dart';
// Push-based live-view streaming over WebSocket.
export 'src/models/live_view/live_view_frame.dart';
export 'src/models/calibration/dark_library_match_tolerances.dart';
// Wire-level model classes for the headless calibration API.
export 'src/models/calibration/remote_calibration_models.dart';
export 'src/models/sequence/sequence_models.dart';
// Active-plan ownership of the editor/executor slot (manual vs automated).
export 'src/models/sequence/active_plan_owner.dart';
// Sky-brightness adaptive exposure event surface.
export 'src/models/sequence/adaptive_exposure_event.dart';
export 'src/models/sequence/instruction_progress_detail.dart';
export 'src/models/sequence/template_snippet.dart';
// Variable / expression interpolation catalog. Dart-side mirror
// of the Rust `expressions::catalog`. Drives the VariablePicker UI.
export 'src/models/sequence/interpolation_catalog.dart';
export 'src/models/target/target_models.dart';
// HiPS framing tile-layer value types (pure Dart): properties parser, tile
// addressing, and the SurveySource -> CDS HiPS survey registry.
export 'src/models/hips/hips_properties.dart';
export 'src/models/hips/hips_tile_id.dart';
export 'src/models/hips/hips_survey_registry.dart';
export 'src/models/annotation_data.dart';
export 'src/models/annotation_settings.dart';
export 'src/models/tutorial/tutorial_models.dart';
// The model-layer FirstNightWizard class collides with the widget class of
// the same name in skotiq_app. We hide it from the barrel so callers
// either import tutorial_step.dart directly (the widget does) or just use
// FirstNightWizardStep.
export 'src/models/tutorial/tutorial_step.dart' hide FirstNightWizard;
export 'src/models/phd2_models.dart';
export 'src/models/weather/weather_models.dart';
export 'src/models/autofocus_progress.dart';
export 'src/models/focuser_backlash_calibration.dart';
export 'src/models/focuser_backlash_progress.dart';
export 'src/services/focuser_backlash/effective_focuser_backlash.dart';
export 'src/models/meridian_flip_settings.dart';
export 'src/models/meridian_flip_event.dart';
export 'src/models/flat_wizard/flat_capture_config.dart';
export 'src/models/flat_wizard/flat_wizard_settings.dart';
export 'src/models/flat_wizard/flat_wizard_state.dart';
export 'src/models/polar_alignment_config.dart';
export 'src/models/alerts/transient_alert.dart';
export 'src/models/planning/target_suggestion.dart';
// Multi-Night & Forecast Planning (Roadmap #5).
//   * project.dart           - Project / ProjectTarget campaign models.
//   * project_progress.dart  - FilterProgressLine / ProjectTargetProgress /
//     CampaignProgress (derived accrued-vs-goal roll-ups). FilterProgressLine
//     is deliberately named to avoid colliding with scheduler FilterProgress;
//     the project roll-up is named `CampaignProgress` (a project IS a
//     multi-night campaign) to avoid colliding with the unrelated, pre-existing
//     analytics project_tracking_service.dart::ProjectProgress (also on the
//     barrel, consumed by analytics/widgets/project_tracking_panel.dart). Both
//     are exported under their own names — no `hide`, no inferred-only type.
//   * night_forecast.dart    - ForecastTargetUp / NightForecast / WeekForecast.
export 'src/models/planning/project.dart';
export 'src/models/planning/project_progress.dart';
export 'src/models/planning/night_forecast.dart';
export 'src/models/optical_config.dart';
export 'src/models/onboarding/onboarding_state.dart';
// Quick Wins Bundle (C1/C2) — post-onboarding "next use" nudge surface.
//   * next_use_steps.dart            - pure-Dart action-step catalog
//     (NextUseActionId / NextUseStep / kNextUseSteps / stepFor).
//   * next_use_prompt_provider.dart  - readiness/completion/dismissal
//     wiring + the pure selectNextUseStep decision and the
//     nextUsePromptProvider the dashboard prompt card watches.
export 'src/models/onboarding/next_use_steps.dart';
export 'src/models/hardware_presets/hardware_preset_models.dart';
export 'src/models/science/science_models.dart';
export 'src/models/defect_map.dart';
export 'src/models/plate_solver.dart';
export 'src/models/readiness/readiness_models.dart';
export 'src/models/session_report.dart';
export 'src/models/campaign_rollup.dart';
// Durable multi-night campaign record (Phase B, v43).
export 'src/models/campaign.dart';

// Scheduler — RoboTarget-class dynamic scheduling.
export 'src/models/scheduler/integration_goal.dart';
export 'src/models/scheduler/target_constraint.dart';
export 'src/models/scheduler/scheduler_decision.dart';
export 'src/models/scheduler/scheduler_status.dart';
export 'src/models/scheduler/scheduler_readiness.dart';
export 'src/models/scheduler/target_progress.dart';
export 'src/services/scheduler/target_progress_service.dart';
export 'src/providers/mount_site_provider.dart';
export 'src/providers/target_progress_provider.dart';
export 'src/services/catalog_target_resolver.dart';
export 'src/services/target_library_service.dart'
    show TargetLibraryService, targetLibraryServiceProvider;

// Sequence import — NINA / SGP sequences.
export 'src/models/import/canonical_sequence_node.dart';
export 'src/models/import/import_result.dart';

// Providers
export 'src/providers/app_version_provider.dart';
export 'src/providers/focuser_backlash_calibration_provider.dart';
export 'src/providers/focuser_backlash_provider.dart';
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
// The one predicate every surface asks before calling a run's end an error.
export 'src/providers/sequence/run_stop_classification.dart';
// The one wording for a target dropped by its own end_when.
export 'src/providers/sequence/run_dither_event.dart';
export 'src/providers/sequence/target_end_when_notice.dart';
// The one vocabulary for an exposure node's per-frame progress line.
export 'src/providers/sequence/exposure_progress_vocabulary.dart';
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
// Hide settings_provider's legacy HorizonProfile so the scheduler's
// samples-based HorizonProfile (services/scheduler/horizon_profile.dart) wins
// at the barrel. Direct importers of settings_provider.dart still see it.
export 'src/providers/settings_provider.dart' hide HorizonProfile;
export 'src/providers/clock_provider.dart';
export 'src/providers/profiles_provider.dart';
export 'src/providers/profile_activation_writethrough.dart';
export 'src/providers/equipment_fov_provider.dart';
export 'src/providers/focus_model_profile_data_provider.dart';
export 'src/providers/guiding_provider.dart';
export 'src/providers/backend_provider.dart';
export 'src/providers/remote_session_sync_provider.dart';
export 'src/providers/remote_sync_events.dart';
export 'src/providers/remote_sync_handler.dart';
export 'src/providers/host_mutation_event_provider.dart';
export 'src/providers/host_local_sync_provider.dart';
// Hot-plug device-detection event bridge.
export 'src/providers/hotplug_event_bridge_provider.dart';
export 'src/models/backend/host_mutation_event.dart';
export 'src/models/depthlock/depthlock_models.dart';
export 'src/providers/depthlock_provider.dart';
export 'src/services/host_mutation_event_hub.dart';
export 'src/providers/simbad_provider.dart';
export 'src/services/sesame_name_resolver.dart';
export 'src/providers/exoplanet_provider.dart';
export 'src/providers/gaia_provider.dart';
export 'src/providers/annotation_settings_provider.dart';
export 'src/providers/annotation_presets_provider.dart'
    hide AnnotationPreset, annotationPresetsProvider, AnnotationPresetsNotifier;
export 'src/providers/tutorial_provider.dart';
export 'src/providers/filter_offset_provider.dart';
export 'src/providers/camera_presets_provider.dart';
export 'src/providers/weather_providers.dart';
export 'src/providers/camera_sensor_specs_provider.dart';
export 'src/providers/capability_provider.dart';
export 'src/providers/equipment/device_capability_provider.dart';
export 'src/providers/equipment/device_type_registry.dart';
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
export 'src/providers/glance_mode_provider.dart';
export 'src/providers/connection_quality_provider.dart';
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

// Backend interface
export 'src/backend/skotiq_backend.dart';
export 'src/backend/ffi_backend.dart';
export 'src/backend/network_backend.dart';
export 'src/backend/disconnected_backend.dart';
// Single seam for the typed sequencer/run event surface — app/headless UI
// consume the bridge event union + display helpers through here instead of
// importing package:skotiq_bridge directly.
//
// SkotiqEvent / EventCategory / EventSeverity are hidden here because the
// names also belong to the wire/JSON event model surfaced via the
// skotiq_backend.dart re-export above (the headless API server + network
// backend serialize it), and that wire model stays canonical on this aggregate
// barrel. The TYPED bridge trio is reached through the dedicated, prefixed
// `package:skotiq_core/skotiq_core_events.dart` library. Everything
// else (every EventPayload_* / per-family variant, SchedulerScoreEntry,
// isCriticalEvent, skotiqEventDisplayTitle/Detail) flows through unprefixed.
export 'src/backend/bridge_events.dart'
    hide SkotiqEvent, EventCategory, EventSeverity;
// Per-frame capture truth carried on FrameAccepted/FrameRejected. Exported so
// the surfaces that persist or assert on a sequenced frame read the event's
// key names from one place rather than re-spelling them.
export 'src/backend/frame_capture_metadata.dart';
// Authored sentence inside a typed bridge error, for UI packages that render a
// caught error as copy without importing package:skotiq_bridge.
export 'src/backend/bridge_error_message.dart';
export 'src/models/backend/fits_header.dart';
export 'src/models/backend/image_result.dart';
export 'src/models/backend/platform_capabilities.dart';
export 'src/models/backend/remote_api_compatibility.dart';
// Recovery Mode — Dart mirror of the Rust `RecoveryContext`,
// `RecoveryHistoryEntry`, `RecoveryCause`, and `RecoveryPhase` so the Run
// Dashboard recovery banner and post-session report render the same data
// the executor publishes.
export 'src/models/sequencer/recovery_status.dart';

// Services
export 'src/services/device_service.dart';
export 'src/services/mount_home_watcher.dart';
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
        kBuiltinGuiderDisplayName,
        kBuiltinGuiderIdPrefix,
        kSimulatorDeviceDisplayNames,
        kPhd2CanonicalId;
export 'src/services/phd2_status_poll.dart';
export 'src/services/phd2_probe.dart'
    show Phd2ProbeOutcome, Phd2ProbeResult, normalizePhd2ProbeHost, probePhd2;
export 'src/services/device_matching_service.dart';
export 'src/services/imaging_records_repository.dart'
    show
        ImagingRecordsRepository,
        imagingRecordsRepositoryProvider,
        SolvedFrameFoldHook,
        applyAtlasFoldDedup;
export 'src/services/imaging_service.dart';
export 'src/services/stretch_pipeline_service.dart';
export 'src/services/thumbnail_sidecar_service.dart';
export 'src/providers/thumbnail_sidecar_provider.dart';
export 'src/services/plate_solve_service.dart';
export 'src/services/first_light/first_light_orchestrator.dart';
export 'src/providers/first_light_provider.dart';
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
export 'src/services/wcs/wcs_sip_codec.dart';
export 'src/services/hips/healpix_nested.dart';
export 'src/services/catalog_overlay_service.dart';
export 'src/providers/catalog_overlay_provider.dart';
export 'src/providers/current_frame_analysis_provider.dart';
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
export 'src/services/scheduler/scheduler_queue_service.dart'
    hide schedulerRemovedTargetsSchemaSql;
// Two HorizonProfile classes exist in the codebase:
//   * settings_provider.dart::HorizonProfile  - legacy 8-point compass profile
//     stored as JSON in app_settings.horizon_profile_json
//   * services/scheduler/horizon_profile.dart::HorizonProfile  - newer
//     samples-based profile persisted in the horizon_profiles drift table
// The legacy one is still referenced by target_suggestion_service.dart via a
// `show` import; we hide it from the barrel so the scheduler's profile is the
// canonical public class.
export 'src/services/scheduler/horizon_profile.dart';
// The single rejection-reason ladder shared by the engine's decision record
// and the queue row's STATUS chip.
export 'src/services/scheduler/rejection_labels.dart';
export 'src/services/scheduler/sky_calculations.dart';
export 'src/providers/scheduler_provider.dart';
// Multi-Night & Forecast Planning (Roadmap #5) — services + Riverpod wiring.
//   * project_service.dart           - Project/membership CRUD + derived
//     CampaignProgress roll-up over the raw projects / project_targets tables.
//     The schema DDL constants are hidden from the barrel (mirroring the
//     scheduler stack); scheduler_provider.dart imports them directly via the
//     src path to ensure the planner tables exist alongside the scheduler ones.
//   * forecast_planning_service.dart - pure, I/O-free N-night clear-dark-hours
//     scorer fed already-fetched hourly cloud data + project target candidates.
//   * planning_provider.dart         - active-project selection, project list /
//     progress, and the week-ahead forecast providers (forecast fetch lives at
//     this provider layer, per the scheduler-stack convention).
export 'src/services/planning/project_service.dart'
    hide
        projectsSchemaSql,
        projectTargetsSchemaSql,
        projectTargetsProjectIndexSql,
        projectTargetsTargetIndexSql;
export 'src/services/planning/forecast_planning_service.dart';
export 'src/providers/planning_provider.dart';
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
export 'src/services/endpoint_sanitizer.dart';
// Plugin management (upload/enable/disable/uninstall)
export 'src/services/plugin_management_service.dart';
export 'src/services/notification_service.dart';
export 'src/services/push_notification_service.dart';

// Comprehensive notification routing.
//   * Per-event-type routing matrix across in-app / mobile push / email /
//     webhook / Pushover / Telegram / Discord / MQTT.
//   * Per-transport configuration models.
//   * NotificationRouter dispatcher (event-stream → transports).
export 'src/models/notification/notification_categories.dart';
export 'src/models/notification/transport_configs.dart';
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
export 'src/providers/notification_router_provider.dart';

// v4 couch-grade remote — Home Assistant MQTT auto-discovery.
//   * Observatory surfaces as one HA device (sensors + binary sensors,
//     optional pause/abort controls) over the notification transport's
//     MQTT broker.
export 'src/services/home_assistant/home_assistant_discovery_config.dart';
export 'src/services/home_assistant/home_assistant_discovery_service.dart';
export 'src/services/home_assistant/ha_discovery_payloads.dart';
export 'src/providers/home_assistant_provider.dart';
export 'src/services/critical_alert_player.dart';
export 'src/services/session_export_service.dart';
export 'src/services/session_report_service.dart';
// Per-target / per-run notes journal + sequence diff.
export 'src/models/notes/journal_note.dart';
export 'src/services/notes_service.dart';
export 'src/services/optical_train_limits.dart';
export 'src/services/sequence_diff_service.dart';
export 'src/providers/notes_provider.dart';
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
// Frame-Failure Forensics (per-rejection cause classification).
export 'src/models/forensics/frame_forensics.dart';
export 'src/services/forensics_service.dart';
export 'src/providers/forensics_provider.dart';
// Replay Debug (retrospective decision-tree scrubber).
export 'src/models/replay_decision.dart';
export 'src/services/replay_debug_service.dart';
export 'src/providers/replay_debug_provider.dart';
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
export 'src/providers/smart_night_draft_provider.dart';
// Smart Night auto-builder (the one-click "plan tonight").
export 'src/services/smart_night_service.dart';
// Conversational sequence builder (LLM-driven sequence planning).
export 'src/services/conversational_builder/llm_provider.dart';
export 'src/services/conversational_builder/llm_settings.dart';
export 'src/services/conversational_builder/conversational_builder_service.dart';
export 'src/services/conversational_builder/conversational_history_service.dart';
export 'src/services/conversational_builder/system_prompt_builder.dart';
export 'src/providers/conversational_builder_provider.dart';
export 'src/services/optical_train_diagnostics_service.dart';
export 'src/services/equipment_health_service.dart';
// USB disconnect log (production source for
// DeviceHealthSnapshot.disconnectCountLast24h).
export 'src/services/usb_disconnect_log.dart';
export 'src/providers/usb_disconnect_log_provider.dart';
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
export 'src/providers/narrator_provider.dart';
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
export 'src/database/daos/integrated_masters_dao.dart';
export 'src/database/daos/flat_library_dao.dart';
// Living Sky (Wave 3): per-pillar retention/prune bookkeeping.
export 'src/database/daos/living_sky_retention_dao.dart';
export 'src/database/tables/living_sky_retention.dart'
    show LivingSkyRetentionScope;
// Pillar A ("Your Sky"): personal sky-atlas persistence + tables + service.
export 'src/database/daos/sky_atlas_dao.dart';
export 'src/database/tables/sky_atlas_tables.dart' show skyAtlasHealpixOrder;
export 'src/services/sky_atlas/sky_atlas_models.dart';
export 'src/services/sky_atlas/sky_atlas_seam.dart';
export 'src/services/sky_atlas/sky_atlas_service.dart';
export 'src/providers/sky_atlas_provider.dart';
// Pillar C ("Constellation"): community hub client + orchestration + providers.
export 'src/database/daos/constellation_contributions_dao.dart';
export 'src/services/constellation/constellation_models.dart';
// Shared trust primitives, co-imaging session membership, and the
// provenance/consent/scoped-role model.
export 'src/database/daos/coimaging_sessions_dao.dart';
export 'src/models/collaboration/collaboration_models.dart';
export 'src/services/coimaging/coimaging_session_service.dart';
export 'src/services/constellation/constellation_client.dart';
export 'src/services/constellation/constellation_service.dart';
export 'src/providers/constellation_provider.dart';
// Pillar B ("First Light"): difference-imaging transient log + scan service +
// report export.
export 'src/database/daos/transient_detections_dao.dart';
export 'src/services/transients/transient_candidate.dart';
export 'src/services/transients/difference_image_seam.dart';
export 'src/services/transients/first_light_service.dart';
export 'src/services/transients/transient_report_service.dart';
export 'src/services/transients/transient_submission_service.dart';
export 'src/services/transients/transient_alert_mapper.dart';
export 'src/providers/transient_detections_provider.dart';
// Smart Morning Report (v42): Night Doctor report persistence.
export 'src/database/daos/night_reports_dao.dart';
// Durable multi-night campaign counter (Phase B, v43).
export 'src/database/daos/campaigns_dao.dart';
// Narrowband palette composites (Phase C, v44).
export 'src/database/daos/narrowband_composites_dao.dart';
// Durable mosaic projects + panels (Mosaic M2, v45).
export 'src/database/daos/mosaic_projects_dao.dart';
export 'src/database/daos/mosaic_panels_dao.dart';
// Darkroom (v58): the non-destructive recipe stack + branch graph, the durable
// dawn-job queue, and the delivery destinations + journal.
export 'src/models/darkroom/darkroom_models.dart';
export 'src/database/daos/recipes_dao.dart';
export 'src/database/daos/darkroom_jobs_dao.dart';
export 'src/database/daos/delivery_targets_dao.dart';
export 'src/database/daos/delivery_journal_dao.dart';
// Darkroom delivery (Phase B): the three transports, the journal-driven retry
// engine, and the peer manifest the paired desktop pulls.
export 'src/services/darkroom_delivery/darkroom_delivery.dart';
// Dawn autopilot (Phase B): the durable job that drafts, renders, reports and
// delivers the night after the integration half has produced its masters.
export 'src/services/darkroom_autopilot/darkroom_autopilot.dart';
export 'src/services/project_tracking_service.dart';
export 'src/services/calibration/defect_map_service.dart';
// Calibration Library Manager (v46): unified browse / tag / auto-match over
// dark_library, flat_library, and defect_maps + the calibration_tags layer.
export 'src/models/calibration/calibration_library_models.dart';
export 'src/services/calibration/fits_header_reader.dart';
export 'src/services/calibration_library_service.dart';
export 'src/database/daos/calibration_tags_dao.dart';
// Shared calibration libraries — the hub wire model, the REST client, and the
// matcher-folding remote-library seam.
export 'src/models/calibration/shared_calibration_models.dart';
export 'src/services/calibration/shared_calibration_client.dart';
export 'src/services/calibration/shared_calibration_library.dart';
export 'src/services/disk_space_service.dart';
export 'src/services/disk_space_guard.dart';
export 'src/services/safe_rig_service.dart';
export 'src/services/safety_config_service.dart';

// Utilities
export 'src/utils/coordinate_parser.dart';
export 'src/utils/coordinate_format.dart';
export 'src/utils/resilient_poll_stream.dart';
export 'src/utils/dither_settle_presets.dart';
export 'src/utils/export_target.dart';
export 'src/utils/duration_format.dart';
export 'src/utils/temperature_format.dart';
export 'src/utils/utc_timestamp.dart';
export 'src/utils/remote_path.dart';
export 'src/utils/aligned_ticker.dart';
export 'src/utils/skotiq_data_directory.dart';
export 'src/utils/legacy_install_migration.dart';

export 'src/services/smart_night/camera_capture_defaults.dart';
