part of '../settings_provider.dart';

extension _AppSettingsPartialPersistenceMapping on AppSettingsNotifier {
  /// The set of database setting keys that the remote wire model
  /// (`models.AppSettings`) can actually round-trip. Built from the fields
  /// mapped in `_toRemoteSettings` / `_fromRemoteSettings`. Anything NOT in
  /// here is dropped on the floor by a remote save, so writing it is refused
  /// rather than letting a phone silently fail to persist an
  /// unattended-night knob.
  ///
  /// Absent by design, so a remote write to them fails loud via
  /// [_assertKeysRemotable]: host-machine-local desktop-shell prefs
  /// (`start_minimized`, `sidebar_collapsed`, `confirm_before_closing`),
  /// host-filesystem infra paths whose remote edit is restart-affecting
  /// (`database_path`, `logs_path`), and the 8-point horizon-mask blob
  /// `horizon_profile_json` (the scalar `effective_horizon_deg` floor IS
  /// remoted). Weather threshold values live in a separate `WeatherSettings`
  /// model with its own endpoint and are not part of this allow-set.
  ///
  /// Keep this in lock-step with `_toRemoteSettings`. A key added to the wire
  /// model must be added here, or remote saves of it will throw.
  static const Set<String> _remotableSettingKeys = {
    // Appearance / general
    'theme',
    'language',
    'auto_connect_equipment',
    'auto_discover_on_launch',
    'accent_color',
    'font_size',
    'ui_scale',
    // Location
    'observer_latitude',
    'observer_longitude',
    'observer_elevation',
    // Imaging / sequencer basics
    'file_naming_pattern',
    'meridian_flip_minutes',
    'auto_focus_every_minutes',
    'dither_every_frames',
    'safety_fail_mode',
    'camera_retries',
    'filter_wheel_retries',
    // Plate solving
    'plate_solve_timeout',
    'plate_solve_search_radius',
    'astap_path',
    // Notifications
    'discord_webhook',
    'pushover_key',
    'pushover_user',
    // Protocol
    'indi_server_host',
    'indi_server_port',
    'indi_auto_connect',
    'alpaca_server_host',
    'alpaca_server_port',
    'alpaca_auto_discover',
    // Sequencer execution / output
    'image_output_path',
    // Image Grading
    'image_grading_enabled',
    'image_grading_hfr_threshold_px',
    'image_grading_hfr_baseline_percent',
    'image_grading_eccentricity_threshold',
    'image_grading_star_count_min',
    'image_grading_max_consecutive_rejects',
    'image_grading_reject_folder_path',
    // Sky-brightness adaptive exposure
    'adaptive_exposure_enabled',
    'adaptive_exposure_target_snr',
    'adaptive_exposure_reference_mag',
    'adaptive_exposure_min_secs',
    'adaptive_exposure_max_secs',
    'adaptive_exposure_per_filter_enabled',
    'adaptive_exposure_per_filter_min_secs',
    'adaptive_exposure_per_filter_max_secs',
    // Autofocus / dither / weather-safety / recovery.
    'park_on_unsafe_weather',
    'auto_focus_on_filter_change',
    'af_disable_guiding',
    'dither_enabled',
    'dither_scale',
    'recovery_default_retry_interval_mins',
    'recovery_default_max_duration_mins',
    'recovery_stop_tracking_during_recovery',
    'recovery_abort_on_meridian',
    'recovery_audible_alert_when_entered',
    // Weather-safety / dawn.
    'park_before_dawn',
    'stop_run_on_quality_problems',
    // Meridian flip detail.
    'enable_meridian_flip',
    // Focuser temp-comp + backlash (calibration).
    'temp_compensation',
    'temp_coefficient',
    'backlash_compensation',
    'focuser_backlash_calibration_settings',
    // Guider settle (calibration).
    'settle_threshold',
    'settle_timeout',
    'settle_time',
    'dither_ra_only',
    // Plate-solving extra.
    'plate_solver',
    'blind_solve',
    'centering_sync_mount',
    // Site / horizon.
    'bortle_class',
    'effective_horizon_deg',
    // Pre-flight.
    'preflight_strictness',
    'polar_alignment_max_age_days',
    'optical_train_drift_threshold',
    // Dark library.
    'dark_library_min_coverage',
    // Smart Night defaults.
    'smart_night_max_session_hours',
    'smart_night_default_af_cadence_frames',
    'smart_night_default_integration_budget_mins_per_target',
    'smart_night_include_flats_at_end',
    'smart_night_use_scheduler_for_multi_target',
    'smart_night_scheduler_target_threshold',
    'smart_night_default_strategy',
    'smart_night_polar_alignment_stale_after_days',
    'smart_night_sub_exposure_floor_secs',
    'smart_night_sub_exposure_ceiling_secs',
    'smart_night_target_snr',
    // Equipment defaults (camera).
    'default_gain',
    'default_offset',
    // Remote access / web server.
    'web_server_enabled',
    'web_server_port',
    // PHD2 connection.
    'phd2_path',
    'phd2_host',
    'phd2_port',
    // Notification toggles.
    'notifications_enabled',
    'notify_on_sequence_complete',
    'notify_on_error',
    'notify_on_meridian_flip',
    'sound_enabled',
    'audible_alerts_on_critical',
    'critical_alert_sound',
    'push_critical_alerts',
    // Session-lifecycle + campaign-rollup prefs.
    'notes.prompt_after_run',
    'session.handoff_auto_prompt',
    'campaign_rollup.surface_targets_tab',
    'campaign_rollup.grouping_mode',
    // Autofocus detailed sweep params.
    'af_method',
    'af_curve_fitting',
    'af_step_size',
    'af_exposure_time',
    'af_initial_offset_steps',
    'af_number_of_attempts',
    'af_use_brightest_n_stars',
    'af_outer_crop_ratio',
    'af_inner_crop_ratio',
    'af_binning',
    'af_r_squared_threshold',
    'af_failure_hfr_tolerance_ratio',
    'af_focuser_settle_time_ms',
    'af_exposures_per_point',
    'af_backlash_comp_method',
    'af_backlash_in',
    'af_backlash_out',
    'af_autofocus_filter_name',
    'af_filter_settings',
    'use_filter_focus_offsets',
    // Misc FITS / imaging / plate-solve config.
    'astrometry_path',
    'observer_name',
    'image_format',
    'bit_depth',
    'timezone',
    'use_system_time',
    // Sequencer output path default.
    'sequences_path',
    // Smart Night target auto-select.
    'smart_night.auto_select',
    'smart_night.auto_select_count',
    // Adaptive sky-conditions target-swap scheduler-seed defaults.
    'adaptive_swap.enabled_by_default',
    'adaptive_swap.default_threshold',
    'adaptive_swap.default_hysteresis_secs',
    'adaptive_swap.score_weights',
  };

  /// FAIL-LOUD guard for the remote-write path. Throws an [UnsupportedError]
  /// naming the offending key(s) when a caller tries to persist a setting the
  /// wire model can't carry. Callers on the local (FFI / Drift) path never
  /// invoke this — every DB key is persistable locally.
  ///
  /// Swallowing the write here would leave a user toggling (say) "park on
  /// unsafe weather" from their phone believing it stuck when it never reaches
  /// the host, so the write throws instead.
  void _assertKeysRemotable(Iterable<String> keys) {
    final unsupported = keys
        .where((k) => !_remotableSettingKeys.contains(k))
        .toList();
    if (unsupported.isNotEmpty) {
      throw UnsupportedError(
        'Cannot persist setting${unsupported.length == 1 ? '' : 's'} over a '
        'remote/network backend: '
        '${unsupported.join(', ')}. These keys are not carried by the '
        'remote settings wire model, so the write would be silently '
        'dropped by the host. Extend models.AppSettings + _toRemoteSettings '
        '(and _remotableSettingKeys) to remote them.',
      );
    }
  }

  /// Apply a DB-keyed partial settings patch onto [current] in-memory state.
  ///
  /// This helper is the remote-write applier: its only callers are
  /// `_saveSetting` / `_saveSettings` inside the `NetworkBackend` branch of
  /// [AppSettingsNotifier]. Because a remote write that names a key the wire
  /// model can't carry would be silently lost on the host, we FAIL LOUD up
  /// front via [_assertKeysRemotable] instead of mapping the key into state
  /// and pretending it persisted. (Local/Drift writes go straight to the DAO
  /// and never reach this method, so the guard never fires for them.)
  AppSettingsState _applySettingsMap(
    AppSettingsState current,
    Map<String, String> settings,
  ) {
    _assertKeysRemotable(settings.keys);
    return current.copyWith(
      startMinimized: settings.containsKey('start_minimized')
          ? _parseBool(settings['start_minimized'], current.startMinimized)
          : null,
      autoConnectEquipment: settings.containsKey('auto_connect_equipment')
          ? _parseBool(
              settings['auto_connect_equipment'],
              current.autoConnectEquipment,
            )
          : null,
      confirmBeforeClosing: settings.containsKey('confirm_before_closing')
          ? _parseBool(
              settings['confirm_before_closing'],
              current.confirmBeforeClosing,
            )
          : null,
      autoDiscoverOnLaunch: settings.containsKey('auto_discover_on_launch')
          ? _parseBool(
              settings['auto_discover_on_launch'],
              current.autoDiscoverOnLaunch,
            )
          : null,
      theme: settings['theme'],
      language: settings['language'],
      accentColor: settings['accent_color'],
      fontSize: settings['font_size'],
      // ui_scale is carried by the remote wire model, so the partial applier
      // must map it too — otherwise a remote save of the UI scale passes the
      // remotable-key guard but never reaches `_toRemoteSettings`.
      uiScale: settings['ui_scale'],
      sidebarCollapsed: settings.containsKey('sidebar_collapsed')
          ? _parseBool(settings['sidebar_collapsed'], current.sidebarCollapsed)
          : null,
      latitude: settings.containsKey('observer_latitude')
          ? _parseDouble(settings['observer_latitude'], current.latitude)
          : null,
      longitude: settings.containsKey('observer_longitude')
          ? _parseDouble(settings['observer_longitude'], current.longitude)
          : null,
      elevation: settings.containsKey('observer_elevation')
          ? _parseDouble(settings['observer_elevation'], current.elevation)
          : null,
      timezone: settings['timezone'],
      useSystemTime: settings.containsKey('use_system_time')
          ? _parseBool(settings['use_system_time'], current.useSystemTime)
          : null,
      imageFormat: settings['image_format'],
      fileNamingPattern: settings['file_naming_pattern'],
      bitDepth: settings['bit_depth'],
      parkOnUnsafeWeather: settings.containsKey('park_on_unsafe_weather')
          ? _parseBool(
              settings['park_on_unsafe_weather'],
              current.parkOnUnsafeWeather,
            )
          : null,
      parkBeforeDawn: settings.containsKey('park_before_dawn')
          ? _parseBool(settings['park_before_dawn'], current.parkBeforeDawn)
          : null,
      stopRunOnQualityProblems:
          settings.containsKey('stop_run_on_quality_problems')
          ? _parseBool(
              settings['stop_run_on_quality_problems'],
              current.stopRunOnQualityProblems,
            )
          : null,
      meridianFlipMinutes: settings.containsKey('meridian_flip_minutes')
          ? _parseInt(
              settings['meridian_flip_minutes'],
              current.meridianFlipMinutes,
            )
          : null,
      autoFocusOnFilterChange:
          settings.containsKey('auto_focus_on_filter_change')
          ? _parseBool(
              settings['auto_focus_on_filter_change'],
              current.autoFocusOnFilterChange,
            )
          : null,
      useFilterFocusOffsets: settings.containsKey('use_filter_focus_offsets')
          ? _parseBool(
              settings['use_filter_focus_offsets'],
              current.useFilterFocusOffsets,
            )
          : null,
      autoFocusEveryMinutes: settings.containsKey('auto_focus_every_minutes')
          ? _parseInt(
              settings['auto_focus_every_minutes'],
              current.autoFocusEveryMinutes,
            )
          : null,
      ditherEnabled: settings.containsKey('dither_enabled')
          ? _parseBool(settings['dither_enabled'], current.ditherEnabled)
          : null,
      ditherEveryFrames: settings.containsKey('dither_every_frames')
          ? _parseInt(
              settings['dither_every_frames'],
              current.ditherEveryFrames,
            )
          : null,
      safetyFailMode: settings.containsKey('safety_fail_mode')
          ? _parseSafetyFailMode(settings['safety_fail_mode'])
          : null,
      cameraRetries: settings.containsKey('camera_retries')
          ? _parseDeviceRetries(
              settings['camera_retries'],
              current.cameraRetries,
            )
          : null,
      filterWheelRetries: settings.containsKey('filter_wheel_retries')
          ? _parseDeviceRetries(
              settings['filter_wheel_retries'],
              current.filterWheelRetries,
            )
          : null,
      plateSolver: settings['plate_solver'],
      astapPath: settings['astap_path'],
      astrometryPath: settings['astrometry_path'],
      plateSolveTimeout: settings.containsKey('plate_solve_timeout')
          ? _parseInt(
              settings['plate_solve_timeout'],
              current.plateSolveTimeout,
            )
          : null,
      plateSolveSearchRadius: settings.containsKey('plate_solve_search_radius')
          ? _parseDouble(
              settings['plate_solve_search_radius'],
              current.plateSolveSearchRadius,
            )
          : null,
      blindSolve: settings.containsKey('blind_solve')
          ? _parseBool(settings['blind_solve'], current.blindSolve)
          : null,
      centeringSyncMount: settings.containsKey('centering_sync_mount')
          ? _parseBool(
              settings['centering_sync_mount'],
              current.centeringSyncMount,
            )
          : null,
      phd2Path: settings['phd2_path'],
      phd2Host: settings['phd2_host'],
      phd2Port: settings.containsKey('phd2_port')
          ? _parseInt(settings['phd2_port'], current.phd2Port)
          : null,
      notificationsEnabled: settings.containsKey('notifications_enabled')
          ? _parseBool(
              settings['notifications_enabled'],
              current.notificationsEnabled,
            )
          : null,
      discordWebhook: settings['discord_webhook'],
      pushoverKey: settings['pushover_key'],
      pushoverUser: settings['pushover_user'],
      notifyOnSequenceComplete:
          settings.containsKey('notify_on_sequence_complete')
          ? _parseBool(
              settings['notify_on_sequence_complete'],
              current.notifyOnSequenceComplete,
            )
          : null,
      notifyOnError: settings.containsKey('notify_on_error')
          ? _parseBool(settings['notify_on_error'], current.notifyOnError)
          : null,
      notifyOnMeridianFlip: settings.containsKey('notify_on_meridian_flip')
          ? _parseBool(
              settings['notify_on_meridian_flip'],
              current.notifyOnMeridianFlip,
            )
          : null,
      soundEnabled: settings.containsKey('sound_enabled')
          ? _parseBool(settings['sound_enabled'], current.soundEnabled)
          : null,
      imageOutputPath: settings['image_output_path'],
      sequencesPath: settings['sequences_path'],
      databasePath: settings['database_path'],
      logsPath: settings['logs_path'],
      indiServerHost: settings['indi_server_host'],
      indiServerPort: settings.containsKey('indi_server_port')
          ? _parseInt(settings['indi_server_port'], current.indiServerPort)
          : null,
      indiAutoConnect: settings.containsKey('indi_auto_connect')
          ? _parseBool(settings['indi_auto_connect'], current.indiAutoConnect)
          : null,
      alpacaServerHost: settings['alpaca_server_host'],
      alpacaServerPort: settings.containsKey('alpaca_server_port')
          ? _parseInt(settings['alpaca_server_port'], current.alpacaServerPort)
          : null,
      alpacaAutoDiscover: settings.containsKey('alpaca_auto_discover')
          ? _parseBool(
              settings['alpaca_auto_discover'],
              current.alpacaAutoDiscover,
            )
          : null,
      webServerEnabled: settings.containsKey('web_server_enabled')
          ? _parseBool(settings['web_server_enabled'], current.webServerEnabled)
          : null,
      webServerPort: settings.containsKey('web_server_port')
          ? _parseInt(settings['web_server_port'], current.webServerPort)
          : null,
      defaultGain: settings.containsKey('default_gain')
          ? _parseInt(settings['default_gain'], current.defaultGain)
          : null,
      defaultOffset: settings.containsKey('default_offset')
          ? _parseInt(settings['default_offset'], current.defaultOffset)
          : null,
      enableMeridianFlip: settings.containsKey('enable_meridian_flip')
          ? _parseBool(
              settings['enable_meridian_flip'],
              current.enableMeridianFlip,
            )
          : null,
      tempCompensation: settings.containsKey('temp_compensation')
          ? _parseBool(settings['temp_compensation'], current.tempCompensation)
          : null,
      tempCoefficient: settings.containsKey('temp_coefficient')
          ? _parseDouble(settings['temp_coefficient'], current.tempCoefficient)
          : null,
      backlashCompensation: settings.containsKey('backlash_compensation')
          ? _parseInt(
              settings['backlash_compensation'],
              current.backlashCompensation,
            )
          : null,
      ditherScale: settings['dither_scale'],
      settleThreshold: settings.containsKey('settle_threshold')
          ? _parseDouble(settings['settle_threshold'], current.settleThreshold)
          : null,
      settleTimeout: settings.containsKey('settle_timeout')
          ? _parseInt(settings['settle_timeout'], current.settleTimeout)
          : null,
      settleTime: settings.containsKey('settle_time')
          ? _parseInt(settings['settle_time'], current.settleTime)
          : null,
      ditherRaOnly: settings.containsKey('dither_ra_only')
          ? _parseBool(settings['dither_ra_only'], current.ditherRaOnly)
          : null,
      bortleClass: settings.containsKey('bortle_class')
          ? _parseInt(settings['bortle_class'], current.bortleClass)
          : null,
      horizonProfileJson: settings['horizon_profile_json'],
      effectiveHorizonDeg: settings.containsKey('effective_horizon_deg')
          ? _parseDouble(
              settings['effective_horizon_deg'],
              current.effectiveHorizonDeg,
            )
          : null,
      audibleAlertsOnCritical:
          settings.containsKey('audible_alerts_on_critical')
          ? _parseBool(
              settings['audible_alerts_on_critical'],
              current.audibleAlertsOnCritical,
            )
          : null,
      criticalAlertSound: settings.containsKey('critical_alert_sound')
          ? _normaliseCriticalAlertSound(settings['critical_alert_sound'])
          : null,
      pushCriticalAlerts: settings.containsKey('push_critical_alerts')
          ? _parseBool(
              settings['push_critical_alerts'],
              current.pushCriticalAlerts,
            )
          : null,
      // Recovery Mode — partial-update path. Each key is only
      // honoured if present in the patch, mirroring the rest of this
      // helper.
      recoveryDefaultRetryIntervalMins:
          settings.containsKey('recovery_default_retry_interval_mins')
          ? _parseDouble(
              settings['recovery_default_retry_interval_mins'],
              current.recoveryDefaultRetryIntervalMins,
            )
          : null,
      recoveryDefaultMaxDurationMins:
          settings.containsKey('recovery_default_max_duration_mins')
          ? _parseDouble(
              settings['recovery_default_max_duration_mins'],
              current.recoveryDefaultMaxDurationMins,
            )
          : null,
      recoveryStopTrackingDuringRecovery:
          settings.containsKey('recovery_stop_tracking_during_recovery')
          ? _parseBool(
              settings['recovery_stop_tracking_during_recovery'],
              current.recoveryStopTrackingDuringRecovery,
            )
          : null,
      recoveryAbortOnMeridian:
          settings.containsKey('recovery_abort_on_meridian')
          ? _parseBool(
              settings['recovery_abort_on_meridian'],
              current.recoveryAbortOnMeridian,
            )
          : null,
      recoveryAudibleAlertWhenEntered:
          settings.containsKey('recovery_audible_alert_when_entered')
          ? _parseBool(
              settings['recovery_audible_alert_when_entered'],
              current.recoveryAudibleAlertWhenEntered,
            )
          : null,
      afMethod: settings['af_method'],
      afCurveFitting: settings['af_curve_fitting'],
      afStepSize: settings.containsKey('af_step_size')
          ? _parseInt(settings['af_step_size'], current.afStepSize)
          : null,
      afExposureTime: settings.containsKey('af_exposure_time')
          ? _parseDouble(settings['af_exposure_time'], current.afExposureTime)
          : null,
      afInitialOffsetSteps: settings.containsKey('af_initial_offset_steps')
          ? _parseInt(
              settings['af_initial_offset_steps'],
              current.afInitialOffsetSteps,
            )
          : null,
      afNumberOfAttempts: settings.containsKey('af_number_of_attempts')
          ? _parseInt(
              settings['af_number_of_attempts'],
              current.afNumberOfAttempts,
            )
          : null,
      afUseBrightestNStars: settings.containsKey('af_use_brightest_n_stars')
          ? _parseInt(
              settings['af_use_brightest_n_stars'],
              current.afUseBrightestNStars,
            )
          : null,
      afOuterCropRatio: settings.containsKey('af_outer_crop_ratio')
          ? _parseDouble(
              settings['af_outer_crop_ratio'],
              current.afOuterCropRatio,
            )
          : null,
      afInnerCropRatio: settings.containsKey('af_inner_crop_ratio')
          ? _parseDouble(
              settings['af_inner_crop_ratio'],
              current.afInnerCropRatio,
            )
          : null,
      afBinning: settings.containsKey('af_binning')
          ? _parseInt(settings['af_binning'], current.afBinning)
          : null,
      afRSquaredThreshold: settings.containsKey('af_r_squared_threshold')
          ? _parseDouble(
              settings['af_r_squared_threshold'],
              current.afRSquaredThreshold,
            )
          : null,
      afFailureHfrToleranceRatio:
          settings.containsKey('af_failure_hfr_tolerance_ratio')
          ? _parseDouble(
              settings['af_failure_hfr_tolerance_ratio'],
              current.afFailureHfrToleranceRatio,
            )
          : null,
      // Canonical key is `af_disable_guiding` — matches the setter in
      // autofocus.dart, the default-settings seed, and the stored-snapshot
      // loader. Any other spelling matches nothing on disk and the toggle
      // silently no-ops, remote writes included: they route through here too.
      afDisableGuidingDuringAf: settings.containsKey('af_disable_guiding')
          ? _parseBool(
              settings['af_disable_guiding'],
              current.afDisableGuidingDuringAf,
            )
          : null,
      afFocuserSettleTimeMs: settings.containsKey('af_focuser_settle_time_ms')
          ? _parseInt(
              settings['af_focuser_settle_time_ms'],
              current.afFocuserSettleTimeMs,
            )
          : null,
      afExposuresPerPoint: settings.containsKey('af_exposures_per_point')
          ? _parseInt(
              settings['af_exposures_per_point'],
              current.afExposuresPerPoint,
            )
          : null,
      afBacklashCompMethod: settings['af_backlash_comp_method'],
      afBacklashIn: settings.containsKey('af_backlash_in')
          ? _parseInt(settings['af_backlash_in'], current.afBacklashIn)
          : null,
      afBacklashOut: settings.containsKey('af_backlash_out')
          ? _parseInt(settings['af_backlash_out'], current.afBacklashOut)
          : null,
      afAutofocusFilterName: settings['af_autofocus_filter_name'],
      afFilterSettingsJson: settings['af_filter_settings'],
      focuserBacklashCalibrationJson:
          settings['focuser_backlash_calibration_settings'],
      // Observer name (FITS OBSERVER).
      observerName: settings['observer_name'],
      // Image Grading. Nullable double / int fields use
      // the `_unset` sentinel for "no change"; an explicit "null" string
      // clears the field.
      enableImageGrading: settings.containsKey('image_grading_enabled')
          ? _parseBool(
              settings['image_grading_enabled'],
              current.enableImageGrading,
            )
          : null,
      imageGradingHfrThresholdPx:
          settings.containsKey('image_grading_hfr_threshold_px')
          ? _parseNullableDouble(
              settings['image_grading_hfr_threshold_px'],
              current.imageGradingHfrThresholdPx,
            )
          : _unset,
      imageGradingHfrBaselinePercent:
          settings.containsKey('image_grading_hfr_baseline_percent')
          ? _parseNullableDouble(
              settings['image_grading_hfr_baseline_percent'],
              current.imageGradingHfrBaselinePercent,
            )
          : _unset,
      imageGradingEccentricityThreshold:
          settings.containsKey('image_grading_eccentricity_threshold')
          ? _parseNullableDouble(
              settings['image_grading_eccentricity_threshold'],
              current.imageGradingEccentricityThreshold,
            )
          : _unset,
      imageGradingStarCountMin:
          settings.containsKey('image_grading_star_count_min')
          ? _parseNullableInt(
              settings['image_grading_star_count_min'],
              current.imageGradingStarCountMin,
            )
          : _unset,
      imageGradingMaxConsecutiveRejects:
          settings.containsKey('image_grading_max_consecutive_rejects')
          ? _parseInt(
              settings['image_grading_max_consecutive_rejects'],
              current.imageGradingMaxConsecutiveRejects,
            )
          : null,
      imageGradingRejectFolderPath:
          settings.containsKey('image_grading_reject_folder_path')
          ? (settings['image_grading_reject_folder_path']?.isEmpty ?? true
                ? null
                : settings['image_grading_reject_folder_path'])
          : _unset,
      // Sky-brightness adaptive exposure partial-update
      // wire-up. Required so a remote save of an adaptive-exposure knob
      // (which is carried by the wire model) actually reaches state and is
      // then forwarded to the host by `_toRemoteSettings`.
      adaptiveExposureEnabled: settings.containsKey('adaptive_exposure_enabled')
          ? _parseBool(
              settings['adaptive_exposure_enabled'],
              current.adaptiveExposureEnabled,
            )
          : null,
      adaptiveExposureTargetSnr:
          settings.containsKey('adaptive_exposure_target_snr')
          ? _parseDouble(
              settings['adaptive_exposure_target_snr'],
              current.adaptiveExposureTargetSnr,
            )
          : null,
      adaptiveExposureReferenceMag:
          settings.containsKey('adaptive_exposure_reference_mag')
          ? _parseDouble(
              settings['adaptive_exposure_reference_mag'],
              current.adaptiveExposureReferenceMag,
            )
          : null,
      adaptiveExposureMinSecs:
          settings.containsKey('adaptive_exposure_min_secs')
          ? _parseDouble(
              settings['adaptive_exposure_min_secs'],
              current.adaptiveExposureMinSecs,
            )
          : null,
      adaptiveExposureMaxSecs:
          settings.containsKey('adaptive_exposure_max_secs')
          ? _parseDouble(
              settings['adaptive_exposure_max_secs'],
              current.adaptiveExposureMaxSecs,
            )
          : null,
      adaptiveExposurePerFilterEnabled:
          settings.containsKey('adaptive_exposure_per_filter_enabled')
          ? _parseFilterBoolMap(
              settings['adaptive_exposure_per_filter_enabled'],
            )
          : null,
      adaptiveExposurePerFilterMinSecs:
          settings.containsKey('adaptive_exposure_per_filter_min_secs')
          ? _parseFilterDoubleMap(
              settings['adaptive_exposure_per_filter_min_secs'],
            )
          : null,
      adaptiveExposurePerFilterMaxSecs:
          settings.containsKey('adaptive_exposure_per_filter_max_secs')
          ? _parseFilterDoubleMap(
              settings['adaptive_exposure_per_filter_max_secs'],
            )
          : null,
      // Pre-flight partial-update wire-up.
      preflightStrictness: settings.containsKey('preflight_strictness')
          ? _parsePreflightStrictness(settings['preflight_strictness'])
          : null,
      polarAlignmentMaxAgeDays:
          settings.containsKey('polar_alignment_max_age_days')
          ? _parseInt(
              settings['polar_alignment_max_age_days'],
              current.polarAlignmentMaxAgeDays,
            )
          : null,
      darkLibraryMinCoverage: settings.containsKey('dark_library_min_coverage')
          ? _parseInt(
              settings['dark_library_min_coverage'],
              current.darkLibraryMinCoverage,
            )
          : null,
      opticalTrainDriftThreshold:
          settings.containsKey('optical_train_drift_threshold')
          ? _parseDouble(
              settings['optical_train_drift_threshold'],
              current.opticalTrainDriftThreshold,
            )
          : null,
      // Smart Night partial-update wiring. The nullable
      // session-hours knob uses the `_unset` sentinel so a patch can
      // either leave it alone (omit the key) or clear it back to
      // "use full dark window" (pass the literal string "null").
      smartNightMaxSessionHours:
          settings.containsKey('smart_night_max_session_hours')
          ? _parseNullableDouble(
              settings['smart_night_max_session_hours'],
              current.smartNightMaxSessionHours,
            )
          : _unset,
      smartNightDefaultAfCadenceFrames:
          settings.containsKey('smart_night_default_af_cadence_frames')
          ? _parseInt(
              settings['smart_night_default_af_cadence_frames'],
              current.smartNightDefaultAfCadenceFrames,
            )
          : null,
      smartNightDefaultIntegrationBudgetMinsPerTarget:
          settings.containsKey(
            'smart_night_default_integration_budget_mins_per_target',
          )
          ? _parseInt(
              settings['smart_night_default_integration_budget_mins_per_target'],
              current.smartNightDefaultIntegrationBudgetMinsPerTarget,
            )
          : null,
      smartNightIncludeFlatsAtEnd:
          settings.containsKey('smart_night_include_flats_at_end')
          ? _parseBool(
              settings['smart_night_include_flats_at_end'],
              current.smartNightIncludeFlatsAtEnd,
            )
          : null,
      smartNightUseSchedulerForMultiTarget:
          settings.containsKey('smart_night_use_scheduler_for_multi_target')
          ? _parseBool(
              settings['smart_night_use_scheduler_for_multi_target'],
              current.smartNightUseSchedulerForMultiTarget,
            )
          : null,
      smartNightSchedulerTargetThreshold:
          settings.containsKey('smart_night_scheduler_target_threshold')
          ? _parseInt(
              settings['smart_night_scheduler_target_threshold'],
              current.smartNightSchedulerTargetThreshold,
            )
          : null,
      smartNightDefaultStrategy: settings['smart_night_default_strategy'],
      smartNightPolarAlignmentStaleAfterDays:
          settings.containsKey('smart_night_polar_alignment_stale_after_days')
          ? _parseInt(
              settings['smart_night_polar_alignment_stale_after_days'],
              current.smartNightPolarAlignmentStaleAfterDays,
            )
          : null,
      // Notes prompt opt-out.
      smartNightSubExposureFloorSecs:
          settings.containsKey('smart_night_sub_exposure_floor_secs')
          ? _parseDouble(
              settings['smart_night_sub_exposure_floor_secs'],
              current.smartNightSubExposureFloorSecs,
            )
          : null,
      smartNightSubExposureCeilingSecs:
          settings.containsKey('smart_night_sub_exposure_ceiling_secs')
          ? _parseDouble(
              settings['smart_night_sub_exposure_ceiling_secs'],
              current.smartNightSubExposureCeilingSecs,
            )
          : null,
      smartNightTargetSnr: settings.containsKey('smart_night_target_snr')
          ? _parseDouble(
              settings['smart_night_target_snr'],
              current.smartNightTargetSnr,
            )
          : null,
      promptForNotesAfterRun: settings.containsKey('notes.prompt_after_run')
          ? _parseBool(
              settings['notes.prompt_after_run'],
              current.promptForNotesAfterRun,
            )
          : null,
      // Session lifecycle. Each key gates the field so a
      // partial patch can update one knob without resetting the others.
      sessionHandoffAutoPrompt:
          settings.containsKey('session.handoff_auto_prompt')
          ? _parseBool(
              settings['session.handoff_auto_prompt'],
              current.sessionHandoffAutoPrompt,
            )
          : null,
      campaignRollupSurfaceTargetsTab:
          settings.containsKey('campaign_rollup.surface_targets_tab')
          ? _parseBool(
              settings['campaign_rollup.surface_targets_tab'],
              current.campaignRollupSurfaceTargetsTab,
            )
          : null,
      campaignRollupGroupingMode:
          settings.containsKey('campaign_rollup.grouping_mode')
          ? _parseCampaignGroupingMode(
              settings['campaign_rollup.grouping_mode'],
            )
          : null,
      // Settings round-trip gap closure (G5 / G7) partial-update wiring.
      // Required so a remote save of one of these (now carried by the wire
      // model) actually reaches state and is forwarded to the host by
      // `_toRemoteSettings`.
      smartNightAutoSelect: settings.containsKey('smart_night.auto_select')
          ? _parseBool(
              settings['smart_night.auto_select'],
              current.smartNightAutoSelect,
            )
          : null,
      smartNightAutoSelectCount:
          settings.containsKey('smart_night.auto_select_count')
          ? _parseInt(
              settings['smart_night.auto_select_count'],
              current.smartNightAutoSelectCount,
            )
          : null,
      adaptiveSwapEnabledByDefault:
          settings.containsKey('adaptive_swap.enabled_by_default')
          ? _parseBool(
              settings['adaptive_swap.enabled_by_default'],
              current.adaptiveSwapEnabledByDefault,
            )
          : null,
      adaptiveSwapDefaultThreshold:
          settings.containsKey('adaptive_swap.default_threshold')
          ? _parseDouble(
              settings['adaptive_swap.default_threshold'],
              current.adaptiveSwapDefaultThreshold,
            ).clamp(0.0, 100.0)
          : null,
      adaptiveSwapDefaultHysteresisSecs:
          settings.containsKey('adaptive_swap.default_hysteresis_secs')
          ? _parseDouble(
              settings['adaptive_swap.default_hysteresis_secs'],
              current.adaptiveSwapDefaultHysteresisSecs,
            ).clamp(0.0, 3600.0)
          : null,
      // The score-weights map is persisted JSON-encoded; reuse the same
      // parser as the stored-snapshot loader so malformed / incomplete
      // payloads fall back to the canonical defaults.
      conditionsScoreWeights:
          settings.containsKey('adaptive_swap.score_weights')
          ? _parseConditionsScoreWeights(
              settings['adaptive_swap.score_weights'],
            )
          : null,
    );
  }

  /// String -> nullable double for the grading settings.
  /// Empty / "null" string => null (the user cleared the field); a parse
  /// failure falls back to the prior value to avoid silently zeroing a
  /// threshold.
  double? _parseNullableDouble(String? value, double? previous) {
    if (value == null || value.isEmpty || value == 'null') return null;
    return double.tryParse(value) ?? previous;
  }

  int? _parseNullableInt(String? value, int? previous) {
    if (value == null || value.isEmpty || value == 'null') return null;
    return int.tryParse(value) ?? previous;
  }
}
