/// Skotiq Core - database barrel.
///
/// Re-exports the drift database, its DAOs, the entity-name alias typedefs, and
/// the integrity-check / seed-data helpers. Prefer this import in code that
/// reads or writes persisted rows directly, so it does not also pull in the
/// service and provider layers.
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
export 'src/database/daos/integrated_masters_dao.dart';
export 'src/database/daos/flat_library_dao.dart';
// Smart Morning Report (v42): Night Doctor report persistence.
export 'src/database/daos/night_reports_dao.dart';
// Durable multi-night campaign counter (Phase B, v43).
export 'src/database/daos/campaigns_dao.dart';
// Narrowband palette composites (Phase C, v44).
export 'src/database/daos/narrowband_composites_dao.dart';
// Durable mosaic projects + panels (Mosaic M2, v45).
export 'src/database/daos/mosaic_projects_dao.dart';
export 'src/database/daos/mosaic_panels_dao.dart';
export 'src/database/daos/calibration_tags_dao.dart';
