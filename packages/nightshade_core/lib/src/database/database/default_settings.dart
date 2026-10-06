part of '../database.dart';

const Map<String, String> _defaultSettings = {
  'theme': 'dark',
  'language': 'en',
  'accent_color': kDefaultAccentColorHex,
  'font_size': 'Medium',
  'ui_scale': 'Auto',
  'sidebar_collapsed': 'true',
  'start_minimized': 'false',
  'auto_connect_equipment': 'true',
  'confirm_before_closing': 'true',
  'auto_discover_on_launch': 'true',
  'observer_latitude': '0.0',
  'observer_longitude': '0.0',
  'observer_elevation': '0.0',
  'timezone': 'UTC',
  'use_system_time': 'true',
  'image_format': 'FITS',
  'file_naming_pattern': r'$TARGET_$FILTER_$DATE_$SEQ',
  'bit_depth': '16-bit',
  // Projection of the native PlateSolverPreference, whose own default is
  // Auto. Seeding 'ASTAP' here made every fresh profile's exported value
  // disagree with the Plate Solving page from the very first launch.
  'plate_solver': 'Auto',
  'astap_path': '',
  'astrometry_path': '',
  'plate_solve_timeout': '60',
  'plate_solve_search_radius': '30.0',
  'blind_solve': 'false',
  'centering_sync_mount': 'true',
  'phd2_path': '',
  'phd2_host': 'localhost',
  'phd2_port': '4400',
  'notifications_enabled': 'true',
  'discord_webhook': '',
  'pushover_key': '',
  'pushover_user': '',
  'notify_on_sequence_complete': 'true',
  'notify_on_error': 'true',
  'notify_on_meridian_flip': 'false',
  'sound_enabled': 'true',
  'default_image_directory': '',
  'image_output_path': '',
  'sequences_path': '',
  'database_path': '',
  'logs_path': '',
  'indi_server_host': 'localhost',
  'indi_server_port': '7624',
  'indi_auto_connect': 'false',
  'alpaca_server_host': 'localhost',
  'alpaca_server_port': '11111',
  'alpaca_auto_discover': 'false',
  'web_server_enabled': 'false',
  'web_server_port': '8080',
  'default_gain': '100',
  'default_offset': '50',
  'enable_meridian_flip': 'true',
  'temp_compensation': 'false',
  'temp_coefficient': '-12.0',
  'backlash_compensation': '0',
  'dither_scale': 'Medium',
  'settle_threshold': '1.5',
  'settle_timeout': '60',
  'settle_time': '10',
  'dither_ra_only': 'false',
  'park_on_unsafe_weather': 'true',
  'park_before_dawn': 'true',
  'meridian_flip_minutes': '5',
  'auto_focus_on_filter_change': 'false',
  'use_filter_focus_offsets': 'true',
  'auto_focus_every_minutes': '60',
  'dither_enabled': 'true',
  'dither_every_frames': '3',
  'safety_fail_mode': 'failClosed',
  'af_method': 'Star HFR',
  'af_curve_fitting': 'Hyperbolic',
  'af_step_size': '50',
  'af_exposure_time': '4.0',
  'af_initial_offset_steps': '4',
  // Two sweeps, not one: a single failed sweep is weak evidence (a passing
  // cloud, a gust, a sparse field), so a second sweep runs before the
  // operator is told autofocus failed.
  'af_number_of_attempts': '2',
  // Star selection on: the brightest 10 stars. Counting every detection read
  // the owner's in-focus frame of 2026-09-14 at 13.8 px instead of 3.2 px
  // (owner decision 2026-10-06).
  'af_use_brightest_n_stars': '10',
  'af_outer_crop_ratio': '1.0',
  'af_inner_crop_ratio': '0.0',
  'af_binning': '1',
  'af_r_squared_threshold': '0.7',
  'af_failure_hfr_tolerance_ratio': '1.6',
  'af_disable_guiding': 'false',
  'af_focuser_settle_time_ms': '500',
  'af_exposures_per_point': '1',
  'af_backlash_comp_method': 'Overshoot',
  'af_backlash_in': '0',
  // ask | never
  'focuser_backlash_offer_mode': 'ask',
  // ask | computerToMount | mountToComputer | never
  'mount_site_sync_mode': 'ask',
  'af_backlash_out': '0',
  'af_autofocus_filter_name': '',
  'af_filter_settings': '{}',
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
/// the whole `app_settings` table into every `.nsbackup`, and the settings
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
  // seeded 'On Connect' — so every settings snapshot, .nsbackup and
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
