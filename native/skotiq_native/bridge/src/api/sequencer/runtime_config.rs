use super::*;

/// Set simulation mode (use mock devices instead of real hardware)
pub async fn api_sequencer_set_simulation_mode(enabled: bool) -> Result<(), SkotiqError> {
    tracing::info!("Setting sequencer simulation mode: {}", enabled);
    let mut executor = get_sequence_executor().write().await;

    // Production/release artifacts must not execute simulated hardware paths.
    if enabled && !cfg!(debug_assertions) {
        return Err(SkotiqError::NotSupported {
            device_id: "sequencer".to_string(),
            operation: "set_simulation_mode(true)".to_string(),
        });
    }

    if enabled {
        // Use NullDeviceOps for simulation
        executor.set_device_ops(std::sync::Arc::new(skotiq_sequencer::NullDeviceOps));
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
) -> Result<(), SkotiqError> {
    tracing::info!(
        "Setting sequencer devices: camera={:?}, mount={:?}, focuser={:?}, filterwheel={:?}, rotator={:?}, filter_names={:?}",
        camera_id, mount_id, focuser_id, filterwheel_id, rotator_id, filter_names
    );
    let filterwheel_for_names = filterwheel_id.clone();
    get_sequence_executor().write().await.set_devices(
        camera_id,
        mount_id,
        focuser_id,
        filterwheel_id,
        rotator_id,
    );

    if let Some(names) = filter_names {
        if names.is_empty() {
            return Err(SkotiqError::InvalidParameter(
                "filter_names was provided but empty; provide at least one name or pass null."
                    .to_string(),
            ));
        }

        let filterwheel_id = filterwheel_for_names.ok_or_else(|| {
            SkotiqError::InvalidParameter(
                "filter_names was provided but filterwheel_id is null. Provide a filter wheel ID before setting filter names."
                    .to_string(),
            )
        })?;

        let mgr = get_device_manager();
        mgr.filter_wheel_set_filter_names(&filterwheel_id, names)
            .await
            .map_err(|e| {
                SkotiqError::OperationFailed(format!(
                    "Failed to apply filter names to '{}': {}",
                    filterwheel_id, e
                ))
            })?;
    }

    Ok(())
}

/// Set the save path for sequencer images.
/// This is the base directory where captured images will be saved.
/// If not set (or set to None), images will NOT be saved to disk.
pub async fn api_sequencer_set_save_path(path: Option<String>) -> Result<(), SkotiqError> {
    let path_display = path.as_deref().unwrap_or("<none>");
    tracing::info!("Setting sequencer save path: {}", path_display);

    let mut executor = get_sequence_executor().write().await;
    executor.set_save_path(path.map(std::path::PathBuf::from));

    Ok(())
}

/// Replace the operator's sequencer settings: `config_json` is a whole
/// `skotiq_sequencer::RunConfig` as JSON, built by the app from its settings.
/// Each section that differs from the current settings takes effect and is
/// announced once; a value the executor refuses changes nothing and the error
/// says why. Never waits on the executor: the settings have their own lock.
pub async fn api_sequencer_apply_run_config(config_json: String) -> Result<(), SkotiqError> {
    let config: skotiq_sequencer::RunConfig = serde_json::from_str(&config_json).map_err(|e| {
        SkotiqError::InvalidParameter(format!("The sequencer settings could not be read: {e}"))
    })?;
    skotiq_sequencer::executor_handle()
        .apply_run_config(config)
        .await
        .map_err(SkotiqError::InvalidParameter)
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
) -> Result<(), SkotiqError> {
    tracing::info!(
        "Updating sequencer integration carry-over: {} target entries",
        carry_over.len()
    );
    let mut executor = get_sequence_executor().write().await;
    executor.update_pending_integration_carry_over(carry_over);
    Ok(())
}

// Cloud-motion-aware triggers
//
// Push the live `cloudMotionAnalyzerProvider` output from Dart into the
// executor's trigger state on a ~60s cadence (see WeatherSafetyNotifier).
// Drives the `CloudArrivingIn`, `CloudOpeningIn`, and `CloudCoverThreshold`
// triggers added in `skotiq_sequencer::TriggerType`.

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
) -> Result<(), SkotiqError> {
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
/// and this layer is inert. `advisory` marks an UNSAFE verdict that rests only
/// on a forecast or cloud model: it holds the run until the sky clears and
/// never parks the mount or ends the run.
pub async fn api_sequencer_update_weather_verdict(
    unsafe_override: Option<bool>,
    advisory: bool,
) -> Result<(), SkotiqError> {
    tracing::debug!(
        "[API] update_weather_verdict: unsafe_override={:?} advisory={}",
        unsafe_override,
        advisory
    );
    let executor = get_sequence_executor().read().await;
    executor
        .update_weather_verdict_from(unsafe_override, advisory)
        .await;
    Ok(())
}

/// The operator says the sky is clear. For `duration_secs` the app's weather
/// verdict is not acted on and a run held for weather resumes at once; `0`
/// ends the override early. A hardware safety monitor that reads unsafe still
/// holds the run. `reason` is recorded with the operator action.
pub async fn api_sequencer_set_weather_operator_clear(
    duration_secs: u32,
    reason: String,
) -> Result<(), SkotiqError> {
    tracing::info!(
        "[API] weather operator clear: {} s ({})",
        duration_secs,
        reason
    );
    let executor = get_sequence_executor().read().await;
    executor
        .set_weather_operator_clear(u64::from(duration_secs), &reason)
        .await;
    Ok(())
}

/// JSON-serialised cloud-motion snapshot for the run
/// dashboard. Returns `Ok(None)` when no data has been pushed yet.
pub async fn api_sequencer_get_cloud_motion_json() -> Result<Option<String>, SkotiqError> {
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
pub async fn api_sequencer_update_sky_brightness(mag: Option<f64>) -> Result<(), SkotiqError> {
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

// Recovery mode — FRB-exposed control surface
//
// added these to `bridge/src/sequencer_api.rs` but that module
// is OUTSIDE `crate::api`, which is FRB's scan root (see
// `flutter_rust_bridge.yaml > rust_input`). The functions never crossed the
// FRB boundary, so the Dart side fell back to `dynamic` dispatch with
// `NoSuchMethodError` placeholders. Re-homing them here closes that gap.

/// Operator pressed "Try Now" on the Run Dashboard banner — punch through
/// the wait timer and force the next recovery attempt immediately. No-op
/// when the executor is not currently in `Recovering`.
pub async fn api_sequencer_recovery_try_now() -> Result<(), SkotiqError> {
    tracing::info!("[API] Recovery: Try Now requested");
    let executor = get_sequence_executor().read().await;
    executor
        .recovery_try_now()
        .await
        .map_err(SkotiqError::OperationFailed)
}

/// Operator pressed "Abort" on the Run Dashboard banner — exits the recovery
/// loop and transitions the executor to `Failed`. No-op when not in
/// `Recovering`.
pub async fn api_sequencer_recovery_abort() -> Result<(), SkotiqError> {
    tracing::info!("[API] Recovery: Abort requested");
    let executor = get_sequence_executor().read().await;
    executor
        .recovery_abort()
        .await
        .map_err(SkotiqError::OperationFailed)
}

/// JSON-serialised snapshot of the current in-flight `RecoveryContext`.
/// Returns `None` when the executor is not currently in `Recovering`.
///
/// JSON-string-over-bridge is intentional: the Dart side already owns a
/// hand-written `RecoveryStatus.fromJson` mirror (see
/// `skotiq_core/lib/src/models/sequencer/recovery_status.dart`) so
/// piping serde JSON across is cheaper than asking FRB to bridge the
/// chrono-dependent `RecoveryContext` Rust struct.
pub async fn api_sequencer_get_current_recovery_json() -> Result<Option<String>, SkotiqError> {
    let executor = get_sequence_executor().read().await;
    let ctx = executor.current_recovery();
    match ctx {
        None => Ok(None),
        Some(c) => {
            let json = serde_json::to_string(&c).map_err(|e| {
                SkotiqError::SerializationError(format!("Recovery context serialise: {}", e))
            })?;
            Ok(Some(json))
        }
    }
}

/// JSON-serialised dump of every completed recovery loop since the executor
/// was constructed. Surfaced for the post-session report dialog. Returns an
/// empty JSON array `"[]"` when no recoveries have completed yet.
pub async fn api_sequencer_get_recovery_history_json() -> Result<String, SkotiqError> {
    let executor = get_sequence_executor().read().await;
    let history = executor.recovery_history();
    serde_json::to_string(&history)
        .map_err(|e| SkotiqError::SerializationError(format!("Recovery history serialise: {}", e)))
}

/// Replay Debug — stamp the active `sequence_runs.id` onto the
/// executor so every subsequent emitted DecisionEvent carries it as
/// `sequence_run_id`. Called by the Dart side immediately after the
/// `sequence_runs` row is inserted.
///
/// Pass `None` (Dart `null`) to clear the slot — useful at run end /
/// reset.
pub async fn api_sequencer_set_active_sequence_run_id(
    sequence_run_id: Option<i64>,
) -> Result<(), SkotiqError> {
    let executor = get_sequence_executor().read().await;
    executor.set_active_sequence_run_id(sequence_run_id);
    Ok(())
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
) -> Result<(), SkotiqError> {
    use skotiq_sequencer::scheduling::{ConditionsScore, ConditionsScoreWeights};
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
pub async fn api_sequencer_get_adaptive_swap_json() -> Result<Option<String>, SkotiqError> {
    let executor = get_sequence_executor().read().await;
    Ok(executor.current_adaptive_swap_json().await)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A start holds the executor through its preflight. Status reads and the
    /// settings push answer meanwhile (the mount guard's run check reads the
    /// same run state, without a lock at all).
    #[tokio::test]
    async fn status_and_settings_never_wait_on_the_executor() {
        let _serialized = crate::api::devices::simulation::sim_singleton_test_lock()
            .lock()
            .await;
        let held = get_sequence_executor().write().await;
        let answer = std::time::Duration::from_secs(2);

        tokio::time::timeout(answer, api_sequencer_get_state())
            .await
            .expect("the status is read while the executor is held");
        let config = skotiq_sequencer::executor_handle().run_config();
        tokio::time::timeout(
            answer,
            api_sequencer_apply_run_config(serde_json::to_string(&config).unwrap()),
        )
        .await
        .expect("the settings push does not wait on the executor")
        .expect("the settings apply");
        drop(held);
    }

    #[tokio::test]
    async fn a_run_config_the_executor_refuses_changes_nothing_and_says_why() {
        let _serialized = crate::api::devices::simulation::sim_singleton_test_lock()
            .lock()
            .await;
        let before = skotiq_sequencer::executor_handle().run_config();

        let refused = api_sequencer_apply_run_config(
            r#"{"autofocus_interval_frames": 0, "dither": {"pixels": 9.0,
                "settle_pixels": 1.0, "settle_time": 5.0, "settle_timeout": 60.0,
                "ra_only": false}}"#
                .to_string(),
        )
        .await;
        match refused {
            Err(SkotiqError::InvalidParameter(reason)) => {
                assert!(reason.contains("autofocus interval"), "{reason}")
            }
            other => panic!("expected a refusal, got {other:?}"),
        }
        assert!(matches!(
            api_sequencer_apply_run_config("not json".to_string()).await,
            Err(SkotiqError::InvalidParameter(_))
        ));
        assert_eq!(skotiq_sequencer::executor_handle().run_config(), before);
    }
}
