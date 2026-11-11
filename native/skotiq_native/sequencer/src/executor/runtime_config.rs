//! The settings surface of the [`SequenceExecutor`]: what the app pushes.
//!
//! Four kinds of thing arrive here, and each has one home:
//!
//!   * Operator settings. Every setter is read-modify-apply on the one
//!     [`RunConfig`] through [`RunConfigStore`]; [`SequenceExecutor::apply_run_config`]
//!     takes the whole value. Idle or running, the path is the same, and a
//!     changed section is announced once as
//!     `ExecutorEvent::RuntimeConfigUpdated`.
//!   * The next start's staging ([`RunStaging`]): the integration carry-over.
//!   * The live sky feed ([`SkyFeed`] and the weather readings on the trigger
//!     state): written straight to the slot the run reads.
//!   * The defect map: a resource the host loads and hands over.
//!
//! Device ids, the save path and the device handlers are wiring, not
//! settings; they are in [`super::setup`].

use super::{
    DefectMapApplyState, ExecutorEvent, ObserverProfile, ParkPolicy, RunConfig, RunConfigStore,
    SequenceExecutor,
};
use crate::node::context::{CloudMotionSnapshot, TransparencyBackupPlan};
use crate::SafetyFailMode;
use std::collections::HashMap;

impl SequenceExecutor {
    // Operator settings

    /// The current operator settings.
    pub fn run_config(&self) -> RunConfig {
        self.settings.snapshot()
    }

    /// The store the run's tasks read the settings from.
    pub fn run_config_store(&self) -> RunConfigStore {
        self.settings.clone()
    }

    /// Replace the operator settings. Each section that differs from the
    /// current value takes effect and is announced once; equal sections do
    /// nothing.
    pub async fn apply_run_config(&self, config: RunConfig) {
        self.settings
            .apply(config, &self.trigger_manager, &self.run_state)
            .await;
    }

    pub(super) async fn update_config(&self, edit: impl FnOnce(&mut RunConfig)) {
        self.settings
            .update(&self.trigger_manager, &self.run_state, edit)
            .await;
    }

    /// The observing site, or `None`s when it is not configured.
    pub fn observer_location(&self) -> (Option<f64>, Option<f64>) {
        let config = self.settings.read();
        (config.latitude, config.longitude)
    }

    /// Dither size and settle. Used by the next dither.
    pub async fn update_dither_config(
        &mut self,
        pixels: f64,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
        ra_only: bool,
    ) {
        self.update_config(|config| {
            config.dither.pixels = pixels;
            config.dither.settle_pixels = settle_pixels;
            config.dither.settle_time = settle_time;
            config.dither.settle_timeout = settle_timeout;
            config.dither.ra_only = ra_only;
        })
        .await;
    }

    /// The observing site. Reaches the altitude, dawn and meridian
    /// evaluation of a running sequence at its next poll. (0, 0) is how an
    /// unset site arrives and is stored as unset.
    pub async fn update_location(&mut self, lat: Option<f64>, lon: Option<f64>) {
        self.set_location(lat, lon).await;
    }

    /// See [`Self::update_location`].
    pub async fn set_location(&mut self, lat: Option<f64>, lon: Option<f64>) {
        self.update_config(|config| {
            config.latitude = lat;
            config.longitude = lon;
        })
        .await;
    }

    /// The daylight gate's maximum Sun altitude. `None` or a non-finite
    /// value means the default; see [`RunConfig::max_sun_altitude`]. The gate
    /// is safe without a push: the default equals the app scheduler's.
    pub async fn update_max_sun_altitude(&mut self, degrees: Option<f64>) {
        self.update_config(|config| config.max_sun_altitude_degrees = degrees)
            .await;
    }

    /// The operator's meridian-flip settings, for the standard flip trigger:
    /// the only flip path that runs on an unattended night.
    pub async fn update_meridian_flip_config(&mut self, flip: crate::MeridianFlipConfig) {
        self.update_config(|config| config.meridian_flip = Some(flip))
            .await;
    }

    /// Per-filter focus offsets from the equipment profile.
    pub async fn update_filter_offsets(&mut self, offsets: HashMap<String, i32>) {
        self.set_filter_focus_offsets(offsets).await;
    }

    /// See [`Self::update_filter_offsets`].
    pub async fn set_filter_focus_offsets(&mut self, offsets: HashMap<String, i32>) {
        self.update_config(|config| config.filter_focus_offsets = offsets)
            .await;
    }

    /// The operator's autofocus tuning, for trigger-fired refocus. It takes
    /// precedence over the sequence's first Autofocus node: a sequence
    /// without one is the sequence whose interval trigger fires unattended.
    pub async fn update_autofocus_config(&mut self, autofocus: crate::AutofocusConfig) {
        self.update_config(|config| config.autofocus = Some(autofocus))
            .await;
    }

    /// Cadence of the standard autofocus-interval trigger.
    pub async fn update_autofocus_interval(&mut self, every_n_frames: u32) {
        self.update_config(|config| config.autofocus_interval_frames = Some(every_n_frames))
            .await;
    }

    /// Grading thresholds for exposures without their own; `None` turns
    /// grading off for them. A run reads this when it starts.
    pub async fn update_default_quality_check(
        &mut self,
        check: Option<crate::quality::ImageQualityCheck>,
    ) {
        self.update_config(|config| config.default_quality_check = check)
            .await;
    }

    /// Where rejected frames go; `None` is a `Reject/` folder beside the
    /// frames. A run reads this when it starts.
    pub async fn update_reject_folder_path(&mut self, path: Option<String>) {
        self.update_config(|config| config.reject_folder_path = path)
            .await;
    }

    /// Observer and equipment names for the FITS header. A run reads this
    /// when it starts.
    pub async fn update_observer_profile(&mut self, profile: ObserverProfile) {
        self.update_config(|config| config.observer_profile = profile)
            .await;
    }

    /// Sky-brightness adaptive exposure for exposures without their own.
    pub async fn update_default_adaptive_exposure(
        &mut self,
        adaptive: Option<crate::scheduling::AdaptiveExposureConfig>,
    ) {
        self.update_config(|config| config.default_adaptive_exposure = adaptive)
            .await;
    }

    /// Retry cadence and budget of the recovery ladder. A ladder already
    /// running keeps the cadence it entered with.
    pub async fn update_recovery_config(&mut self, recovery: crate::recovery::RecoveryRuntimeConfig) {
        self.update_config(|config| config.recovery = recovery).await;
    }

    /// Whether the standard weather and dawn triggers may park (the
    /// operator's "Park on unsafe weather" and "Park before dawn"). Read each
    /// time one of them fires.
    pub async fn set_park_policy(&mut self, policy: ParkPolicy) {
        self.update_config(|config| config.park_policy = policy).await;
    }

    /// How many times a failed camera exposure or filter-wheel move is
    /// retried before it counts as a failure. Applies to the next attempt.
    pub async fn set_device_retry_policy(
        &mut self,
        policy: crate::instructions::DeviceRetryPolicy,
    ) {
        self.update_config(|config| config.device_retry = policy)
            .await;
    }

    /// Whether a quality problem the software judges (guiding RMS over the
    /// limit, a Center that did not converge, a dither that did not settle,
    /// a failed post-flip recenter or guiding check) stops the run or
    /// notifies the operator while imaging continues (the default).
    pub async fn set_stop_on_quality_problems(&self, stop: bool) {
        self.update_config(|config| config.stop_on_quality_problems = stop)
            .await;
    }

    /// What missing safety data means.
    pub async fn set_safety_fail_mode(&mut self, mode: SafetyFailMode) {
        self.update_config(|config| config.safety_fail_mode = mode)
            .await;
    }

    /// Cadence of safety and humidity device polls, held to 5..=3600 s; `0`
    /// is the default cadence, so it cannot switch polling off.
    pub async fn set_safety_check_interval_secs(&mut self, seconds: u64) {
        self.update_config(|config| {
            config.safety_check_interval_secs =
                super::effective_safety_check_interval_secs(seconds)
        })
        .await;
    }

    /// How long the sky must read safe before a weather hold ends: the
    /// operator's "required safe duration". Read at each weather-hold check.
    pub async fn set_weather_resume_after_safe_secs(&self, secs: u64) {
        self.update_config(|config| config.weather_resume_after_safe_secs = Some(secs))
            .await;
    }

    /// Whether decisions are written to the replay log.
    pub async fn set_decision_logging_enabled(&self, enabled: bool) {
        self.update_config(|config| config.decision_logging_enabled = enabled)
            .await;
    }

    pub fn decision_logging_enabled(&self) -> bool {
        self.settings.read().decision_logging_enabled
    }

    // The next start's staging

    /// Stage the operator's Resume / Restart choice from the session-handoff
    /// dialog for the next `start()`: `target_id` -> `filter` -> seconds.
    /// Calls merge per target (the last one wins), an empty inner map zeroes
    /// that target, and a target left out keeps what the run would otherwise
    /// start with. A start that is refused leaves the staging for the next
    /// attempt.
    pub fn update_pending_integration_carry_over(
        &mut self,
        carry_over: HashMap<String, HashMap<String, f64>>,
    ) {
        self.staging.integration_carry_over.extend(carry_over);
        self.run_state.emit(ExecutorEvent::RuntimeConfigUpdated {
            what: "integration_carry_over".to_string(),
        });
    }

    // The defect map

    /// The defect map applied to lights during capture, loaded by the host;
    /// `None` turns correction off. Applies from the next exposure.
    pub async fn update_defect_map(&mut self, state: Option<DefectMapApplyState>) {
        match &state {
            Some(s) => tracing::info!(
                "Updating defect map: camera={}, defects={}, kernel={}x{}, method={}, save_original={}",
                s.camera_id,
                s.map.defective_count(),
                s.kernel.diameter(),
                s.kernel.diameter(),
                s.method.as_str(),
                s.save_original,
            ),
            None => tracing::info!("Clearing defect map (defect correction disabled)"),
        }
        *self.defect_map_apply.write().await = state;
        self.announce_feed("defect_map");
    }

    // The live sky feed

    fn announce_feed(&self, what: &str) {
        self.run_state.emit(ExecutorEvent::RuntimeConfigUpdated {
            what: what.to_string(),
        });
    }

    /// JSON-serialised snapshot of the current cloud-motion
    /// reading for the run dashboard.
    ///
    /// Reads from the trigger manager state (the canonical home of
    /// pushed data) so the dashboard sees the same value the evaluator
    /// does. Uses try-lock so an in-flight write doesn't stall the
    /// dashboard tick: a stale reading beats blocking the UI.
    /// Returns `None` when no data has ever been pushed (distinguishes
    /// "no data yet" from "data says everything is clear").
    pub fn current_cloud_motion_json(&self) -> Option<String> {
        // Try-lock so an in-flight write doesn't stall the dashboard tick;
        // a stale reading beats blocking the UI.
        let manager = self.trigger_manager.try_read().ok()?;
        let state_lock = manager.state();
        let state = state_lock.try_read().ok()?;
        // Surface nothing if every field is None — distinguishes "no data
        // yet" from "data says everything is clear / unknown".
        if state.telemetry.current_cloud_coverage_percent.is_none()
            && state.telemetry.predicted_cloud_arrival_minutes.is_none()
            && state.telemetry.predicted_cloud_opening_minutes.is_none()
            && state.telemetry.predicted_clear_sky_direction.is_none()
            && state.telemetry.cloud_motion_last_update.is_none()
        {
            return None;
        }
        let snapshot = serde_json::json!({
            "current_cover_percent": state.telemetry.current_cloud_coverage_percent,
            "predicted_arrival_minutes": state.telemetry.predicted_cloud_arrival_minutes,
            "predicted_opening_minutes": state.telemetry.predicted_cloud_opening_minutes,
            "predicted_opening_duration_secs": state.telemetry.predicted_cloud_opening_duration_secs,
            "predicted_clear_sky_alt": state.telemetry.predicted_clear_sky_direction.map(|(a, _)| a),
            "predicted_clear_sky_az": state.telemetry.predicted_clear_sky_direction.map(|(_, a)| a),
            // last_update is a monotonic `Instant`, which is not directly
            // serializable; emit "now - elapsed_secs" so the dashboard can
            // show a "Xs ago" freshness indicator.
            "last_update_secs_ago":
                state.telemetry.cloud_motion_last_update.map(|i| i.elapsed().as_secs_f64()),
        });
        Some(snapshot.to_string())
    }

    /// The latest cloud-motion analyzer reading, for the cloud triggers and
    /// the slew-to-gap action. A clear-sky direction given as only one of
    /// altitude and azimuth is dropped: the executor does not invent the
    /// other coordinate.
    pub async fn update_cloud_motion(
        &self,
        current_cover_percent: Option<f64>,
        predicted_arrival_minutes: Option<f64>,
        predicted_opening_minutes: Option<f64>,
        predicted_opening_duration_secs: Option<f64>,
        predicted_clear_sky_alt: Option<f64>,
        predicted_clear_sky_az: Option<f64>,
    ) {
        let clear_sky = predicted_clear_sky_alt.zip(predicted_clear_sky_az);
        self.update_trigger_state(|state| {
            state.update_cloud_motion(
                current_cover_percent,
                predicted_arrival_minutes,
                predicted_opening_minutes,
                predicted_opening_duration_secs,
                clear_sky,
            )
        })
        .await;
        *self.sky.cloud_motion.write().await = CloudMotionSnapshot {
            current_cover_percent,
            predicted_arrival_minutes,
            predicted_opening_minutes,
            predicted_opening_duration_secs,
            predicted_clear_sky_direction: clear_sky,
            last_update_unix_secs: Some(chrono::Utc::now().timestamp()),
        };
        self.announce_feed("cloud_motion");
    }

    /// The app's weather-safety verdict: `Some(true)` unsafe, `Some(false)`
    /// safe, `None` no opinion. It is a second unsafe source next to the
    /// hardware safety monitor, for rigs without one, and can only make the
    /// run safer than the hardware reading.
    pub async fn update_weather_verdict(&self, unsafe_override: Option<bool>) {
        self.update_weather_verdict_from(unsafe_override, false)
            .await;
    }

    /// [`Self::update_weather_verdict`] with the verdict's source class.
    /// `advisory` marks an UNSAFE verdict that rests only on a forecast or
    /// cloud model: it holds the run and never parks it or ends it.
    pub async fn update_weather_verdict_from(&self, unsafe_override: Option<bool>, advisory: bool) {
        self.update_trigger_state(|state| {
            state.update_weather_verdict_from(unsafe_override, advisory)
        })
        .await;
        self.announce_feed("weather_verdict");
    }

    /// The operator says the sky is clear: for `duration_secs` the app's
    /// weather verdict is not acted on, and a run held for weather resumes now
    /// rather than after the safe period. `0` ends the override. A hardware
    /// safety monitor that reads unsafe still holds the run.
    pub async fn set_weather_operator_clear(&self, duration_secs: u64, reason: &str) {
        let until = (duration_secs > 0)
            .then(|| std::time::Instant::now() + std::time::Duration::from_secs(duration_secs));
        {
            let manager = self.trigger_manager.read().await;
            let state_lock = manager.state();
            state_lock
                .write()
                .await
                .telemetry
                .weather_operator_clear_until = until;
        }
        tracing::info!(
            "[SEQ] Operator weather override: clear for {} s ({})",
            duration_secs,
            reason
        );
        if until.is_some() {
            // Wake a weather hold that is waiting out its check interval.
            self.recovery_signals.request_try_now();
        }
        self.emit_manual_intervention(
            "weather_sky_clear",
            serde_json::json!({ "duration_secs": duration_secs, "reason": reason }),
        );
    }

<<<<<<< HEAD
    /// The latest sky-brightness reading, for adaptive exposure; `None` when
    /// the tracker has lost lock.
=======
    /// Set how long the sky must read safe before a weather hold ends: the
    /// operator's "required safe duration". Read at each weather-hold check,
    /// so it reaches a hold already in progress.
    pub fn set_weather_resume_after_safe_secs(&self, secs: u64) {
        self.runtime_config.write().weather_resume_after_safe_secs = Some(secs);
    }

    /// Update dither configuration at runtime.
    ///
    /// Writes through `runtime_config` so a running sequence picks up the new
    /// values on its next dither (no sequence reload required), then forwards
    /// `UpdateDitherConfig` to a live task per this file's two-step contract.
    pub async fn update_dither_config(
        &mut self,
        pixels: f64,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
        ra_only: bool,
    ) {
        tracing::info!(
            "Updating dither config: pixels={}, settle_pixels={}, settle_time={}, settle_timeout={}, ra_only={}",
            pixels, settle_pixels, settle_time, settle_timeout, ra_only
        );
        {
            let mut rc = self.runtime_config.write();
            rc.dither.pixels = pixels;
            rc.dither.settle_pixels = settle_pixels;
            rc.dither.settle_time = settle_time;
            rc.dither.settle_timeout = settle_timeout;
            rc.dither.ra_only = ra_only;
        }
        if let Some(tx) = &self.command_tx {
            let _ = tx
                .send(ExecutorCommand::UpdateDitherConfig {
                    pixels,
                    settle_pixels,
                    settle_time,
                    settle_timeout,
                    ra_only,
                })
                .await;
        }
        let _ = self.event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
            what: "dither".to_string(),
        });
    }

    /// Update observer location at runtime.
    ///
    /// Writes through `runtime_config` and the executor's own fields so a
    /// fresh `start()` sees the new site, then puts the location where the
    /// live consumers actually read it: `TriggerState`. `AltitudeLimit`,
    /// `DawnApproaching` and the meridian hour-angle all read the trigger
    /// state and nothing else — the per-tick `runtime_config` read in the
    /// trigger monitor only carries safety-poll settings — so a write that
    /// stops at `runtime_config` reaches none of them. A running task is
    /// updated through `ExecutorCommand::UpdateLocation`; an idle one is
    /// patched directly, since it has no task to send to.
    pub async fn update_location(&mut self, lat: Option<f64>, lon: Option<f64>) {
        // (0, 0) is how an unset observing site reaches us; it must not become a
        // real site in the Gulf of Guinea.
        let (lat, lon) = crate::node::context::normalized_observer_location(lat, lon);
        tracing::info!("Updating executor location: lat={:?}, lon={:?}", lat, lon);
        self.latitude = lat;
        self.longitude = lon;
        {
            let mut rc = self.runtime_config.write();
            rc.latitude = lat;
            rc.longitude = lon;
        }
        // A task whose run has ended keeps its sender, and a send to it
        // reaches nobody; patching the shared state as well is idempotent
        // with the live task's own update.
        let delivered = match &self.command_tx {
            Some(tx) => tx
                .send(ExecutorCommand::UpdateLocation {
                    latitude: lat,
                    longitude: lon,
                })
                .await
                .is_ok(),
            None => false,
        };
        if !delivered {
            let manager = self.trigger_manager.read().await;
            let state_lock = manager.state();
            let mut state = state_lock.write().await;
            state.set_observer_location(lat, lon);
        }
        let _ = self.event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
            what: "location".to_string(),
        });
    }

    /// Runtime override for the native daylight gate's maximum Sun altitude.
    ///
    /// The gate is safe without it: when this is never called, `start()` resolves
    /// the unset (`None`) field to
    /// [`crate::instructions::DEFAULT_MAX_SUN_ALTITUDE_DEGREES`] (-12°, nautical
    /// darkness), which equals the Dart `SchedulerConfig.maxSunAltitudeDegrees`
    /// default, so the native backstop never blocks weaker than the Dart gate.
    /// The setter is what a custom darkness limit — a future user-facing setting,
    /// or a non-default `SchedulerConfig` — is pushed through. No Dart caller is
    /// wired today because the darkness limit is not user-configurable, so an FFI
    /// export would only transmit a constant equal to the default.
    ///
    /// Follows the two-step write-then-forward contract: writes through
    /// `runtime_config` (canonical, honoured by the next `start()`), patches the
    /// idle trigger state directly so a loaded-but-not-running executor picks it
    /// up, and forwards `UpdateMaxSunAltitude` to a live task so a running
    /// sequence honours it on the next slew / exposure. `None`/non-finite
    /// resolves to [`crate::instructions::DEFAULT_MAX_SUN_ALTITUDE_DEGREES`].
    pub async fn update_max_sun_altitude(&mut self, degrees: Option<f64>) {
        let effective = match degrees {
            Some(v) if v.is_finite() => v,
            _ => crate::instructions::DEFAULT_MAX_SUN_ALTITUDE_DEGREES,
        };
        tracing::info!(
            "Updating max Sun altitude (W1 daylight gate): {:?} -> effective {:.1}°",
            degrees,
            effective
        );
        {
            let mut rc = self.runtime_config.write();
            rc.max_sun_altitude_degrees = degrees;
        }
        // Patch the idle trigger state directly so a loaded-but-not-running
        // executor also picks up the change (the command_tx path covers a live
        // executor; this covers the idle case).
        {
            let manager = self.trigger_manager.read().await;
            let state_lock = manager.state();
            let mut state = state_lock.write().await;
            state.set_max_sun_altitude_degrees(effective);
        }
        if let Some(tx) = &self.command_tx {
            let _ = tx
                .send(ExecutorCommand::UpdateMaxSunAltitude { degrees })
                .await;
        }
        let _ = self.event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
            what: "max_sun_altitude".to_string(),
        });
    }

    /// Push the operator's meridian-flip settings onto the standard
    /// `meridian_flip` trigger.
    ///
    /// Until this existed the trigger created by
    /// `TriggerManager::create_standard_triggers` kept
    /// `MeridianFlipConfig::default()` forever, so the entire
    /// Settings → Meridian Flip panel had NO effect on the trigger-driven flip
    /// — the only flip path that runs on an unattended night. Proven live: a
    /// run with `recenterAfterFlip: false` still executed
    /// `"Step 6/8: Plate solving and centering"`.
    ///
    /// The trigger manager is shared (`Arc<RwLock<..>>`) with the running
    /// trigger-monitor task, which re-reads it on every poll, so writing here
    /// covers both the idle (pre-`start()`) and live cases without a separate
    /// `ExecutorCommand` round trip.
    pub async fn update_meridian_flip_config(&mut self, config: crate::MeridianFlipConfig) {
        tracing::info!(
            "Updating meridian-flip trigger config: method={:?}, minutes_past={:.1}, \
             pause_before_meridian={:.1}, auto_center={}, refocus={}, pause_guiding={}, \
             resume_guiding={}, max_retries={}, failure_action={:?}",
            config.trigger_method,
            config.minutes_past_meridian,
            config.pause_before_meridian_minutes,
            config.auto_center,
            config.refocus_after,
            config.pause_guiding,
            config.resume_guiding,
            config.max_retries,
            config.failure_action,
        );
        let guiding = crate::GuiderSettle::from(&config);
        let applied = {
            let mut manager = self.trigger_manager.write().await;
            let applied = manager.set_meridian_flip_config(config);
            manager.state().write().await.settings.guiding_settle = Some(guiding);
            applied
        };
        if !applied {
            tracing::warn!(
                "Meridian-flip settings could not be applied: no 'meridian_flip' trigger \
                 is registered. The flip would run on Rust defaults."
            );
            return;
        }
        let _ = self.event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
            what: "meridian_flip_config".to_string(),
        });
    }

    /// stage per-target carry-over integration seconds so the
    /// next `start()` seeds the `BudgetRegistry` with the operator's
    /// "Resume" / "Restart" decision from the session-handoff dialog.
    ///
    /// Map shape: `target_id` → `filter_name` → `seconds`. Repeated
    /// calls merge (last-write-wins per `target_id`) so the Dart side
    /// can stage each target independently as the handoff dialog
    /// cycles through them. An empty inner map zeroes that target's
    /// carry-over (Restart semantics); omitting the target entirely
    /// preserves the existing behaviour (Continue New / no decision).
    ///
    /// The staged map is consumed exactly once by the spawned executor
    /// task at the top of `start()`. If `start()` aborts before
    /// consumption, the staged map persists for the next attempt.
    pub fn update_pending_integration_carry_over(
        &mut self,
        carry_over: std::collections::HashMap<String, std::collections::HashMap<String, f64>>,
    ) {
        tracing::info!(
            "Staging integration carry-over for {} targets",
            carry_over.len()
        );
        let mut rc = self.runtime_config.write();
        for (target_id, per_filter) in carry_over.into_iter() {
            rc.pending_integration_carry_over
                .insert(target_id, per_filter);
        }
        let _ = self.event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
            what: "integration_carry_over".to_string(),
        });
    }

    /// Update filter focus offsets at runtime.
    ///
    /// Writes through `runtime_config` so the next filter change reads the
    /// updated offsets, updates the executor's own `filter_focus_offsets` so a
    /// fresh start sees them too, and forwards `UpdateFilterOffsets` to a live
    /// task per this file's two-step contract.
    pub async fn update_filter_offsets(&mut self, offsets: std::collections::HashMap<String, i32>) {
        tracing::info!("Updating filter focus offsets: {} entries", offsets.len());
        self.filter_focus_offsets = offsets.clone();
        {
            let mut rc = self.runtime_config.write();
            rc.filter_focus_offsets = offsets.clone();
        }
        if let Some(tx) = &self.command_tx {
            let _ = tx
                .send(ExecutorCommand::UpdateFilterOffsets { offsets })
                .await;
        }
        let _ = self.event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
            what: "filter_offsets".to_string(),
        });
    }

    /// Push the operator's autofocus tuning so trigger-fired refocus uses it,
    /// and update the autofocus-interval cadence, at runtime.
    ///
    /// Without this the only source of trigger-autofocus config is an Autofocus
    /// node inside the sequence — and a sequence without one is exactly the
    /// sequence whose interval trigger fires unattended, running every refocus on
    /// library defaults rather than the operator's step size, exposure, backlash,
    /// failure tolerance and failure action. A node still wins at `start()`,
    /// because a node is a per-sequence decision and this is a global one.
    ///
    /// When a sequence is running the change is forwarded as an
    /// `ExecutorCommand::UpdateAutofocusInterval` so the live trigger manager is
    /// patched in place; otherwise the value is recorded in the runtime config
    /// and applied to the seeded standard trigger on the next `start()`. This
    /// method also patches the trigger directly, so an idle (loaded but not
    /// running) executor picks the change up immediately — that path cannot go
    /// through the command channel because no task is spawned.
    pub async fn update_autofocus_config(&mut self, config: crate::AutofocusConfig) {
        tracing::info!(
            "Updating trigger-autofocus config from operator settings (attempts={}, \
             failure tolerance={}x)",
            config.number_of_attempts,
            config.failure_hfr_tolerance_ratio,
        );
        let mut rc = self.runtime_config.write();
        rc.autofocus = Some(config);
    }

    pub async fn update_autofocus_interval(&mut self, every_n_frames: u32) {
        tracing::info!(
            "Updating autofocus-interval cadence: every {} frames",
            every_n_frames
        );
        {
            let mut rc = self.runtime_config.write();
            rc.autofocus_interval_frames = Some(every_n_frames);
        }
        // Patch the trigger directly so an idle (loaded but not running)
        // executor also picks up the change. The command_tx path covers a
        // live executor; this covers the idle case.
        {
            let mut mgr = self.trigger_manager.write().await;
            if let Some(trigger) =
                mgr.standard_mut(crate::triggers::StandardTrigger::AutofocusInterval)
            {
                if let TriggerType::AutofocusInterval {
                    every_n_frames: live,
                } = &mut trigger.trigger_type
                {
                    *live = every_n_frames;
                }
            }
        }
        if let Some(tx) = &self.command_tx {
            let _ = tx
                .send(ExecutorCommand::UpdateAutofocusInterval { every_n_frames })
                .await;
        }
        let _ = self.event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
            what: "autofocus_interval".to_string(),
        });
    }

    /// read-only handle for the runtime config so callers
    /// (the bridge layer, tests) can verify the latest values without
    /// constructing their own state. The returned `Arc` shares
    /// storage with the executor; callers see live writes.
    pub fn runtime_config_handle(&self) -> Arc<StdRwLock<RuntimeConfig>> {
        self.runtime_config.clone()
    }

    /// update the global default image-grading thresholds.
    ///
    /// `None` disables grading globally (per-node `quality_check` on
    /// TakeExposure still wins). When a sequence is running the
    /// change is forwarded as an
    /// `ExecutorCommand::UpdateDefaultQualityCheck` so the live tree
    /// picks it up on the next exposure; otherwise it is recorded for
    /// the next `start()`.
    pub async fn update_default_quality_check(
        &mut self,
        check: Option<crate::quality::ImageQualityCheck>,
    ) {
        tracing::info!(
            "Updating default_quality_check (active={})",
            check.as_ref().map(|c| c.is_active()).unwrap_or(false)
        );
        {
            let mut rc = self.runtime_config.write();
            rc.default_quality_check = check.clone();
        }
        if let Some(tx) = &self.command_tx {
            let _ = tx
                .send(ExecutorCommand::UpdateDefaultQualityCheck { check })
                .await;
        }
        let _ = self.event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
            what: "default_quality_check".to_string(),
        });
    }

    /// update the per-frame defect map applied to
    /// lights during capture.
    ///
    /// `None` disables defect correction (the user toggled the apply
    /// switch off, or the camera disconnected). A `Some(...)` value
    /// carries the pre-loaded `DefectMap`, replacement method, kernel
    /// size, and the save-original flag. Pre-loading happens bridge-
    /// side so per-frame application is just a slice operation; this
    /// method only swaps the `Arc<DefectMap>` reference.
    ///
    /// When a sequence is running the change is forwarded via
    /// `ExecutorCommand::UpdateDefectMap` so the live capture path
    /// sees it on the next exposure; otherwise it is only recorded
    /// for the next `start()`.
    pub async fn update_defect_map(&mut self, state: Option<DefectMapApplyState>) {
        match &state {
            Some(s) => tracing::info!(
                "Updating defect map: camera={}, defects={}, kernel={}x{}, method={}, save_original={}",
                s.camera_id,
                s.map.defective_count(),
                s.kernel.diameter(),
                s.kernel.diameter(),
                s.method.as_str(),
                s.save_original,
            ),
            None => tracing::info!("Clearing defect map (defect correction disabled)"),
        }
        {
            let mut rc = self.runtime_config.write();
            rc.defect_map_apply = state.clone();
        }
        if let Some(tx) = &self.command_tx {
            let _ = tx.send(ExecutorCommand::UpdateDefectMap { state }).await;
        }
        let _ = self.event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
            what: "defect_map".to_string(),
        });
    }

    /// update the reject-folder override.
    ///
    /// `None` => default `<save_path>/<target>/Reject/`. The image-grading code
    /// path consults this on each reject; mid-flight changes take
    /// effect at the next rejected frame.
    pub async fn update_reject_folder_path(&mut self, path: Option<String>) {
        tracing::info!("Updating reject_folder_path: {:?}", path);
        {
            let mut rc = self.runtime_config.write();
            rc.reject_folder_path = path.clone();
        }
        if let Some(tx) = &self.command_tx {
            let _ = tx
                .send(ExecutorCommand::UpdateRejectFolderPath { path })
                .await;
        }
        let _ = self.event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
            what: "reject_folder_path".to_string(),
        });
    }

    /// push observer / equipment identification so the next
    /// FITS save stamps real keywords (OBSERVER, TELESCOP, FOCALLEN,
    /// APTDIA, INSTRUME, SITEELEV).
    ///
    /// Idle executors record the value; the next `start()` seeds the
    /// ExecutionContext from runtime_config. Running executors get
    /// the value through the command channel so the very next
    /// exposure picks it up.
    pub async fn update_observer_profile(&mut self, profile: ObserverProfile) {
        tracing::info!(
            "Updating observer_profile: observer={:?}, telescope={:?}",
            profile.observer_name,
            profile.telescope_name
        );
        {
            let mut rc = self.runtime_config.write();
            rc.observer_profile = profile.clone();
        }
        if let Some(tx) = &self.command_tx {
            let _ = tx
                .send(ExecutorCommand::UpdateObserverProfile { profile })
                .await;
        }
        let _ = self.event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
            what: "observer_profile".to_string(),
        });
    }

    /// push the latest sky-brightness reading.
    ///
    /// The next exposure-burst's adaptive-exposure decision reads this
    /// value from the shared `ExecutionContext` field. Idle executors
    /// accept the call as a no-op — the value is only relevant once
    /// an exposure is being captured. NOT mirrored into
    /// `runtime_config` because the value is a transient telemetry
    /// reading rather than a persistent setting.
>>>>>>> 9aab79a51 (Split TriggerState into parts; reset and checkpoint follow from the part)
    pub async fn update_sky_brightness(&self, mag: Option<f64>) {
        *self.sky.sky_brightness_mag.write().await = mag;
        self.announce_feed("sky_brightness");
    }

    /// The latest sky transparency (fraction of clear sky), for the
    /// transparency trigger and the photometry gates; `None` when there is
    /// no reading.
    pub async fn update_transparency(&self, transparency: Option<f64>) {
        self.update_trigger_state(|state| state.update_transparency(transparency))
            .await;
        *self.sky.transparency.write().await = transparency;
        self.announce_feed("transparency");
    }

    /// The backup filter or target the switch-on-poor-transparency action
    /// turns to; `None` clears it.
    pub async fn update_transparency_backup(&self, plan: Option<TransparencyBackupPlan>) {
        *self.sky.transparency_backup.write().await = plan;
        self.announce_feed("transparency_backup");
    }

    /// The composite sky-conditions score the target scheduler's adaptive
    /// swap consults; `None` when the app has too little data.
    pub async fn update_conditions_score(&self, score: Option<crate::scheduling::ConditionsScore>) {
        *self.sky.conditions_score.write().await = score;
        self.announce_feed("conditions_score");
    }

    /// JSON-serialised snapshot of the live conditions score
    /// plus adaptive-swap accounting (last swap, current tier,
    /// hysteresis countdown) for the Run Dashboard "Adaptive
    /// Conditions" panel.
    ///
    /// Returns `None` only if neither slot has been touched, which
    /// lets the panel render an "off" state cleanly instead of
    /// fabricating zeros.
    pub async fn current_adaptive_swap_json(&self) -> Option<String> {
        let score = self.sky.conditions_score.read().await.clone();
        let state = self.shared_adaptive_swap_state.read().await.clone();
        if score.is_none()
            && state.last_decision_kind.is_none()
            && state.current_target_id.is_none()
        {
            return None;
        }
        let payload = serde_json::json!({
            "score": score,
            "state": state,
        });
        Some(payload.to_string())
    }

}
