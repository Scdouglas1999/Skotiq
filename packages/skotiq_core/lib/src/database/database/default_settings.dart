part of '../database.dart';

/// Rows a fresh install starts with. An older database gains any that are
/// missing when it is opened.
final Map<String, String> _defaultSettings = {
  ...appSettingsInstallRows(),
  'science.advanced_mode.enabled': 'false',
  'science.overlay.enabled': 'true',
  'science.feature.photometry': 'true',
  'science.feature.photometric_calibration': 'true',
  'science.feature.transparency': 'true',
  'science.feature.psf_map': 'true',
  'science.feature.astrometric_residuals': 'true',
  'science.feature.moving_objects': 'false',
  'science.feature.narrowband_ratios': 'false',
  'science.feature.frame_quality_maps': 'true',
  'science.feature.surface3d': 'true',
  // Your Sky: fold every accepted, solved light into the personal sky atlas.
  // Off until the user turns it on: it keeps gigabytes of tiles on disk.
  'science.feature.sky_atlas': 'false',
  'science.retention.manual_purge_only': 'true',
  'science.photometry.differential_active': 'false',
  'science.photometry.target_anchor': '',
  'science.photometry.comparison_anchors': '[]',
  'science.overlay.opacity': '0.35',
  'science.overlay.live_grid_rows': '12',
  'science.overlay.live_grid_cols': '16',
  'science.overlay.analysis_grid_rows': '24',
  'science.overlay.analysis_grid_cols': '32',
  'dark_library.auto_subtract': 'false',
  'dark_library.temp_tolerance': '2.0',
  // Predictive autofocus defaults. See migration v31 + PredictiveAfService.
  'predictive_af.enabled': 'true',
  'predictive_af.min_samples_for_trust': '8',
  'predictive_af.high_confidence_threshold': '0.8',
  'predictive_af.low_confidence_threshold': '0.5',
  'predictive_af.drift_threshold_steps': '200',
  'predictive_af.drift_runs_before_warn': '5',
  // v40 Multi-Night & Forecast Planning: the currently-selected planning
  // project. Stored out-of-band in app_settings (rather than a column on
  // `projects`) so the active selection survives even when no projects exist.
  // Empty string = no active project; otherwise the stringified projects.id.
  // Seeded via INSERT ... ON CONFLICT DO NOTHING by _ensureDefaultSettings().
  'planning.active_project_id': '',
};

/// Keys that were seeded by an earlier build and no longer have an owner.
///
/// A retired key is worse than a missing one: nothing writes it, so it keeps
/// its stale seed value forever — while `BackupService._exportSettings` dumps
/// the whole `app_settings` table into every `.skbackup`, and the settings
/// snapshot serves it. Deleting the row on open stops an already-created
/// profile from carrying a retired key's value forward.
const Set<String> _retiredSettingKeys = {
  // Removed 2026-08: duplicated `autosave.sequence_enabled` with no UI, no
  // reader, and the opposite default.
  'auto_save_sequences',
  // Removed 2026-08: whether the cooler runs on connect is a PER-PROFILE
  // decision (`equipment_profiles.cool_on_connect`, asked in the onboarding
  // wizard and in Equipment > Edit Profile > Camera Defaults). This key had
  // no UI, no setter caller and no reader that acted on it, yet it shipped
  // seeded 'On Connect' — so every settings snapshot, .skbackup and
  // /api/settings payload announced automatic cooling that nothing performed.
  'cooling_behavior',
  // Removed 2026-08: simulation mode is installed natively (debug builds
  // only); the persisted toggle had no effect in any shippable configuration
  // and its plumbing is gone.
  'use_simulation_mode',
  // Removed 2026-10: a failed autofocus never parks the rig or ends the run
  // (owner decision 2026-10-06), so there is no failure action left to choose.
  // The seeded default was 'AbortAndPark'; the native engine no longer reads
  // the field, and a stored row would only keep exporting a choice that does
  // nothing.
  'af_failure_action',
};

/// Set once a profile has been through the rule that made Your Sky opt-in.
const String skyAtlasOptInMigratedKey = 'science.sky_atlas.opt_in_migrated';

/// "pending" while the one-time "Your sky is now off" notice is owed to the
/// user; "shown" once they have answered it.
const String skyAtlasOffNoticeKey = 'science.sky_atlas.off_notice';
