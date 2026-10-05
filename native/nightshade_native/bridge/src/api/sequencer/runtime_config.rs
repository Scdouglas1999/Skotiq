use super::*;

/// Set simulation mode (use mock devices instead of real hardware)
pub async fn api_sequencer_set_simulation_mode(enabled: bool) -> Result<(), NightshadeError> {
    tracing::info!("Setting sequencer simulation mode: {}", enabled);
    let mut executor = get_sequence_executor().write().await;

    // Production/release artifacts must not execute simulated hardware paths.
    if enabled && !cfg!(debug_assertions) {
        return Err(NightshadeError::NotSupported {
            device_id: "sequencer".to_string(),
            operation: "set_simulation_mode(true)".to_string(),
        });
    }

    if enabled {
        // Use NullDeviceOps for simulation
        executor.set_device_ops(std::sync::Arc::new(nightshade_sequencer::NullDeviceOps));
    } else {
        // Use UnifiedDeviceOps which routes through DeviceManager for real hardware
        let ops = create_unified_device_ops();
        executor.set_device_ops(ops);
    }

    Ok(())
}

/// Set connected devices for the sequencer
pub async fn api_sequencer_set_devices(
    camera_id: Option<String>,
    mount_id: Option<String>,
    focuser_id: Option<String>,
    filterwheel_id: Option<String>,
    rotator_id: Option<String>,
    filter_names: Option<Vec<String>>,
    filter_focus_offsets: Option<std::collections::HashMap<String, i32>>,
) -> Result<(), NightshadeError> {
    tracing::info!(
        "Setting sequencer devices: camera={:?}, mount={:?}, focuser={:?}, filterwheel={:?}, rotator={:?}, filter_names={:?}, filter_focus_offsets={:?}",
        camera_id, mount_id, focuser_id, filterwheel_id, rotator_id, filter_names, filter_focus_offsets
    );
    let filterwheel_for_names = filterwheel_id.clone();
    {
        let mut executor = get_sequence_executor().write().await;
        executor.set_devices(camera_id, mount_id, focuser_id, filterwheel_id, rotator_id);
        if let Some(offsets) = filter_focus_offsets {
            executor.set_filter_focus_offsets(offsets);
        }
    }

    if let Some(names) = filter_names {
        if names.is_empty() {
            return Err(NightshadeError::InvalidParameter(
                "filter_names was provided but empty; provide at least one name or pass null."
                    .to_string(),
            ));
        }

        let filterwheel_id = filterwheel_for_names.ok_or_else(|| {
            NightshadeError::InvalidParameter(
                "filter_names was provided but filterwheel_id is null. Provide a filter wheel ID before setting filter names."
                    .to_string(),
            )
        })?;

        let mgr = get_device_manager();
        mgr.filter_wheel_set_filter_names(&filterwheel_id, names)
            .await
            .map_err(|e| {
                NightshadeError::OperationFailed(format!(
                    "Failed to apply filter names to '{}': {}",
                    filterwheel_id, e
                ))
            })?;
    }

    Ok(())
}

/// Set the safety fail mode for the sequencer.
/// This determines behavior when safety devices fail or are unavailable:
/// - "fail_closed": Treat unavailable safety data as unsafe
/// - "fail_open": Treat unavailable safety data as safe
/// - "warn_only": Preserve the previous safety state and emit a warning event
pub async fn api_sequencer_set_safety_fail_mode(mode: String) -> Result<(), NightshadeError> {
    use nightshade_sequencer::SafetyFailMode;

    let mode_lower = mode.to_lowercase();
    let fail_mode = match mode_lower.as_str() {
        "fail_closed" | "failclosed" => SafetyFailMode::FailClosed,
        "fail_open" | "failopen" => SafetyFailMode::FailOpen,
        "warn_only" | "warnonly" => SafetyFailMode::WarnOnly,
        _ => {
            return Err(NightshadeError::InvalidParameter(format!(
                "Invalid safety fail mode: '{}'. Must be 'fail_closed', 'fail_open', or 'warn_only'.",
                mode
            )));
        }
    };

    tracing::info!("Setting sequencer safety fail mode: {:?}", fail_mode);
    let mut executor = get_sequence_executor().write().await;
    executor.set_safety_fail_mode(fail_mode);

    Ok(())
}

/// Set the safety/humidity polling interval for the sequencer.
/// Must be between 5 seconds and 3600 seconds. The executor applies the
/// update live without restarting the current sequence.
pub async fn api_sequencer_set_safety_check_interval_seconds(
    seconds: u32,
) -> Result<(), NightshadeError> {
    if !(5..=3600).contains(&seconds) {
        return Err(NightshadeError::InvalidParameter(format!(
            "Invalid safety check interval: {}. Must be between 5 and 3600 seconds.",
            seconds
        )));
    }

    tracing::info!(
        "Setting sequencer safety check interval: {} seconds",
        seconds
    );
    let mut executor = get_sequence_executor().write().await;
    executor.set_safety_check_interval_secs(u64::from(seconds));

    Ok(())
}

/// Set the save path for sequencer images.
/// This is the base directory where captured images will be saved.
/// If not set (or set to None), images will NOT be saved to disk.
pub async fn api_sequencer_set_save_path(path: Option<String>) -> Result<(), NightshadeError> {
    let path_display = path.as_deref().unwrap_or("<none>");
    tracing::info!("Setting sequencer save path: {}", path_display);

    let mut executor = get_sequence_executor().write().await;
    executor.set_save_path(path.map(std::path::PathBuf::from));

    Ok(())
}

// Sequencer runtime settings propagation

/// Update dither configuration at runtime while a sequence is running or paused.
/// The updated values are stored on the executor and will be used by subsequent
/// trigger-initiated dithers and checkpoint resumes.
pub async fn api_sequencer_update_dither_config(
    pixels: f64,
    settle_pixels: f64,
    settle_time: f64,
    settle_timeout: f64,
    ra_only: bool,
) -> Result<(), NightshadeError> {
    tracing::info!(
        "Updating sequencer dither config: pixels={}, settle_pixels={}, settle_time={}, settle_timeout={}, ra_only={}",
        pixels, settle_pixels, settle_time, settle_timeout, ra_only
    );
    let mut executor = get_sequence_executor().write().await;
    executor
        .update_dither_config(pixels, settle_pixels, settle_time, settle_timeout, ra_only)
        .await;
    Ok(())
}

/// Push the operator's meridian-flip settings onto the standard
/// `meridian_flip` trigger.
///
/// `config_json` is a serialised `MeridianFlipConfig` — the SAME shape the Dart
/// side already builds for a `MeridianFlipNode`, so there is exactly one
/// wire format for meridian settings and one place to keep in sync.
///
/// Why JSON rather than a typed FRB struct: `MeridianFlipConfig` has 21 fields
/// including a `Vec<f64>` retry ladder and two enums, and every one of them is
/// already covered by the serde contract the sequence JSON uses. Mirroring it
/// as an FRB struct would duplicate that contract and give it two places to
/// drift.
///
/// Without this call the trigger keeps `MeridianFlipConfig::default()` for the
/// whole run and the user's Settings → Meridian Flip panel is inert on the
/// trigger path.
pub async fn api_sequencer_update_meridian_flip_config(
    config_json: String,
) -> Result<(), NightshadeError> {
    let config: nightshade_sequencer::MeridianFlipConfig = serde_json::from_str(&config_json)
        .map_err(|e| {
            NightshadeError::InvalidParameter(format!("Invalid meridian-flip config JSON: {}", e))
        })?;
    if config.max_retries > 0 && config.retry_delays_secs.is_empty() {
        return Err(NightshadeError::InvalidParameter(
            "meridian-flip config sets max_retries > 0 but no retry delays; the flip \
             would refuse to retry"
                .to_string(),
        ));
    }
    tracing::info!(
        "[API] Updating meridian-flip trigger config from user settings (auto_center={}, \
         minutes_past={:.1}, max_retries={})",
        config.auto_center,
        config.minutes_past_meridian,
        config.max_retries
    );
    let mut executor = get_sequence_executor().write().await;
    executor.update_meridian_flip_config(config).await;
    Ok(())
}

/// Update observer location at runtime while a sequence is running or paused.
/// Updates the executor's stored latitude/longitude so altitude-based triggers
/// use the correct location on their next evaluation.
pub async fn api_sequencer_update_location(
    latitude: Option<f64>,
    longitude: Option<f64>,
) -> Result<(), NightshadeError> {
    tracing::info!(
        "Updating sequencer location: lat={:?}, lon={:?}",
        latitude,
        longitude
    );
    let mut executor = get_sequence_executor().write().await;
    executor.update_location(latitude, longitude).await;
    Ok(())
}

/// stage per-target / per-filter carry-over integration so the
/// next `sequencerStart()` seeds the IntegrationBudget tracker with frames
/// already captured in prior sessions. The Dart `SequenceExecutor.start()`
/// calls this once per target after reading `sessionHandoffDecisionProvider`:
///
///   * `Resume`      → supply the prior per-filter totals.
///   * `Restart`     → supply an empty inner map (zeroes the carry-over).
///   * `ContinueNew` → omit the target from the call (default behaviour).
///
/// `carry_over` shape: `target_id` -> { `filter_name` -> `seconds` }.
/// The Rust side merges entries (last-write-wins per target_id), then drains
/// the staged map on the next `start()`.
pub async fn api_sequencer_update_pending_integration_carry_over(
    carry_over: std::collections::HashMap<String, std::collections::HashMap<String, f64>>,
) -> Result<(), NightshadeError> {
    tracing::info!(
        "Updating sequencer integration carry-over: {} target entries",
        carry_over.len()
    );
    let mut executor = get_sequence_executor().write().await;
    executor.update_pending_integration_carry_over(carry_over);
    Ok(())
}

/// Update filter focus offsets at runtime while a sequence is running or paused.
/// Updates the executor's stored offsets so subsequent filter changes apply
/// the correct focus compensation.
pub async fn api_sequencer_update_filter_offsets(
    offsets: std::collections::HashMap<String, i32>,
) -> Result<(), NightshadeError> {
    tracing::info!(
        "Updating sequencer filter focus offsets: {} entries",
        offsets.len()
    );
    let mut executor = get_sequence_executor().write().await;
    executor.update_filter_offsets(offsets).await;
    Ok(())
}

/// update the autofocus-interval trigger cadence at runtime.
/// The default in `default_autofocus_interval_frames()` is 25 frames; this
/// is wrong for both very-short (5 s) and very-long (5 min) subs, so the UI
/// must let the user override it. `every_n_frames == 0` is rejected because
/// the trigger evaluator disables the periodic AF when the cadence is zero,
/// which would silently turn AF off.
pub async fn api_sequencer_update_autofocus_interval(
    every_n_frames: u32,
) -> Result<(), NightshadeError> {
    if every_n_frames == 0 {
        return Err(NightshadeError::InvalidParameter(
            "autofocus_interval_frames must be > 0. Pass a positive frame cadence; \
             use the trigger 'enabled' toggle in the trigger list to disable periodic AF."
                .to_string(),
        ));
    }
    tracing::info!(
        "Updating sequencer autofocus-interval cadence: every {} frames",
        every_n_frames
    );
    let mut executor = get_sequence_executor().write().await;
    executor.update_autofocus_interval(every_n_frames).await;
    Ok(())
}

/// Push the operator's autofocus settings so trigger-fired refocus uses them.
///
/// A sequence without an Autofocus node — which is exactly the sequence whose
/// interval trigger fires unattended — otherwise refocuses on library defaults,
/// ignoring the operator's step size, exposure, backlash, failure tolerance and
/// failure action. An Autofocus node still wins at `start()`: a node is a
/// per-sequence decision, this is the global one.
///
/// Takes the same JSON shape the sequence's Autofocus node carries, so the
/// Dart side has exactly one serializer to keep correct.
pub async fn api_sequencer_update_autofocus_config(
    config_json: String,
) -> Result<(), NightshadeError> {
    let config: nightshade_sequencer::AutofocusConfig = serde_json::from_str(&config_json)
        .map_err(|e| {
            NightshadeError::InvalidParameter(format!(
                "autofocus config JSON could not be parsed: {e}. Trigger-fired refocus would \
                 have silently fallen back to library defaults."
            ))
        })?;
    let mut executor = get_sequence_executor().write().await;
    executor.update_autofocus_config(config).await;
    Ok(())
}

/// update the global default image-grading thresholds at runtime.
///
/// All fields are optional; when `enabled` is `false` an `ImageQualityCheck`
/// is NOT constructed (grading disabled globally — per-node `quality_check`
/// on TakeExposure still wins). The Dart `enableImageGrading` toggle on
/// app settings drives this directly.
pub async fn api_sequencer_update_default_quality_check(
    hfr_threshold: Option<f64>,
    hfr_baseline_percent: Option<f64>,
    eccentricity_threshold: Option<f64>,
    star_count_min: Option<u32>,
    max_consecutive_rejects: u32,
    enabled: bool,
) -> Result<(), NightshadeError> {
    use nightshade_sequencer::quality::ImageQualityCheck;
    let check = if enabled {
        Some(ImageQualityCheck {
            hfr_threshold,
            hfr_baseline_percent,
            eccentricity_threshold,
            star_count_min,
            max_consecutive_rejects,
        })
    } else {
        None
    };
    tracing::info!(
        "Updating sequencer default_quality_check: enabled={}, hfr={:?}, hfr_baseline={:?}, ecc={:?}, stars={:?}, max_rejects={}",
        enabled,
        hfr_threshold,
        hfr_baseline_percent,
        eccentricity_threshold,
        star_count_min,
        max_consecutive_rejects,
    );
    let mut executor = get_sequence_executor().write().await;
    executor.update_default_quality_check(check).await;
    Ok(())
}

/// update the reject-folder override at runtime. Empty string =>
/// None (i.e. fall back to `<save_path>/Reject/`).
pub async fn api_sequencer_update_reject_folder_path(
    path: Option<String>,
) -> Result<(), NightshadeError> {
    // Normalise empty / whitespace-only to None so the user can clear the
    // override by deleting the text field without us treating "" as a
    // path-relative-to-cwd.
    let normalised = path.and_then(|p| {
        let trimmed = p.trim().to_string();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        }
    });
    tracing::info!("Updating sequencer reject_folder_path: {:?}", normalised);
    let mut executor = get_sequence_executor().write().await;
    executor.update_reject_folder_path(normalised).await;
    Ok(())
}

/// Push observer / equipment identification to the executor so the next FITS
/// save stamps real keywords (OBSERVER, TELESCOP, FOCALLEN, APTDIA, INSTRUME,
/// SITEELEV). Every field is optional so a headless / no-profile run omits the
/// keyword instead of emitting a sentinel.
pub async fn api_sequencer_update_observer_profile(
    observer_name: Option<String>,
    site_elevation_m: Option<f64>,
    camera_make: Option<String>,
    camera_model: Option<String>,
    telescope_name: Option<String>,
    telescope_focal_length_mm: Option<f64>,
    telescope_aperture_mm: Option<f64>,
) -> Result<(), NightshadeError> {
    use nightshade_sequencer::ObserverProfile;
    let trim_opt = |s: Option<String>| -> Option<String> {
        s.and_then(|v| {
            let t = v.trim().to_string();
            if t.is_empty() {
                None
            } else {
                Some(t)
            }
        })
    };
    let profile = ObserverProfile {
        observer_name: trim_opt(observer_name),
        site_elevation_m,
        camera_make: trim_opt(camera_make),
        camera_model: trim_opt(camera_model),
        telescope_name: trim_opt(telescope_name),
        telescope_focal_length_mm,
        telescope_aperture_mm,
    };
    tracing::info!(
        "Updating sequencer observer_profile: observer={:?}, telescope={:?}, camera_make={:?}, camera_model={:?}",
        profile.observer_name,
        profile.telescope_name,
        profile.camera_make,
        profile.camera_model,
    );
    let mut executor = get_sequence_executor().write().await;
    executor.update_observer_profile(profile).await;
    Ok(())
}

// Cloud-motion-aware triggers
//
// Push the live `cloudMotionAnalyzerProvider` output from Dart into the
// executor's trigger state on a ~60s cadence (see WeatherSafetyNotifier).
// Drives the `CloudArrivingIn`, `CloudOpeningIn`, and `CloudCoverThreshold`
// triggers added in `nightshade_sequencer::TriggerType`.

/// Push the latest cloud-motion analyzer reading into the executor.
///
/// All fields are optional because the Dart analyzer may not yet have
/// enough radar history to produce every quantity. `None` values disable
/// the corresponding evaluator branch rather than firing on a default —
/// silently picking a sentinel would mask analyzer failures.
///
/// `predicted_clear_sky_alt` / `predicted_clear_sky_az` must be either
/// both `Some` or both `None`; a half-specified direction is logged at
/// WARN and treated as no-direction.
pub async fn api_sequencer_update_cloud_motion(
    current_cover_percent: Option<f64>,
    predicted_arrival_minutes: Option<f64>,
    predicted_opening_minutes: Option<f64>,
    predicted_opening_duration_secs: Option<f64>,
    predicted_clear_sky_alt: Option<f64>,
    predicted_clear_sky_az: Option<f64>,
) -> Result<(), NightshadeError> {
    if predicted_clear_sky_alt.is_some() != predicted_clear_sky_az.is_some() {
        tracing::warn!(
            "[API] update_cloud_motion: half-specified clear-sky direction ignored (alt={:?}, az={:?})",
            predicted_clear_sky_alt,
            predicted_clear_sky_az,
        );
    }
    tracing::debug!(
        "[API] update_cloud_motion: cover={:?}%, arrival={:?}min, opening={:?}min ({:?}s), clear=({:?},{:?})",
        current_cover_percent,
        predicted_arrival_minutes,
        predicted_opening_minutes,
        predicted_opening_duration_secs,
        predicted_clear_sky_alt,
        predicted_clear_sky_az,
    );
    let executor = get_sequence_executor().read().await;
    executor
        .update_cloud_motion(
            current_cover_percent,
            predicted_arrival_minutes,
            predicted_opening_minutes,
            predicted_opening_duration_secs,
            predicted_clear_sky_alt,
            predicted_clear_sky_az,
        )
        .await;
    Ok(())
}

/// Push the Dart-side weather-safety verdict into the executor.
///
/// The in-sequencer `WeatherUnsafe` trigger keys off the hardware
/// `safety_is_safe` poll only; a rig WITHOUT a hardware safety device never
/// aborts via that trigger even when `weatherSafetyProvider` computed UNSAFE
/// from the user's configured thresholds + API/cloud sources. This carries
/// that verdict as an additional unsafe source folded (OR-of-unsafe) into the
/// trigger evaluation — it can only make the rig safer, never less safe than
/// the hardware reading.
///
/// `unsafe_override = Some(true)` => Dart computed UNSAFE; `Some(false)` =>
/// Dart computed SAFE; `None` => Dart abstains (provider disabled / no data)
/// and this layer is inert.
pub async fn api_sequencer_update_weather_verdict(
    unsafe_override: Option<bool>,
) -> Result<(), NightshadeError> {
    tracing::debug!(
        "[API] update_weather_verdict: unsafe_override={:?}",
        unsafe_override
    );
    let executor = get_sequence_executor().read().await;
    executor.update_weather_verdict(unsafe_override).await;
    Ok(())
}

/// JSON-serialised cloud-motion snapshot for the run
/// dashboard. Returns `Ok(None)` when no data has been pushed yet.
pub async fn api_sequencer_get_cloud_motion_json() -> Result<Option<String>, NightshadeError> {
    let executor = get_sequence_executor().read().await;
    Ok(executor.current_cloud_motion_json())
}

// Sky-brightness adaptive exposures
//
// The Dart `SkyBrightnessTracker` produces a continuous mag/arcsec² reading
// during execution. We push that reading to the sequencer executor whenever
// it changes; the next `TakeExposure` burst consults it and may scale the
// per-frame duration to keep SNR roughly constant across changing sky
// conditions. The global default `AdaptiveExposureConfig` is pushed via a
// separate API so the user's app-settings UI can configure once and have
// it apply to every exposure node that doesn't carry its own override.

/// Push the latest live sky-brightness reading to the executor.
///
/// `mag` is the sky brightness in mag/arcsec² (bigger = darker). Pass
/// `None` when the tracker has lost lock — the adapter then falls back to
/// the nominal duration and emits a structured `Unavailable` event.
pub async fn api_sequencer_update_sky_brightness(mag: Option<f64>) -> Result<(), NightshadeError> {
    if let Some(m) = mag {
        if !m.is_finite() || m <= 0.0 {
            tracing::warn!(
                "[API] update_sky_brightness: non-finite or non-positive value {:?} — treating as None",
                m
            );
        }
    }
    tracing::debug!("[API] update_sky_brightness: {:?} mag/arcsec²", mag);
    let executor = get_sequence_executor().read().await;
    executor.update_sky_brightness(mag).await;
    Ok(())
}

/// Push the global default sky-brightness adaptive-exposure config to the
/// executor. Per-node `ExposureConfig.adaptive_exposure` still wins; this
/// is the runtime fallback applied to TakeExposure nodes that have no
/// own block.
///
/// Pass `enabled = false` to disable the feature globally. The per-filter
/// maps are flattened into parallel arrays because FRB cannot bridge
/// `HashMap<String, T>` directly — Dart serialises its own filter map to
/// the (`*_filters`, `*_values`) pair shape.
#[allow(clippy::too_many_arguments)]
pub async fn api_sequencer_update_default_adaptive_exposure(
    enabled: bool,
    target_snr: f64,
    reference_sky_brightness_mag: f64,
    min_exposure_secs: f64,
    max_exposure_secs: f64,
    per_filter_enabled_keys: Vec<String>,
    per_filter_enabled_values: Vec<bool>,
    per_filter_min_keys: Vec<String>,
    per_filter_min_values: Vec<f64>,
    per_filter_max_keys: Vec<String>,
    per_filter_max_values: Vec<f64>,
) -> Result<(), NightshadeError> {
    use nightshade_sequencer::scheduling::AdaptiveExposureConfig;

    if per_filter_enabled_keys.len() != per_filter_enabled_values.len() {
        return Err(NightshadeError::InvalidParameter(
            "per_filter_enabled_keys and per_filter_enabled_values lengths differ".to_string(),
        ));
    }
    if per_filter_min_keys.len() != per_filter_min_values.len() {
        return Err(NightshadeError::InvalidParameter(
            "per_filter_min_keys and per_filter_min_values lengths differ".to_string(),
        ));
    }
    if per_filter_max_keys.len() != per_filter_max_values.len() {
        return Err(NightshadeError::InvalidParameter(
            "per_filter_max_keys and per_filter_max_values lengths differ".to_string(),
        ));
    }

    let per_filter_enabled = per_filter_enabled_keys
        .into_iter()
        .zip(per_filter_enabled_values)
        .collect::<std::collections::HashMap<_, _>>();
    let per_filter_min_secs = per_filter_min_keys
        .into_iter()
        .zip(per_filter_min_values)
        .collect::<std::collections::HashMap<_, _>>();
    let per_filter_max_secs = per_filter_max_keys
        .into_iter()
        .zip(per_filter_max_values)
        .collect::<std::collections::HashMap<_, _>>();

    let config = AdaptiveExposureConfig {
        enabled,
        target_snr,
        reference_sky_brightness_mag,
        min_exposure_secs,
        max_exposure_secs,
        per_filter_enabled,
        per_filter_min_secs,
        per_filter_max_secs,
    };
    tracing::info!(
        "[API] update_default_adaptive_exposure: enabled={}, ref={} mag/arcsec², min={}s, max={}s, per_filter_enabled={}, per_filter_min={}, per_filter_max={}",
        enabled,
        reference_sky_brightness_mag,
        min_exposure_secs,
        max_exposure_secs,
        config.per_filter_enabled.len(),
        config.per_filter_min_secs.len(),
        config.per_filter_max_secs.len(),
    );
    let mut executor = get_sequence_executor().write().await;
    executor
        .update_default_adaptive_exposure(Some(config))
        .await;
    Ok(())
}

/// disable the global default adaptive-exposure config
/// (push `None`). Convenience entry-point so the Dart side doesn't have
/// to pass a sentinel struct just to disable.
pub async fn api_sequencer_clear_default_adaptive_exposure() -> Result<(), NightshadeError> {
    tracing::info!("[API] clear_default_adaptive_exposure: disabling global default");
    let mut executor = get_sequence_executor().write().await;
    executor.update_default_adaptive_exposure(None).await;
    Ok(())
}

// Recovery mode — FRB-exposed control surface
//
// added these to `bridge/src/sequencer_api.rs` but that module
// is OUTSIDE `crate::api`, which is FRB's scan root (see
// `flutter_rust_bridge.yaml > rust_input`). The functions never crossed the
// FRB boundary, so the Dart side fell back to `dynamic` dispatch with
// `NoSuchMethodError` placeholders. Re-homing them here closes that gap.

/// User-tunable recovery defaults pushed from the Settings > Recovery Mode
/// page. Field-for-field mirror of
/// `nightshade_sequencer::recovery::RecoveryRuntimeConfig` so the FRB wire
/// shape stays stable across regen cycles.
#[derive(Debug, Clone)]
pub struct RecoveryConfigUpdate {
    pub retry_interval_secs: f64,
    pub max_duration_secs: f64,
    pub stop_tracking_during_recovery: bool,
    pub abort_on_meridian: bool,
    pub audible_alert_when_entered: bool,
    /// Off by default. See
    /// `RecoveryRuntimeConfig::park_and_close_when_recovery_gives_up` for why
    /// this is an explicit operator decision and never an inference.
    pub park_and_close_when_recovery_gives_up: bool,
}

/// Operator pressed "Try Now" on the Run Dashboard banner — punch through
/// the wait timer and force the next recovery attempt immediately. No-op
/// when the executor is not currently in `Recovering`.
pub async fn api_sequencer_recovery_try_now() -> Result<(), NightshadeError> {
    tracing::info!("[API] Recovery: Try Now requested");
    let executor = get_sequence_executor().read().await;
    executor
        .recovery_try_now()
        .await
        .map_err(NightshadeError::OperationFailed)
}

/// Operator pressed "Abort" on the Run Dashboard banner — exits the recovery
/// loop and transitions the executor to `Failed`. No-op when not in
/// `Recovering`.
pub async fn api_sequencer_recovery_abort() -> Result<(), NightshadeError> {
    tracing::info!("[API] Recovery: Abort requested");
    let executor = get_sequence_executor().read().await;
    executor
        .recovery_abort()
        .await
        .map_err(NightshadeError::OperationFailed)
}

/// Push updated recovery defaults into the executor's runtime config. The
/// next recovery entry uses these values; an in-flight loop continues with
/// the values that were live when it entered.
///
/// Validation here matches the gate the Rust sequencer applies internally:
/// both `retry_interval_secs` and `max_duration_secs` must be > 0. We
/// surface a structured InvalidParameter error so the Dart settings page
/// can render a precise validation message instead of "unknown error".
pub async fn api_sequencer_update_recovery_config(
    update: RecoveryConfigUpdate,
) -> Result<(), NightshadeError> {
    if update.retry_interval_secs <= 0.0 {
        return Err(NightshadeError::InvalidParameter(format!(
            "retry_interval_secs must be > 0 (was {})",
            update.retry_interval_secs
        )));
    }
    if update.max_duration_secs <= 0.0 {
        return Err(NightshadeError::InvalidParameter(format!(
            "max_duration_secs must be > 0 (was {})",
            update.max_duration_secs
        )));
    }
    tracing::info!(
        "[API] Recovery: update config interval={:.0}s, max_duration={:.0}s, stop_track={}, abort_meridian={}, audible={}, park_and_close_on_give_up={}",
        update.retry_interval_secs,
        update.max_duration_secs,
        update.stop_tracking_during_recovery,
        update.abort_on_meridian,
        update.audible_alert_when_entered,
        update.park_and_close_when_recovery_gives_up,
    );
    let config = nightshade_sequencer::recovery::RecoveryRuntimeConfig {
        retry_interval_secs: update.retry_interval_secs,
        max_duration_secs: update.max_duration_secs,
        stop_tracking_during_recovery: update.stop_tracking_during_recovery,
        abort_on_meridian: update.abort_on_meridian,
        audible_alert_when_entered: update.audible_alert_when_entered,
        park_and_close_when_recovery_gives_up: update.park_and_close_when_recovery_gives_up,
    };
    let mut executor = get_sequence_executor().write().await;
    executor.update_recovery_config(config).await;
    Ok(())
}

/// JSON-serialised snapshot of the current in-flight `RecoveryContext`.
/// Returns `None` when the executor is not currently in `Recovering`.
///
/// JSON-string-over-bridge is intentional: the Dart side already owns a
/// hand-written `RecoveryStatus.fromJson` mirror (see
/// `nightshade_core/lib/src/models/sequencer/recovery_status.dart`) so
/// piping serde JSON across is cheaper than asking FRB to bridge the
/// chrono-dependent `RecoveryContext` Rust struct.
pub async fn api_sequencer_get_current_recovery_json() -> Result<Option<String>, NightshadeError> {
    let executor = get_sequence_executor().read().await;
    let ctx = executor.current_recovery();
    match ctx {
        None => Ok(None),
        Some(c) => {
            let json = serde_json::to_string(&c).map_err(|e| {
                NightshadeError::SerializationError(format!("Recovery context serialise: {}", e))
            })?;
            Ok(Some(json))
        }
    }
}

/// JSON-serialised dump of every completed recovery loop since the executor
/// was constructed. Surfaced for the post-session report dialog. Returns an
/// empty JSON array `"[]"` when no recoveries have completed yet.
pub async fn api_sequencer_get_recovery_history_json() -> Result<String, NightshadeError> {
    let executor = get_sequence_executor().read().await;
    let history = executor.recovery_history();
    serde_json::to_string(&history).map_err(|e| {
        NightshadeError::SerializationError(format!("Recovery history serialise: {}", e))
    })
}

// Replay debug

/// Replay Debug — stamp the active `sequence_runs.id` onto the
/// executor so every subsequent emitted DecisionEvent carries it as
/// `sequence_run_id`. Called by the Dart side immediately after the
/// `sequence_runs` row is inserted.
///
/// Pass `None` (Dart `null`) to clear the slot — useful at run end /
/// reset.
pub async fn api_sequencer_set_active_sequence_run_id(
    sequence_run_id: Option<i64>,
) -> Result<(), NightshadeError> {
    let executor = get_sequence_executor().read().await;
    executor.set_active_sequence_run_id(sequence_run_id);
    Ok(())
}

/// Replay Debug — read back the currently-stamped
/// `sequence_runs.id`. Used by tests and as a sanity check from the
/// Dart side.
pub async fn api_sequencer_get_active_sequence_run_id() -> Result<Option<i64>, NightshadeError> {
    let executor = get_sequence_executor().read().await;
    Ok(executor.active_sequence_run_id())
}

/// Replay Debug — runtime toggle for decision emission. When
/// `enabled = false`, the executor short-circuits all decision sends
/// (no channel publish, no allocation) so power users who don't want
/// the replay log can opt out. Defaults to ON.
pub async fn api_sequencer_set_decision_logging_enabled(
    enabled: bool,
) -> Result<(), NightshadeError> {
    let executor = get_sequence_executor().read().await;
    executor.set_decision_logging_enabled(enabled);
    tracing::info!(
        "[REPLAY_DEBUG] decision logging {} (runtime toggle)",
        if enabled { "ENABLED" } else { "DISABLED" }
    );
    Ok(())
}

/// Replay Debug — readback for the runtime toggle.
pub async fn api_sequencer_get_decision_logging_enabled() -> Result<bool, NightshadeError> {
    let executor = get_sequence_executor().read().await;
    Ok(executor.decision_logging_enabled())
}

// Adaptive sky-conditions target swap
//
// The Dart `AdaptiveSwapService` composes the live ConditionsScore from
// transparency / seeing / cloud cover / wind every ~30s and pushes it
// here. The `TargetScheduler` consults the score on every decision tick
// when `swap_on_conditions_below` is configured. The dashboard reads
// the live state via `api_sequencer_get_adaptive_swap_json` to render
// the "Adaptive Conditions" panel.

/// Push the latest composite sky-conditions score to the executor. All
/// fields are optional because the Dart composer may not have every axis
/// (e.g. no weather station => `wind_score = None`); the score itself
/// is computed by Dart from the available axes using
/// [`ConditionsScoreWeights`].
///
/// Pass `score = None` to clear the slot (telemetry lost — the
/// scheduler then falls back to the ordinary ranking).
#[allow(clippy::too_many_arguments)]
pub async fn api_sequencer_update_conditions_score(
    score: Option<f64>,
    transparency_score: Option<f64>,
    seeing_score: Option<f64>,
    cloud_score: Option<f64>,
    wind_score: Option<f64>,
    transparency_weight: f64,
    seeing_weight: f64,
    cloud_weight: f64,
    wind_weight: f64,
    generated_unix_secs: i64,
) -> Result<(), NightshadeError> {
    use nightshade_sequencer::scheduling::{ConditionsScore, ConditionsScoreWeights};
    let payload = score.map(|s| ConditionsScore {
        score: s,
        transparency_score,
        seeing_score,
        cloud_score,
        wind_score,
        weights: ConditionsScoreWeights {
            transparency_weight,
            seeing_weight,
            cloud_weight,
            wind_weight,
        },
        generated_unix_secs,
    });
    tracing::debug!(
        "[API] update_conditions_score: {:?}",
        payload.as_ref().map(|p| p.score)
    );
    let executor = get_sequence_executor().read().await;
    executor.update_conditions_score(payload).await;
    Ok(())
}

/// JSON-serialised snapshot of the live conditions score + adaptive
/// swap accounting (last swap timestamp, current tier, hysteresis
/// countdown info) for the Run Dashboard "Adaptive Conditions" panel.
/// Returns `Ok(None)` when no telemetry has been pushed since startup.
pub async fn api_sequencer_get_adaptive_swap_json() -> Result<Option<String>, NightshadeError> {
    let executor = get_sequence_executor().read().await;
    Ok(executor.current_adaptive_swap_json().await)
}

/// Set whether the standard weather and dawn triggers may park the mount and
/// close the cover and dome: the operator's "Park on unsafe weather" and
/// "Park before dawn" settings. Both default to parking. With one off, the
/// trigger still stops the run exposing (weather) or ends it (dawn), without
/// moving or closing anything. Takes effect on a running sequence at once.
pub async fn api_sequencer_set_park_policy(
    park_on_unsafe_weather: bool,
    park_before_dawn: bool,
) -> Result<(), NightshadeError> {
    tracing::info!(
        "Setting sequencer park policy: park on unsafe weather={}, park before dawn={}",
        park_on_unsafe_weather,
        park_before_dawn
    );
    let mut executor = get_sequence_executor().write().await;
    executor.set_park_policy(nightshade_sequencer::ParkPolicy {
        park_on_unsafe_weather,
        park_before_dawn,
    });
    Ok(())
}
