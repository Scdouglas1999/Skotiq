/// Skotiq Core - domain models barrel.
///
/// Re-exports the pure data/value types (equipment, imaging, sequence,
/// scheduler, planning, notification, science, …) without dragging in the
/// database, services, providers, or backend layers. Prefer this import when a
/// caller only needs the model classes so the dependency surface stays small.
library;

// Data models (domain models, distinct from DB entities)
// TrackingRate is re-exported from equipment_models.dart (canonical source: device_capabilities.dart)
export 'src/models/equipment/equipment_models.dart';
export 'src/models/equipment/unified_device.dart';
export 'src/models/equipment/discovery_state.dart';
export 'src/models/equipment_profile.dart';
export 'src/models/equipment_profile_validation.dart';
export 'src/models/settings/app_settings.dart';
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

// Sequence import — NINA / SGP sequences.
export 'src/models/import/canonical_sequence_node.dart';
export 'src/models/import/import_result.dart';

// Host mutation event surface.
export 'src/models/backend/host_mutation_event.dart';

// Per-target / per-run notes journal value type.
export 'src/models/notes/journal_note.dart';

// Frame-Failure Forensics (per-rejection cause classification).
export 'src/models/forensics/frame_forensics.dart';

// Replay Debug (retrospective decision-tree scrubber).
export 'src/models/replay_decision.dart';

// Comprehensive notification routing — per-event-type categories +
// per-transport configuration models.
export 'src/models/notification/notification_categories.dart';
export 'src/models/notification/transport_configs.dart';

// Calibration Library Manager (v46): unified browse / tag / auto-match models.
export 'src/models/calibration/calibration_library_models.dart';
