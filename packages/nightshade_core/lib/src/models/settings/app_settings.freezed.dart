// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'app_settings.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$ObserverLocation {

 double get latitude; double get longitude; double get elevation;
/// Create a copy of ObserverLocation
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ObserverLocationCopyWith<ObserverLocation> get copyWith => _$ObserverLocationCopyWithImpl<ObserverLocation>(this as ObserverLocation, _$identity);

  /// Serializes this ObserverLocation to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ObserverLocation&&(identical(other.latitude, latitude) || other.latitude == latitude)&&(identical(other.longitude, longitude) || other.longitude == longitude)&&(identical(other.elevation, elevation) || other.elevation == elevation));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,latitude,longitude,elevation);

@override
String toString() {
  return 'ObserverLocation(latitude: $latitude, longitude: $longitude, elevation: $elevation)';
}


}

/// @nodoc
abstract mixin class $ObserverLocationCopyWith<$Res>  {
  factory $ObserverLocationCopyWith(ObserverLocation value, $Res Function(ObserverLocation) _then) = _$ObserverLocationCopyWithImpl;
@useResult
$Res call({
 double latitude, double longitude, double elevation
});




}
/// @nodoc
class _$ObserverLocationCopyWithImpl<$Res>
    implements $ObserverLocationCopyWith<$Res> {
  _$ObserverLocationCopyWithImpl(this._self, this._then);

  final ObserverLocation _self;
  final $Res Function(ObserverLocation) _then;

/// Create a copy of ObserverLocation
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? latitude = null,Object? longitude = null,Object? elevation = null,}) {
  return _then(_self.copyWith(
latitude: null == latitude ? _self.latitude : latitude // ignore: cast_nullable_to_non_nullable
as double,longitude: null == longitude ? _self.longitude : longitude // ignore: cast_nullable_to_non_nullable
as double,elevation: null == elevation ? _self.elevation : elevation // ignore: cast_nullable_to_non_nullable
as double,
  ));
}

}


/// Adds pattern-matching-related methods to [ObserverLocation].
extension ObserverLocationPatterns on ObserverLocation {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ObserverLocation value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ObserverLocation() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ObserverLocation value)  $default,){
final _that = this;
switch (_that) {
case _ObserverLocation():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ObserverLocation value)?  $default,){
final _that = this;
switch (_that) {
case _ObserverLocation() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( double latitude,  double longitude,  double elevation)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ObserverLocation() when $default != null:
return $default(_that.latitude,_that.longitude,_that.elevation);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( double latitude,  double longitude,  double elevation)  $default,) {final _that = this;
switch (_that) {
case _ObserverLocation():
return $default(_that.latitude,_that.longitude,_that.elevation);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( double latitude,  double longitude,  double elevation)?  $default,) {final _that = this;
switch (_that) {
case _ObserverLocation() when $default != null:
return $default(_that.latitude,_that.longitude,_that.elevation);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ObserverLocation implements ObserverLocation {
  const _ObserverLocation({required this.latitude, required this.longitude, required this.elevation});
  factory _ObserverLocation.fromJson(Map<String, dynamic> json) => _$ObserverLocationFromJson(json);

@override final  double latitude;
@override final  double longitude;
@override final  double elevation;

/// Create a copy of ObserverLocation
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ObserverLocationCopyWith<_ObserverLocation> get copyWith => __$ObserverLocationCopyWithImpl<_ObserverLocation>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ObserverLocationToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ObserverLocation&&(identical(other.latitude, latitude) || other.latitude == latitude)&&(identical(other.longitude, longitude) || other.longitude == longitude)&&(identical(other.elevation, elevation) || other.elevation == elevation));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,latitude,longitude,elevation);

@override
String toString() {
  return 'ObserverLocation(latitude: $latitude, longitude: $longitude, elevation: $elevation)';
}


}

/// @nodoc
abstract mixin class _$ObserverLocationCopyWith<$Res> implements $ObserverLocationCopyWith<$Res> {
  factory _$ObserverLocationCopyWith(_ObserverLocation value, $Res Function(_ObserverLocation) _then) = __$ObserverLocationCopyWithImpl;
@override @useResult
$Res call({
 double latitude, double longitude, double elevation
});




}
/// @nodoc
class __$ObserverLocationCopyWithImpl<$Res>
    implements _$ObserverLocationCopyWith<$Res> {
  __$ObserverLocationCopyWithImpl(this._self, this._then);

  final _ObserverLocation _self;
  final $Res Function(_ObserverLocation) _then;

/// Create a copy of ObserverLocation
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? latitude = null,Object? longitude = null,Object? elevation = null,}) {
  return _then(_ObserverLocation(
latitude: null == latitude ? _self.latitude : latitude // ignore: cast_nullable_to_non_nullable
as double,longitude: null == longitude ? _self.longitude : longitude // ignore: cast_nullable_to_non_nullable
as double,elevation: null == elevation ? _self.elevation : elevation // ignore: cast_nullable_to_non_nullable
as double,
  ));
}


}


/// @nodoc
mixin _$AppSettings {

 ObserverLocation? get location; String get theme; String get language; bool get autoConnect;// Additional fields for compatibility with provider AppSettings
 double get latitude; double get longitude; double get elevation; String get fileNamingPattern; int get meridianFlipMinutes; int get autoFocusEveryMinutes; int get ditherEveryFrames; int get plateSolveTimeout; double get plateSolveSearchRadius; String get discordWebhook; String get pushoverKey; String get pushoverUser; String get astapPath;// Discovery settings
 bool get autoDiscoverOnLaunch; String get accentColor; String get fontSize; String get uiScale;// Auto, Small (0.8x), Normal (1.0x), Large (1.2x), Extra Large (1.4x)
// Protocol settings
 String get indiServerHost; int get indiServerPort; bool get indiAutoConnect; String get alpacaServerHost; int get alpacaServerPort; bool get alpacaAutoDiscover;// Retired: simulation mode is not a shippable runtime state (the bundled
// native library is always a release build and refuses it). The field
// stays so stored and remote payloads that still carry it decode; nothing
// reads it.
 bool get useSimulationMode;// Image capture settings
 String get imageOutputPath; String get observer; String get telescope; String get instrument;// Update settings
 bool get updateCheckEnabled; String get updateServerUrl; String get updateChannel; int get updateCheckIntervalHours; String get skippedUpdateVersion;// Safety settings
 SafetyFailMode get safetyFailMode;// Image grading: live frame Pass/Reject thresholds. Opt-in — disabled by
// default, so every captured frame is saved and none auto-rejected.
/// Master switch: when false, no grading runs at all.
 bool get enableImageGrading;/// Reject if HFR exceeds this absolute pixel value. `null` => don't
/// apply the absolute check.
 double? get imageGradingHfrThresholdPx;/// Reject if HFR exceeds `baseline * (1 + percent / 100)`. `null` =>
/// don't apply the baseline-relative check.
 double? get imageGradingHfrBaselinePercent;/// Reject if star eccentricity exceeds this value. `null` => don't apply.
 double? get imageGradingEccentricityThreshold;/// Reject if detected star count falls below this. `null` => don't apply.
 int? get imageGradingStarCountMin;/// Notify the operator once when this many frames in a row are rejected
/// (default 3). The run carries on.
 int get imageGradingMaxConsecutiveRejects;/// Override for the reject folder. `null` => use `<save_path>/Reject/`.
/// Relative paths resolve against the run save_path; absolute paths
/// are used verbatim.
 String? get imageGradingRejectFolderPath;// Sky-brightness adaptive exposures: global defaults, pushed into the
// executor via `sequencerUpdateDefaultAdaptiveExposure` when no active
// node carries its own block. Per-ExposureNode overrides win at runtime.
/// Master switch — when false, the global default adaptive-exposure
/// is cleared and the executor falls back to nominal duration for
/// any node without an explicit per-node override.
 bool get adaptiveExposureEnabled;/// Target SNR for the SNR-based scaling (informational; the live
/// math uses background flux ratio).
 double get adaptiveExposureTargetSnr;/// Reference sky brightness in mag/arcsec² the nominal exposure
/// duration was calibrated for. Dark-site default is 21.5.
 double get adaptiveExposureReferenceMag;/// Global minimum exposure clamp in seconds.
 double get adaptiveExposureMinSecs;/// Global maximum exposure clamp in seconds.
 double get adaptiveExposureMaxSecs;/// Per-filter enable map (filter name -> bool). Empty => apply
/// globally (matches the Rust `is_enabled_for_filter` semantics).
 Map<String, bool> get adaptiveExposurePerFilterEnabled;/// Per-filter minimum exposure overrides (seconds).
 Map<String, double> get adaptiveExposurePerFilterMinSecs;/// Per-filter maximum exposure overrides (seconds).
 Map<String, double> get adaptiveExposurePerFilterMaxSecs;// Autofocus / dither / weather-safety / recovery knobs an operator tunes
// for an unattended night.
/// Weather-safety: when true, the rig parks (not just pauses) when weather
/// turns unsafe. Mirrors `app_settings` DB key `park_on_unsafe_weather`.
 bool get parkOnUnsafeWeather;/// Autofocus: run an autofocus pass on every filter change.
/// DB key `auto_focus_on_filter_change`.
 bool get autoFocusOnFilterChange;/// Autofocus: disable the guider while an autofocus sweep runs (avoids the
/// guide star wandering out of frame during the focuser sweep).
/// DB key `af_disable_guiding`.
 bool get afDisableGuidingDuringAf;/// Dither: master enable for between-frame dithering.
/// DB key `dither_enabled`.
 bool get ditherEnabled;/// Dither: dither step size — 'Small', 'Medium', or 'Large'.
/// DB key `dither_scale`.
 String get ditherScale;/// Recovery: minutes between auto-retry attempts during a recovery loop.
/// DB key `recovery_default_retry_interval_mins`.
 double get recoveryDefaultRetryIntervalMins;/// Recovery: total minutes before the recovery loop gives up.
/// DB key `recovery_default_max_duration_mins`.
 double get recoveryDefaultMaxDurationMins;/// Recovery: stop tracking while recovering (dew/cloud wait).
/// DB key `recovery_stop_tracking_during_recovery`.
 bool get recoveryStopTrackingDuringRecovery;/// Recovery: abort the recovery loop if a meridian crossing falls inside
/// the recovery window. DB key `recovery_abort_on_meridian`.
 bool get recoveryAbortOnMeridian;/// Recovery: ring the platform alert sound on recovery entry.
/// DB key `recovery_audible_alert_when_entered`.
 bool get recoveryAudibleAlertWhenEntered;// Weather-safety / dawn.
/// Park the mount before astronomical dawn at the end of the night.
/// DB key `park_before_dawn`.
 bool get parkBeforeDawn;// Device retries.
/// Times a failed camera exposure is retried before it counts as a
/// failure (0 = one attempt). DB key `camera_retries`.
 int get cameraRetries;/// Times a failed filter-wheel move is retried before it counts as a
/// failure (0 = one attempt). DB key `filter_wheel_retries`.
 int get filterWheelRetries;// Meridian flip detail.
/// Master enable for automatic meridian flips. DB key `enable_meridian_flip`.
 bool get enableMeridianFlip;// Focuser temperature compensation + backlash (calibration).
/// Enable focuser temperature compensation. DB key `temp_compensation`.
 bool get tempCompensation;/// Temp-comp coefficient (steps per °C). DB key `temp_coefficient`.
 double get tempCoefficient;/// Focuser backlash compensation (steps). DB key `backlash_compensation`.
 int get backlashCompensation;// Guider settle (calibration).
/// Guider settle pixel threshold. DB key `settle_threshold`. Default mirrors
/// the NINA/PHD2 community convention (~1.5 px); 0.5 px at typical guide
/// scales makes every dither settle slowly or time out.
 double get settleThreshold;/// Guider settle timeout in seconds. DB key `settle_timeout`. Generous so
/// a legitimate settle is not aborted early.
 int get settleTimeout;/// Guider settle stabilisation time in seconds — how long the guide error
/// must stay within [settleThreshold] before a settle is declared done.
/// DB key `settle_time`.
 int get settleTime;/// Dither on the RA axis only, leaving Dec fixed. DB key `dither_ra_only`.
 bool get ditherRaOnly;// Plate-solving extra.
/// Selected plate solver ('ASTAP', 'Astrometry.net', 'PlateSolve2').
/// DB key `plate_solver`.
 String get plateSolver;/// Allow a blind (no-hint) solve fallback. DB key `blind_solve`.
 bool get blindSolve;/// Sync the mount to the plate-solved position between centering
/// iterations. Without the sync the correction re-issues the slew that
/// produced the mis-pointed frame, so centering cannot converge.
/// DB key `centering_sync_mount`.
 bool get centeringSyncMount;// Site / horizon.
/// Bortle dark-sky class (1-9). DB key `bortle_class`.
 int get bortleClass;/// Effective horizon altitude floor in degrees. DB key `effective_horizon_deg`.
 double get effectiveHorizonDeg;// Pre-flight checklist strictness + freshness gates.
/// Pre-flight strictness as the enum name ('lax' / 'normal' / 'strict').
/// Carried as a String to avoid the wire model depending on the provider
/// library that owns the `PreflightStrictness` enum. DB key
/// `preflight_strictness`.
 String get preflightStrictness;/// Polar-alignment max age (days) before pre-flight flags it.
/// DB key `polar_alignment_max_age_days`.
 int get polarAlignmentMaxAgeDays;/// Optical-train drift threshold (arcmin) before pre-flight flags it.
/// DB key `optical_train_drift_threshold`.
 double get opticalTrainDriftThreshold;// Dark library.
/// Minimum matching dark frames before the dark library is "covered".
/// DB key `dark_library_min_coverage`.
 int get darkLibraryMinCoverage;// Smart Night defaults — the one-click "plan tonight" builder reads these
// when assembling a sequence.
/// Cap a planned session to this many hours. `null` => use the full dark
/// window. DB key `smart_night_max_session_hours`.
 double? get smartNightMaxSessionHours;/// Default autofocus cadence (frames) for built sequences.
/// DB key `smart_night_default_af_cadence_frames`.
 int get smartNightDefaultAfCadenceFrames;/// Default per-target integration budget (minutes).
/// DB key `smart_night_default_integration_budget_mins_per_target`.
 int get smartNightDefaultIntegrationBudgetMinsPerTarget;/// Append flats at the end of the planned night.
/// DB key `smart_night_include_flats_at_end`.
 bool get smartNightIncludeFlatsAtEnd;/// Use the scheduler (vs a single linear sequence) for multi-target nights.
/// DB key `smart_night_use_scheduler_for_multi_target`.
 bool get smartNightUseSchedulerForMultiTarget;/// Target count at/above which the scheduler is used.
/// DB key `smart_night_scheduler_target_threshold`.
 int get smartNightSchedulerTargetThreshold;/// Default capture strategy id (e.g. 'auto_lrgb').
/// DB key `smart_night_default_strategy`.
 String get smartNightDefaultStrategy;/// Days after which polar alignment is considered stale for the wizard.
/// DB key `smart_night_polar_alignment_stale_after_days`.
 int get smartNightPolarAlignmentStaleAfterDays;/// Sub-exposure floor (seconds) for the planner.
/// DB key `smart_night_sub_exposure_floor_secs`.
 double get smartNightSubExposureFloorSecs;/// Sub-exposure ceiling (seconds) for the planner.
/// DB key `smart_night_sub_exposure_ceiling_secs`.
 double get smartNightSubExposureCeilingSecs;/// Target SNR the planner sizes sub-exposures toward.
/// DB key `smart_night_target_snr`.
 double get smartNightTargetSnr;// Defaults from here down mirror AppSettingsState's constructor defaults,
// so the wire model never injects a different value than local state.
// Equipment defaults (camera).
/// Default camera gain. DB `default_gain`.
 int get defaultGain;/// Default camera offset. DB `default_offset`.
 int get defaultOffset;// Remote access / web server.
/// Headless web server enabled. DB `web_server_enabled`.
 bool get webServerEnabled;/// Headless web server port. DB `web_server_port`.
 int get webServerPort;// PHD2 connection.
/// PHD2 executable path. DB `phd2_path`.
 String get phd2Path;/// PHD2 host. DB `phd2_host`.
 String get phd2Host;/// PHD2 port. DB `phd2_port`.
 int get phd2Port;// Notification toggles.
/// Master notifications switch. DB `notifications_enabled`.
 bool get notificationsEnabled;/// Notify when a sequence completes. DB `notify_on_sequence_complete`.
 bool get notifyOnSequenceComplete;/// Notify on error. DB `notify_on_error`.
 bool get notifyOnError;/// Notify on meridian flip. DB `notify_on_meridian_flip`.
 bool get notifyOnMeridianFlip;/// In-app notification sound. DB `sound_enabled`.
 bool get soundEnabled;/// Ring the platform alert on critical-severity events. DB
/// `audible_alerts_on_critical`.
 bool get audibleAlertsOnCritical;/// Which sound for critical alerts ('systemBell' / 'none'). DB
/// `critical_alert_sound`.
 String get criticalAlertSound;/// Forward critical alerts to paired phones as push. DB `push_critical_alerts`.
 bool get pushCriticalAlerts;// Session-lifecycle + campaign-rollup prefs.
/// Show the Smart-Night auto-prompt when equipment is ready. DB
/// `smart_night.auto_prompt_enabled`.
 bool get smartNightAutoPromptEnabled;/// Prompt for notes after a run. DB `notes.prompt_after_run`.
 bool get promptForNotesAfterRun;/// Auto-open the multi-night carry-over banner. DB
/// `session.handoff_auto_prompt`.
 bool get sessionHandoffAutoPrompt;/// Surface the campaign-rollup column on the Targets tab. DB
/// `campaign_rollup.surface_targets_tab`.
 bool get campaignRollupSurfaceTargetsTab;/// Campaign-rollup grouping mode. DB `campaign_rollup.grouping_mode`.
 String get campaignRollupGroupingMode;// Autofocus detailed sweep params.
/// AF method. DB `af_method`.
 String get afMethod;/// AF curve fitting. DB `af_curve_fitting`.
 String get afCurveFitting;/// AF step size between measurement points. DB `af_step_size`.
 int get afStepSize;/// AF exposure time (seconds). DB `af_exposure_time`.
 double get afExposureTime;/// AF initial offset steps out from center. DB `af_initial_offset_steps`.
 int get afInitialOffsetSteps;/// AF retry count on failure. DB `af_number_of_attempts`.
 int get afNumberOfAttempts;/// AF brightest-N stars (0 = all). DB `af_use_brightest_n_stars`.
/// On by default: counting every detection lets faint, noisy sources
/// swamp the measurement.
 int get afUseBrightestNStars;/// AF outer crop ratio. DB `af_outer_crop_ratio`.
 double get afOuterCropRatio;/// AF inner crop ratio. DB `af_inner_crop_ratio`.
 double get afInnerCropRatio;/// AF binning. DB `af_binning`.
 int get afBinning;/// AF R² fit-quality threshold. DB `af_r_squared_threshold`.
 double get afRSquaredThreshold;/// How far above the reference HFR the frames may sit, as a multiple, and
/// still be worth capturing after autofocus has failed.
/// DB `af_failure_hfr_tolerance_ratio`.
///
/// A failed autofocus never parks the rig or ends the run: the focuser
/// goes back where it was, the operator is notified and imaging carries
/// on. This ratio decides what the notice says about the frames: at 1.6
/// a run whose good HFR is 2.5 is told frames at 3.8 are slightly soft
/// and frames at 10 are past the limit.
 double get afFailureHfrToleranceRatio;/// AF focuser settle time (ms). DB `af_focuser_settle_time_ms`.
 int get afFocuserSettleTimeMs;/// AF exposures per measurement point. DB `af_exposures_per_point`.
 int get afExposuresPerPoint;/// AF backlash compensation method. DB `af_backlash_comp_method`.
 String get afBacklashCompMethod;/// AF backlash-in steps. DB `af_backlash_in`.
 int get afBacklashIn;/// What to do when a connected mount's site/time disagrees with this
/// computer's. DB `mount_site_sync_mode`.
 String get mountSiteSyncMode;/// AF backlash-out steps. DB `af_backlash_out`.
 int get afBacklashOut;/// Designated AF filter (empty = current). DB `af_autofocus_filter_name`.
 String get afAutofocusFilterName;/// Per-filter AF config JSON map. DB `af_filter_settings`.
 String get afFilterSettingsJson;/// Apply focus offsets on filter change. DB `use_filter_focus_offsets`.
 bool get useFilterFocusOffsets;// Misc imaging / FITS / plate-solve config relevant to an unattended night.
/// Astrometry.net solver path. DB `astrometry_path`.
 String get astrometryPath;/// FITS OBSERVER keyword. DB `observer_name`.
 String get observerName;/// Image format ('FITS' / 'XISF' / 'TIFF'). DB `image_format`.
 String get imageFormat;/// Bit depth ('16-bit' / '32-bit'). DB `bit_depth`.
 String get bitDepth;/// Observing timezone. DB `timezone`.
 String get timezone;/// Use system time vs a fixed observing time. DB `use_system_time`.
 bool get useSystemTime;// Sequencer output path default.
/// User-facing default output directory for saved sequence files. DB
/// key `sequences_path`.
 String get sequencesPath;// Smart Night target auto-select (the rest of the smart_night.* group
// is already remoted).
/// Auto-select the top-N targets when building a Smart Night plan. DB
/// key `smart_night.auto_select`.
 bool get smartNightAutoSelect;/// How many targets to auto-select when [smartNightAutoSelect] is true.
/// DB key `smart_night.auto_select_count`.
 int get smartNightAutoSelectCount;// Adaptive sky-conditions target-swap scheduler-SEED defaults. These
// pre-fill a new TargetSchedulerNode; the score weights feed the live
// ConditionsScore composer (weather_safety_provider). DB keys under
// `adaptive_swap.*`.
/// New schedulers ship with adaptive swap enabled by default. DB key
/// `adaptive_swap.enabled_by_default`.
 bool get adaptiveSwapEnabledByDefault;/// Default conditions-score floor (0..=100) seeded into a new scheduler.
/// DB key `adaptive_swap.default_threshold`.
 double get adaptiveSwapDefaultThreshold;/// Default seconds between consecutive swaps seeded into a new scheduler.
/// DB key `adaptive_swap.default_hysteresis_secs`.
 double get adaptiveSwapDefaultHysteresisSecs;/// Per-axis composer weights for the live ConditionsScore. Keys:
/// `transparency` / `seeing` / `cloud` / `wind`. DB key
/// `adaptive_swap.score_weights` (a JSON object).
 Map<String, double> get conditionsScoreWeights;
/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AppSettingsCopyWith<AppSettings> get copyWith => _$AppSettingsCopyWithImpl<AppSettings>(this as AppSettings, _$identity);

  /// Serializes this AppSettings to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AppSettings&&(identical(other.location, location) || other.location == location)&&(identical(other.theme, theme) || other.theme == theme)&&(identical(other.language, language) || other.language == language)&&(identical(other.autoConnect, autoConnect) || other.autoConnect == autoConnect)&&(identical(other.latitude, latitude) || other.latitude == latitude)&&(identical(other.longitude, longitude) || other.longitude == longitude)&&(identical(other.elevation, elevation) || other.elevation == elevation)&&(identical(other.fileNamingPattern, fileNamingPattern) || other.fileNamingPattern == fileNamingPattern)&&(identical(other.meridianFlipMinutes, meridianFlipMinutes) || other.meridianFlipMinutes == meridianFlipMinutes)&&(identical(other.autoFocusEveryMinutes, autoFocusEveryMinutes) || other.autoFocusEveryMinutes == autoFocusEveryMinutes)&&(identical(other.ditherEveryFrames, ditherEveryFrames) || other.ditherEveryFrames == ditherEveryFrames)&&(identical(other.plateSolveTimeout, plateSolveTimeout) || other.plateSolveTimeout == plateSolveTimeout)&&(identical(other.plateSolveSearchRadius, plateSolveSearchRadius) || other.plateSolveSearchRadius == plateSolveSearchRadius)&&(identical(other.discordWebhook, discordWebhook) || other.discordWebhook == discordWebhook)&&(identical(other.pushoverKey, pushoverKey) || other.pushoverKey == pushoverKey)&&(identical(other.pushoverUser, pushoverUser) || other.pushoverUser == pushoverUser)&&(identical(other.astapPath, astapPath) || other.astapPath == astapPath)&&(identical(other.autoDiscoverOnLaunch, autoDiscoverOnLaunch) || other.autoDiscoverOnLaunch == autoDiscoverOnLaunch)&&(identical(other.accentColor, accentColor) || other.accentColor == accentColor)&&(identical(other.fontSize, fontSize) || other.fontSize == fontSize)&&(identical(other.uiScale, uiScale) || other.uiScale == uiScale)&&(identical(other.indiServerHost, indiServerHost) || other.indiServerHost == indiServerHost)&&(identical(other.indiServerPort, indiServerPort) || other.indiServerPort == indiServerPort)&&(identical(other.indiAutoConnect, indiAutoConnect) || other.indiAutoConnect == indiAutoConnect)&&(identical(other.alpacaServerHost, alpacaServerHost) || other.alpacaServerHost == alpacaServerHost)&&(identical(other.alpacaServerPort, alpacaServerPort) || other.alpacaServerPort == alpacaServerPort)&&(identical(other.alpacaAutoDiscover, alpacaAutoDiscover) || other.alpacaAutoDiscover == alpacaAutoDiscover)&&(identical(other.useSimulationMode, useSimulationMode) || other.useSimulationMode == useSimulationMode)&&(identical(other.imageOutputPath, imageOutputPath) || other.imageOutputPath == imageOutputPath)&&(identical(other.observer, observer) || other.observer == observer)&&(identical(other.telescope, telescope) || other.telescope == telescope)&&(identical(other.instrument, instrument) || other.instrument == instrument)&&(identical(other.updateCheckEnabled, updateCheckEnabled) || other.updateCheckEnabled == updateCheckEnabled)&&(identical(other.updateServerUrl, updateServerUrl) || other.updateServerUrl == updateServerUrl)&&(identical(other.updateChannel, updateChannel) || other.updateChannel == updateChannel)&&(identical(other.updateCheckIntervalHours, updateCheckIntervalHours) || other.updateCheckIntervalHours == updateCheckIntervalHours)&&(identical(other.skippedUpdateVersion, skippedUpdateVersion) || other.skippedUpdateVersion == skippedUpdateVersion)&&(identical(other.safetyFailMode, safetyFailMode) || other.safetyFailMode == safetyFailMode)&&(identical(other.enableImageGrading, enableImageGrading) || other.enableImageGrading == enableImageGrading)&&(identical(other.imageGradingHfrThresholdPx, imageGradingHfrThresholdPx) || other.imageGradingHfrThresholdPx == imageGradingHfrThresholdPx)&&(identical(other.imageGradingHfrBaselinePercent, imageGradingHfrBaselinePercent) || other.imageGradingHfrBaselinePercent == imageGradingHfrBaselinePercent)&&(identical(other.imageGradingEccentricityThreshold, imageGradingEccentricityThreshold) || other.imageGradingEccentricityThreshold == imageGradingEccentricityThreshold)&&(identical(other.imageGradingStarCountMin, imageGradingStarCountMin) || other.imageGradingStarCountMin == imageGradingStarCountMin)&&(identical(other.imageGradingMaxConsecutiveRejects, imageGradingMaxConsecutiveRejects) || other.imageGradingMaxConsecutiveRejects == imageGradingMaxConsecutiveRejects)&&(identical(other.imageGradingRejectFolderPath, imageGradingRejectFolderPath) || other.imageGradingRejectFolderPath == imageGradingRejectFolderPath)&&(identical(other.adaptiveExposureEnabled, adaptiveExposureEnabled) || other.adaptiveExposureEnabled == adaptiveExposureEnabled)&&(identical(other.adaptiveExposureTargetSnr, adaptiveExposureTargetSnr) || other.adaptiveExposureTargetSnr == adaptiveExposureTargetSnr)&&(identical(other.adaptiveExposureReferenceMag, adaptiveExposureReferenceMag) || other.adaptiveExposureReferenceMag == adaptiveExposureReferenceMag)&&(identical(other.adaptiveExposureMinSecs, adaptiveExposureMinSecs) || other.adaptiveExposureMinSecs == adaptiveExposureMinSecs)&&(identical(other.adaptiveExposureMaxSecs, adaptiveExposureMaxSecs) || other.adaptiveExposureMaxSecs == adaptiveExposureMaxSecs)&&const DeepCollectionEquality().equals(other.adaptiveExposurePerFilterEnabled, adaptiveExposurePerFilterEnabled)&&const DeepCollectionEquality().equals(other.adaptiveExposurePerFilterMinSecs, adaptiveExposurePerFilterMinSecs)&&const DeepCollectionEquality().equals(other.adaptiveExposurePerFilterMaxSecs, adaptiveExposurePerFilterMaxSecs)&&(identical(other.parkOnUnsafeWeather, parkOnUnsafeWeather) || other.parkOnUnsafeWeather == parkOnUnsafeWeather)&&(identical(other.autoFocusOnFilterChange, autoFocusOnFilterChange) || other.autoFocusOnFilterChange == autoFocusOnFilterChange)&&(identical(other.afDisableGuidingDuringAf, afDisableGuidingDuringAf) || other.afDisableGuidingDuringAf == afDisableGuidingDuringAf)&&(identical(other.ditherEnabled, ditherEnabled) || other.ditherEnabled == ditherEnabled)&&(identical(other.ditherScale, ditherScale) || other.ditherScale == ditherScale)&&(identical(other.recoveryDefaultRetryIntervalMins, recoveryDefaultRetryIntervalMins) || other.recoveryDefaultRetryIntervalMins == recoveryDefaultRetryIntervalMins)&&(identical(other.recoveryDefaultMaxDurationMins, recoveryDefaultMaxDurationMins) || other.recoveryDefaultMaxDurationMins == recoveryDefaultMaxDurationMins)&&(identical(other.recoveryStopTrackingDuringRecovery, recoveryStopTrackingDuringRecovery) || other.recoveryStopTrackingDuringRecovery == recoveryStopTrackingDuringRecovery)&&(identical(other.recoveryAbortOnMeridian, recoveryAbortOnMeridian) || other.recoveryAbortOnMeridian == recoveryAbortOnMeridian)&&(identical(other.recoveryAudibleAlertWhenEntered, recoveryAudibleAlertWhenEntered) || other.recoveryAudibleAlertWhenEntered == recoveryAudibleAlertWhenEntered)&&(identical(other.parkBeforeDawn, parkBeforeDawn) || other.parkBeforeDawn == parkBeforeDawn)&&(identical(other.cameraRetries, cameraRetries) || other.cameraRetries == cameraRetries)&&(identical(other.filterWheelRetries, filterWheelRetries) || other.filterWheelRetries == filterWheelRetries)&&(identical(other.enableMeridianFlip, enableMeridianFlip) || other.enableMeridianFlip == enableMeridianFlip)&&(identical(other.tempCompensation, tempCompensation) || other.tempCompensation == tempCompensation)&&(identical(other.tempCoefficient, tempCoefficient) || other.tempCoefficient == tempCoefficient)&&(identical(other.backlashCompensation, backlashCompensation) || other.backlashCompensation == backlashCompensation)&&(identical(other.settleThreshold, settleThreshold) || other.settleThreshold == settleThreshold)&&(identical(other.settleTimeout, settleTimeout) || other.settleTimeout == settleTimeout)&&(identical(other.settleTime, settleTime) || other.settleTime == settleTime)&&(identical(other.ditherRaOnly, ditherRaOnly) || other.ditherRaOnly == ditherRaOnly)&&(identical(other.plateSolver, plateSolver) || other.plateSolver == plateSolver)&&(identical(other.blindSolve, blindSolve) || other.blindSolve == blindSolve)&&(identical(other.centeringSyncMount, centeringSyncMount) || other.centeringSyncMount == centeringSyncMount)&&(identical(other.bortleClass, bortleClass) || other.bortleClass == bortleClass)&&(identical(other.effectiveHorizonDeg, effectiveHorizonDeg) || other.effectiveHorizonDeg == effectiveHorizonDeg)&&(identical(other.preflightStrictness, preflightStrictness) || other.preflightStrictness == preflightStrictness)&&(identical(other.polarAlignmentMaxAgeDays, polarAlignmentMaxAgeDays) || other.polarAlignmentMaxAgeDays == polarAlignmentMaxAgeDays)&&(identical(other.opticalTrainDriftThreshold, opticalTrainDriftThreshold) || other.opticalTrainDriftThreshold == opticalTrainDriftThreshold)&&(identical(other.darkLibraryMinCoverage, darkLibraryMinCoverage) || other.darkLibraryMinCoverage == darkLibraryMinCoverage)&&(identical(other.smartNightMaxSessionHours, smartNightMaxSessionHours) || other.smartNightMaxSessionHours == smartNightMaxSessionHours)&&(identical(other.smartNightDefaultAfCadenceFrames, smartNightDefaultAfCadenceFrames) || other.smartNightDefaultAfCadenceFrames == smartNightDefaultAfCadenceFrames)&&(identical(other.smartNightDefaultIntegrationBudgetMinsPerTarget, smartNightDefaultIntegrationBudgetMinsPerTarget) || other.smartNightDefaultIntegrationBudgetMinsPerTarget == smartNightDefaultIntegrationBudgetMinsPerTarget)&&(identical(other.smartNightIncludeFlatsAtEnd, smartNightIncludeFlatsAtEnd) || other.smartNightIncludeFlatsAtEnd == smartNightIncludeFlatsAtEnd)&&(identical(other.smartNightUseSchedulerForMultiTarget, smartNightUseSchedulerForMultiTarget) || other.smartNightUseSchedulerForMultiTarget == smartNightUseSchedulerForMultiTarget)&&(identical(other.smartNightSchedulerTargetThreshold, smartNightSchedulerTargetThreshold) || other.smartNightSchedulerTargetThreshold == smartNightSchedulerTargetThreshold)&&(identical(other.smartNightDefaultStrategy, smartNightDefaultStrategy) || other.smartNightDefaultStrategy == smartNightDefaultStrategy)&&(identical(other.smartNightPolarAlignmentStaleAfterDays, smartNightPolarAlignmentStaleAfterDays) || other.smartNightPolarAlignmentStaleAfterDays == smartNightPolarAlignmentStaleAfterDays)&&(identical(other.smartNightSubExposureFloorSecs, smartNightSubExposureFloorSecs) || other.smartNightSubExposureFloorSecs == smartNightSubExposureFloorSecs)&&(identical(other.smartNightSubExposureCeilingSecs, smartNightSubExposureCeilingSecs) || other.smartNightSubExposureCeilingSecs == smartNightSubExposureCeilingSecs)&&(identical(other.smartNightTargetSnr, smartNightTargetSnr) || other.smartNightTargetSnr == smartNightTargetSnr)&&(identical(other.defaultGain, defaultGain) || other.defaultGain == defaultGain)&&(identical(other.defaultOffset, defaultOffset) || other.defaultOffset == defaultOffset)&&(identical(other.webServerEnabled, webServerEnabled) || other.webServerEnabled == webServerEnabled)&&(identical(other.webServerPort, webServerPort) || other.webServerPort == webServerPort)&&(identical(other.phd2Path, phd2Path) || other.phd2Path == phd2Path)&&(identical(other.phd2Host, phd2Host) || other.phd2Host == phd2Host)&&(identical(other.phd2Port, phd2Port) || other.phd2Port == phd2Port)&&(identical(other.notificationsEnabled, notificationsEnabled) || other.notificationsEnabled == notificationsEnabled)&&(identical(other.notifyOnSequenceComplete, notifyOnSequenceComplete) || other.notifyOnSequenceComplete == notifyOnSequenceComplete)&&(identical(other.notifyOnError, notifyOnError) || other.notifyOnError == notifyOnError)&&(identical(other.notifyOnMeridianFlip, notifyOnMeridianFlip) || other.notifyOnMeridianFlip == notifyOnMeridianFlip)&&(identical(other.soundEnabled, soundEnabled) || other.soundEnabled == soundEnabled)&&(identical(other.audibleAlertsOnCritical, audibleAlertsOnCritical) || other.audibleAlertsOnCritical == audibleAlertsOnCritical)&&(identical(other.criticalAlertSound, criticalAlertSound) || other.criticalAlertSound == criticalAlertSound)&&(identical(other.pushCriticalAlerts, pushCriticalAlerts) || other.pushCriticalAlerts == pushCriticalAlerts)&&(identical(other.smartNightAutoPromptEnabled, smartNightAutoPromptEnabled) || other.smartNightAutoPromptEnabled == smartNightAutoPromptEnabled)&&(identical(other.promptForNotesAfterRun, promptForNotesAfterRun) || other.promptForNotesAfterRun == promptForNotesAfterRun)&&(identical(other.sessionHandoffAutoPrompt, sessionHandoffAutoPrompt) || other.sessionHandoffAutoPrompt == sessionHandoffAutoPrompt)&&(identical(other.campaignRollupSurfaceTargetsTab, campaignRollupSurfaceTargetsTab) || other.campaignRollupSurfaceTargetsTab == campaignRollupSurfaceTargetsTab)&&(identical(other.campaignRollupGroupingMode, campaignRollupGroupingMode) || other.campaignRollupGroupingMode == campaignRollupGroupingMode)&&(identical(other.afMethod, afMethod) || other.afMethod == afMethod)&&(identical(other.afCurveFitting, afCurveFitting) || other.afCurveFitting == afCurveFitting)&&(identical(other.afStepSize, afStepSize) || other.afStepSize == afStepSize)&&(identical(other.afExposureTime, afExposureTime) || other.afExposureTime == afExposureTime)&&(identical(other.afInitialOffsetSteps, afInitialOffsetSteps) || other.afInitialOffsetSteps == afInitialOffsetSteps)&&(identical(other.afNumberOfAttempts, afNumberOfAttempts) || other.afNumberOfAttempts == afNumberOfAttempts)&&(identical(other.afUseBrightestNStars, afUseBrightestNStars) || other.afUseBrightestNStars == afUseBrightestNStars)&&(identical(other.afOuterCropRatio, afOuterCropRatio) || other.afOuterCropRatio == afOuterCropRatio)&&(identical(other.afInnerCropRatio, afInnerCropRatio) || other.afInnerCropRatio == afInnerCropRatio)&&(identical(other.afBinning, afBinning) || other.afBinning == afBinning)&&(identical(other.afRSquaredThreshold, afRSquaredThreshold) || other.afRSquaredThreshold == afRSquaredThreshold)&&(identical(other.afFailureHfrToleranceRatio, afFailureHfrToleranceRatio) || other.afFailureHfrToleranceRatio == afFailureHfrToleranceRatio)&&(identical(other.afFocuserSettleTimeMs, afFocuserSettleTimeMs) || other.afFocuserSettleTimeMs == afFocuserSettleTimeMs)&&(identical(other.afExposuresPerPoint, afExposuresPerPoint) || other.afExposuresPerPoint == afExposuresPerPoint)&&(identical(other.afBacklashCompMethod, afBacklashCompMethod) || other.afBacklashCompMethod == afBacklashCompMethod)&&(identical(other.afBacklashIn, afBacklashIn) || other.afBacklashIn == afBacklashIn)&&(identical(other.mountSiteSyncMode, mountSiteSyncMode) || other.mountSiteSyncMode == mountSiteSyncMode)&&(identical(other.afBacklashOut, afBacklashOut) || other.afBacklashOut == afBacklashOut)&&(identical(other.afAutofocusFilterName, afAutofocusFilterName) || other.afAutofocusFilterName == afAutofocusFilterName)&&(identical(other.afFilterSettingsJson, afFilterSettingsJson) || other.afFilterSettingsJson == afFilterSettingsJson)&&(identical(other.useFilterFocusOffsets, useFilterFocusOffsets) || other.useFilterFocusOffsets == useFilterFocusOffsets)&&(identical(other.astrometryPath, astrometryPath) || other.astrometryPath == astrometryPath)&&(identical(other.observerName, observerName) || other.observerName == observerName)&&(identical(other.imageFormat, imageFormat) || other.imageFormat == imageFormat)&&(identical(other.bitDepth, bitDepth) || other.bitDepth == bitDepth)&&(identical(other.timezone, timezone) || other.timezone == timezone)&&(identical(other.useSystemTime, useSystemTime) || other.useSystemTime == useSystemTime)&&(identical(other.sequencesPath, sequencesPath) || other.sequencesPath == sequencesPath)&&(identical(other.smartNightAutoSelect, smartNightAutoSelect) || other.smartNightAutoSelect == smartNightAutoSelect)&&(identical(other.smartNightAutoSelectCount, smartNightAutoSelectCount) || other.smartNightAutoSelectCount == smartNightAutoSelectCount)&&(identical(other.adaptiveSwapEnabledByDefault, adaptiveSwapEnabledByDefault) || other.adaptiveSwapEnabledByDefault == adaptiveSwapEnabledByDefault)&&(identical(other.adaptiveSwapDefaultThreshold, adaptiveSwapDefaultThreshold) || other.adaptiveSwapDefaultThreshold == adaptiveSwapDefaultThreshold)&&(identical(other.adaptiveSwapDefaultHysteresisSecs, adaptiveSwapDefaultHysteresisSecs) || other.adaptiveSwapDefaultHysteresisSecs == adaptiveSwapDefaultHysteresisSecs)&&const DeepCollectionEquality().equals(other.conditionsScoreWeights, conditionsScoreWeights));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,location,theme,language,autoConnect,latitude,longitude,elevation,fileNamingPattern,meridianFlipMinutes,autoFocusEveryMinutes,ditherEveryFrames,plateSolveTimeout,plateSolveSearchRadius,discordWebhook,pushoverKey,pushoverUser,astapPath,autoDiscoverOnLaunch,accentColor,fontSize,uiScale,indiServerHost,indiServerPort,indiAutoConnect,alpacaServerHost,alpacaServerPort,alpacaAutoDiscover,useSimulationMode,imageOutputPath,observer,telescope,instrument,updateCheckEnabled,updateServerUrl,updateChannel,updateCheckIntervalHours,skippedUpdateVersion,safetyFailMode,enableImageGrading,imageGradingHfrThresholdPx,imageGradingHfrBaselinePercent,imageGradingEccentricityThreshold,imageGradingStarCountMin,imageGradingMaxConsecutiveRejects,imageGradingRejectFolderPath,adaptiveExposureEnabled,adaptiveExposureTargetSnr,adaptiveExposureReferenceMag,adaptiveExposureMinSecs,adaptiveExposureMaxSecs,const DeepCollectionEquality().hash(adaptiveExposurePerFilterEnabled),const DeepCollectionEquality().hash(adaptiveExposurePerFilterMinSecs),const DeepCollectionEquality().hash(adaptiveExposurePerFilterMaxSecs),parkOnUnsafeWeather,autoFocusOnFilterChange,afDisableGuidingDuringAf,ditherEnabled,ditherScale,recoveryDefaultRetryIntervalMins,recoveryDefaultMaxDurationMins,recoveryStopTrackingDuringRecovery,recoveryAbortOnMeridian,recoveryAudibleAlertWhenEntered,parkBeforeDawn,cameraRetries,filterWheelRetries,enableMeridianFlip,tempCompensation,tempCoefficient,backlashCompensation,settleThreshold,settleTimeout,settleTime,ditherRaOnly,plateSolver,blindSolve,centeringSyncMount,bortleClass,effectiveHorizonDeg,preflightStrictness,polarAlignmentMaxAgeDays,opticalTrainDriftThreshold,darkLibraryMinCoverage,smartNightMaxSessionHours,smartNightDefaultAfCadenceFrames,smartNightDefaultIntegrationBudgetMinsPerTarget,smartNightIncludeFlatsAtEnd,smartNightUseSchedulerForMultiTarget,smartNightSchedulerTargetThreshold,smartNightDefaultStrategy,smartNightPolarAlignmentStaleAfterDays,smartNightSubExposureFloorSecs,smartNightSubExposureCeilingSecs,smartNightTargetSnr,defaultGain,defaultOffset,webServerEnabled,webServerPort,phd2Path,phd2Host,phd2Port,notificationsEnabled,notifyOnSequenceComplete,notifyOnError,notifyOnMeridianFlip,soundEnabled,audibleAlertsOnCritical,criticalAlertSound,pushCriticalAlerts,smartNightAutoPromptEnabled,promptForNotesAfterRun,sessionHandoffAutoPrompt,campaignRollupSurfaceTargetsTab,campaignRollupGroupingMode,afMethod,afCurveFitting,afStepSize,afExposureTime,afInitialOffsetSteps,afNumberOfAttempts,afUseBrightestNStars,afOuterCropRatio,afInnerCropRatio,afBinning,afRSquaredThreshold,afFailureHfrToleranceRatio,afFocuserSettleTimeMs,afExposuresPerPoint,afBacklashCompMethod,afBacklashIn,mountSiteSyncMode,afBacklashOut,afAutofocusFilterName,afFilterSettingsJson,useFilterFocusOffsets,astrometryPath,observerName,imageFormat,bitDepth,timezone,useSystemTime,sequencesPath,smartNightAutoSelect,smartNightAutoSelectCount,adaptiveSwapEnabledByDefault,adaptiveSwapDefaultThreshold,adaptiveSwapDefaultHysteresisSecs,const DeepCollectionEquality().hash(conditionsScoreWeights)]);

@override
String toString() {
  return 'AppSettings(location: $location, theme: $theme, language: $language, autoConnect: $autoConnect, latitude: $latitude, longitude: $longitude, elevation: $elevation, fileNamingPattern: $fileNamingPattern, meridianFlipMinutes: $meridianFlipMinutes, autoFocusEveryMinutes: $autoFocusEveryMinutes, ditherEveryFrames: $ditherEveryFrames, plateSolveTimeout: $plateSolveTimeout, plateSolveSearchRadius: $plateSolveSearchRadius, discordWebhook: $discordWebhook, pushoverKey: $pushoverKey, pushoverUser: $pushoverUser, astapPath: $astapPath, autoDiscoverOnLaunch: $autoDiscoverOnLaunch, accentColor: $accentColor, fontSize: $fontSize, uiScale: $uiScale, indiServerHost: $indiServerHost, indiServerPort: $indiServerPort, indiAutoConnect: $indiAutoConnect, alpacaServerHost: $alpacaServerHost, alpacaServerPort: $alpacaServerPort, alpacaAutoDiscover: $alpacaAutoDiscover, useSimulationMode: $useSimulationMode, imageOutputPath: $imageOutputPath, observer: $observer, telescope: $telescope, instrument: $instrument, updateCheckEnabled: $updateCheckEnabled, updateServerUrl: $updateServerUrl, updateChannel: $updateChannel, updateCheckIntervalHours: $updateCheckIntervalHours, skippedUpdateVersion: $skippedUpdateVersion, safetyFailMode: $safetyFailMode, enableImageGrading: $enableImageGrading, imageGradingHfrThresholdPx: $imageGradingHfrThresholdPx, imageGradingHfrBaselinePercent: $imageGradingHfrBaselinePercent, imageGradingEccentricityThreshold: $imageGradingEccentricityThreshold, imageGradingStarCountMin: $imageGradingStarCountMin, imageGradingMaxConsecutiveRejects: $imageGradingMaxConsecutiveRejects, imageGradingRejectFolderPath: $imageGradingRejectFolderPath, adaptiveExposureEnabled: $adaptiveExposureEnabled, adaptiveExposureTargetSnr: $adaptiveExposureTargetSnr, adaptiveExposureReferenceMag: $adaptiveExposureReferenceMag, adaptiveExposureMinSecs: $adaptiveExposureMinSecs, adaptiveExposureMaxSecs: $adaptiveExposureMaxSecs, adaptiveExposurePerFilterEnabled: $adaptiveExposurePerFilterEnabled, adaptiveExposurePerFilterMinSecs: $adaptiveExposurePerFilterMinSecs, adaptiveExposurePerFilterMaxSecs: $adaptiveExposurePerFilterMaxSecs, parkOnUnsafeWeather: $parkOnUnsafeWeather, autoFocusOnFilterChange: $autoFocusOnFilterChange, afDisableGuidingDuringAf: $afDisableGuidingDuringAf, ditherEnabled: $ditherEnabled, ditherScale: $ditherScale, recoveryDefaultRetryIntervalMins: $recoveryDefaultRetryIntervalMins, recoveryDefaultMaxDurationMins: $recoveryDefaultMaxDurationMins, recoveryStopTrackingDuringRecovery: $recoveryStopTrackingDuringRecovery, recoveryAbortOnMeridian: $recoveryAbortOnMeridian, recoveryAudibleAlertWhenEntered: $recoveryAudibleAlertWhenEntered, parkBeforeDawn: $parkBeforeDawn, cameraRetries: $cameraRetries, filterWheelRetries: $filterWheelRetries, enableMeridianFlip: $enableMeridianFlip, tempCompensation: $tempCompensation, tempCoefficient: $tempCoefficient, backlashCompensation: $backlashCompensation, settleThreshold: $settleThreshold, settleTimeout: $settleTimeout, settleTime: $settleTime, ditherRaOnly: $ditherRaOnly, plateSolver: $plateSolver, blindSolve: $blindSolve, centeringSyncMount: $centeringSyncMount, bortleClass: $bortleClass, effectiveHorizonDeg: $effectiveHorizonDeg, preflightStrictness: $preflightStrictness, polarAlignmentMaxAgeDays: $polarAlignmentMaxAgeDays, opticalTrainDriftThreshold: $opticalTrainDriftThreshold, darkLibraryMinCoverage: $darkLibraryMinCoverage, smartNightMaxSessionHours: $smartNightMaxSessionHours, smartNightDefaultAfCadenceFrames: $smartNightDefaultAfCadenceFrames, smartNightDefaultIntegrationBudgetMinsPerTarget: $smartNightDefaultIntegrationBudgetMinsPerTarget, smartNightIncludeFlatsAtEnd: $smartNightIncludeFlatsAtEnd, smartNightUseSchedulerForMultiTarget: $smartNightUseSchedulerForMultiTarget, smartNightSchedulerTargetThreshold: $smartNightSchedulerTargetThreshold, smartNightDefaultStrategy: $smartNightDefaultStrategy, smartNightPolarAlignmentStaleAfterDays: $smartNightPolarAlignmentStaleAfterDays, smartNightSubExposureFloorSecs: $smartNightSubExposureFloorSecs, smartNightSubExposureCeilingSecs: $smartNightSubExposureCeilingSecs, smartNightTargetSnr: $smartNightTargetSnr, defaultGain: $defaultGain, defaultOffset: $defaultOffset, webServerEnabled: $webServerEnabled, webServerPort: $webServerPort, phd2Path: $phd2Path, phd2Host: $phd2Host, phd2Port: $phd2Port, notificationsEnabled: $notificationsEnabled, notifyOnSequenceComplete: $notifyOnSequenceComplete, notifyOnError: $notifyOnError, notifyOnMeridianFlip: $notifyOnMeridianFlip, soundEnabled: $soundEnabled, audibleAlertsOnCritical: $audibleAlertsOnCritical, criticalAlertSound: $criticalAlertSound, pushCriticalAlerts: $pushCriticalAlerts, smartNightAutoPromptEnabled: $smartNightAutoPromptEnabled, promptForNotesAfterRun: $promptForNotesAfterRun, sessionHandoffAutoPrompt: $sessionHandoffAutoPrompt, campaignRollupSurfaceTargetsTab: $campaignRollupSurfaceTargetsTab, campaignRollupGroupingMode: $campaignRollupGroupingMode, afMethod: $afMethod, afCurveFitting: $afCurveFitting, afStepSize: $afStepSize, afExposureTime: $afExposureTime, afInitialOffsetSteps: $afInitialOffsetSteps, afNumberOfAttempts: $afNumberOfAttempts, afUseBrightestNStars: $afUseBrightestNStars, afOuterCropRatio: $afOuterCropRatio, afInnerCropRatio: $afInnerCropRatio, afBinning: $afBinning, afRSquaredThreshold: $afRSquaredThreshold, afFailureHfrToleranceRatio: $afFailureHfrToleranceRatio, afFocuserSettleTimeMs: $afFocuserSettleTimeMs, afExposuresPerPoint: $afExposuresPerPoint, afBacklashCompMethod: $afBacklashCompMethod, afBacklashIn: $afBacklashIn, mountSiteSyncMode: $mountSiteSyncMode, afBacklashOut: $afBacklashOut, afAutofocusFilterName: $afAutofocusFilterName, afFilterSettingsJson: $afFilterSettingsJson, useFilterFocusOffsets: $useFilterFocusOffsets, astrometryPath: $astrometryPath, observerName: $observerName, imageFormat: $imageFormat, bitDepth: $bitDepth, timezone: $timezone, useSystemTime: $useSystemTime, sequencesPath: $sequencesPath, smartNightAutoSelect: $smartNightAutoSelect, smartNightAutoSelectCount: $smartNightAutoSelectCount, adaptiveSwapEnabledByDefault: $adaptiveSwapEnabledByDefault, adaptiveSwapDefaultThreshold: $adaptiveSwapDefaultThreshold, adaptiveSwapDefaultHysteresisSecs: $adaptiveSwapDefaultHysteresisSecs, conditionsScoreWeights: $conditionsScoreWeights)';
}


}

/// @nodoc
abstract mixin class $AppSettingsCopyWith<$Res>  {
  factory $AppSettingsCopyWith(AppSettings value, $Res Function(AppSettings) _then) = _$AppSettingsCopyWithImpl;
@useResult
$Res call({
 ObserverLocation? location, String theme, String language, bool autoConnect, double latitude, double longitude, double elevation, String fileNamingPattern, int meridianFlipMinutes, int autoFocusEveryMinutes, int ditherEveryFrames, int plateSolveTimeout, double plateSolveSearchRadius, String discordWebhook, String pushoverKey, String pushoverUser, String astapPath, bool autoDiscoverOnLaunch, String accentColor, String fontSize, String uiScale, String indiServerHost, int indiServerPort, bool indiAutoConnect, String alpacaServerHost, int alpacaServerPort, bool alpacaAutoDiscover, bool useSimulationMode, String imageOutputPath, String observer, String telescope, String instrument, bool updateCheckEnabled, String updateServerUrl, String updateChannel, int updateCheckIntervalHours, String skippedUpdateVersion, SafetyFailMode safetyFailMode, bool enableImageGrading, double? imageGradingHfrThresholdPx, double? imageGradingHfrBaselinePercent, double? imageGradingEccentricityThreshold, int? imageGradingStarCountMin, int imageGradingMaxConsecutiveRejects, String? imageGradingRejectFolderPath, bool adaptiveExposureEnabled, double adaptiveExposureTargetSnr, double adaptiveExposureReferenceMag, double adaptiveExposureMinSecs, double adaptiveExposureMaxSecs, Map<String, bool> adaptiveExposurePerFilterEnabled, Map<String, double> adaptiveExposurePerFilterMinSecs, Map<String, double> adaptiveExposurePerFilterMaxSecs, bool parkOnUnsafeWeather, bool autoFocusOnFilterChange, bool afDisableGuidingDuringAf, bool ditherEnabled, String ditherScale, double recoveryDefaultRetryIntervalMins, double recoveryDefaultMaxDurationMins, bool recoveryStopTrackingDuringRecovery, bool recoveryAbortOnMeridian, bool recoveryAudibleAlertWhenEntered, bool parkBeforeDawn, int cameraRetries, int filterWheelRetries, bool enableMeridianFlip, bool tempCompensation, double tempCoefficient, int backlashCompensation, double settleThreshold, int settleTimeout, int settleTime, bool ditherRaOnly, String plateSolver, bool blindSolve, bool centeringSyncMount, int bortleClass, double effectiveHorizonDeg, String preflightStrictness, int polarAlignmentMaxAgeDays, double opticalTrainDriftThreshold, int darkLibraryMinCoverage, double? smartNightMaxSessionHours, int smartNightDefaultAfCadenceFrames, int smartNightDefaultIntegrationBudgetMinsPerTarget, bool smartNightIncludeFlatsAtEnd, bool smartNightUseSchedulerForMultiTarget, int smartNightSchedulerTargetThreshold, String smartNightDefaultStrategy, int smartNightPolarAlignmentStaleAfterDays, double smartNightSubExposureFloorSecs, double smartNightSubExposureCeilingSecs, double smartNightTargetSnr, int defaultGain, int defaultOffset, bool webServerEnabled, int webServerPort, String phd2Path, String phd2Host, int phd2Port, bool notificationsEnabled, bool notifyOnSequenceComplete, bool notifyOnError, bool notifyOnMeridianFlip, bool soundEnabled, bool audibleAlertsOnCritical, String criticalAlertSound, bool pushCriticalAlerts, bool smartNightAutoPromptEnabled, bool promptForNotesAfterRun, bool sessionHandoffAutoPrompt, bool campaignRollupSurfaceTargetsTab, String campaignRollupGroupingMode, String afMethod, String afCurveFitting, int afStepSize, double afExposureTime, int afInitialOffsetSteps, int afNumberOfAttempts, int afUseBrightestNStars, double afOuterCropRatio, double afInnerCropRatio, int afBinning, double afRSquaredThreshold, double afFailureHfrToleranceRatio, int afFocuserSettleTimeMs, int afExposuresPerPoint, String afBacklashCompMethod, int afBacklashIn, String mountSiteSyncMode, int afBacklashOut, String afAutofocusFilterName, String afFilterSettingsJson, bool useFilterFocusOffsets, String astrometryPath, String observerName, String imageFormat, String bitDepth, String timezone, bool useSystemTime, String sequencesPath, bool smartNightAutoSelect, int smartNightAutoSelectCount, bool adaptiveSwapEnabledByDefault, double adaptiveSwapDefaultThreshold, double adaptiveSwapDefaultHysteresisSecs, Map<String, double> conditionsScoreWeights
});


$ObserverLocationCopyWith<$Res>? get location;

}
/// @nodoc
class _$AppSettingsCopyWithImpl<$Res>
    implements $AppSettingsCopyWith<$Res> {
  _$AppSettingsCopyWithImpl(this._self, this._then);

  final AppSettings _self;
  final $Res Function(AppSettings) _then;

/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? location = freezed,Object? theme = null,Object? language = null,Object? autoConnect = null,Object? latitude = null,Object? longitude = null,Object? elevation = null,Object? fileNamingPattern = null,Object? meridianFlipMinutes = null,Object? autoFocusEveryMinutes = null,Object? ditherEveryFrames = null,Object? plateSolveTimeout = null,Object? plateSolveSearchRadius = null,Object? discordWebhook = null,Object? pushoverKey = null,Object? pushoverUser = null,Object? astapPath = null,Object? autoDiscoverOnLaunch = null,Object? accentColor = null,Object? fontSize = null,Object? uiScale = null,Object? indiServerHost = null,Object? indiServerPort = null,Object? indiAutoConnect = null,Object? alpacaServerHost = null,Object? alpacaServerPort = null,Object? alpacaAutoDiscover = null,Object? useSimulationMode = null,Object? imageOutputPath = null,Object? observer = null,Object? telescope = null,Object? instrument = null,Object? updateCheckEnabled = null,Object? updateServerUrl = null,Object? updateChannel = null,Object? updateCheckIntervalHours = null,Object? skippedUpdateVersion = null,Object? safetyFailMode = null,Object? enableImageGrading = null,Object? imageGradingHfrThresholdPx = freezed,Object? imageGradingHfrBaselinePercent = freezed,Object? imageGradingEccentricityThreshold = freezed,Object? imageGradingStarCountMin = freezed,Object? imageGradingMaxConsecutiveRejects = null,Object? imageGradingRejectFolderPath = freezed,Object? adaptiveExposureEnabled = null,Object? adaptiveExposureTargetSnr = null,Object? adaptiveExposureReferenceMag = null,Object? adaptiveExposureMinSecs = null,Object? adaptiveExposureMaxSecs = null,Object? adaptiveExposurePerFilterEnabled = null,Object? adaptiveExposurePerFilterMinSecs = null,Object? adaptiveExposurePerFilterMaxSecs = null,Object? parkOnUnsafeWeather = null,Object? autoFocusOnFilterChange = null,Object? afDisableGuidingDuringAf = null,Object? ditherEnabled = null,Object? ditherScale = null,Object? recoveryDefaultRetryIntervalMins = null,Object? recoveryDefaultMaxDurationMins = null,Object? recoveryStopTrackingDuringRecovery = null,Object? recoveryAbortOnMeridian = null,Object? recoveryAudibleAlertWhenEntered = null,Object? parkBeforeDawn = null,Object? cameraRetries = null,Object? filterWheelRetries = null,Object? enableMeridianFlip = null,Object? tempCompensation = null,Object? tempCoefficient = null,Object? backlashCompensation = null,Object? settleThreshold = null,Object? settleTimeout = null,Object? settleTime = null,Object? ditherRaOnly = null,Object? plateSolver = null,Object? blindSolve = null,Object? centeringSyncMount = null,Object? bortleClass = null,Object? effectiveHorizonDeg = null,Object? preflightStrictness = null,Object? polarAlignmentMaxAgeDays = null,Object? opticalTrainDriftThreshold = null,Object? darkLibraryMinCoverage = null,Object? smartNightMaxSessionHours = freezed,Object? smartNightDefaultAfCadenceFrames = null,Object? smartNightDefaultIntegrationBudgetMinsPerTarget = null,Object? smartNightIncludeFlatsAtEnd = null,Object? smartNightUseSchedulerForMultiTarget = null,Object? smartNightSchedulerTargetThreshold = null,Object? smartNightDefaultStrategy = null,Object? smartNightPolarAlignmentStaleAfterDays = null,Object? smartNightSubExposureFloorSecs = null,Object? smartNightSubExposureCeilingSecs = null,Object? smartNightTargetSnr = null,Object? defaultGain = null,Object? defaultOffset = null,Object? webServerEnabled = null,Object? webServerPort = null,Object? phd2Path = null,Object? phd2Host = null,Object? phd2Port = null,Object? notificationsEnabled = null,Object? notifyOnSequenceComplete = null,Object? notifyOnError = null,Object? notifyOnMeridianFlip = null,Object? soundEnabled = null,Object? audibleAlertsOnCritical = null,Object? criticalAlertSound = null,Object? pushCriticalAlerts = null,Object? smartNightAutoPromptEnabled = null,Object? promptForNotesAfterRun = null,Object? sessionHandoffAutoPrompt = null,Object? campaignRollupSurfaceTargetsTab = null,Object? campaignRollupGroupingMode = null,Object? afMethod = null,Object? afCurveFitting = null,Object? afStepSize = null,Object? afExposureTime = null,Object? afInitialOffsetSteps = null,Object? afNumberOfAttempts = null,Object? afUseBrightestNStars = null,Object? afOuterCropRatio = null,Object? afInnerCropRatio = null,Object? afBinning = null,Object? afRSquaredThreshold = null,Object? afFailureHfrToleranceRatio = null,Object? afFocuserSettleTimeMs = null,Object? afExposuresPerPoint = null,Object? afBacklashCompMethod = null,Object? afBacklashIn = null,Object? mountSiteSyncMode = null,Object? afBacklashOut = null,Object? afAutofocusFilterName = null,Object? afFilterSettingsJson = null,Object? useFilterFocusOffsets = null,Object? astrometryPath = null,Object? observerName = null,Object? imageFormat = null,Object? bitDepth = null,Object? timezone = null,Object? useSystemTime = null,Object? sequencesPath = null,Object? smartNightAutoSelect = null,Object? smartNightAutoSelectCount = null,Object? adaptiveSwapEnabledByDefault = null,Object? adaptiveSwapDefaultThreshold = null,Object? adaptiveSwapDefaultHysteresisSecs = null,Object? conditionsScoreWeights = null,}) {
  return _then(_self.copyWith(
location: freezed == location ? _self.location : location // ignore: cast_nullable_to_non_nullable
as ObserverLocation?,theme: null == theme ? _self.theme : theme // ignore: cast_nullable_to_non_nullable
as String,language: null == language ? _self.language : language // ignore: cast_nullable_to_non_nullable
as String,autoConnect: null == autoConnect ? _self.autoConnect : autoConnect // ignore: cast_nullable_to_non_nullable
as bool,latitude: null == latitude ? _self.latitude : latitude // ignore: cast_nullable_to_non_nullable
as double,longitude: null == longitude ? _self.longitude : longitude // ignore: cast_nullable_to_non_nullable
as double,elevation: null == elevation ? _self.elevation : elevation // ignore: cast_nullable_to_non_nullable
as double,fileNamingPattern: null == fileNamingPattern ? _self.fileNamingPattern : fileNamingPattern // ignore: cast_nullable_to_non_nullable
as String,meridianFlipMinutes: null == meridianFlipMinutes ? _self.meridianFlipMinutes : meridianFlipMinutes // ignore: cast_nullable_to_non_nullable
as int,autoFocusEveryMinutes: null == autoFocusEveryMinutes ? _self.autoFocusEveryMinutes : autoFocusEveryMinutes // ignore: cast_nullable_to_non_nullable
as int,ditherEveryFrames: null == ditherEveryFrames ? _self.ditherEveryFrames : ditherEveryFrames // ignore: cast_nullable_to_non_nullable
as int,plateSolveTimeout: null == plateSolveTimeout ? _self.plateSolveTimeout : plateSolveTimeout // ignore: cast_nullable_to_non_nullable
as int,plateSolveSearchRadius: null == plateSolveSearchRadius ? _self.plateSolveSearchRadius : plateSolveSearchRadius // ignore: cast_nullable_to_non_nullable
as double,discordWebhook: null == discordWebhook ? _self.discordWebhook : discordWebhook // ignore: cast_nullable_to_non_nullable
as String,pushoverKey: null == pushoverKey ? _self.pushoverKey : pushoverKey // ignore: cast_nullable_to_non_nullable
as String,pushoverUser: null == pushoverUser ? _self.pushoverUser : pushoverUser // ignore: cast_nullable_to_non_nullable
as String,astapPath: null == astapPath ? _self.astapPath : astapPath // ignore: cast_nullable_to_non_nullable
as String,autoDiscoverOnLaunch: null == autoDiscoverOnLaunch ? _self.autoDiscoverOnLaunch : autoDiscoverOnLaunch // ignore: cast_nullable_to_non_nullable
as bool,accentColor: null == accentColor ? _self.accentColor : accentColor // ignore: cast_nullable_to_non_nullable
as String,fontSize: null == fontSize ? _self.fontSize : fontSize // ignore: cast_nullable_to_non_nullable
as String,uiScale: null == uiScale ? _self.uiScale : uiScale // ignore: cast_nullable_to_non_nullable
as String,indiServerHost: null == indiServerHost ? _self.indiServerHost : indiServerHost // ignore: cast_nullable_to_non_nullable
as String,indiServerPort: null == indiServerPort ? _self.indiServerPort : indiServerPort // ignore: cast_nullable_to_non_nullable
as int,indiAutoConnect: null == indiAutoConnect ? _self.indiAutoConnect : indiAutoConnect // ignore: cast_nullable_to_non_nullable
as bool,alpacaServerHost: null == alpacaServerHost ? _self.alpacaServerHost : alpacaServerHost // ignore: cast_nullable_to_non_nullable
as String,alpacaServerPort: null == alpacaServerPort ? _self.alpacaServerPort : alpacaServerPort // ignore: cast_nullable_to_non_nullable
as int,alpacaAutoDiscover: null == alpacaAutoDiscover ? _self.alpacaAutoDiscover : alpacaAutoDiscover // ignore: cast_nullable_to_non_nullable
as bool,useSimulationMode: null == useSimulationMode ? _self.useSimulationMode : useSimulationMode // ignore: cast_nullable_to_non_nullable
as bool,imageOutputPath: null == imageOutputPath ? _self.imageOutputPath : imageOutputPath // ignore: cast_nullable_to_non_nullable
as String,observer: null == observer ? _self.observer : observer // ignore: cast_nullable_to_non_nullable
as String,telescope: null == telescope ? _self.telescope : telescope // ignore: cast_nullable_to_non_nullable
as String,instrument: null == instrument ? _self.instrument : instrument // ignore: cast_nullable_to_non_nullable
as String,updateCheckEnabled: null == updateCheckEnabled ? _self.updateCheckEnabled : updateCheckEnabled // ignore: cast_nullable_to_non_nullable
as bool,updateServerUrl: null == updateServerUrl ? _self.updateServerUrl : updateServerUrl // ignore: cast_nullable_to_non_nullable
as String,updateChannel: null == updateChannel ? _self.updateChannel : updateChannel // ignore: cast_nullable_to_non_nullable
as String,updateCheckIntervalHours: null == updateCheckIntervalHours ? _self.updateCheckIntervalHours : updateCheckIntervalHours // ignore: cast_nullable_to_non_nullable
as int,skippedUpdateVersion: null == skippedUpdateVersion ? _self.skippedUpdateVersion : skippedUpdateVersion // ignore: cast_nullable_to_non_nullable
as String,safetyFailMode: null == safetyFailMode ? _self.safetyFailMode : safetyFailMode // ignore: cast_nullable_to_non_nullable
as SafetyFailMode,enableImageGrading: null == enableImageGrading ? _self.enableImageGrading : enableImageGrading // ignore: cast_nullable_to_non_nullable
as bool,imageGradingHfrThresholdPx: freezed == imageGradingHfrThresholdPx ? _self.imageGradingHfrThresholdPx : imageGradingHfrThresholdPx // ignore: cast_nullable_to_non_nullable
as double?,imageGradingHfrBaselinePercent: freezed == imageGradingHfrBaselinePercent ? _self.imageGradingHfrBaselinePercent : imageGradingHfrBaselinePercent // ignore: cast_nullable_to_non_nullable
as double?,imageGradingEccentricityThreshold: freezed == imageGradingEccentricityThreshold ? _self.imageGradingEccentricityThreshold : imageGradingEccentricityThreshold // ignore: cast_nullable_to_non_nullable
as double?,imageGradingStarCountMin: freezed == imageGradingStarCountMin ? _self.imageGradingStarCountMin : imageGradingStarCountMin // ignore: cast_nullable_to_non_nullable
as int?,imageGradingMaxConsecutiveRejects: null == imageGradingMaxConsecutiveRejects ? _self.imageGradingMaxConsecutiveRejects : imageGradingMaxConsecutiveRejects // ignore: cast_nullable_to_non_nullable
as int,imageGradingRejectFolderPath: freezed == imageGradingRejectFolderPath ? _self.imageGradingRejectFolderPath : imageGradingRejectFolderPath // ignore: cast_nullable_to_non_nullable
as String?,adaptiveExposureEnabled: null == adaptiveExposureEnabled ? _self.adaptiveExposureEnabled : adaptiveExposureEnabled // ignore: cast_nullable_to_non_nullable
as bool,adaptiveExposureTargetSnr: null == adaptiveExposureTargetSnr ? _self.adaptiveExposureTargetSnr : adaptiveExposureTargetSnr // ignore: cast_nullable_to_non_nullable
as double,adaptiveExposureReferenceMag: null == adaptiveExposureReferenceMag ? _self.adaptiveExposureReferenceMag : adaptiveExposureReferenceMag // ignore: cast_nullable_to_non_nullable
as double,adaptiveExposureMinSecs: null == adaptiveExposureMinSecs ? _self.adaptiveExposureMinSecs : adaptiveExposureMinSecs // ignore: cast_nullable_to_non_nullable
as double,adaptiveExposureMaxSecs: null == adaptiveExposureMaxSecs ? _self.adaptiveExposureMaxSecs : adaptiveExposureMaxSecs // ignore: cast_nullable_to_non_nullable
as double,adaptiveExposurePerFilterEnabled: null == adaptiveExposurePerFilterEnabled ? _self.adaptiveExposurePerFilterEnabled : adaptiveExposurePerFilterEnabled // ignore: cast_nullable_to_non_nullable
as Map<String, bool>,adaptiveExposurePerFilterMinSecs: null == adaptiveExposurePerFilterMinSecs ? _self.adaptiveExposurePerFilterMinSecs : adaptiveExposurePerFilterMinSecs // ignore: cast_nullable_to_non_nullable
as Map<String, double>,adaptiveExposurePerFilterMaxSecs: null == adaptiveExposurePerFilterMaxSecs ? _self.adaptiveExposurePerFilterMaxSecs : adaptiveExposurePerFilterMaxSecs // ignore: cast_nullable_to_non_nullable
as Map<String, double>,parkOnUnsafeWeather: null == parkOnUnsafeWeather ? _self.parkOnUnsafeWeather : parkOnUnsafeWeather // ignore: cast_nullable_to_non_nullable
as bool,autoFocusOnFilterChange: null == autoFocusOnFilterChange ? _self.autoFocusOnFilterChange : autoFocusOnFilterChange // ignore: cast_nullable_to_non_nullable
as bool,afDisableGuidingDuringAf: null == afDisableGuidingDuringAf ? _self.afDisableGuidingDuringAf : afDisableGuidingDuringAf // ignore: cast_nullable_to_non_nullable
as bool,ditherEnabled: null == ditherEnabled ? _self.ditherEnabled : ditherEnabled // ignore: cast_nullable_to_non_nullable
as bool,ditherScale: null == ditherScale ? _self.ditherScale : ditherScale // ignore: cast_nullable_to_non_nullable
as String,recoveryDefaultRetryIntervalMins: null == recoveryDefaultRetryIntervalMins ? _self.recoveryDefaultRetryIntervalMins : recoveryDefaultRetryIntervalMins // ignore: cast_nullable_to_non_nullable
as double,recoveryDefaultMaxDurationMins: null == recoveryDefaultMaxDurationMins ? _self.recoveryDefaultMaxDurationMins : recoveryDefaultMaxDurationMins // ignore: cast_nullable_to_non_nullable
as double,recoveryStopTrackingDuringRecovery: null == recoveryStopTrackingDuringRecovery ? _self.recoveryStopTrackingDuringRecovery : recoveryStopTrackingDuringRecovery // ignore: cast_nullable_to_non_nullable
as bool,recoveryAbortOnMeridian: null == recoveryAbortOnMeridian ? _self.recoveryAbortOnMeridian : recoveryAbortOnMeridian // ignore: cast_nullable_to_non_nullable
as bool,recoveryAudibleAlertWhenEntered: null == recoveryAudibleAlertWhenEntered ? _self.recoveryAudibleAlertWhenEntered : recoveryAudibleAlertWhenEntered // ignore: cast_nullable_to_non_nullable
as bool,parkBeforeDawn: null == parkBeforeDawn ? _self.parkBeforeDawn : parkBeforeDawn // ignore: cast_nullable_to_non_nullable
as bool,cameraRetries: null == cameraRetries ? _self.cameraRetries : cameraRetries // ignore: cast_nullable_to_non_nullable
as int,filterWheelRetries: null == filterWheelRetries ? _self.filterWheelRetries : filterWheelRetries // ignore: cast_nullable_to_non_nullable
as int,enableMeridianFlip: null == enableMeridianFlip ? _self.enableMeridianFlip : enableMeridianFlip // ignore: cast_nullable_to_non_nullable
as bool,tempCompensation: null == tempCompensation ? _self.tempCompensation : tempCompensation // ignore: cast_nullable_to_non_nullable
as bool,tempCoefficient: null == tempCoefficient ? _self.tempCoefficient : tempCoefficient // ignore: cast_nullable_to_non_nullable
as double,backlashCompensation: null == backlashCompensation ? _self.backlashCompensation : backlashCompensation // ignore: cast_nullable_to_non_nullable
as int,settleThreshold: null == settleThreshold ? _self.settleThreshold : settleThreshold // ignore: cast_nullable_to_non_nullable
as double,settleTimeout: null == settleTimeout ? _self.settleTimeout : settleTimeout // ignore: cast_nullable_to_non_nullable
as int,settleTime: null == settleTime ? _self.settleTime : settleTime // ignore: cast_nullable_to_non_nullable
as int,ditherRaOnly: null == ditherRaOnly ? _self.ditherRaOnly : ditherRaOnly // ignore: cast_nullable_to_non_nullable
as bool,plateSolver: null == plateSolver ? _self.plateSolver : plateSolver // ignore: cast_nullable_to_non_nullable
as String,blindSolve: null == blindSolve ? _self.blindSolve : blindSolve // ignore: cast_nullable_to_non_nullable
as bool,centeringSyncMount: null == centeringSyncMount ? _self.centeringSyncMount : centeringSyncMount // ignore: cast_nullable_to_non_nullable
as bool,bortleClass: null == bortleClass ? _self.bortleClass : bortleClass // ignore: cast_nullable_to_non_nullable
as int,effectiveHorizonDeg: null == effectiveHorizonDeg ? _self.effectiveHorizonDeg : effectiveHorizonDeg // ignore: cast_nullable_to_non_nullable
as double,preflightStrictness: null == preflightStrictness ? _self.preflightStrictness : preflightStrictness // ignore: cast_nullable_to_non_nullable
as String,polarAlignmentMaxAgeDays: null == polarAlignmentMaxAgeDays ? _self.polarAlignmentMaxAgeDays : polarAlignmentMaxAgeDays // ignore: cast_nullable_to_non_nullable
as int,opticalTrainDriftThreshold: null == opticalTrainDriftThreshold ? _self.opticalTrainDriftThreshold : opticalTrainDriftThreshold // ignore: cast_nullable_to_non_nullable
as double,darkLibraryMinCoverage: null == darkLibraryMinCoverage ? _self.darkLibraryMinCoverage : darkLibraryMinCoverage // ignore: cast_nullable_to_non_nullable
as int,smartNightMaxSessionHours: freezed == smartNightMaxSessionHours ? _self.smartNightMaxSessionHours : smartNightMaxSessionHours // ignore: cast_nullable_to_non_nullable
as double?,smartNightDefaultAfCadenceFrames: null == smartNightDefaultAfCadenceFrames ? _self.smartNightDefaultAfCadenceFrames : smartNightDefaultAfCadenceFrames // ignore: cast_nullable_to_non_nullable
as int,smartNightDefaultIntegrationBudgetMinsPerTarget: null == smartNightDefaultIntegrationBudgetMinsPerTarget ? _self.smartNightDefaultIntegrationBudgetMinsPerTarget : smartNightDefaultIntegrationBudgetMinsPerTarget // ignore: cast_nullable_to_non_nullable
as int,smartNightIncludeFlatsAtEnd: null == smartNightIncludeFlatsAtEnd ? _self.smartNightIncludeFlatsAtEnd : smartNightIncludeFlatsAtEnd // ignore: cast_nullable_to_non_nullable
as bool,smartNightUseSchedulerForMultiTarget: null == smartNightUseSchedulerForMultiTarget ? _self.smartNightUseSchedulerForMultiTarget : smartNightUseSchedulerForMultiTarget // ignore: cast_nullable_to_non_nullable
as bool,smartNightSchedulerTargetThreshold: null == smartNightSchedulerTargetThreshold ? _self.smartNightSchedulerTargetThreshold : smartNightSchedulerTargetThreshold // ignore: cast_nullable_to_non_nullable
as int,smartNightDefaultStrategy: null == smartNightDefaultStrategy ? _self.smartNightDefaultStrategy : smartNightDefaultStrategy // ignore: cast_nullable_to_non_nullable
as String,smartNightPolarAlignmentStaleAfterDays: null == smartNightPolarAlignmentStaleAfterDays ? _self.smartNightPolarAlignmentStaleAfterDays : smartNightPolarAlignmentStaleAfterDays // ignore: cast_nullable_to_non_nullable
as int,smartNightSubExposureFloorSecs: null == smartNightSubExposureFloorSecs ? _self.smartNightSubExposureFloorSecs : smartNightSubExposureFloorSecs // ignore: cast_nullable_to_non_nullable
as double,smartNightSubExposureCeilingSecs: null == smartNightSubExposureCeilingSecs ? _self.smartNightSubExposureCeilingSecs : smartNightSubExposureCeilingSecs // ignore: cast_nullable_to_non_nullable
as double,smartNightTargetSnr: null == smartNightTargetSnr ? _self.smartNightTargetSnr : smartNightTargetSnr // ignore: cast_nullable_to_non_nullable
as double,defaultGain: null == defaultGain ? _self.defaultGain : defaultGain // ignore: cast_nullable_to_non_nullable
as int,defaultOffset: null == defaultOffset ? _self.defaultOffset : defaultOffset // ignore: cast_nullable_to_non_nullable
as int,webServerEnabled: null == webServerEnabled ? _self.webServerEnabled : webServerEnabled // ignore: cast_nullable_to_non_nullable
as bool,webServerPort: null == webServerPort ? _self.webServerPort : webServerPort // ignore: cast_nullable_to_non_nullable
as int,phd2Path: null == phd2Path ? _self.phd2Path : phd2Path // ignore: cast_nullable_to_non_nullable
as String,phd2Host: null == phd2Host ? _self.phd2Host : phd2Host // ignore: cast_nullable_to_non_nullable
as String,phd2Port: null == phd2Port ? _self.phd2Port : phd2Port // ignore: cast_nullable_to_non_nullable
as int,notificationsEnabled: null == notificationsEnabled ? _self.notificationsEnabled : notificationsEnabled // ignore: cast_nullable_to_non_nullable
as bool,notifyOnSequenceComplete: null == notifyOnSequenceComplete ? _self.notifyOnSequenceComplete : notifyOnSequenceComplete // ignore: cast_nullable_to_non_nullable
as bool,notifyOnError: null == notifyOnError ? _self.notifyOnError : notifyOnError // ignore: cast_nullable_to_non_nullable
as bool,notifyOnMeridianFlip: null == notifyOnMeridianFlip ? _self.notifyOnMeridianFlip : notifyOnMeridianFlip // ignore: cast_nullable_to_non_nullable
as bool,soundEnabled: null == soundEnabled ? _self.soundEnabled : soundEnabled // ignore: cast_nullable_to_non_nullable
as bool,audibleAlertsOnCritical: null == audibleAlertsOnCritical ? _self.audibleAlertsOnCritical : audibleAlertsOnCritical // ignore: cast_nullable_to_non_nullable
as bool,criticalAlertSound: null == criticalAlertSound ? _self.criticalAlertSound : criticalAlertSound // ignore: cast_nullable_to_non_nullable
as String,pushCriticalAlerts: null == pushCriticalAlerts ? _self.pushCriticalAlerts : pushCriticalAlerts // ignore: cast_nullable_to_non_nullable
as bool,smartNightAutoPromptEnabled: null == smartNightAutoPromptEnabled ? _self.smartNightAutoPromptEnabled : smartNightAutoPromptEnabled // ignore: cast_nullable_to_non_nullable
as bool,promptForNotesAfterRun: null == promptForNotesAfterRun ? _self.promptForNotesAfterRun : promptForNotesAfterRun // ignore: cast_nullable_to_non_nullable
as bool,sessionHandoffAutoPrompt: null == sessionHandoffAutoPrompt ? _self.sessionHandoffAutoPrompt : sessionHandoffAutoPrompt // ignore: cast_nullable_to_non_nullable
as bool,campaignRollupSurfaceTargetsTab: null == campaignRollupSurfaceTargetsTab ? _self.campaignRollupSurfaceTargetsTab : campaignRollupSurfaceTargetsTab // ignore: cast_nullable_to_non_nullable
as bool,campaignRollupGroupingMode: null == campaignRollupGroupingMode ? _self.campaignRollupGroupingMode : campaignRollupGroupingMode // ignore: cast_nullable_to_non_nullable
as String,afMethod: null == afMethod ? _self.afMethod : afMethod // ignore: cast_nullable_to_non_nullable
as String,afCurveFitting: null == afCurveFitting ? _self.afCurveFitting : afCurveFitting // ignore: cast_nullable_to_non_nullable
as String,afStepSize: null == afStepSize ? _self.afStepSize : afStepSize // ignore: cast_nullable_to_non_nullable
as int,afExposureTime: null == afExposureTime ? _self.afExposureTime : afExposureTime // ignore: cast_nullable_to_non_nullable
as double,afInitialOffsetSteps: null == afInitialOffsetSteps ? _self.afInitialOffsetSteps : afInitialOffsetSteps // ignore: cast_nullable_to_non_nullable
as int,afNumberOfAttempts: null == afNumberOfAttempts ? _self.afNumberOfAttempts : afNumberOfAttempts // ignore: cast_nullable_to_non_nullable
as int,afUseBrightestNStars: null == afUseBrightestNStars ? _self.afUseBrightestNStars : afUseBrightestNStars // ignore: cast_nullable_to_non_nullable
as int,afOuterCropRatio: null == afOuterCropRatio ? _self.afOuterCropRatio : afOuterCropRatio // ignore: cast_nullable_to_non_nullable
as double,afInnerCropRatio: null == afInnerCropRatio ? _self.afInnerCropRatio : afInnerCropRatio // ignore: cast_nullable_to_non_nullable
as double,afBinning: null == afBinning ? _self.afBinning : afBinning // ignore: cast_nullable_to_non_nullable
as int,afRSquaredThreshold: null == afRSquaredThreshold ? _self.afRSquaredThreshold : afRSquaredThreshold // ignore: cast_nullable_to_non_nullable
as double,afFailureHfrToleranceRatio: null == afFailureHfrToleranceRatio ? _self.afFailureHfrToleranceRatio : afFailureHfrToleranceRatio // ignore: cast_nullable_to_non_nullable
as double,afFocuserSettleTimeMs: null == afFocuserSettleTimeMs ? _self.afFocuserSettleTimeMs : afFocuserSettleTimeMs // ignore: cast_nullable_to_non_nullable
as int,afExposuresPerPoint: null == afExposuresPerPoint ? _self.afExposuresPerPoint : afExposuresPerPoint // ignore: cast_nullable_to_non_nullable
as int,afBacklashCompMethod: null == afBacklashCompMethod ? _self.afBacklashCompMethod : afBacklashCompMethod // ignore: cast_nullable_to_non_nullable
as String,afBacklashIn: null == afBacklashIn ? _self.afBacklashIn : afBacklashIn // ignore: cast_nullable_to_non_nullable
as int,mountSiteSyncMode: null == mountSiteSyncMode ? _self.mountSiteSyncMode : mountSiteSyncMode // ignore: cast_nullable_to_non_nullable
as String,afBacklashOut: null == afBacklashOut ? _self.afBacklashOut : afBacklashOut // ignore: cast_nullable_to_non_nullable
as int,afAutofocusFilterName: null == afAutofocusFilterName ? _self.afAutofocusFilterName : afAutofocusFilterName // ignore: cast_nullable_to_non_nullable
as String,afFilterSettingsJson: null == afFilterSettingsJson ? _self.afFilterSettingsJson : afFilterSettingsJson // ignore: cast_nullable_to_non_nullable
as String,useFilterFocusOffsets: null == useFilterFocusOffsets ? _self.useFilterFocusOffsets : useFilterFocusOffsets // ignore: cast_nullable_to_non_nullable
as bool,astrometryPath: null == astrometryPath ? _self.astrometryPath : astrometryPath // ignore: cast_nullable_to_non_nullable
as String,observerName: null == observerName ? _self.observerName : observerName // ignore: cast_nullable_to_non_nullable
as String,imageFormat: null == imageFormat ? _self.imageFormat : imageFormat // ignore: cast_nullable_to_non_nullable
as String,bitDepth: null == bitDepth ? _self.bitDepth : bitDepth // ignore: cast_nullable_to_non_nullable
as String,timezone: null == timezone ? _self.timezone : timezone // ignore: cast_nullable_to_non_nullable
as String,useSystemTime: null == useSystemTime ? _self.useSystemTime : useSystemTime // ignore: cast_nullable_to_non_nullable
as bool,sequencesPath: null == sequencesPath ? _self.sequencesPath : sequencesPath // ignore: cast_nullable_to_non_nullable
as String,smartNightAutoSelect: null == smartNightAutoSelect ? _self.smartNightAutoSelect : smartNightAutoSelect // ignore: cast_nullable_to_non_nullable
as bool,smartNightAutoSelectCount: null == smartNightAutoSelectCount ? _self.smartNightAutoSelectCount : smartNightAutoSelectCount // ignore: cast_nullable_to_non_nullable
as int,adaptiveSwapEnabledByDefault: null == adaptiveSwapEnabledByDefault ? _self.adaptiveSwapEnabledByDefault : adaptiveSwapEnabledByDefault // ignore: cast_nullable_to_non_nullable
as bool,adaptiveSwapDefaultThreshold: null == adaptiveSwapDefaultThreshold ? _self.adaptiveSwapDefaultThreshold : adaptiveSwapDefaultThreshold // ignore: cast_nullable_to_non_nullable
as double,adaptiveSwapDefaultHysteresisSecs: null == adaptiveSwapDefaultHysteresisSecs ? _self.adaptiveSwapDefaultHysteresisSecs : adaptiveSwapDefaultHysteresisSecs // ignore: cast_nullable_to_non_nullable
as double,conditionsScoreWeights: null == conditionsScoreWeights ? _self.conditionsScoreWeights : conditionsScoreWeights // ignore: cast_nullable_to_non_nullable
as Map<String, double>,
  ));
}
/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ObserverLocationCopyWith<$Res>? get location {
    if (_self.location == null) {
    return null;
  }

  return $ObserverLocationCopyWith<$Res>(_self.location!, (value) {
    return _then(_self.copyWith(location: value));
  });
}
}


/// Adds pattern-matching-related methods to [AppSettings].
extension AppSettingsPatterns on AppSettings {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _AppSettings value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _AppSettings() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _AppSettings value)  $default,){
final _that = this;
switch (_that) {
case _AppSettings():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _AppSettings value)?  $default,){
final _that = this;
switch (_that) {
case _AppSettings() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( ObserverLocation? location,  String theme,  String language,  bool autoConnect,  double latitude,  double longitude,  double elevation,  String fileNamingPattern,  int meridianFlipMinutes,  int autoFocusEveryMinutes,  int ditherEveryFrames,  int plateSolveTimeout,  double plateSolveSearchRadius,  String discordWebhook,  String pushoverKey,  String pushoverUser,  String astapPath,  bool autoDiscoverOnLaunch,  String accentColor,  String fontSize,  String uiScale,  String indiServerHost,  int indiServerPort,  bool indiAutoConnect,  String alpacaServerHost,  int alpacaServerPort,  bool alpacaAutoDiscover,  bool useSimulationMode,  String imageOutputPath,  String observer,  String telescope,  String instrument,  bool updateCheckEnabled,  String updateServerUrl,  String updateChannel,  int updateCheckIntervalHours,  String skippedUpdateVersion,  SafetyFailMode safetyFailMode,  bool enableImageGrading,  double? imageGradingHfrThresholdPx,  double? imageGradingHfrBaselinePercent,  double? imageGradingEccentricityThreshold,  int? imageGradingStarCountMin,  int imageGradingMaxConsecutiveRejects,  String? imageGradingRejectFolderPath,  bool adaptiveExposureEnabled,  double adaptiveExposureTargetSnr,  double adaptiveExposureReferenceMag,  double adaptiveExposureMinSecs,  double adaptiveExposureMaxSecs,  Map<String, bool> adaptiveExposurePerFilterEnabled,  Map<String, double> adaptiveExposurePerFilterMinSecs,  Map<String, double> adaptiveExposurePerFilterMaxSecs,  bool parkOnUnsafeWeather,  bool autoFocusOnFilterChange,  bool afDisableGuidingDuringAf,  bool ditherEnabled,  String ditherScale,  double recoveryDefaultRetryIntervalMins,  double recoveryDefaultMaxDurationMins,  bool recoveryStopTrackingDuringRecovery,  bool recoveryAbortOnMeridian,  bool recoveryAudibleAlertWhenEntered,  bool parkBeforeDawn,  int cameraRetries,  int filterWheelRetries,  bool enableMeridianFlip,  bool tempCompensation,  double tempCoefficient,  int backlashCompensation,  double settleThreshold,  int settleTimeout,  int settleTime,  bool ditherRaOnly,  String plateSolver,  bool blindSolve,  bool centeringSyncMount,  int bortleClass,  double effectiveHorizonDeg,  String preflightStrictness,  int polarAlignmentMaxAgeDays,  double opticalTrainDriftThreshold,  int darkLibraryMinCoverage,  double? smartNightMaxSessionHours,  int smartNightDefaultAfCadenceFrames,  int smartNightDefaultIntegrationBudgetMinsPerTarget,  bool smartNightIncludeFlatsAtEnd,  bool smartNightUseSchedulerForMultiTarget,  int smartNightSchedulerTargetThreshold,  String smartNightDefaultStrategy,  int smartNightPolarAlignmentStaleAfterDays,  double smartNightSubExposureFloorSecs,  double smartNightSubExposureCeilingSecs,  double smartNightTargetSnr,  int defaultGain,  int defaultOffset,  bool webServerEnabled,  int webServerPort,  String phd2Path,  String phd2Host,  int phd2Port,  bool notificationsEnabled,  bool notifyOnSequenceComplete,  bool notifyOnError,  bool notifyOnMeridianFlip,  bool soundEnabled,  bool audibleAlertsOnCritical,  String criticalAlertSound,  bool pushCriticalAlerts,  bool smartNightAutoPromptEnabled,  bool promptForNotesAfterRun,  bool sessionHandoffAutoPrompt,  bool campaignRollupSurfaceTargetsTab,  String campaignRollupGroupingMode,  String afMethod,  String afCurveFitting,  int afStepSize,  double afExposureTime,  int afInitialOffsetSteps,  int afNumberOfAttempts,  int afUseBrightestNStars,  double afOuterCropRatio,  double afInnerCropRatio,  int afBinning,  double afRSquaredThreshold,  double afFailureHfrToleranceRatio,  int afFocuserSettleTimeMs,  int afExposuresPerPoint,  String afBacklashCompMethod,  int afBacklashIn,  String mountSiteSyncMode,  int afBacklashOut,  String afAutofocusFilterName,  String afFilterSettingsJson,  bool useFilterFocusOffsets,  String astrometryPath,  String observerName,  String imageFormat,  String bitDepth,  String timezone,  bool useSystemTime,  String sequencesPath,  bool smartNightAutoSelect,  int smartNightAutoSelectCount,  bool adaptiveSwapEnabledByDefault,  double adaptiveSwapDefaultThreshold,  double adaptiveSwapDefaultHysteresisSecs,  Map<String, double> conditionsScoreWeights)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _AppSettings() when $default != null:
return $default(_that.location,_that.theme,_that.language,_that.autoConnect,_that.latitude,_that.longitude,_that.elevation,_that.fileNamingPattern,_that.meridianFlipMinutes,_that.autoFocusEveryMinutes,_that.ditherEveryFrames,_that.plateSolveTimeout,_that.plateSolveSearchRadius,_that.discordWebhook,_that.pushoverKey,_that.pushoverUser,_that.astapPath,_that.autoDiscoverOnLaunch,_that.accentColor,_that.fontSize,_that.uiScale,_that.indiServerHost,_that.indiServerPort,_that.indiAutoConnect,_that.alpacaServerHost,_that.alpacaServerPort,_that.alpacaAutoDiscover,_that.useSimulationMode,_that.imageOutputPath,_that.observer,_that.telescope,_that.instrument,_that.updateCheckEnabled,_that.updateServerUrl,_that.updateChannel,_that.updateCheckIntervalHours,_that.skippedUpdateVersion,_that.safetyFailMode,_that.enableImageGrading,_that.imageGradingHfrThresholdPx,_that.imageGradingHfrBaselinePercent,_that.imageGradingEccentricityThreshold,_that.imageGradingStarCountMin,_that.imageGradingMaxConsecutiveRejects,_that.imageGradingRejectFolderPath,_that.adaptiveExposureEnabled,_that.adaptiveExposureTargetSnr,_that.adaptiveExposureReferenceMag,_that.adaptiveExposureMinSecs,_that.adaptiveExposureMaxSecs,_that.adaptiveExposurePerFilterEnabled,_that.adaptiveExposurePerFilterMinSecs,_that.adaptiveExposurePerFilterMaxSecs,_that.parkOnUnsafeWeather,_that.autoFocusOnFilterChange,_that.afDisableGuidingDuringAf,_that.ditherEnabled,_that.ditherScale,_that.recoveryDefaultRetryIntervalMins,_that.recoveryDefaultMaxDurationMins,_that.recoveryStopTrackingDuringRecovery,_that.recoveryAbortOnMeridian,_that.recoveryAudibleAlertWhenEntered,_that.parkBeforeDawn,_that.cameraRetries,_that.filterWheelRetries,_that.enableMeridianFlip,_that.tempCompensation,_that.tempCoefficient,_that.backlashCompensation,_that.settleThreshold,_that.settleTimeout,_that.settleTime,_that.ditherRaOnly,_that.plateSolver,_that.blindSolve,_that.centeringSyncMount,_that.bortleClass,_that.effectiveHorizonDeg,_that.preflightStrictness,_that.polarAlignmentMaxAgeDays,_that.opticalTrainDriftThreshold,_that.darkLibraryMinCoverage,_that.smartNightMaxSessionHours,_that.smartNightDefaultAfCadenceFrames,_that.smartNightDefaultIntegrationBudgetMinsPerTarget,_that.smartNightIncludeFlatsAtEnd,_that.smartNightUseSchedulerForMultiTarget,_that.smartNightSchedulerTargetThreshold,_that.smartNightDefaultStrategy,_that.smartNightPolarAlignmentStaleAfterDays,_that.smartNightSubExposureFloorSecs,_that.smartNightSubExposureCeilingSecs,_that.smartNightTargetSnr,_that.defaultGain,_that.defaultOffset,_that.webServerEnabled,_that.webServerPort,_that.phd2Path,_that.phd2Host,_that.phd2Port,_that.notificationsEnabled,_that.notifyOnSequenceComplete,_that.notifyOnError,_that.notifyOnMeridianFlip,_that.soundEnabled,_that.audibleAlertsOnCritical,_that.criticalAlertSound,_that.pushCriticalAlerts,_that.smartNightAutoPromptEnabled,_that.promptForNotesAfterRun,_that.sessionHandoffAutoPrompt,_that.campaignRollupSurfaceTargetsTab,_that.campaignRollupGroupingMode,_that.afMethod,_that.afCurveFitting,_that.afStepSize,_that.afExposureTime,_that.afInitialOffsetSteps,_that.afNumberOfAttempts,_that.afUseBrightestNStars,_that.afOuterCropRatio,_that.afInnerCropRatio,_that.afBinning,_that.afRSquaredThreshold,_that.afFailureHfrToleranceRatio,_that.afFocuserSettleTimeMs,_that.afExposuresPerPoint,_that.afBacklashCompMethod,_that.afBacklashIn,_that.mountSiteSyncMode,_that.afBacklashOut,_that.afAutofocusFilterName,_that.afFilterSettingsJson,_that.useFilterFocusOffsets,_that.astrometryPath,_that.observerName,_that.imageFormat,_that.bitDepth,_that.timezone,_that.useSystemTime,_that.sequencesPath,_that.smartNightAutoSelect,_that.smartNightAutoSelectCount,_that.adaptiveSwapEnabledByDefault,_that.adaptiveSwapDefaultThreshold,_that.adaptiveSwapDefaultHysteresisSecs,_that.conditionsScoreWeights);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( ObserverLocation? location,  String theme,  String language,  bool autoConnect,  double latitude,  double longitude,  double elevation,  String fileNamingPattern,  int meridianFlipMinutes,  int autoFocusEveryMinutes,  int ditherEveryFrames,  int plateSolveTimeout,  double plateSolveSearchRadius,  String discordWebhook,  String pushoverKey,  String pushoverUser,  String astapPath,  bool autoDiscoverOnLaunch,  String accentColor,  String fontSize,  String uiScale,  String indiServerHost,  int indiServerPort,  bool indiAutoConnect,  String alpacaServerHost,  int alpacaServerPort,  bool alpacaAutoDiscover,  bool useSimulationMode,  String imageOutputPath,  String observer,  String telescope,  String instrument,  bool updateCheckEnabled,  String updateServerUrl,  String updateChannel,  int updateCheckIntervalHours,  String skippedUpdateVersion,  SafetyFailMode safetyFailMode,  bool enableImageGrading,  double? imageGradingHfrThresholdPx,  double? imageGradingHfrBaselinePercent,  double? imageGradingEccentricityThreshold,  int? imageGradingStarCountMin,  int imageGradingMaxConsecutiveRejects,  String? imageGradingRejectFolderPath,  bool adaptiveExposureEnabled,  double adaptiveExposureTargetSnr,  double adaptiveExposureReferenceMag,  double adaptiveExposureMinSecs,  double adaptiveExposureMaxSecs,  Map<String, bool> adaptiveExposurePerFilterEnabled,  Map<String, double> adaptiveExposurePerFilterMinSecs,  Map<String, double> adaptiveExposurePerFilterMaxSecs,  bool parkOnUnsafeWeather,  bool autoFocusOnFilterChange,  bool afDisableGuidingDuringAf,  bool ditherEnabled,  String ditherScale,  double recoveryDefaultRetryIntervalMins,  double recoveryDefaultMaxDurationMins,  bool recoveryStopTrackingDuringRecovery,  bool recoveryAbortOnMeridian,  bool recoveryAudibleAlertWhenEntered,  bool parkBeforeDawn,  int cameraRetries,  int filterWheelRetries,  bool enableMeridianFlip,  bool tempCompensation,  double tempCoefficient,  int backlashCompensation,  double settleThreshold,  int settleTimeout,  int settleTime,  bool ditherRaOnly,  String plateSolver,  bool blindSolve,  bool centeringSyncMount,  int bortleClass,  double effectiveHorizonDeg,  String preflightStrictness,  int polarAlignmentMaxAgeDays,  double opticalTrainDriftThreshold,  int darkLibraryMinCoverage,  double? smartNightMaxSessionHours,  int smartNightDefaultAfCadenceFrames,  int smartNightDefaultIntegrationBudgetMinsPerTarget,  bool smartNightIncludeFlatsAtEnd,  bool smartNightUseSchedulerForMultiTarget,  int smartNightSchedulerTargetThreshold,  String smartNightDefaultStrategy,  int smartNightPolarAlignmentStaleAfterDays,  double smartNightSubExposureFloorSecs,  double smartNightSubExposureCeilingSecs,  double smartNightTargetSnr,  int defaultGain,  int defaultOffset,  bool webServerEnabled,  int webServerPort,  String phd2Path,  String phd2Host,  int phd2Port,  bool notificationsEnabled,  bool notifyOnSequenceComplete,  bool notifyOnError,  bool notifyOnMeridianFlip,  bool soundEnabled,  bool audibleAlertsOnCritical,  String criticalAlertSound,  bool pushCriticalAlerts,  bool smartNightAutoPromptEnabled,  bool promptForNotesAfterRun,  bool sessionHandoffAutoPrompt,  bool campaignRollupSurfaceTargetsTab,  String campaignRollupGroupingMode,  String afMethod,  String afCurveFitting,  int afStepSize,  double afExposureTime,  int afInitialOffsetSteps,  int afNumberOfAttempts,  int afUseBrightestNStars,  double afOuterCropRatio,  double afInnerCropRatio,  int afBinning,  double afRSquaredThreshold,  double afFailureHfrToleranceRatio,  int afFocuserSettleTimeMs,  int afExposuresPerPoint,  String afBacklashCompMethod,  int afBacklashIn,  String mountSiteSyncMode,  int afBacklashOut,  String afAutofocusFilterName,  String afFilterSettingsJson,  bool useFilterFocusOffsets,  String astrometryPath,  String observerName,  String imageFormat,  String bitDepth,  String timezone,  bool useSystemTime,  String sequencesPath,  bool smartNightAutoSelect,  int smartNightAutoSelectCount,  bool adaptiveSwapEnabledByDefault,  double adaptiveSwapDefaultThreshold,  double adaptiveSwapDefaultHysteresisSecs,  Map<String, double> conditionsScoreWeights)  $default,) {final _that = this;
switch (_that) {
case _AppSettings():
return $default(_that.location,_that.theme,_that.language,_that.autoConnect,_that.latitude,_that.longitude,_that.elevation,_that.fileNamingPattern,_that.meridianFlipMinutes,_that.autoFocusEveryMinutes,_that.ditherEveryFrames,_that.plateSolveTimeout,_that.plateSolveSearchRadius,_that.discordWebhook,_that.pushoverKey,_that.pushoverUser,_that.astapPath,_that.autoDiscoverOnLaunch,_that.accentColor,_that.fontSize,_that.uiScale,_that.indiServerHost,_that.indiServerPort,_that.indiAutoConnect,_that.alpacaServerHost,_that.alpacaServerPort,_that.alpacaAutoDiscover,_that.useSimulationMode,_that.imageOutputPath,_that.observer,_that.telescope,_that.instrument,_that.updateCheckEnabled,_that.updateServerUrl,_that.updateChannel,_that.updateCheckIntervalHours,_that.skippedUpdateVersion,_that.safetyFailMode,_that.enableImageGrading,_that.imageGradingHfrThresholdPx,_that.imageGradingHfrBaselinePercent,_that.imageGradingEccentricityThreshold,_that.imageGradingStarCountMin,_that.imageGradingMaxConsecutiveRejects,_that.imageGradingRejectFolderPath,_that.adaptiveExposureEnabled,_that.adaptiveExposureTargetSnr,_that.adaptiveExposureReferenceMag,_that.adaptiveExposureMinSecs,_that.adaptiveExposureMaxSecs,_that.adaptiveExposurePerFilterEnabled,_that.adaptiveExposurePerFilterMinSecs,_that.adaptiveExposurePerFilterMaxSecs,_that.parkOnUnsafeWeather,_that.autoFocusOnFilterChange,_that.afDisableGuidingDuringAf,_that.ditherEnabled,_that.ditherScale,_that.recoveryDefaultRetryIntervalMins,_that.recoveryDefaultMaxDurationMins,_that.recoveryStopTrackingDuringRecovery,_that.recoveryAbortOnMeridian,_that.recoveryAudibleAlertWhenEntered,_that.parkBeforeDawn,_that.cameraRetries,_that.filterWheelRetries,_that.enableMeridianFlip,_that.tempCompensation,_that.tempCoefficient,_that.backlashCompensation,_that.settleThreshold,_that.settleTimeout,_that.settleTime,_that.ditherRaOnly,_that.plateSolver,_that.blindSolve,_that.centeringSyncMount,_that.bortleClass,_that.effectiveHorizonDeg,_that.preflightStrictness,_that.polarAlignmentMaxAgeDays,_that.opticalTrainDriftThreshold,_that.darkLibraryMinCoverage,_that.smartNightMaxSessionHours,_that.smartNightDefaultAfCadenceFrames,_that.smartNightDefaultIntegrationBudgetMinsPerTarget,_that.smartNightIncludeFlatsAtEnd,_that.smartNightUseSchedulerForMultiTarget,_that.smartNightSchedulerTargetThreshold,_that.smartNightDefaultStrategy,_that.smartNightPolarAlignmentStaleAfterDays,_that.smartNightSubExposureFloorSecs,_that.smartNightSubExposureCeilingSecs,_that.smartNightTargetSnr,_that.defaultGain,_that.defaultOffset,_that.webServerEnabled,_that.webServerPort,_that.phd2Path,_that.phd2Host,_that.phd2Port,_that.notificationsEnabled,_that.notifyOnSequenceComplete,_that.notifyOnError,_that.notifyOnMeridianFlip,_that.soundEnabled,_that.audibleAlertsOnCritical,_that.criticalAlertSound,_that.pushCriticalAlerts,_that.smartNightAutoPromptEnabled,_that.promptForNotesAfterRun,_that.sessionHandoffAutoPrompt,_that.campaignRollupSurfaceTargetsTab,_that.campaignRollupGroupingMode,_that.afMethod,_that.afCurveFitting,_that.afStepSize,_that.afExposureTime,_that.afInitialOffsetSteps,_that.afNumberOfAttempts,_that.afUseBrightestNStars,_that.afOuterCropRatio,_that.afInnerCropRatio,_that.afBinning,_that.afRSquaredThreshold,_that.afFailureHfrToleranceRatio,_that.afFocuserSettleTimeMs,_that.afExposuresPerPoint,_that.afBacklashCompMethod,_that.afBacklashIn,_that.mountSiteSyncMode,_that.afBacklashOut,_that.afAutofocusFilterName,_that.afFilterSettingsJson,_that.useFilterFocusOffsets,_that.astrometryPath,_that.observerName,_that.imageFormat,_that.bitDepth,_that.timezone,_that.useSystemTime,_that.sequencesPath,_that.smartNightAutoSelect,_that.smartNightAutoSelectCount,_that.adaptiveSwapEnabledByDefault,_that.adaptiveSwapDefaultThreshold,_that.adaptiveSwapDefaultHysteresisSecs,_that.conditionsScoreWeights);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( ObserverLocation? location,  String theme,  String language,  bool autoConnect,  double latitude,  double longitude,  double elevation,  String fileNamingPattern,  int meridianFlipMinutes,  int autoFocusEveryMinutes,  int ditherEveryFrames,  int plateSolveTimeout,  double plateSolveSearchRadius,  String discordWebhook,  String pushoverKey,  String pushoverUser,  String astapPath,  bool autoDiscoverOnLaunch,  String accentColor,  String fontSize,  String uiScale,  String indiServerHost,  int indiServerPort,  bool indiAutoConnect,  String alpacaServerHost,  int alpacaServerPort,  bool alpacaAutoDiscover,  bool useSimulationMode,  String imageOutputPath,  String observer,  String telescope,  String instrument,  bool updateCheckEnabled,  String updateServerUrl,  String updateChannel,  int updateCheckIntervalHours,  String skippedUpdateVersion,  SafetyFailMode safetyFailMode,  bool enableImageGrading,  double? imageGradingHfrThresholdPx,  double? imageGradingHfrBaselinePercent,  double? imageGradingEccentricityThreshold,  int? imageGradingStarCountMin,  int imageGradingMaxConsecutiveRejects,  String? imageGradingRejectFolderPath,  bool adaptiveExposureEnabled,  double adaptiveExposureTargetSnr,  double adaptiveExposureReferenceMag,  double adaptiveExposureMinSecs,  double adaptiveExposureMaxSecs,  Map<String, bool> adaptiveExposurePerFilterEnabled,  Map<String, double> adaptiveExposurePerFilterMinSecs,  Map<String, double> adaptiveExposurePerFilterMaxSecs,  bool parkOnUnsafeWeather,  bool autoFocusOnFilterChange,  bool afDisableGuidingDuringAf,  bool ditherEnabled,  String ditherScale,  double recoveryDefaultRetryIntervalMins,  double recoveryDefaultMaxDurationMins,  bool recoveryStopTrackingDuringRecovery,  bool recoveryAbortOnMeridian,  bool recoveryAudibleAlertWhenEntered,  bool parkBeforeDawn,  int cameraRetries,  int filterWheelRetries,  bool enableMeridianFlip,  bool tempCompensation,  double tempCoefficient,  int backlashCompensation,  double settleThreshold,  int settleTimeout,  int settleTime,  bool ditherRaOnly,  String plateSolver,  bool blindSolve,  bool centeringSyncMount,  int bortleClass,  double effectiveHorizonDeg,  String preflightStrictness,  int polarAlignmentMaxAgeDays,  double opticalTrainDriftThreshold,  int darkLibraryMinCoverage,  double? smartNightMaxSessionHours,  int smartNightDefaultAfCadenceFrames,  int smartNightDefaultIntegrationBudgetMinsPerTarget,  bool smartNightIncludeFlatsAtEnd,  bool smartNightUseSchedulerForMultiTarget,  int smartNightSchedulerTargetThreshold,  String smartNightDefaultStrategy,  int smartNightPolarAlignmentStaleAfterDays,  double smartNightSubExposureFloorSecs,  double smartNightSubExposureCeilingSecs,  double smartNightTargetSnr,  int defaultGain,  int defaultOffset,  bool webServerEnabled,  int webServerPort,  String phd2Path,  String phd2Host,  int phd2Port,  bool notificationsEnabled,  bool notifyOnSequenceComplete,  bool notifyOnError,  bool notifyOnMeridianFlip,  bool soundEnabled,  bool audibleAlertsOnCritical,  String criticalAlertSound,  bool pushCriticalAlerts,  bool smartNightAutoPromptEnabled,  bool promptForNotesAfterRun,  bool sessionHandoffAutoPrompt,  bool campaignRollupSurfaceTargetsTab,  String campaignRollupGroupingMode,  String afMethod,  String afCurveFitting,  int afStepSize,  double afExposureTime,  int afInitialOffsetSteps,  int afNumberOfAttempts,  int afUseBrightestNStars,  double afOuterCropRatio,  double afInnerCropRatio,  int afBinning,  double afRSquaredThreshold,  double afFailureHfrToleranceRatio,  int afFocuserSettleTimeMs,  int afExposuresPerPoint,  String afBacklashCompMethod,  int afBacklashIn,  String mountSiteSyncMode,  int afBacklashOut,  String afAutofocusFilterName,  String afFilterSettingsJson,  bool useFilterFocusOffsets,  String astrometryPath,  String observerName,  String imageFormat,  String bitDepth,  String timezone,  bool useSystemTime,  String sequencesPath,  bool smartNightAutoSelect,  int smartNightAutoSelectCount,  bool adaptiveSwapEnabledByDefault,  double adaptiveSwapDefaultThreshold,  double adaptiveSwapDefaultHysteresisSecs,  Map<String, double> conditionsScoreWeights)?  $default,) {final _that = this;
switch (_that) {
case _AppSettings() when $default != null:
return $default(_that.location,_that.theme,_that.language,_that.autoConnect,_that.latitude,_that.longitude,_that.elevation,_that.fileNamingPattern,_that.meridianFlipMinutes,_that.autoFocusEveryMinutes,_that.ditherEveryFrames,_that.plateSolveTimeout,_that.plateSolveSearchRadius,_that.discordWebhook,_that.pushoverKey,_that.pushoverUser,_that.astapPath,_that.autoDiscoverOnLaunch,_that.accentColor,_that.fontSize,_that.uiScale,_that.indiServerHost,_that.indiServerPort,_that.indiAutoConnect,_that.alpacaServerHost,_that.alpacaServerPort,_that.alpacaAutoDiscover,_that.useSimulationMode,_that.imageOutputPath,_that.observer,_that.telescope,_that.instrument,_that.updateCheckEnabled,_that.updateServerUrl,_that.updateChannel,_that.updateCheckIntervalHours,_that.skippedUpdateVersion,_that.safetyFailMode,_that.enableImageGrading,_that.imageGradingHfrThresholdPx,_that.imageGradingHfrBaselinePercent,_that.imageGradingEccentricityThreshold,_that.imageGradingStarCountMin,_that.imageGradingMaxConsecutiveRejects,_that.imageGradingRejectFolderPath,_that.adaptiveExposureEnabled,_that.adaptiveExposureTargetSnr,_that.adaptiveExposureReferenceMag,_that.adaptiveExposureMinSecs,_that.adaptiveExposureMaxSecs,_that.adaptiveExposurePerFilterEnabled,_that.adaptiveExposurePerFilterMinSecs,_that.adaptiveExposurePerFilterMaxSecs,_that.parkOnUnsafeWeather,_that.autoFocusOnFilterChange,_that.afDisableGuidingDuringAf,_that.ditherEnabled,_that.ditherScale,_that.recoveryDefaultRetryIntervalMins,_that.recoveryDefaultMaxDurationMins,_that.recoveryStopTrackingDuringRecovery,_that.recoveryAbortOnMeridian,_that.recoveryAudibleAlertWhenEntered,_that.parkBeforeDawn,_that.cameraRetries,_that.filterWheelRetries,_that.enableMeridianFlip,_that.tempCompensation,_that.tempCoefficient,_that.backlashCompensation,_that.settleThreshold,_that.settleTimeout,_that.settleTime,_that.ditherRaOnly,_that.plateSolver,_that.blindSolve,_that.centeringSyncMount,_that.bortleClass,_that.effectiveHorizonDeg,_that.preflightStrictness,_that.polarAlignmentMaxAgeDays,_that.opticalTrainDriftThreshold,_that.darkLibraryMinCoverage,_that.smartNightMaxSessionHours,_that.smartNightDefaultAfCadenceFrames,_that.smartNightDefaultIntegrationBudgetMinsPerTarget,_that.smartNightIncludeFlatsAtEnd,_that.smartNightUseSchedulerForMultiTarget,_that.smartNightSchedulerTargetThreshold,_that.smartNightDefaultStrategy,_that.smartNightPolarAlignmentStaleAfterDays,_that.smartNightSubExposureFloorSecs,_that.smartNightSubExposureCeilingSecs,_that.smartNightTargetSnr,_that.defaultGain,_that.defaultOffset,_that.webServerEnabled,_that.webServerPort,_that.phd2Path,_that.phd2Host,_that.phd2Port,_that.notificationsEnabled,_that.notifyOnSequenceComplete,_that.notifyOnError,_that.notifyOnMeridianFlip,_that.soundEnabled,_that.audibleAlertsOnCritical,_that.criticalAlertSound,_that.pushCriticalAlerts,_that.smartNightAutoPromptEnabled,_that.promptForNotesAfterRun,_that.sessionHandoffAutoPrompt,_that.campaignRollupSurfaceTargetsTab,_that.campaignRollupGroupingMode,_that.afMethod,_that.afCurveFitting,_that.afStepSize,_that.afExposureTime,_that.afInitialOffsetSteps,_that.afNumberOfAttempts,_that.afUseBrightestNStars,_that.afOuterCropRatio,_that.afInnerCropRatio,_that.afBinning,_that.afRSquaredThreshold,_that.afFailureHfrToleranceRatio,_that.afFocuserSettleTimeMs,_that.afExposuresPerPoint,_that.afBacklashCompMethod,_that.afBacklashIn,_that.mountSiteSyncMode,_that.afBacklashOut,_that.afAutofocusFilterName,_that.afFilterSettingsJson,_that.useFilterFocusOffsets,_that.astrometryPath,_that.observerName,_that.imageFormat,_that.bitDepth,_that.timezone,_that.useSystemTime,_that.sequencesPath,_that.smartNightAutoSelect,_that.smartNightAutoSelectCount,_that.adaptiveSwapEnabledByDefault,_that.adaptiveSwapDefaultThreshold,_that.adaptiveSwapDefaultHysteresisSecs,_that.conditionsScoreWeights);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _AppSettings implements AppSettings {
  const _AppSettings({this.location, this.theme = 'dark', this.language = 'en', this.autoConnect = true, this.latitude = 0.0, this.longitude = 0.0, this.elevation = 0.0, this.fileNamingPattern = '', this.meridianFlipMinutes = 5, this.autoFocusEveryMinutes = 60, this.ditherEveryFrames = 3, this.plateSolveTimeout = 60, this.plateSolveSearchRadius = 30.0, this.discordWebhook = '', this.pushoverKey = '', this.pushoverUser = '', this.astapPath = '', this.autoDiscoverOnLaunch = true, this.accentColor = '', this.fontSize = 'Medium', this.uiScale = 'Auto', this.indiServerHost = 'localhost', this.indiServerPort = 7624, this.indiAutoConnect = false, this.alpacaServerHost = 'localhost', this.alpacaServerPort = 11111, this.alpacaAutoDiscover = false, this.useSimulationMode = false, this.imageOutputPath = '', this.observer = '', this.telescope = '', this.instrument = '', this.updateCheckEnabled = true, this.updateServerUrl = '', this.updateChannel = 'stable', this.updateCheckIntervalHours = 24, this.skippedUpdateVersion = '', this.safetyFailMode = SafetyFailMode.failClosed, this.enableImageGrading = false, this.imageGradingHfrThresholdPx, this.imageGradingHfrBaselinePercent, this.imageGradingEccentricityThreshold, this.imageGradingStarCountMin, this.imageGradingMaxConsecutiveRejects = 3, this.imageGradingRejectFolderPath, this.adaptiveExposureEnabled = false, this.adaptiveExposureTargetSnr = 30.0, this.adaptiveExposureReferenceMag = 21.5, this.adaptiveExposureMinSecs = 5.0, this.adaptiveExposureMaxSecs = 600.0, final  Map<String, bool> adaptiveExposurePerFilterEnabled = const <String, bool>{}, final  Map<String, double> adaptiveExposurePerFilterMinSecs = const <String, double>{}, final  Map<String, double> adaptiveExposurePerFilterMaxSecs = const <String, double>{}, this.parkOnUnsafeWeather = true, this.autoFocusOnFilterChange = false, this.afDisableGuidingDuringAf = false, this.ditherEnabled = true, this.ditherScale = 'Medium', this.recoveryDefaultRetryIntervalMins = 10.0, this.recoveryDefaultMaxDurationMins = 90.0, this.recoveryStopTrackingDuringRecovery = true, this.recoveryAbortOnMeridian = true, this.recoveryAudibleAlertWhenEntered = true, this.parkBeforeDawn = true, this.cameraRetries = 3, this.filterWheelRetries = 3, this.enableMeridianFlip = true, this.tempCompensation = false, this.tempCoefficient = -12.0, this.backlashCompensation = 0, this.settleThreshold = 1.5, this.settleTimeout = 60, this.settleTime = 10, this.ditherRaOnly = false, this.plateSolver = 'ASTAP', this.blindSolve = false, this.centeringSyncMount = true, this.bortleClass = 5, this.effectiveHorizonDeg = 0.0, this.preflightStrictness = 'normal', this.polarAlignmentMaxAgeDays = 7, this.opticalTrainDriftThreshold = 8.0, this.darkLibraryMinCoverage = 10, this.smartNightMaxSessionHours, this.smartNightDefaultAfCadenceFrames = 25, this.smartNightDefaultIntegrationBudgetMinsPerTarget = 240, this.smartNightIncludeFlatsAtEnd = true, this.smartNightUseSchedulerForMultiTarget = true, this.smartNightSchedulerTargetThreshold = 3, this.smartNightDefaultStrategy = 'auto_lrgb', this.smartNightPolarAlignmentStaleAfterDays = 7, this.smartNightSubExposureFloorSecs = 30.0, this.smartNightSubExposureCeilingSecs = 300.0, this.smartNightTargetSnr = 30.0, this.defaultGain = 100, this.defaultOffset = 50, this.webServerEnabled = false, this.webServerPort = 8080, this.phd2Path = '', this.phd2Host = 'localhost', this.phd2Port = 4400, this.notificationsEnabled = true, this.notifyOnSequenceComplete = true, this.notifyOnError = true, this.notifyOnMeridianFlip = false, this.soundEnabled = true, this.audibleAlertsOnCritical = false, this.criticalAlertSound = 'systemBell', this.pushCriticalAlerts = true, this.smartNightAutoPromptEnabled = true, this.promptForNotesAfterRun = true, this.sessionHandoffAutoPrompt = true, this.campaignRollupSurfaceTargetsTab = true, this.campaignRollupGroupingMode = 'by_target_name', this.afMethod = 'Star HFR', this.afCurveFitting = 'Hyperbolic', this.afStepSize = 50, this.afExposureTime = 4.0, this.afInitialOffsetSteps = 4, this.afNumberOfAttempts = 1, this.afUseBrightestNStars = 10, this.afOuterCropRatio = 1.0, this.afInnerCropRatio = 0.0, this.afBinning = 1, this.afRSquaredThreshold = 0.7, this.afFailureHfrToleranceRatio = 1.6, this.afFocuserSettleTimeMs = 500, this.afExposuresPerPoint = 1, this.afBacklashCompMethod = 'Overshoot', this.afBacklashIn = 0, this.mountSiteSyncMode = 'ask', this.afBacklashOut = 0, this.afAutofocusFilterName = '', this.afFilterSettingsJson = '{}', this.useFilterFocusOffsets = true, this.astrometryPath = '', this.observerName = '', this.imageFormat = 'FITS', this.bitDepth = '16-bit', this.timezone = 'UTC', this.useSystemTime = true, this.sequencesPath = '', this.smartNightAutoSelect = true, this.smartNightAutoSelectCount = 2, this.adaptiveSwapEnabledByDefault = false, this.adaptiveSwapDefaultThreshold = 50.0, this.adaptiveSwapDefaultHysteresisSecs = 180.0, final  Map<String, double> conditionsScoreWeights = const <String, double>{'transparency' : 0.40, 'seeing' : 0.25, 'cloud' : 0.25, 'wind' : 0.10}}): _adaptiveExposurePerFilterEnabled = adaptiveExposurePerFilterEnabled,_adaptiveExposurePerFilterMinSecs = adaptiveExposurePerFilterMinSecs,_adaptiveExposurePerFilterMaxSecs = adaptiveExposurePerFilterMaxSecs,_conditionsScoreWeights = conditionsScoreWeights;
  factory _AppSettings.fromJson(Map<String, dynamic> json) => _$AppSettingsFromJson(json);

@override final  ObserverLocation? location;
@override@JsonKey() final  String theme;
@override@JsonKey() final  String language;
@override@JsonKey() final  bool autoConnect;
// Additional fields for compatibility with provider AppSettings
@override@JsonKey() final  double latitude;
@override@JsonKey() final  double longitude;
@override@JsonKey() final  double elevation;
@override@JsonKey() final  String fileNamingPattern;
@override@JsonKey() final  int meridianFlipMinutes;
@override@JsonKey() final  int autoFocusEveryMinutes;
@override@JsonKey() final  int ditherEveryFrames;
@override@JsonKey() final  int plateSolveTimeout;
@override@JsonKey() final  double plateSolveSearchRadius;
@override@JsonKey() final  String discordWebhook;
@override@JsonKey() final  String pushoverKey;
@override@JsonKey() final  String pushoverUser;
@override@JsonKey() final  String astapPath;
// Discovery settings
@override@JsonKey() final  bool autoDiscoverOnLaunch;
@override@JsonKey() final  String accentColor;
@override@JsonKey() final  String fontSize;
@override@JsonKey() final  String uiScale;
// Auto, Small (0.8x), Normal (1.0x), Large (1.2x), Extra Large (1.4x)
// Protocol settings
@override@JsonKey() final  String indiServerHost;
@override@JsonKey() final  int indiServerPort;
@override@JsonKey() final  bool indiAutoConnect;
@override@JsonKey() final  String alpacaServerHost;
@override@JsonKey() final  int alpacaServerPort;
@override@JsonKey() final  bool alpacaAutoDiscover;
// Retired: simulation mode is not a shippable runtime state (the bundled
// native library is always a release build and refuses it). The field
// stays so stored and remote payloads that still carry it decode; nothing
// reads it.
@override@JsonKey() final  bool useSimulationMode;
// Image capture settings
@override@JsonKey() final  String imageOutputPath;
@override@JsonKey() final  String observer;
@override@JsonKey() final  String telescope;
@override@JsonKey() final  String instrument;
// Update settings
@override@JsonKey() final  bool updateCheckEnabled;
@override@JsonKey() final  String updateServerUrl;
@override@JsonKey() final  String updateChannel;
@override@JsonKey() final  int updateCheckIntervalHours;
@override@JsonKey() final  String skippedUpdateVersion;
// Safety settings
@override@JsonKey() final  SafetyFailMode safetyFailMode;
// Image grading: live frame Pass/Reject thresholds. Opt-in — disabled by
// default, so every captured frame is saved and none auto-rejected.
/// Master switch: when false, no grading runs at all.
@override@JsonKey() final  bool enableImageGrading;
/// Reject if HFR exceeds this absolute pixel value. `null` => don't
/// apply the absolute check.
@override final  double? imageGradingHfrThresholdPx;
/// Reject if HFR exceeds `baseline * (1 + percent / 100)`. `null` =>
/// don't apply the baseline-relative check.
@override final  double? imageGradingHfrBaselinePercent;
/// Reject if star eccentricity exceeds this value. `null` => don't apply.
@override final  double? imageGradingEccentricityThreshold;
/// Reject if detected star count falls below this. `null` => don't apply.
@override final  int? imageGradingStarCountMin;
/// Notify the operator once when this many frames in a row are rejected
/// (default 3). The run carries on.
@override@JsonKey() final  int imageGradingMaxConsecutiveRejects;
/// Override for the reject folder. `null` => use `<save_path>/Reject/`.
/// Relative paths resolve against the run save_path; absolute paths
/// are used verbatim.
@override final  String? imageGradingRejectFolderPath;
// Sky-brightness adaptive exposures: global defaults, pushed into the
// executor via `sequencerUpdateDefaultAdaptiveExposure` when no active
// node carries its own block. Per-ExposureNode overrides win at runtime.
/// Master switch — when false, the global default adaptive-exposure
/// is cleared and the executor falls back to nominal duration for
/// any node without an explicit per-node override.
@override@JsonKey() final  bool adaptiveExposureEnabled;
/// Target SNR for the SNR-based scaling (informational; the live
/// math uses background flux ratio).
@override@JsonKey() final  double adaptiveExposureTargetSnr;
/// Reference sky brightness in mag/arcsec² the nominal exposure
/// duration was calibrated for. Dark-site default is 21.5.
@override@JsonKey() final  double adaptiveExposureReferenceMag;
/// Global minimum exposure clamp in seconds.
@override@JsonKey() final  double adaptiveExposureMinSecs;
/// Global maximum exposure clamp in seconds.
@override@JsonKey() final  double adaptiveExposureMaxSecs;
/// Per-filter enable map (filter name -> bool). Empty => apply
/// globally (matches the Rust `is_enabled_for_filter` semantics).
 final  Map<String, bool> _adaptiveExposurePerFilterEnabled;
/// Per-filter enable map (filter name -> bool). Empty => apply
/// globally (matches the Rust `is_enabled_for_filter` semantics).
@override@JsonKey() Map<String, bool> get adaptiveExposurePerFilterEnabled {
  if (_adaptiveExposurePerFilterEnabled is EqualUnmodifiableMapView) return _adaptiveExposurePerFilterEnabled;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_adaptiveExposurePerFilterEnabled);
}

/// Per-filter minimum exposure overrides (seconds).
 final  Map<String, double> _adaptiveExposurePerFilterMinSecs;
/// Per-filter minimum exposure overrides (seconds).
@override@JsonKey() Map<String, double> get adaptiveExposurePerFilterMinSecs {
  if (_adaptiveExposurePerFilterMinSecs is EqualUnmodifiableMapView) return _adaptiveExposurePerFilterMinSecs;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_adaptiveExposurePerFilterMinSecs);
}

/// Per-filter maximum exposure overrides (seconds).
 final  Map<String, double> _adaptiveExposurePerFilterMaxSecs;
/// Per-filter maximum exposure overrides (seconds).
@override@JsonKey() Map<String, double> get adaptiveExposurePerFilterMaxSecs {
  if (_adaptiveExposurePerFilterMaxSecs is EqualUnmodifiableMapView) return _adaptiveExposurePerFilterMaxSecs;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_adaptiveExposurePerFilterMaxSecs);
}

// Autofocus / dither / weather-safety / recovery knobs an operator tunes
// for an unattended night.
/// Weather-safety: when true, the rig parks (not just pauses) when weather
/// turns unsafe. Mirrors `app_settings` DB key `park_on_unsafe_weather`.
@override@JsonKey() final  bool parkOnUnsafeWeather;
/// Autofocus: run an autofocus pass on every filter change.
/// DB key `auto_focus_on_filter_change`.
@override@JsonKey() final  bool autoFocusOnFilterChange;
/// Autofocus: disable the guider while an autofocus sweep runs (avoids the
/// guide star wandering out of frame during the focuser sweep).
/// DB key `af_disable_guiding`.
@override@JsonKey() final  bool afDisableGuidingDuringAf;
/// Dither: master enable for between-frame dithering.
/// DB key `dither_enabled`.
@override@JsonKey() final  bool ditherEnabled;
/// Dither: dither step size — 'Small', 'Medium', or 'Large'.
/// DB key `dither_scale`.
@override@JsonKey() final  String ditherScale;
/// Recovery: minutes between auto-retry attempts during a recovery loop.
/// DB key `recovery_default_retry_interval_mins`.
@override@JsonKey() final  double recoveryDefaultRetryIntervalMins;
/// Recovery: total minutes before the recovery loop gives up.
/// DB key `recovery_default_max_duration_mins`.
@override@JsonKey() final  double recoveryDefaultMaxDurationMins;
/// Recovery: stop tracking while recovering (dew/cloud wait).
/// DB key `recovery_stop_tracking_during_recovery`.
@override@JsonKey() final  bool recoveryStopTrackingDuringRecovery;
/// Recovery: abort the recovery loop if a meridian crossing falls inside
/// the recovery window. DB key `recovery_abort_on_meridian`.
@override@JsonKey() final  bool recoveryAbortOnMeridian;
/// Recovery: ring the platform alert sound on recovery entry.
/// DB key `recovery_audible_alert_when_entered`.
@override@JsonKey() final  bool recoveryAudibleAlertWhenEntered;
// Weather-safety / dawn.
/// Park the mount before astronomical dawn at the end of the night.
/// DB key `park_before_dawn`.
@override@JsonKey() final  bool parkBeforeDawn;
// Device retries.
/// Times a failed camera exposure is retried before it counts as a
/// failure (0 = one attempt). DB key `camera_retries`.
@override@JsonKey() final  int cameraRetries;
/// Times a failed filter-wheel move is retried before it counts as a
/// failure (0 = one attempt). DB key `filter_wheel_retries`.
@override@JsonKey() final  int filterWheelRetries;
// Meridian flip detail.
/// Master enable for automatic meridian flips. DB key `enable_meridian_flip`.
@override@JsonKey() final  bool enableMeridianFlip;
// Focuser temperature compensation + backlash (calibration).
/// Enable focuser temperature compensation. DB key `temp_compensation`.
@override@JsonKey() final  bool tempCompensation;
/// Temp-comp coefficient (steps per °C). DB key `temp_coefficient`.
@override@JsonKey() final  double tempCoefficient;
/// Focuser backlash compensation (steps). DB key `backlash_compensation`.
@override@JsonKey() final  int backlashCompensation;
// Guider settle (calibration).
/// Guider settle pixel threshold. DB key `settle_threshold`. Default mirrors
/// the NINA/PHD2 community convention (~1.5 px); 0.5 px at typical guide
/// scales makes every dither settle slowly or time out.
@override@JsonKey() final  double settleThreshold;
/// Guider settle timeout in seconds. DB key `settle_timeout`. Generous so
/// a legitimate settle is not aborted early.
@override@JsonKey() final  int settleTimeout;
/// Guider settle stabilisation time in seconds — how long the guide error
/// must stay within [settleThreshold] before a settle is declared done.
/// DB key `settle_time`.
@override@JsonKey() final  int settleTime;
/// Dither on the RA axis only, leaving Dec fixed. DB key `dither_ra_only`.
@override@JsonKey() final  bool ditherRaOnly;
// Plate-solving extra.
/// Selected plate solver ('ASTAP', 'Astrometry.net', 'PlateSolve2').
/// DB key `plate_solver`.
@override@JsonKey() final  String plateSolver;
/// Allow a blind (no-hint) solve fallback. DB key `blind_solve`.
@override@JsonKey() final  bool blindSolve;
/// Sync the mount to the plate-solved position between centering
/// iterations. Without the sync the correction re-issues the slew that
/// produced the mis-pointed frame, so centering cannot converge.
/// DB key `centering_sync_mount`.
@override@JsonKey() final  bool centeringSyncMount;
// Site / horizon.
/// Bortle dark-sky class (1-9). DB key `bortle_class`.
@override@JsonKey() final  int bortleClass;
/// Effective horizon altitude floor in degrees. DB key `effective_horizon_deg`.
@override@JsonKey() final  double effectiveHorizonDeg;
// Pre-flight checklist strictness + freshness gates.
/// Pre-flight strictness as the enum name ('lax' / 'normal' / 'strict').
/// Carried as a String to avoid the wire model depending on the provider
/// library that owns the `PreflightStrictness` enum. DB key
/// `preflight_strictness`.
@override@JsonKey() final  String preflightStrictness;
/// Polar-alignment max age (days) before pre-flight flags it.
/// DB key `polar_alignment_max_age_days`.
@override@JsonKey() final  int polarAlignmentMaxAgeDays;
/// Optical-train drift threshold (arcmin) before pre-flight flags it.
/// DB key `optical_train_drift_threshold`.
@override@JsonKey() final  double opticalTrainDriftThreshold;
// Dark library.
/// Minimum matching dark frames before the dark library is "covered".
/// DB key `dark_library_min_coverage`.
@override@JsonKey() final  int darkLibraryMinCoverage;
// Smart Night defaults — the one-click "plan tonight" builder reads these
// when assembling a sequence.
/// Cap a planned session to this many hours. `null` => use the full dark
/// window. DB key `smart_night_max_session_hours`.
@override final  double? smartNightMaxSessionHours;
/// Default autofocus cadence (frames) for built sequences.
/// DB key `smart_night_default_af_cadence_frames`.
@override@JsonKey() final  int smartNightDefaultAfCadenceFrames;
/// Default per-target integration budget (minutes).
/// DB key `smart_night_default_integration_budget_mins_per_target`.
@override@JsonKey() final  int smartNightDefaultIntegrationBudgetMinsPerTarget;
/// Append flats at the end of the planned night.
/// DB key `smart_night_include_flats_at_end`.
@override@JsonKey() final  bool smartNightIncludeFlatsAtEnd;
/// Use the scheduler (vs a single linear sequence) for multi-target nights.
/// DB key `smart_night_use_scheduler_for_multi_target`.
@override@JsonKey() final  bool smartNightUseSchedulerForMultiTarget;
/// Target count at/above which the scheduler is used.
/// DB key `smart_night_scheduler_target_threshold`.
@override@JsonKey() final  int smartNightSchedulerTargetThreshold;
/// Default capture strategy id (e.g. 'auto_lrgb').
/// DB key `smart_night_default_strategy`.
@override@JsonKey() final  String smartNightDefaultStrategy;
/// Days after which polar alignment is considered stale for the wizard.
/// DB key `smart_night_polar_alignment_stale_after_days`.
@override@JsonKey() final  int smartNightPolarAlignmentStaleAfterDays;
/// Sub-exposure floor (seconds) for the planner.
/// DB key `smart_night_sub_exposure_floor_secs`.
@override@JsonKey() final  double smartNightSubExposureFloorSecs;
/// Sub-exposure ceiling (seconds) for the planner.
/// DB key `smart_night_sub_exposure_ceiling_secs`.
@override@JsonKey() final  double smartNightSubExposureCeilingSecs;
/// Target SNR the planner sizes sub-exposures toward.
/// DB key `smart_night_target_snr`.
@override@JsonKey() final  double smartNightTargetSnr;
// Defaults from here down mirror AppSettingsState's constructor defaults,
// so the wire model never injects a different value than local state.
// Equipment defaults (camera).
/// Default camera gain. DB `default_gain`.
@override@JsonKey() final  int defaultGain;
/// Default camera offset. DB `default_offset`.
@override@JsonKey() final  int defaultOffset;
// Remote access / web server.
/// Headless web server enabled. DB `web_server_enabled`.
@override@JsonKey() final  bool webServerEnabled;
/// Headless web server port. DB `web_server_port`.
@override@JsonKey() final  int webServerPort;
// PHD2 connection.
/// PHD2 executable path. DB `phd2_path`.
@override@JsonKey() final  String phd2Path;
/// PHD2 host. DB `phd2_host`.
@override@JsonKey() final  String phd2Host;
/// PHD2 port. DB `phd2_port`.
@override@JsonKey() final  int phd2Port;
// Notification toggles.
/// Master notifications switch. DB `notifications_enabled`.
@override@JsonKey() final  bool notificationsEnabled;
/// Notify when a sequence completes. DB `notify_on_sequence_complete`.
@override@JsonKey() final  bool notifyOnSequenceComplete;
/// Notify on error. DB `notify_on_error`.
@override@JsonKey() final  bool notifyOnError;
/// Notify on meridian flip. DB `notify_on_meridian_flip`.
@override@JsonKey() final  bool notifyOnMeridianFlip;
/// In-app notification sound. DB `sound_enabled`.
@override@JsonKey() final  bool soundEnabled;
/// Ring the platform alert on critical-severity events. DB
/// `audible_alerts_on_critical`.
@override@JsonKey() final  bool audibleAlertsOnCritical;
/// Which sound for critical alerts ('systemBell' / 'none'). DB
/// `critical_alert_sound`.
@override@JsonKey() final  String criticalAlertSound;
/// Forward critical alerts to paired phones as push. DB `push_critical_alerts`.
@override@JsonKey() final  bool pushCriticalAlerts;
// Session-lifecycle + campaign-rollup prefs.
/// Show the Smart-Night auto-prompt when equipment is ready. DB
/// `smart_night.auto_prompt_enabled`.
@override@JsonKey() final  bool smartNightAutoPromptEnabled;
/// Prompt for notes after a run. DB `notes.prompt_after_run`.
@override@JsonKey() final  bool promptForNotesAfterRun;
/// Auto-open the multi-night carry-over banner. DB
/// `session.handoff_auto_prompt`.
@override@JsonKey() final  bool sessionHandoffAutoPrompt;
/// Surface the campaign-rollup column on the Targets tab. DB
/// `campaign_rollup.surface_targets_tab`.
@override@JsonKey() final  bool campaignRollupSurfaceTargetsTab;
/// Campaign-rollup grouping mode. DB `campaign_rollup.grouping_mode`.
@override@JsonKey() final  String campaignRollupGroupingMode;
// Autofocus detailed sweep params.
/// AF method. DB `af_method`.
@override@JsonKey() final  String afMethod;
/// AF curve fitting. DB `af_curve_fitting`.
@override@JsonKey() final  String afCurveFitting;
/// AF step size between measurement points. DB `af_step_size`.
@override@JsonKey() final  int afStepSize;
/// AF exposure time (seconds). DB `af_exposure_time`.
@override@JsonKey() final  double afExposureTime;
/// AF initial offset steps out from center. DB `af_initial_offset_steps`.
@override@JsonKey() final  int afInitialOffsetSteps;
/// AF retry count on failure. DB `af_number_of_attempts`.
@override@JsonKey() final  int afNumberOfAttempts;
/// AF brightest-N stars (0 = all). DB `af_use_brightest_n_stars`.
/// On by default: counting every detection lets faint, noisy sources
/// swamp the measurement.
@override@JsonKey() final  int afUseBrightestNStars;
/// AF outer crop ratio. DB `af_outer_crop_ratio`.
@override@JsonKey() final  double afOuterCropRatio;
/// AF inner crop ratio. DB `af_inner_crop_ratio`.
@override@JsonKey() final  double afInnerCropRatio;
/// AF binning. DB `af_binning`.
@override@JsonKey() final  int afBinning;
/// AF R² fit-quality threshold. DB `af_r_squared_threshold`.
@override@JsonKey() final  double afRSquaredThreshold;
/// How far above the reference HFR the frames may sit, as a multiple, and
/// still be worth capturing after autofocus has failed.
/// DB `af_failure_hfr_tolerance_ratio`.
///
/// A failed autofocus never parks the rig or ends the run: the focuser
/// goes back where it was, the operator is notified and imaging carries
/// on. This ratio decides what the notice says about the frames: at 1.6
/// a run whose good HFR is 2.5 is told frames at 3.8 are slightly soft
/// and frames at 10 are past the limit.
@override@JsonKey() final  double afFailureHfrToleranceRatio;
/// AF focuser settle time (ms). DB `af_focuser_settle_time_ms`.
@override@JsonKey() final  int afFocuserSettleTimeMs;
/// AF exposures per measurement point. DB `af_exposures_per_point`.
@override@JsonKey() final  int afExposuresPerPoint;
/// AF backlash compensation method. DB `af_backlash_comp_method`.
@override@JsonKey() final  String afBacklashCompMethod;
/// AF backlash-in steps. DB `af_backlash_in`.
@override@JsonKey() final  int afBacklashIn;
/// What to do when a connected mount's site/time disagrees with this
/// computer's. DB `mount_site_sync_mode`.
@override@JsonKey() final  String mountSiteSyncMode;
/// AF backlash-out steps. DB `af_backlash_out`.
@override@JsonKey() final  int afBacklashOut;
/// Designated AF filter (empty = current). DB `af_autofocus_filter_name`.
@override@JsonKey() final  String afAutofocusFilterName;
/// Per-filter AF config JSON map. DB `af_filter_settings`.
@override@JsonKey() final  String afFilterSettingsJson;
/// Apply focus offsets on filter change. DB `use_filter_focus_offsets`.
@override@JsonKey() final  bool useFilterFocusOffsets;
// Misc imaging / FITS / plate-solve config relevant to an unattended night.
/// Astrometry.net solver path. DB `astrometry_path`.
@override@JsonKey() final  String astrometryPath;
/// FITS OBSERVER keyword. DB `observer_name`.
@override@JsonKey() final  String observerName;
/// Image format ('FITS' / 'XISF' / 'TIFF'). DB `image_format`.
@override@JsonKey() final  String imageFormat;
/// Bit depth ('16-bit' / '32-bit'). DB `bit_depth`.
@override@JsonKey() final  String bitDepth;
/// Observing timezone. DB `timezone`.
@override@JsonKey() final  String timezone;
/// Use system time vs a fixed observing time. DB `use_system_time`.
@override@JsonKey() final  bool useSystemTime;
// Sequencer output path default.
/// User-facing default output directory for saved sequence files. DB
/// key `sequences_path`.
@override@JsonKey() final  String sequencesPath;
// Smart Night target auto-select (the rest of the smart_night.* group
// is already remoted).
/// Auto-select the top-N targets when building a Smart Night plan. DB
/// key `smart_night.auto_select`.
@override@JsonKey() final  bool smartNightAutoSelect;
/// How many targets to auto-select when [smartNightAutoSelect] is true.
/// DB key `smart_night.auto_select_count`.
@override@JsonKey() final  int smartNightAutoSelectCount;
// Adaptive sky-conditions target-swap scheduler-SEED defaults. These
// pre-fill a new TargetSchedulerNode; the score weights feed the live
// ConditionsScore composer (weather_safety_provider). DB keys under
// `adaptive_swap.*`.
/// New schedulers ship with adaptive swap enabled by default. DB key
/// `adaptive_swap.enabled_by_default`.
@override@JsonKey() final  bool adaptiveSwapEnabledByDefault;
/// Default conditions-score floor (0..=100) seeded into a new scheduler.
/// DB key `adaptive_swap.default_threshold`.
@override@JsonKey() final  double adaptiveSwapDefaultThreshold;
/// Default seconds between consecutive swaps seeded into a new scheduler.
/// DB key `adaptive_swap.default_hysteresis_secs`.
@override@JsonKey() final  double adaptiveSwapDefaultHysteresisSecs;
/// Per-axis composer weights for the live ConditionsScore. Keys:
/// `transparency` / `seeing` / `cloud` / `wind`. DB key
/// `adaptive_swap.score_weights` (a JSON object).
 final  Map<String, double> _conditionsScoreWeights;
/// Per-axis composer weights for the live ConditionsScore. Keys:
/// `transparency` / `seeing` / `cloud` / `wind`. DB key
/// `adaptive_swap.score_weights` (a JSON object).
@override@JsonKey() Map<String, double> get conditionsScoreWeights {
  if (_conditionsScoreWeights is EqualUnmodifiableMapView) return _conditionsScoreWeights;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_conditionsScoreWeights);
}


/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$AppSettingsCopyWith<_AppSettings> get copyWith => __$AppSettingsCopyWithImpl<_AppSettings>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AppSettingsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _AppSettings&&(identical(other.location, location) || other.location == location)&&(identical(other.theme, theme) || other.theme == theme)&&(identical(other.language, language) || other.language == language)&&(identical(other.autoConnect, autoConnect) || other.autoConnect == autoConnect)&&(identical(other.latitude, latitude) || other.latitude == latitude)&&(identical(other.longitude, longitude) || other.longitude == longitude)&&(identical(other.elevation, elevation) || other.elevation == elevation)&&(identical(other.fileNamingPattern, fileNamingPattern) || other.fileNamingPattern == fileNamingPattern)&&(identical(other.meridianFlipMinutes, meridianFlipMinutes) || other.meridianFlipMinutes == meridianFlipMinutes)&&(identical(other.autoFocusEveryMinutes, autoFocusEveryMinutes) || other.autoFocusEveryMinutes == autoFocusEveryMinutes)&&(identical(other.ditherEveryFrames, ditherEveryFrames) || other.ditherEveryFrames == ditherEveryFrames)&&(identical(other.plateSolveTimeout, plateSolveTimeout) || other.plateSolveTimeout == plateSolveTimeout)&&(identical(other.plateSolveSearchRadius, plateSolveSearchRadius) || other.plateSolveSearchRadius == plateSolveSearchRadius)&&(identical(other.discordWebhook, discordWebhook) || other.discordWebhook == discordWebhook)&&(identical(other.pushoverKey, pushoverKey) || other.pushoverKey == pushoverKey)&&(identical(other.pushoverUser, pushoverUser) || other.pushoverUser == pushoverUser)&&(identical(other.astapPath, astapPath) || other.astapPath == astapPath)&&(identical(other.autoDiscoverOnLaunch, autoDiscoverOnLaunch) || other.autoDiscoverOnLaunch == autoDiscoverOnLaunch)&&(identical(other.accentColor, accentColor) || other.accentColor == accentColor)&&(identical(other.fontSize, fontSize) || other.fontSize == fontSize)&&(identical(other.uiScale, uiScale) || other.uiScale == uiScale)&&(identical(other.indiServerHost, indiServerHost) || other.indiServerHost == indiServerHost)&&(identical(other.indiServerPort, indiServerPort) || other.indiServerPort == indiServerPort)&&(identical(other.indiAutoConnect, indiAutoConnect) || other.indiAutoConnect == indiAutoConnect)&&(identical(other.alpacaServerHost, alpacaServerHost) || other.alpacaServerHost == alpacaServerHost)&&(identical(other.alpacaServerPort, alpacaServerPort) || other.alpacaServerPort == alpacaServerPort)&&(identical(other.alpacaAutoDiscover, alpacaAutoDiscover) || other.alpacaAutoDiscover == alpacaAutoDiscover)&&(identical(other.useSimulationMode, useSimulationMode) || other.useSimulationMode == useSimulationMode)&&(identical(other.imageOutputPath, imageOutputPath) || other.imageOutputPath == imageOutputPath)&&(identical(other.observer, observer) || other.observer == observer)&&(identical(other.telescope, telescope) || other.telescope == telescope)&&(identical(other.instrument, instrument) || other.instrument == instrument)&&(identical(other.updateCheckEnabled, updateCheckEnabled) || other.updateCheckEnabled == updateCheckEnabled)&&(identical(other.updateServerUrl, updateServerUrl) || other.updateServerUrl == updateServerUrl)&&(identical(other.updateChannel, updateChannel) || other.updateChannel == updateChannel)&&(identical(other.updateCheckIntervalHours, updateCheckIntervalHours) || other.updateCheckIntervalHours == updateCheckIntervalHours)&&(identical(other.skippedUpdateVersion, skippedUpdateVersion) || other.skippedUpdateVersion == skippedUpdateVersion)&&(identical(other.safetyFailMode, safetyFailMode) || other.safetyFailMode == safetyFailMode)&&(identical(other.enableImageGrading, enableImageGrading) || other.enableImageGrading == enableImageGrading)&&(identical(other.imageGradingHfrThresholdPx, imageGradingHfrThresholdPx) || other.imageGradingHfrThresholdPx == imageGradingHfrThresholdPx)&&(identical(other.imageGradingHfrBaselinePercent, imageGradingHfrBaselinePercent) || other.imageGradingHfrBaselinePercent == imageGradingHfrBaselinePercent)&&(identical(other.imageGradingEccentricityThreshold, imageGradingEccentricityThreshold) || other.imageGradingEccentricityThreshold == imageGradingEccentricityThreshold)&&(identical(other.imageGradingStarCountMin, imageGradingStarCountMin) || other.imageGradingStarCountMin == imageGradingStarCountMin)&&(identical(other.imageGradingMaxConsecutiveRejects, imageGradingMaxConsecutiveRejects) || other.imageGradingMaxConsecutiveRejects == imageGradingMaxConsecutiveRejects)&&(identical(other.imageGradingRejectFolderPath, imageGradingRejectFolderPath) || other.imageGradingRejectFolderPath == imageGradingRejectFolderPath)&&(identical(other.adaptiveExposureEnabled, adaptiveExposureEnabled) || other.adaptiveExposureEnabled == adaptiveExposureEnabled)&&(identical(other.adaptiveExposureTargetSnr, adaptiveExposureTargetSnr) || other.adaptiveExposureTargetSnr == adaptiveExposureTargetSnr)&&(identical(other.adaptiveExposureReferenceMag, adaptiveExposureReferenceMag) || other.adaptiveExposureReferenceMag == adaptiveExposureReferenceMag)&&(identical(other.adaptiveExposureMinSecs, adaptiveExposureMinSecs) || other.adaptiveExposureMinSecs == adaptiveExposureMinSecs)&&(identical(other.adaptiveExposureMaxSecs, adaptiveExposureMaxSecs) || other.adaptiveExposureMaxSecs == adaptiveExposureMaxSecs)&&const DeepCollectionEquality().equals(other._adaptiveExposurePerFilterEnabled, _adaptiveExposurePerFilterEnabled)&&const DeepCollectionEquality().equals(other._adaptiveExposurePerFilterMinSecs, _adaptiveExposurePerFilterMinSecs)&&const DeepCollectionEquality().equals(other._adaptiveExposurePerFilterMaxSecs, _adaptiveExposurePerFilterMaxSecs)&&(identical(other.parkOnUnsafeWeather, parkOnUnsafeWeather) || other.parkOnUnsafeWeather == parkOnUnsafeWeather)&&(identical(other.autoFocusOnFilterChange, autoFocusOnFilterChange) || other.autoFocusOnFilterChange == autoFocusOnFilterChange)&&(identical(other.afDisableGuidingDuringAf, afDisableGuidingDuringAf) || other.afDisableGuidingDuringAf == afDisableGuidingDuringAf)&&(identical(other.ditherEnabled, ditherEnabled) || other.ditherEnabled == ditherEnabled)&&(identical(other.ditherScale, ditherScale) || other.ditherScale == ditherScale)&&(identical(other.recoveryDefaultRetryIntervalMins, recoveryDefaultRetryIntervalMins) || other.recoveryDefaultRetryIntervalMins == recoveryDefaultRetryIntervalMins)&&(identical(other.recoveryDefaultMaxDurationMins, recoveryDefaultMaxDurationMins) || other.recoveryDefaultMaxDurationMins == recoveryDefaultMaxDurationMins)&&(identical(other.recoveryStopTrackingDuringRecovery, recoveryStopTrackingDuringRecovery) || other.recoveryStopTrackingDuringRecovery == recoveryStopTrackingDuringRecovery)&&(identical(other.recoveryAbortOnMeridian, recoveryAbortOnMeridian) || other.recoveryAbortOnMeridian == recoveryAbortOnMeridian)&&(identical(other.recoveryAudibleAlertWhenEntered, recoveryAudibleAlertWhenEntered) || other.recoveryAudibleAlertWhenEntered == recoveryAudibleAlertWhenEntered)&&(identical(other.parkBeforeDawn, parkBeforeDawn) || other.parkBeforeDawn == parkBeforeDawn)&&(identical(other.cameraRetries, cameraRetries) || other.cameraRetries == cameraRetries)&&(identical(other.filterWheelRetries, filterWheelRetries) || other.filterWheelRetries == filterWheelRetries)&&(identical(other.enableMeridianFlip, enableMeridianFlip) || other.enableMeridianFlip == enableMeridianFlip)&&(identical(other.tempCompensation, tempCompensation) || other.tempCompensation == tempCompensation)&&(identical(other.tempCoefficient, tempCoefficient) || other.tempCoefficient == tempCoefficient)&&(identical(other.backlashCompensation, backlashCompensation) || other.backlashCompensation == backlashCompensation)&&(identical(other.settleThreshold, settleThreshold) || other.settleThreshold == settleThreshold)&&(identical(other.settleTimeout, settleTimeout) || other.settleTimeout == settleTimeout)&&(identical(other.settleTime, settleTime) || other.settleTime == settleTime)&&(identical(other.ditherRaOnly, ditherRaOnly) || other.ditherRaOnly == ditherRaOnly)&&(identical(other.plateSolver, plateSolver) || other.plateSolver == plateSolver)&&(identical(other.blindSolve, blindSolve) || other.blindSolve == blindSolve)&&(identical(other.centeringSyncMount, centeringSyncMount) || other.centeringSyncMount == centeringSyncMount)&&(identical(other.bortleClass, bortleClass) || other.bortleClass == bortleClass)&&(identical(other.effectiveHorizonDeg, effectiveHorizonDeg) || other.effectiveHorizonDeg == effectiveHorizonDeg)&&(identical(other.preflightStrictness, preflightStrictness) || other.preflightStrictness == preflightStrictness)&&(identical(other.polarAlignmentMaxAgeDays, polarAlignmentMaxAgeDays) || other.polarAlignmentMaxAgeDays == polarAlignmentMaxAgeDays)&&(identical(other.opticalTrainDriftThreshold, opticalTrainDriftThreshold) || other.opticalTrainDriftThreshold == opticalTrainDriftThreshold)&&(identical(other.darkLibraryMinCoverage, darkLibraryMinCoverage) || other.darkLibraryMinCoverage == darkLibraryMinCoverage)&&(identical(other.smartNightMaxSessionHours, smartNightMaxSessionHours) || other.smartNightMaxSessionHours == smartNightMaxSessionHours)&&(identical(other.smartNightDefaultAfCadenceFrames, smartNightDefaultAfCadenceFrames) || other.smartNightDefaultAfCadenceFrames == smartNightDefaultAfCadenceFrames)&&(identical(other.smartNightDefaultIntegrationBudgetMinsPerTarget, smartNightDefaultIntegrationBudgetMinsPerTarget) || other.smartNightDefaultIntegrationBudgetMinsPerTarget == smartNightDefaultIntegrationBudgetMinsPerTarget)&&(identical(other.smartNightIncludeFlatsAtEnd, smartNightIncludeFlatsAtEnd) || other.smartNightIncludeFlatsAtEnd == smartNightIncludeFlatsAtEnd)&&(identical(other.smartNightUseSchedulerForMultiTarget, smartNightUseSchedulerForMultiTarget) || other.smartNightUseSchedulerForMultiTarget == smartNightUseSchedulerForMultiTarget)&&(identical(other.smartNightSchedulerTargetThreshold, smartNightSchedulerTargetThreshold) || other.smartNightSchedulerTargetThreshold == smartNightSchedulerTargetThreshold)&&(identical(other.smartNightDefaultStrategy, smartNightDefaultStrategy) || other.smartNightDefaultStrategy == smartNightDefaultStrategy)&&(identical(other.smartNightPolarAlignmentStaleAfterDays, smartNightPolarAlignmentStaleAfterDays) || other.smartNightPolarAlignmentStaleAfterDays == smartNightPolarAlignmentStaleAfterDays)&&(identical(other.smartNightSubExposureFloorSecs, smartNightSubExposureFloorSecs) || other.smartNightSubExposureFloorSecs == smartNightSubExposureFloorSecs)&&(identical(other.smartNightSubExposureCeilingSecs, smartNightSubExposureCeilingSecs) || other.smartNightSubExposureCeilingSecs == smartNightSubExposureCeilingSecs)&&(identical(other.smartNightTargetSnr, smartNightTargetSnr) || other.smartNightTargetSnr == smartNightTargetSnr)&&(identical(other.defaultGain, defaultGain) || other.defaultGain == defaultGain)&&(identical(other.defaultOffset, defaultOffset) || other.defaultOffset == defaultOffset)&&(identical(other.webServerEnabled, webServerEnabled) || other.webServerEnabled == webServerEnabled)&&(identical(other.webServerPort, webServerPort) || other.webServerPort == webServerPort)&&(identical(other.phd2Path, phd2Path) || other.phd2Path == phd2Path)&&(identical(other.phd2Host, phd2Host) || other.phd2Host == phd2Host)&&(identical(other.phd2Port, phd2Port) || other.phd2Port == phd2Port)&&(identical(other.notificationsEnabled, notificationsEnabled) || other.notificationsEnabled == notificationsEnabled)&&(identical(other.notifyOnSequenceComplete, notifyOnSequenceComplete) || other.notifyOnSequenceComplete == notifyOnSequenceComplete)&&(identical(other.notifyOnError, notifyOnError) || other.notifyOnError == notifyOnError)&&(identical(other.notifyOnMeridianFlip, notifyOnMeridianFlip) || other.notifyOnMeridianFlip == notifyOnMeridianFlip)&&(identical(other.soundEnabled, soundEnabled) || other.soundEnabled == soundEnabled)&&(identical(other.audibleAlertsOnCritical, audibleAlertsOnCritical) || other.audibleAlertsOnCritical == audibleAlertsOnCritical)&&(identical(other.criticalAlertSound, criticalAlertSound) || other.criticalAlertSound == criticalAlertSound)&&(identical(other.pushCriticalAlerts, pushCriticalAlerts) || other.pushCriticalAlerts == pushCriticalAlerts)&&(identical(other.smartNightAutoPromptEnabled, smartNightAutoPromptEnabled) || other.smartNightAutoPromptEnabled == smartNightAutoPromptEnabled)&&(identical(other.promptForNotesAfterRun, promptForNotesAfterRun) || other.promptForNotesAfterRun == promptForNotesAfterRun)&&(identical(other.sessionHandoffAutoPrompt, sessionHandoffAutoPrompt) || other.sessionHandoffAutoPrompt == sessionHandoffAutoPrompt)&&(identical(other.campaignRollupSurfaceTargetsTab, campaignRollupSurfaceTargetsTab) || other.campaignRollupSurfaceTargetsTab == campaignRollupSurfaceTargetsTab)&&(identical(other.campaignRollupGroupingMode, campaignRollupGroupingMode) || other.campaignRollupGroupingMode == campaignRollupGroupingMode)&&(identical(other.afMethod, afMethod) || other.afMethod == afMethod)&&(identical(other.afCurveFitting, afCurveFitting) || other.afCurveFitting == afCurveFitting)&&(identical(other.afStepSize, afStepSize) || other.afStepSize == afStepSize)&&(identical(other.afExposureTime, afExposureTime) || other.afExposureTime == afExposureTime)&&(identical(other.afInitialOffsetSteps, afInitialOffsetSteps) || other.afInitialOffsetSteps == afInitialOffsetSteps)&&(identical(other.afNumberOfAttempts, afNumberOfAttempts) || other.afNumberOfAttempts == afNumberOfAttempts)&&(identical(other.afUseBrightestNStars, afUseBrightestNStars) || other.afUseBrightestNStars == afUseBrightestNStars)&&(identical(other.afOuterCropRatio, afOuterCropRatio) || other.afOuterCropRatio == afOuterCropRatio)&&(identical(other.afInnerCropRatio, afInnerCropRatio) || other.afInnerCropRatio == afInnerCropRatio)&&(identical(other.afBinning, afBinning) || other.afBinning == afBinning)&&(identical(other.afRSquaredThreshold, afRSquaredThreshold) || other.afRSquaredThreshold == afRSquaredThreshold)&&(identical(other.afFailureHfrToleranceRatio, afFailureHfrToleranceRatio) || other.afFailureHfrToleranceRatio == afFailureHfrToleranceRatio)&&(identical(other.afFocuserSettleTimeMs, afFocuserSettleTimeMs) || other.afFocuserSettleTimeMs == afFocuserSettleTimeMs)&&(identical(other.afExposuresPerPoint, afExposuresPerPoint) || other.afExposuresPerPoint == afExposuresPerPoint)&&(identical(other.afBacklashCompMethod, afBacklashCompMethod) || other.afBacklashCompMethod == afBacklashCompMethod)&&(identical(other.afBacklashIn, afBacklashIn) || other.afBacklashIn == afBacklashIn)&&(identical(other.mountSiteSyncMode, mountSiteSyncMode) || other.mountSiteSyncMode == mountSiteSyncMode)&&(identical(other.afBacklashOut, afBacklashOut) || other.afBacklashOut == afBacklashOut)&&(identical(other.afAutofocusFilterName, afAutofocusFilterName) || other.afAutofocusFilterName == afAutofocusFilterName)&&(identical(other.afFilterSettingsJson, afFilterSettingsJson) || other.afFilterSettingsJson == afFilterSettingsJson)&&(identical(other.useFilterFocusOffsets, useFilterFocusOffsets) || other.useFilterFocusOffsets == useFilterFocusOffsets)&&(identical(other.astrometryPath, astrometryPath) || other.astrometryPath == astrometryPath)&&(identical(other.observerName, observerName) || other.observerName == observerName)&&(identical(other.imageFormat, imageFormat) || other.imageFormat == imageFormat)&&(identical(other.bitDepth, bitDepth) || other.bitDepth == bitDepth)&&(identical(other.timezone, timezone) || other.timezone == timezone)&&(identical(other.useSystemTime, useSystemTime) || other.useSystemTime == useSystemTime)&&(identical(other.sequencesPath, sequencesPath) || other.sequencesPath == sequencesPath)&&(identical(other.smartNightAutoSelect, smartNightAutoSelect) || other.smartNightAutoSelect == smartNightAutoSelect)&&(identical(other.smartNightAutoSelectCount, smartNightAutoSelectCount) || other.smartNightAutoSelectCount == smartNightAutoSelectCount)&&(identical(other.adaptiveSwapEnabledByDefault, adaptiveSwapEnabledByDefault) || other.adaptiveSwapEnabledByDefault == adaptiveSwapEnabledByDefault)&&(identical(other.adaptiveSwapDefaultThreshold, adaptiveSwapDefaultThreshold) || other.adaptiveSwapDefaultThreshold == adaptiveSwapDefaultThreshold)&&(identical(other.adaptiveSwapDefaultHysteresisSecs, adaptiveSwapDefaultHysteresisSecs) || other.adaptiveSwapDefaultHysteresisSecs == adaptiveSwapDefaultHysteresisSecs)&&const DeepCollectionEquality().equals(other._conditionsScoreWeights, _conditionsScoreWeights));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,location,theme,language,autoConnect,latitude,longitude,elevation,fileNamingPattern,meridianFlipMinutes,autoFocusEveryMinutes,ditherEveryFrames,plateSolveTimeout,plateSolveSearchRadius,discordWebhook,pushoverKey,pushoverUser,astapPath,autoDiscoverOnLaunch,accentColor,fontSize,uiScale,indiServerHost,indiServerPort,indiAutoConnect,alpacaServerHost,alpacaServerPort,alpacaAutoDiscover,useSimulationMode,imageOutputPath,observer,telescope,instrument,updateCheckEnabled,updateServerUrl,updateChannel,updateCheckIntervalHours,skippedUpdateVersion,safetyFailMode,enableImageGrading,imageGradingHfrThresholdPx,imageGradingHfrBaselinePercent,imageGradingEccentricityThreshold,imageGradingStarCountMin,imageGradingMaxConsecutiveRejects,imageGradingRejectFolderPath,adaptiveExposureEnabled,adaptiveExposureTargetSnr,adaptiveExposureReferenceMag,adaptiveExposureMinSecs,adaptiveExposureMaxSecs,const DeepCollectionEquality().hash(_adaptiveExposurePerFilterEnabled),const DeepCollectionEquality().hash(_adaptiveExposurePerFilterMinSecs),const DeepCollectionEquality().hash(_adaptiveExposurePerFilterMaxSecs),parkOnUnsafeWeather,autoFocusOnFilterChange,afDisableGuidingDuringAf,ditherEnabled,ditherScale,recoveryDefaultRetryIntervalMins,recoveryDefaultMaxDurationMins,recoveryStopTrackingDuringRecovery,recoveryAbortOnMeridian,recoveryAudibleAlertWhenEntered,parkBeforeDawn,cameraRetries,filterWheelRetries,enableMeridianFlip,tempCompensation,tempCoefficient,backlashCompensation,settleThreshold,settleTimeout,settleTime,ditherRaOnly,plateSolver,blindSolve,centeringSyncMount,bortleClass,effectiveHorizonDeg,preflightStrictness,polarAlignmentMaxAgeDays,opticalTrainDriftThreshold,darkLibraryMinCoverage,smartNightMaxSessionHours,smartNightDefaultAfCadenceFrames,smartNightDefaultIntegrationBudgetMinsPerTarget,smartNightIncludeFlatsAtEnd,smartNightUseSchedulerForMultiTarget,smartNightSchedulerTargetThreshold,smartNightDefaultStrategy,smartNightPolarAlignmentStaleAfterDays,smartNightSubExposureFloorSecs,smartNightSubExposureCeilingSecs,smartNightTargetSnr,defaultGain,defaultOffset,webServerEnabled,webServerPort,phd2Path,phd2Host,phd2Port,notificationsEnabled,notifyOnSequenceComplete,notifyOnError,notifyOnMeridianFlip,soundEnabled,audibleAlertsOnCritical,criticalAlertSound,pushCriticalAlerts,smartNightAutoPromptEnabled,promptForNotesAfterRun,sessionHandoffAutoPrompt,campaignRollupSurfaceTargetsTab,campaignRollupGroupingMode,afMethod,afCurveFitting,afStepSize,afExposureTime,afInitialOffsetSteps,afNumberOfAttempts,afUseBrightestNStars,afOuterCropRatio,afInnerCropRatio,afBinning,afRSquaredThreshold,afFailureHfrToleranceRatio,afFocuserSettleTimeMs,afExposuresPerPoint,afBacklashCompMethod,afBacklashIn,mountSiteSyncMode,afBacklashOut,afAutofocusFilterName,afFilterSettingsJson,useFilterFocusOffsets,astrometryPath,observerName,imageFormat,bitDepth,timezone,useSystemTime,sequencesPath,smartNightAutoSelect,smartNightAutoSelectCount,adaptiveSwapEnabledByDefault,adaptiveSwapDefaultThreshold,adaptiveSwapDefaultHysteresisSecs,const DeepCollectionEquality().hash(_conditionsScoreWeights)]);

@override
String toString() {
  return 'AppSettings(location: $location, theme: $theme, language: $language, autoConnect: $autoConnect, latitude: $latitude, longitude: $longitude, elevation: $elevation, fileNamingPattern: $fileNamingPattern, meridianFlipMinutes: $meridianFlipMinutes, autoFocusEveryMinutes: $autoFocusEveryMinutes, ditherEveryFrames: $ditherEveryFrames, plateSolveTimeout: $plateSolveTimeout, plateSolveSearchRadius: $plateSolveSearchRadius, discordWebhook: $discordWebhook, pushoverKey: $pushoverKey, pushoverUser: $pushoverUser, astapPath: $astapPath, autoDiscoverOnLaunch: $autoDiscoverOnLaunch, accentColor: $accentColor, fontSize: $fontSize, uiScale: $uiScale, indiServerHost: $indiServerHost, indiServerPort: $indiServerPort, indiAutoConnect: $indiAutoConnect, alpacaServerHost: $alpacaServerHost, alpacaServerPort: $alpacaServerPort, alpacaAutoDiscover: $alpacaAutoDiscover, useSimulationMode: $useSimulationMode, imageOutputPath: $imageOutputPath, observer: $observer, telescope: $telescope, instrument: $instrument, updateCheckEnabled: $updateCheckEnabled, updateServerUrl: $updateServerUrl, updateChannel: $updateChannel, updateCheckIntervalHours: $updateCheckIntervalHours, skippedUpdateVersion: $skippedUpdateVersion, safetyFailMode: $safetyFailMode, enableImageGrading: $enableImageGrading, imageGradingHfrThresholdPx: $imageGradingHfrThresholdPx, imageGradingHfrBaselinePercent: $imageGradingHfrBaselinePercent, imageGradingEccentricityThreshold: $imageGradingEccentricityThreshold, imageGradingStarCountMin: $imageGradingStarCountMin, imageGradingMaxConsecutiveRejects: $imageGradingMaxConsecutiveRejects, imageGradingRejectFolderPath: $imageGradingRejectFolderPath, adaptiveExposureEnabled: $adaptiveExposureEnabled, adaptiveExposureTargetSnr: $adaptiveExposureTargetSnr, adaptiveExposureReferenceMag: $adaptiveExposureReferenceMag, adaptiveExposureMinSecs: $adaptiveExposureMinSecs, adaptiveExposureMaxSecs: $adaptiveExposureMaxSecs, adaptiveExposurePerFilterEnabled: $adaptiveExposurePerFilterEnabled, adaptiveExposurePerFilterMinSecs: $adaptiveExposurePerFilterMinSecs, adaptiveExposurePerFilterMaxSecs: $adaptiveExposurePerFilterMaxSecs, parkOnUnsafeWeather: $parkOnUnsafeWeather, autoFocusOnFilterChange: $autoFocusOnFilterChange, afDisableGuidingDuringAf: $afDisableGuidingDuringAf, ditherEnabled: $ditherEnabled, ditherScale: $ditherScale, recoveryDefaultRetryIntervalMins: $recoveryDefaultRetryIntervalMins, recoveryDefaultMaxDurationMins: $recoveryDefaultMaxDurationMins, recoveryStopTrackingDuringRecovery: $recoveryStopTrackingDuringRecovery, recoveryAbortOnMeridian: $recoveryAbortOnMeridian, recoveryAudibleAlertWhenEntered: $recoveryAudibleAlertWhenEntered, parkBeforeDawn: $parkBeforeDawn, cameraRetries: $cameraRetries, filterWheelRetries: $filterWheelRetries, enableMeridianFlip: $enableMeridianFlip, tempCompensation: $tempCompensation, tempCoefficient: $tempCoefficient, backlashCompensation: $backlashCompensation, settleThreshold: $settleThreshold, settleTimeout: $settleTimeout, settleTime: $settleTime, ditherRaOnly: $ditherRaOnly, plateSolver: $plateSolver, blindSolve: $blindSolve, centeringSyncMount: $centeringSyncMount, bortleClass: $bortleClass, effectiveHorizonDeg: $effectiveHorizonDeg, preflightStrictness: $preflightStrictness, polarAlignmentMaxAgeDays: $polarAlignmentMaxAgeDays, opticalTrainDriftThreshold: $opticalTrainDriftThreshold, darkLibraryMinCoverage: $darkLibraryMinCoverage, smartNightMaxSessionHours: $smartNightMaxSessionHours, smartNightDefaultAfCadenceFrames: $smartNightDefaultAfCadenceFrames, smartNightDefaultIntegrationBudgetMinsPerTarget: $smartNightDefaultIntegrationBudgetMinsPerTarget, smartNightIncludeFlatsAtEnd: $smartNightIncludeFlatsAtEnd, smartNightUseSchedulerForMultiTarget: $smartNightUseSchedulerForMultiTarget, smartNightSchedulerTargetThreshold: $smartNightSchedulerTargetThreshold, smartNightDefaultStrategy: $smartNightDefaultStrategy, smartNightPolarAlignmentStaleAfterDays: $smartNightPolarAlignmentStaleAfterDays, smartNightSubExposureFloorSecs: $smartNightSubExposureFloorSecs, smartNightSubExposureCeilingSecs: $smartNightSubExposureCeilingSecs, smartNightTargetSnr: $smartNightTargetSnr, defaultGain: $defaultGain, defaultOffset: $defaultOffset, webServerEnabled: $webServerEnabled, webServerPort: $webServerPort, phd2Path: $phd2Path, phd2Host: $phd2Host, phd2Port: $phd2Port, notificationsEnabled: $notificationsEnabled, notifyOnSequenceComplete: $notifyOnSequenceComplete, notifyOnError: $notifyOnError, notifyOnMeridianFlip: $notifyOnMeridianFlip, soundEnabled: $soundEnabled, audibleAlertsOnCritical: $audibleAlertsOnCritical, criticalAlertSound: $criticalAlertSound, pushCriticalAlerts: $pushCriticalAlerts, smartNightAutoPromptEnabled: $smartNightAutoPromptEnabled, promptForNotesAfterRun: $promptForNotesAfterRun, sessionHandoffAutoPrompt: $sessionHandoffAutoPrompt, campaignRollupSurfaceTargetsTab: $campaignRollupSurfaceTargetsTab, campaignRollupGroupingMode: $campaignRollupGroupingMode, afMethod: $afMethod, afCurveFitting: $afCurveFitting, afStepSize: $afStepSize, afExposureTime: $afExposureTime, afInitialOffsetSteps: $afInitialOffsetSteps, afNumberOfAttempts: $afNumberOfAttempts, afUseBrightestNStars: $afUseBrightestNStars, afOuterCropRatio: $afOuterCropRatio, afInnerCropRatio: $afInnerCropRatio, afBinning: $afBinning, afRSquaredThreshold: $afRSquaredThreshold, afFailureHfrToleranceRatio: $afFailureHfrToleranceRatio, afFocuserSettleTimeMs: $afFocuserSettleTimeMs, afExposuresPerPoint: $afExposuresPerPoint, afBacklashCompMethod: $afBacklashCompMethod, afBacklashIn: $afBacklashIn, mountSiteSyncMode: $mountSiteSyncMode, afBacklashOut: $afBacklashOut, afAutofocusFilterName: $afAutofocusFilterName, afFilterSettingsJson: $afFilterSettingsJson, useFilterFocusOffsets: $useFilterFocusOffsets, astrometryPath: $astrometryPath, observerName: $observerName, imageFormat: $imageFormat, bitDepth: $bitDepth, timezone: $timezone, useSystemTime: $useSystemTime, sequencesPath: $sequencesPath, smartNightAutoSelect: $smartNightAutoSelect, smartNightAutoSelectCount: $smartNightAutoSelectCount, adaptiveSwapEnabledByDefault: $adaptiveSwapEnabledByDefault, adaptiveSwapDefaultThreshold: $adaptiveSwapDefaultThreshold, adaptiveSwapDefaultHysteresisSecs: $adaptiveSwapDefaultHysteresisSecs, conditionsScoreWeights: $conditionsScoreWeights)';
}


}

/// @nodoc
abstract mixin class _$AppSettingsCopyWith<$Res> implements $AppSettingsCopyWith<$Res> {
  factory _$AppSettingsCopyWith(_AppSettings value, $Res Function(_AppSettings) _then) = __$AppSettingsCopyWithImpl;
@override @useResult
$Res call({
 ObserverLocation? location, String theme, String language, bool autoConnect, double latitude, double longitude, double elevation, String fileNamingPattern, int meridianFlipMinutes, int autoFocusEveryMinutes, int ditherEveryFrames, int plateSolveTimeout, double plateSolveSearchRadius, String discordWebhook, String pushoverKey, String pushoverUser, String astapPath, bool autoDiscoverOnLaunch, String accentColor, String fontSize, String uiScale, String indiServerHost, int indiServerPort, bool indiAutoConnect, String alpacaServerHost, int alpacaServerPort, bool alpacaAutoDiscover, bool useSimulationMode, String imageOutputPath, String observer, String telescope, String instrument, bool updateCheckEnabled, String updateServerUrl, String updateChannel, int updateCheckIntervalHours, String skippedUpdateVersion, SafetyFailMode safetyFailMode, bool enableImageGrading, double? imageGradingHfrThresholdPx, double? imageGradingHfrBaselinePercent, double? imageGradingEccentricityThreshold, int? imageGradingStarCountMin, int imageGradingMaxConsecutiveRejects, String? imageGradingRejectFolderPath, bool adaptiveExposureEnabled, double adaptiveExposureTargetSnr, double adaptiveExposureReferenceMag, double adaptiveExposureMinSecs, double adaptiveExposureMaxSecs, Map<String, bool> adaptiveExposurePerFilterEnabled, Map<String, double> adaptiveExposurePerFilterMinSecs, Map<String, double> adaptiveExposurePerFilterMaxSecs, bool parkOnUnsafeWeather, bool autoFocusOnFilterChange, bool afDisableGuidingDuringAf, bool ditherEnabled, String ditherScale, double recoveryDefaultRetryIntervalMins, double recoveryDefaultMaxDurationMins, bool recoveryStopTrackingDuringRecovery, bool recoveryAbortOnMeridian, bool recoveryAudibleAlertWhenEntered, bool parkBeforeDawn, int cameraRetries, int filterWheelRetries, bool enableMeridianFlip, bool tempCompensation, double tempCoefficient, int backlashCompensation, double settleThreshold, int settleTimeout, int settleTime, bool ditherRaOnly, String plateSolver, bool blindSolve, bool centeringSyncMount, int bortleClass, double effectiveHorizonDeg, String preflightStrictness, int polarAlignmentMaxAgeDays, double opticalTrainDriftThreshold, int darkLibraryMinCoverage, double? smartNightMaxSessionHours, int smartNightDefaultAfCadenceFrames, int smartNightDefaultIntegrationBudgetMinsPerTarget, bool smartNightIncludeFlatsAtEnd, bool smartNightUseSchedulerForMultiTarget, int smartNightSchedulerTargetThreshold, String smartNightDefaultStrategy, int smartNightPolarAlignmentStaleAfterDays, double smartNightSubExposureFloorSecs, double smartNightSubExposureCeilingSecs, double smartNightTargetSnr, int defaultGain, int defaultOffset, bool webServerEnabled, int webServerPort, String phd2Path, String phd2Host, int phd2Port, bool notificationsEnabled, bool notifyOnSequenceComplete, bool notifyOnError, bool notifyOnMeridianFlip, bool soundEnabled, bool audibleAlertsOnCritical, String criticalAlertSound, bool pushCriticalAlerts, bool smartNightAutoPromptEnabled, bool promptForNotesAfterRun, bool sessionHandoffAutoPrompt, bool campaignRollupSurfaceTargetsTab, String campaignRollupGroupingMode, String afMethod, String afCurveFitting, int afStepSize, double afExposureTime, int afInitialOffsetSteps, int afNumberOfAttempts, int afUseBrightestNStars, double afOuterCropRatio, double afInnerCropRatio, int afBinning, double afRSquaredThreshold, double afFailureHfrToleranceRatio, int afFocuserSettleTimeMs, int afExposuresPerPoint, String afBacklashCompMethod, int afBacklashIn, String mountSiteSyncMode, int afBacklashOut, String afAutofocusFilterName, String afFilterSettingsJson, bool useFilterFocusOffsets, String astrometryPath, String observerName, String imageFormat, String bitDepth, String timezone, bool useSystemTime, String sequencesPath, bool smartNightAutoSelect, int smartNightAutoSelectCount, bool adaptiveSwapEnabledByDefault, double adaptiveSwapDefaultThreshold, double adaptiveSwapDefaultHysteresisSecs, Map<String, double> conditionsScoreWeights
});


@override $ObserverLocationCopyWith<$Res>? get location;

}
/// @nodoc
class __$AppSettingsCopyWithImpl<$Res>
    implements _$AppSettingsCopyWith<$Res> {
  __$AppSettingsCopyWithImpl(this._self, this._then);

  final _AppSettings _self;
  final $Res Function(_AppSettings) _then;

/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? location = freezed,Object? theme = null,Object? language = null,Object? autoConnect = null,Object? latitude = null,Object? longitude = null,Object? elevation = null,Object? fileNamingPattern = null,Object? meridianFlipMinutes = null,Object? autoFocusEveryMinutes = null,Object? ditherEveryFrames = null,Object? plateSolveTimeout = null,Object? plateSolveSearchRadius = null,Object? discordWebhook = null,Object? pushoverKey = null,Object? pushoverUser = null,Object? astapPath = null,Object? autoDiscoverOnLaunch = null,Object? accentColor = null,Object? fontSize = null,Object? uiScale = null,Object? indiServerHost = null,Object? indiServerPort = null,Object? indiAutoConnect = null,Object? alpacaServerHost = null,Object? alpacaServerPort = null,Object? alpacaAutoDiscover = null,Object? useSimulationMode = null,Object? imageOutputPath = null,Object? observer = null,Object? telescope = null,Object? instrument = null,Object? updateCheckEnabled = null,Object? updateServerUrl = null,Object? updateChannel = null,Object? updateCheckIntervalHours = null,Object? skippedUpdateVersion = null,Object? safetyFailMode = null,Object? enableImageGrading = null,Object? imageGradingHfrThresholdPx = freezed,Object? imageGradingHfrBaselinePercent = freezed,Object? imageGradingEccentricityThreshold = freezed,Object? imageGradingStarCountMin = freezed,Object? imageGradingMaxConsecutiveRejects = null,Object? imageGradingRejectFolderPath = freezed,Object? adaptiveExposureEnabled = null,Object? adaptiveExposureTargetSnr = null,Object? adaptiveExposureReferenceMag = null,Object? adaptiveExposureMinSecs = null,Object? adaptiveExposureMaxSecs = null,Object? adaptiveExposurePerFilterEnabled = null,Object? adaptiveExposurePerFilterMinSecs = null,Object? adaptiveExposurePerFilterMaxSecs = null,Object? parkOnUnsafeWeather = null,Object? autoFocusOnFilterChange = null,Object? afDisableGuidingDuringAf = null,Object? ditherEnabled = null,Object? ditherScale = null,Object? recoveryDefaultRetryIntervalMins = null,Object? recoveryDefaultMaxDurationMins = null,Object? recoveryStopTrackingDuringRecovery = null,Object? recoveryAbortOnMeridian = null,Object? recoveryAudibleAlertWhenEntered = null,Object? parkBeforeDawn = null,Object? cameraRetries = null,Object? filterWheelRetries = null,Object? enableMeridianFlip = null,Object? tempCompensation = null,Object? tempCoefficient = null,Object? backlashCompensation = null,Object? settleThreshold = null,Object? settleTimeout = null,Object? settleTime = null,Object? ditherRaOnly = null,Object? plateSolver = null,Object? blindSolve = null,Object? centeringSyncMount = null,Object? bortleClass = null,Object? effectiveHorizonDeg = null,Object? preflightStrictness = null,Object? polarAlignmentMaxAgeDays = null,Object? opticalTrainDriftThreshold = null,Object? darkLibraryMinCoverage = null,Object? smartNightMaxSessionHours = freezed,Object? smartNightDefaultAfCadenceFrames = null,Object? smartNightDefaultIntegrationBudgetMinsPerTarget = null,Object? smartNightIncludeFlatsAtEnd = null,Object? smartNightUseSchedulerForMultiTarget = null,Object? smartNightSchedulerTargetThreshold = null,Object? smartNightDefaultStrategy = null,Object? smartNightPolarAlignmentStaleAfterDays = null,Object? smartNightSubExposureFloorSecs = null,Object? smartNightSubExposureCeilingSecs = null,Object? smartNightTargetSnr = null,Object? defaultGain = null,Object? defaultOffset = null,Object? webServerEnabled = null,Object? webServerPort = null,Object? phd2Path = null,Object? phd2Host = null,Object? phd2Port = null,Object? notificationsEnabled = null,Object? notifyOnSequenceComplete = null,Object? notifyOnError = null,Object? notifyOnMeridianFlip = null,Object? soundEnabled = null,Object? audibleAlertsOnCritical = null,Object? criticalAlertSound = null,Object? pushCriticalAlerts = null,Object? smartNightAutoPromptEnabled = null,Object? promptForNotesAfterRun = null,Object? sessionHandoffAutoPrompt = null,Object? campaignRollupSurfaceTargetsTab = null,Object? campaignRollupGroupingMode = null,Object? afMethod = null,Object? afCurveFitting = null,Object? afStepSize = null,Object? afExposureTime = null,Object? afInitialOffsetSteps = null,Object? afNumberOfAttempts = null,Object? afUseBrightestNStars = null,Object? afOuterCropRatio = null,Object? afInnerCropRatio = null,Object? afBinning = null,Object? afRSquaredThreshold = null,Object? afFailureHfrToleranceRatio = null,Object? afFocuserSettleTimeMs = null,Object? afExposuresPerPoint = null,Object? afBacklashCompMethod = null,Object? afBacklashIn = null,Object? mountSiteSyncMode = null,Object? afBacklashOut = null,Object? afAutofocusFilterName = null,Object? afFilterSettingsJson = null,Object? useFilterFocusOffsets = null,Object? astrometryPath = null,Object? observerName = null,Object? imageFormat = null,Object? bitDepth = null,Object? timezone = null,Object? useSystemTime = null,Object? sequencesPath = null,Object? smartNightAutoSelect = null,Object? smartNightAutoSelectCount = null,Object? adaptiveSwapEnabledByDefault = null,Object? adaptiveSwapDefaultThreshold = null,Object? adaptiveSwapDefaultHysteresisSecs = null,Object? conditionsScoreWeights = null,}) {
  return _then(_AppSettings(
location: freezed == location ? _self.location : location // ignore: cast_nullable_to_non_nullable
as ObserverLocation?,theme: null == theme ? _self.theme : theme // ignore: cast_nullable_to_non_nullable
as String,language: null == language ? _self.language : language // ignore: cast_nullable_to_non_nullable
as String,autoConnect: null == autoConnect ? _self.autoConnect : autoConnect // ignore: cast_nullable_to_non_nullable
as bool,latitude: null == latitude ? _self.latitude : latitude // ignore: cast_nullable_to_non_nullable
as double,longitude: null == longitude ? _self.longitude : longitude // ignore: cast_nullable_to_non_nullable
as double,elevation: null == elevation ? _self.elevation : elevation // ignore: cast_nullable_to_non_nullable
as double,fileNamingPattern: null == fileNamingPattern ? _self.fileNamingPattern : fileNamingPattern // ignore: cast_nullable_to_non_nullable
as String,meridianFlipMinutes: null == meridianFlipMinutes ? _self.meridianFlipMinutes : meridianFlipMinutes // ignore: cast_nullable_to_non_nullable
as int,autoFocusEveryMinutes: null == autoFocusEveryMinutes ? _self.autoFocusEveryMinutes : autoFocusEveryMinutes // ignore: cast_nullable_to_non_nullable
as int,ditherEveryFrames: null == ditherEveryFrames ? _self.ditherEveryFrames : ditherEveryFrames // ignore: cast_nullable_to_non_nullable
as int,plateSolveTimeout: null == plateSolveTimeout ? _self.plateSolveTimeout : plateSolveTimeout // ignore: cast_nullable_to_non_nullable
as int,plateSolveSearchRadius: null == plateSolveSearchRadius ? _self.plateSolveSearchRadius : plateSolveSearchRadius // ignore: cast_nullable_to_non_nullable
as double,discordWebhook: null == discordWebhook ? _self.discordWebhook : discordWebhook // ignore: cast_nullable_to_non_nullable
as String,pushoverKey: null == pushoverKey ? _self.pushoverKey : pushoverKey // ignore: cast_nullable_to_non_nullable
as String,pushoverUser: null == pushoverUser ? _self.pushoverUser : pushoverUser // ignore: cast_nullable_to_non_nullable
as String,astapPath: null == astapPath ? _self.astapPath : astapPath // ignore: cast_nullable_to_non_nullable
as String,autoDiscoverOnLaunch: null == autoDiscoverOnLaunch ? _self.autoDiscoverOnLaunch : autoDiscoverOnLaunch // ignore: cast_nullable_to_non_nullable
as bool,accentColor: null == accentColor ? _self.accentColor : accentColor // ignore: cast_nullable_to_non_nullable
as String,fontSize: null == fontSize ? _self.fontSize : fontSize // ignore: cast_nullable_to_non_nullable
as String,uiScale: null == uiScale ? _self.uiScale : uiScale // ignore: cast_nullable_to_non_nullable
as String,indiServerHost: null == indiServerHost ? _self.indiServerHost : indiServerHost // ignore: cast_nullable_to_non_nullable
as String,indiServerPort: null == indiServerPort ? _self.indiServerPort : indiServerPort // ignore: cast_nullable_to_non_nullable
as int,indiAutoConnect: null == indiAutoConnect ? _self.indiAutoConnect : indiAutoConnect // ignore: cast_nullable_to_non_nullable
as bool,alpacaServerHost: null == alpacaServerHost ? _self.alpacaServerHost : alpacaServerHost // ignore: cast_nullable_to_non_nullable
as String,alpacaServerPort: null == alpacaServerPort ? _self.alpacaServerPort : alpacaServerPort // ignore: cast_nullable_to_non_nullable
as int,alpacaAutoDiscover: null == alpacaAutoDiscover ? _self.alpacaAutoDiscover : alpacaAutoDiscover // ignore: cast_nullable_to_non_nullable
as bool,useSimulationMode: null == useSimulationMode ? _self.useSimulationMode : useSimulationMode // ignore: cast_nullable_to_non_nullable
as bool,imageOutputPath: null == imageOutputPath ? _self.imageOutputPath : imageOutputPath // ignore: cast_nullable_to_non_nullable
as String,observer: null == observer ? _self.observer : observer // ignore: cast_nullable_to_non_nullable
as String,telescope: null == telescope ? _self.telescope : telescope // ignore: cast_nullable_to_non_nullable
as String,instrument: null == instrument ? _self.instrument : instrument // ignore: cast_nullable_to_non_nullable
as String,updateCheckEnabled: null == updateCheckEnabled ? _self.updateCheckEnabled : updateCheckEnabled // ignore: cast_nullable_to_non_nullable
as bool,updateServerUrl: null == updateServerUrl ? _self.updateServerUrl : updateServerUrl // ignore: cast_nullable_to_non_nullable
as String,updateChannel: null == updateChannel ? _self.updateChannel : updateChannel // ignore: cast_nullable_to_non_nullable
as String,updateCheckIntervalHours: null == updateCheckIntervalHours ? _self.updateCheckIntervalHours : updateCheckIntervalHours // ignore: cast_nullable_to_non_nullable
as int,skippedUpdateVersion: null == skippedUpdateVersion ? _self.skippedUpdateVersion : skippedUpdateVersion // ignore: cast_nullable_to_non_nullable
as String,safetyFailMode: null == safetyFailMode ? _self.safetyFailMode : safetyFailMode // ignore: cast_nullable_to_non_nullable
as SafetyFailMode,enableImageGrading: null == enableImageGrading ? _self.enableImageGrading : enableImageGrading // ignore: cast_nullable_to_non_nullable
as bool,imageGradingHfrThresholdPx: freezed == imageGradingHfrThresholdPx ? _self.imageGradingHfrThresholdPx : imageGradingHfrThresholdPx // ignore: cast_nullable_to_non_nullable
as double?,imageGradingHfrBaselinePercent: freezed == imageGradingHfrBaselinePercent ? _self.imageGradingHfrBaselinePercent : imageGradingHfrBaselinePercent // ignore: cast_nullable_to_non_nullable
as double?,imageGradingEccentricityThreshold: freezed == imageGradingEccentricityThreshold ? _self.imageGradingEccentricityThreshold : imageGradingEccentricityThreshold // ignore: cast_nullable_to_non_nullable
as double?,imageGradingStarCountMin: freezed == imageGradingStarCountMin ? _self.imageGradingStarCountMin : imageGradingStarCountMin // ignore: cast_nullable_to_non_nullable
as int?,imageGradingMaxConsecutiveRejects: null == imageGradingMaxConsecutiveRejects ? _self.imageGradingMaxConsecutiveRejects : imageGradingMaxConsecutiveRejects // ignore: cast_nullable_to_non_nullable
as int,imageGradingRejectFolderPath: freezed == imageGradingRejectFolderPath ? _self.imageGradingRejectFolderPath : imageGradingRejectFolderPath // ignore: cast_nullable_to_non_nullable
as String?,adaptiveExposureEnabled: null == adaptiveExposureEnabled ? _self.adaptiveExposureEnabled : adaptiveExposureEnabled // ignore: cast_nullable_to_non_nullable
as bool,adaptiveExposureTargetSnr: null == adaptiveExposureTargetSnr ? _self.adaptiveExposureTargetSnr : adaptiveExposureTargetSnr // ignore: cast_nullable_to_non_nullable
as double,adaptiveExposureReferenceMag: null == adaptiveExposureReferenceMag ? _self.adaptiveExposureReferenceMag : adaptiveExposureReferenceMag // ignore: cast_nullable_to_non_nullable
as double,adaptiveExposureMinSecs: null == adaptiveExposureMinSecs ? _self.adaptiveExposureMinSecs : adaptiveExposureMinSecs // ignore: cast_nullable_to_non_nullable
as double,adaptiveExposureMaxSecs: null == adaptiveExposureMaxSecs ? _self.adaptiveExposureMaxSecs : adaptiveExposureMaxSecs // ignore: cast_nullable_to_non_nullable
as double,adaptiveExposurePerFilterEnabled: null == adaptiveExposurePerFilterEnabled ? _self._adaptiveExposurePerFilterEnabled : adaptiveExposurePerFilterEnabled // ignore: cast_nullable_to_non_nullable
as Map<String, bool>,adaptiveExposurePerFilterMinSecs: null == adaptiveExposurePerFilterMinSecs ? _self._adaptiveExposurePerFilterMinSecs : adaptiveExposurePerFilterMinSecs // ignore: cast_nullable_to_non_nullable
as Map<String, double>,adaptiveExposurePerFilterMaxSecs: null == adaptiveExposurePerFilterMaxSecs ? _self._adaptiveExposurePerFilterMaxSecs : adaptiveExposurePerFilterMaxSecs // ignore: cast_nullable_to_non_nullable
as Map<String, double>,parkOnUnsafeWeather: null == parkOnUnsafeWeather ? _self.parkOnUnsafeWeather : parkOnUnsafeWeather // ignore: cast_nullable_to_non_nullable
as bool,autoFocusOnFilterChange: null == autoFocusOnFilterChange ? _self.autoFocusOnFilterChange : autoFocusOnFilterChange // ignore: cast_nullable_to_non_nullable
as bool,afDisableGuidingDuringAf: null == afDisableGuidingDuringAf ? _self.afDisableGuidingDuringAf : afDisableGuidingDuringAf // ignore: cast_nullable_to_non_nullable
as bool,ditherEnabled: null == ditherEnabled ? _self.ditherEnabled : ditherEnabled // ignore: cast_nullable_to_non_nullable
as bool,ditherScale: null == ditherScale ? _self.ditherScale : ditherScale // ignore: cast_nullable_to_non_nullable
as String,recoveryDefaultRetryIntervalMins: null == recoveryDefaultRetryIntervalMins ? _self.recoveryDefaultRetryIntervalMins : recoveryDefaultRetryIntervalMins // ignore: cast_nullable_to_non_nullable
as double,recoveryDefaultMaxDurationMins: null == recoveryDefaultMaxDurationMins ? _self.recoveryDefaultMaxDurationMins : recoveryDefaultMaxDurationMins // ignore: cast_nullable_to_non_nullable
as double,recoveryStopTrackingDuringRecovery: null == recoveryStopTrackingDuringRecovery ? _self.recoveryStopTrackingDuringRecovery : recoveryStopTrackingDuringRecovery // ignore: cast_nullable_to_non_nullable
as bool,recoveryAbortOnMeridian: null == recoveryAbortOnMeridian ? _self.recoveryAbortOnMeridian : recoveryAbortOnMeridian // ignore: cast_nullable_to_non_nullable
as bool,recoveryAudibleAlertWhenEntered: null == recoveryAudibleAlertWhenEntered ? _self.recoveryAudibleAlertWhenEntered : recoveryAudibleAlertWhenEntered // ignore: cast_nullable_to_non_nullable
as bool,parkBeforeDawn: null == parkBeforeDawn ? _self.parkBeforeDawn : parkBeforeDawn // ignore: cast_nullable_to_non_nullable
as bool,cameraRetries: null == cameraRetries ? _self.cameraRetries : cameraRetries // ignore: cast_nullable_to_non_nullable
as int,filterWheelRetries: null == filterWheelRetries ? _self.filterWheelRetries : filterWheelRetries // ignore: cast_nullable_to_non_nullable
as int,enableMeridianFlip: null == enableMeridianFlip ? _self.enableMeridianFlip : enableMeridianFlip // ignore: cast_nullable_to_non_nullable
as bool,tempCompensation: null == tempCompensation ? _self.tempCompensation : tempCompensation // ignore: cast_nullable_to_non_nullable
as bool,tempCoefficient: null == tempCoefficient ? _self.tempCoefficient : tempCoefficient // ignore: cast_nullable_to_non_nullable
as double,backlashCompensation: null == backlashCompensation ? _self.backlashCompensation : backlashCompensation // ignore: cast_nullable_to_non_nullable
as int,settleThreshold: null == settleThreshold ? _self.settleThreshold : settleThreshold // ignore: cast_nullable_to_non_nullable
as double,settleTimeout: null == settleTimeout ? _self.settleTimeout : settleTimeout // ignore: cast_nullable_to_non_nullable
as int,settleTime: null == settleTime ? _self.settleTime : settleTime // ignore: cast_nullable_to_non_nullable
as int,ditherRaOnly: null == ditherRaOnly ? _self.ditherRaOnly : ditherRaOnly // ignore: cast_nullable_to_non_nullable
as bool,plateSolver: null == plateSolver ? _self.plateSolver : plateSolver // ignore: cast_nullable_to_non_nullable
as String,blindSolve: null == blindSolve ? _self.blindSolve : blindSolve // ignore: cast_nullable_to_non_nullable
as bool,centeringSyncMount: null == centeringSyncMount ? _self.centeringSyncMount : centeringSyncMount // ignore: cast_nullable_to_non_nullable
as bool,bortleClass: null == bortleClass ? _self.bortleClass : bortleClass // ignore: cast_nullable_to_non_nullable
as int,effectiveHorizonDeg: null == effectiveHorizonDeg ? _self.effectiveHorizonDeg : effectiveHorizonDeg // ignore: cast_nullable_to_non_nullable
as double,preflightStrictness: null == preflightStrictness ? _self.preflightStrictness : preflightStrictness // ignore: cast_nullable_to_non_nullable
as String,polarAlignmentMaxAgeDays: null == polarAlignmentMaxAgeDays ? _self.polarAlignmentMaxAgeDays : polarAlignmentMaxAgeDays // ignore: cast_nullable_to_non_nullable
as int,opticalTrainDriftThreshold: null == opticalTrainDriftThreshold ? _self.opticalTrainDriftThreshold : opticalTrainDriftThreshold // ignore: cast_nullable_to_non_nullable
as double,darkLibraryMinCoverage: null == darkLibraryMinCoverage ? _self.darkLibraryMinCoverage : darkLibraryMinCoverage // ignore: cast_nullable_to_non_nullable
as int,smartNightMaxSessionHours: freezed == smartNightMaxSessionHours ? _self.smartNightMaxSessionHours : smartNightMaxSessionHours // ignore: cast_nullable_to_non_nullable
as double?,smartNightDefaultAfCadenceFrames: null == smartNightDefaultAfCadenceFrames ? _self.smartNightDefaultAfCadenceFrames : smartNightDefaultAfCadenceFrames // ignore: cast_nullable_to_non_nullable
as int,smartNightDefaultIntegrationBudgetMinsPerTarget: null == smartNightDefaultIntegrationBudgetMinsPerTarget ? _self.smartNightDefaultIntegrationBudgetMinsPerTarget : smartNightDefaultIntegrationBudgetMinsPerTarget // ignore: cast_nullable_to_non_nullable
as int,smartNightIncludeFlatsAtEnd: null == smartNightIncludeFlatsAtEnd ? _self.smartNightIncludeFlatsAtEnd : smartNightIncludeFlatsAtEnd // ignore: cast_nullable_to_non_nullable
as bool,smartNightUseSchedulerForMultiTarget: null == smartNightUseSchedulerForMultiTarget ? _self.smartNightUseSchedulerForMultiTarget : smartNightUseSchedulerForMultiTarget // ignore: cast_nullable_to_non_nullable
as bool,smartNightSchedulerTargetThreshold: null == smartNightSchedulerTargetThreshold ? _self.smartNightSchedulerTargetThreshold : smartNightSchedulerTargetThreshold // ignore: cast_nullable_to_non_nullable
as int,smartNightDefaultStrategy: null == smartNightDefaultStrategy ? _self.smartNightDefaultStrategy : smartNightDefaultStrategy // ignore: cast_nullable_to_non_nullable
as String,smartNightPolarAlignmentStaleAfterDays: null == smartNightPolarAlignmentStaleAfterDays ? _self.smartNightPolarAlignmentStaleAfterDays : smartNightPolarAlignmentStaleAfterDays // ignore: cast_nullable_to_non_nullable
as int,smartNightSubExposureFloorSecs: null == smartNightSubExposureFloorSecs ? _self.smartNightSubExposureFloorSecs : smartNightSubExposureFloorSecs // ignore: cast_nullable_to_non_nullable
as double,smartNightSubExposureCeilingSecs: null == smartNightSubExposureCeilingSecs ? _self.smartNightSubExposureCeilingSecs : smartNightSubExposureCeilingSecs // ignore: cast_nullable_to_non_nullable
as double,smartNightTargetSnr: null == smartNightTargetSnr ? _self.smartNightTargetSnr : smartNightTargetSnr // ignore: cast_nullable_to_non_nullable
as double,defaultGain: null == defaultGain ? _self.defaultGain : defaultGain // ignore: cast_nullable_to_non_nullable
as int,defaultOffset: null == defaultOffset ? _self.defaultOffset : defaultOffset // ignore: cast_nullable_to_non_nullable
as int,webServerEnabled: null == webServerEnabled ? _self.webServerEnabled : webServerEnabled // ignore: cast_nullable_to_non_nullable
as bool,webServerPort: null == webServerPort ? _self.webServerPort : webServerPort // ignore: cast_nullable_to_non_nullable
as int,phd2Path: null == phd2Path ? _self.phd2Path : phd2Path // ignore: cast_nullable_to_non_nullable
as String,phd2Host: null == phd2Host ? _self.phd2Host : phd2Host // ignore: cast_nullable_to_non_nullable
as String,phd2Port: null == phd2Port ? _self.phd2Port : phd2Port // ignore: cast_nullable_to_non_nullable
as int,notificationsEnabled: null == notificationsEnabled ? _self.notificationsEnabled : notificationsEnabled // ignore: cast_nullable_to_non_nullable
as bool,notifyOnSequenceComplete: null == notifyOnSequenceComplete ? _self.notifyOnSequenceComplete : notifyOnSequenceComplete // ignore: cast_nullable_to_non_nullable
as bool,notifyOnError: null == notifyOnError ? _self.notifyOnError : notifyOnError // ignore: cast_nullable_to_non_nullable
as bool,notifyOnMeridianFlip: null == notifyOnMeridianFlip ? _self.notifyOnMeridianFlip : notifyOnMeridianFlip // ignore: cast_nullable_to_non_nullable
as bool,soundEnabled: null == soundEnabled ? _self.soundEnabled : soundEnabled // ignore: cast_nullable_to_non_nullable
as bool,audibleAlertsOnCritical: null == audibleAlertsOnCritical ? _self.audibleAlertsOnCritical : audibleAlertsOnCritical // ignore: cast_nullable_to_non_nullable
as bool,criticalAlertSound: null == criticalAlertSound ? _self.criticalAlertSound : criticalAlertSound // ignore: cast_nullable_to_non_nullable
as String,pushCriticalAlerts: null == pushCriticalAlerts ? _self.pushCriticalAlerts : pushCriticalAlerts // ignore: cast_nullable_to_non_nullable
as bool,smartNightAutoPromptEnabled: null == smartNightAutoPromptEnabled ? _self.smartNightAutoPromptEnabled : smartNightAutoPromptEnabled // ignore: cast_nullable_to_non_nullable
as bool,promptForNotesAfterRun: null == promptForNotesAfterRun ? _self.promptForNotesAfterRun : promptForNotesAfterRun // ignore: cast_nullable_to_non_nullable
as bool,sessionHandoffAutoPrompt: null == sessionHandoffAutoPrompt ? _self.sessionHandoffAutoPrompt : sessionHandoffAutoPrompt // ignore: cast_nullable_to_non_nullable
as bool,campaignRollupSurfaceTargetsTab: null == campaignRollupSurfaceTargetsTab ? _self.campaignRollupSurfaceTargetsTab : campaignRollupSurfaceTargetsTab // ignore: cast_nullable_to_non_nullable
as bool,campaignRollupGroupingMode: null == campaignRollupGroupingMode ? _self.campaignRollupGroupingMode : campaignRollupGroupingMode // ignore: cast_nullable_to_non_nullable
as String,afMethod: null == afMethod ? _self.afMethod : afMethod // ignore: cast_nullable_to_non_nullable
as String,afCurveFitting: null == afCurveFitting ? _self.afCurveFitting : afCurveFitting // ignore: cast_nullable_to_non_nullable
as String,afStepSize: null == afStepSize ? _self.afStepSize : afStepSize // ignore: cast_nullable_to_non_nullable
as int,afExposureTime: null == afExposureTime ? _self.afExposureTime : afExposureTime // ignore: cast_nullable_to_non_nullable
as double,afInitialOffsetSteps: null == afInitialOffsetSteps ? _self.afInitialOffsetSteps : afInitialOffsetSteps // ignore: cast_nullable_to_non_nullable
as int,afNumberOfAttempts: null == afNumberOfAttempts ? _self.afNumberOfAttempts : afNumberOfAttempts // ignore: cast_nullable_to_non_nullable
as int,afUseBrightestNStars: null == afUseBrightestNStars ? _self.afUseBrightestNStars : afUseBrightestNStars // ignore: cast_nullable_to_non_nullable
as int,afOuterCropRatio: null == afOuterCropRatio ? _self.afOuterCropRatio : afOuterCropRatio // ignore: cast_nullable_to_non_nullable
as double,afInnerCropRatio: null == afInnerCropRatio ? _self.afInnerCropRatio : afInnerCropRatio // ignore: cast_nullable_to_non_nullable
as double,afBinning: null == afBinning ? _self.afBinning : afBinning // ignore: cast_nullable_to_non_nullable
as int,afRSquaredThreshold: null == afRSquaredThreshold ? _self.afRSquaredThreshold : afRSquaredThreshold // ignore: cast_nullable_to_non_nullable
as double,afFailureHfrToleranceRatio: null == afFailureHfrToleranceRatio ? _self.afFailureHfrToleranceRatio : afFailureHfrToleranceRatio // ignore: cast_nullable_to_non_nullable
as double,afFocuserSettleTimeMs: null == afFocuserSettleTimeMs ? _self.afFocuserSettleTimeMs : afFocuserSettleTimeMs // ignore: cast_nullable_to_non_nullable
as int,afExposuresPerPoint: null == afExposuresPerPoint ? _self.afExposuresPerPoint : afExposuresPerPoint // ignore: cast_nullable_to_non_nullable
as int,afBacklashCompMethod: null == afBacklashCompMethod ? _self.afBacklashCompMethod : afBacklashCompMethod // ignore: cast_nullable_to_non_nullable
as String,afBacklashIn: null == afBacklashIn ? _self.afBacklashIn : afBacklashIn // ignore: cast_nullable_to_non_nullable
as int,mountSiteSyncMode: null == mountSiteSyncMode ? _self.mountSiteSyncMode : mountSiteSyncMode // ignore: cast_nullable_to_non_nullable
as String,afBacklashOut: null == afBacklashOut ? _self.afBacklashOut : afBacklashOut // ignore: cast_nullable_to_non_nullable
as int,afAutofocusFilterName: null == afAutofocusFilterName ? _self.afAutofocusFilterName : afAutofocusFilterName // ignore: cast_nullable_to_non_nullable
as String,afFilterSettingsJson: null == afFilterSettingsJson ? _self.afFilterSettingsJson : afFilterSettingsJson // ignore: cast_nullable_to_non_nullable
as String,useFilterFocusOffsets: null == useFilterFocusOffsets ? _self.useFilterFocusOffsets : useFilterFocusOffsets // ignore: cast_nullable_to_non_nullable
as bool,astrometryPath: null == astrometryPath ? _self.astrometryPath : astrometryPath // ignore: cast_nullable_to_non_nullable
as String,observerName: null == observerName ? _self.observerName : observerName // ignore: cast_nullable_to_non_nullable
as String,imageFormat: null == imageFormat ? _self.imageFormat : imageFormat // ignore: cast_nullable_to_non_nullable
as String,bitDepth: null == bitDepth ? _self.bitDepth : bitDepth // ignore: cast_nullable_to_non_nullable
as String,timezone: null == timezone ? _self.timezone : timezone // ignore: cast_nullable_to_non_nullable
as String,useSystemTime: null == useSystemTime ? _self.useSystemTime : useSystemTime // ignore: cast_nullable_to_non_nullable
as bool,sequencesPath: null == sequencesPath ? _self.sequencesPath : sequencesPath // ignore: cast_nullable_to_non_nullable
as String,smartNightAutoSelect: null == smartNightAutoSelect ? _self.smartNightAutoSelect : smartNightAutoSelect // ignore: cast_nullable_to_non_nullable
as bool,smartNightAutoSelectCount: null == smartNightAutoSelectCount ? _self.smartNightAutoSelectCount : smartNightAutoSelectCount // ignore: cast_nullable_to_non_nullable
as int,adaptiveSwapEnabledByDefault: null == adaptiveSwapEnabledByDefault ? _self.adaptiveSwapEnabledByDefault : adaptiveSwapEnabledByDefault // ignore: cast_nullable_to_non_nullable
as bool,adaptiveSwapDefaultThreshold: null == adaptiveSwapDefaultThreshold ? _self.adaptiveSwapDefaultThreshold : adaptiveSwapDefaultThreshold // ignore: cast_nullable_to_non_nullable
as double,adaptiveSwapDefaultHysteresisSecs: null == adaptiveSwapDefaultHysteresisSecs ? _self.adaptiveSwapDefaultHysteresisSecs : adaptiveSwapDefaultHysteresisSecs // ignore: cast_nullable_to_non_nullable
as double,conditionsScoreWeights: null == conditionsScoreWeights ? _self._conditionsScoreWeights : conditionsScoreWeights // ignore: cast_nullable_to_non_nullable
as Map<String, double>,
  ));
}

/// Create a copy of AppSettings
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ObserverLocationCopyWith<$Res>? get location {
    if (_self.location == null) {
    return null;
  }

  return $ObserverLocationCopyWith<$Res>(_self.location!, (value) {
    return _then(_self.copyWith(location: value));
  });
}
}

// dart format on
