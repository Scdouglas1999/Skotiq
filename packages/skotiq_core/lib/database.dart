/// The drift database of skotiq_core: tables, row classes, DAOs, integrity and recovery.
///
/// Exports only files under `src/database/`.
library;

export 'src/database/database.dart';
export 'src/database/integrity_check.dart';
export 'src/database/recovery/crash_recovery.dart';
export 'src/database/integration_stage_marker.dart';
export 'src/database/session_orphan_sweep.dart';
export 'src/database/single_instance_lock.dart';
export 'src/database/sqlite_busy.dart';
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
export 'src/database/daos/polar_alignment_history_dao.dart';
export 'src/database/daos/science_dao.dart';
export 'src/database/daos/dark_library_dao.dart';
// Stack-and-Share Loop (component C3): persisted stacked-result provenance.
export 'src/database/daos/stacked_results_dao.dart';
export 'src/database/daos/observation_logs_dao.dart';
export 'src/database/daos/observing_lists_dao.dart';
export 'src/database/daos/sequence_runs_dao.dart';
export 'src/database/daos/integrated_masters_dao.dart';
export 'src/database/daos/flat_library_dao.dart';
// Living Sky (Wave 3): per-pillar retention/prune bookkeeping.
export 'src/database/daos/living_sky_retention_dao.dart';
export 'src/database/tables/living_sky_retention.dart'
    show LivingSkyRetentionScope;
// Pillar A ("Your Sky"): personal sky-atlas persistence + tables + service.
export 'src/database/daos/sky_atlas_dao.dart';
export 'src/database/tables/sky_atlas_tables.dart' show skyAtlasHealpixOrder;
// Pillar C ("Constellation"): community hub client + orchestration + providers.
export 'src/database/daos/constellation_contributions_dao.dart';
// Shared trust primitives, co-imaging session membership, and the
// provenance/consent/scoped-role model.
export 'src/database/daos/coimaging_sessions_dao.dart';
// Pillar B ("First Light"): difference-imaging transient log + scan service +
// report export.
export 'src/database/daos/transient_detections_dao.dart';
// Smart Morning Report (v42): Night Doctor report persistence.
export 'src/database/daos/night_reports_dao.dart';
// Durable multi-night campaign counter (Phase B, v43).
export 'src/database/daos/campaigns_dao.dart';
// Narrowband palette composites (Phase C, v44).
export 'src/database/daos/narrowband_composites_dao.dart';
// Durable mosaic projects + panels (Mosaic M2, v45).
export 'src/database/daos/mosaic_projects_dao.dart';
export 'src/database/daos/mosaic_panels_dao.dart';
export 'src/database/daos/recipes_dao.dart';
export 'src/database/daos/darkroom_jobs_dao.dart';
export 'src/database/daos/delivery_targets_dao.dart';
export 'src/database/daos/delivery_journal_dao.dart';
export 'src/database/daos/calibration_tags_dao.dart';
export 'src/database/database_health_check.dart';
export 'src/database/integrity_findings.dart';
