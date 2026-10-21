//! Mid-flight `update_*` configuration mutators on the [`SequenceExecutor`].
//!
//! Every value the bridge / Dart UI can change WHILE A SEQUENCE IS
//! RUNNING lives here. Each method follows the same contract:
//!
//!   1. Write through `self.runtime_config` (the
//!      [`super::RuntimeConfig`] handle the spawned executor task reads
//!      on every iteration). This is the canonical write — even an
//!      idle executor sees the change on the next `start()`.
//!   2. If a sequence is running (`self.command_tx` is `Some`), forward
//!      the change as the matching `ExecutorCommand` so the live task
//!      picks it up without having to re-read the runtime config slot
//!      itself — important for atomic fields the task caches.
//!   3. Emit `ExecutorEvent::RuntimeConfigUpdated { what: "..." }` so
//!      UI subscribers can invalidate any cached display.
//!
//! The two-step write-then-forward pattern is what keeps a mid-flight
//! update from becoming a silent fallback: an executor that
//! `let _ = (pixels, ...)`-ignores `UpdateDitherConfig` accepts the call
//! and changes nothing. The runtime config IS the truth; the command
//! channel only exists to wake the task.
//!
//! What is deliberately NOT here:
//!   * `set_*` pre-start setters — they live in [`super::setup`] because
//!     they mutate executor fields directly without going through the
//!     command channel.
//!   * `update_recovery_config` — lives in [`super::recovery`] because
//!     its value is recovery-specific and recovery is the only
//!     consumer. The cross-axis note in `recovery.rs` documents this.
//!   * `update_trigger_state` — lives in [`super::setup`] because it
//!     mutates the trigger manager state via a closure, not the
//!     runtime config.
//!   * Read-only `current_*` dashboard snapshots that are NOT paired
//!     with an `update_*` push (none currently) — those would belong
//!     wherever they read from. The two `current_*` methods that ARE
//!     here (cloud-motion JSON, adaptive-swap JSON) are paired with
//!     their matching `update_*` because the dashboard reads back what
//!     was pushed; co-locating them keeps the contract obvious.

use super::{
    DefectMapApplyState, ExecutorCommand, ExecutorEvent, ObserverProfile, RuntimeConfig,
    SequenceExecutor,
};
use crate::TriggerType;
use parking_lot::RwLock as StdRwLock;
use std::sync::Arc;

impl SequenceExecutor {
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
        if state.current_cloud_coverage_percent.is_none()
            && state.predicted_cloud_arrival_minutes.is_none()
            && state.predicted_cloud_opening_minutes.is_none()
            && state.predicted_clear_sky_direction.is_none()
            && state.cloud_motion_last_update.is_none()
        {
            return None;
        }
        let snapshot = serde_json::json!({
            "current_cover_percent": state.current_cloud_coverage_percent,
            "predicted_arrival_minutes": state.predicted_cloud_arrival_minutes,
            "predicted_opening_minutes": state.predicted_cloud_opening_minutes,
            "predicted_opening_duration_secs": state.predicted_cloud_opening_duration_secs,
            "predicted_clear_sky_alt": state.predicted_clear_sky_direction.map(|(a, _)| a),
            "predicted_clear_sky_az": state.predicted_clear_sky_direction.map(|(_, a)| a),
            // last_update is a monotonic `Instant`, which is not directly
            // serializable; emit "now - elapsed_secs" so the dashboard can
            // show a "Xs ago" freshness indicator.
            "last_update_secs_ago":
                state.cloud_motion_last_update.map(|i| i.elapsed().as_secs_f64()),
        });
        Some(snapshot.to_string())
    }

    /// push the latest cloud-motion analyzer reading.
    ///
    /// The cloud-aware triggers (`CloudArrivingIn`, `CloudOpeningIn`,
    /// `CloudCoverThreshold`) read these values on their next
    /// evaluation tick (1 Hz). When the executor is idle the sample
    /// is stashed directly on the trigger manager state so a fresh
    /// `start()` (which builds a new ExecutionContext) still sees the
    /// most-recent reading immediately, instead of waiting for the
    /// next Dart push.
    ///
    /// Invariant: `predicted_clear_sky_alt` and `predicted_clear_sky_az`
    /// must be both `Some` or both `None`; a half-specified direction
    /// is silently dropped (the executor refuses to invent a missing
    /// coordinate — "no silent fallbacks", and this one is
    /// explicit-drop with a None mirror, not a fabricated value).
    pub async fn update_cloud_motion(
        &self,
        current_cover_percent: Option<f64>,
        predicted_arrival_minutes: Option<f64>,
        predicted_opening_minutes: Option<f64>,
        predicted_opening_duration_secs: Option<f64>,
        predicted_clear_sky_alt: Option<f64>,
        predicted_clear_sky_az: Option<f64>,
    ) {
        tracing::debug!(
            "[SEQ] update_cloud_motion: cover={:?}%, arrival={:?}min, opening={:?}min ({:?}s), clear=({:?},{:?})",
            current_cover_percent,
            predicted_arrival_minutes,
            predicted_opening_minutes,
            predicted_opening_duration_secs,
            predicted_clear_sky_alt,
            predicted_clear_sky_az,
        );
        if let Some(tx) = &self.command_tx {
            let _ = tx
                .send(ExecutorCommand::UpdateCloudMotion {
                    current_cover_percent,
                    predicted_arrival_minutes,
                    predicted_opening_minutes,
                    predicted_opening_duration_secs,
                    predicted_clear_sky_alt,
                    predicted_clear_sky_az,
                })
                .await;
        } else {
            // Idle executor: stash the latest sample on the trigger
            // manager state directly so a fresh `start()` (which builds
            // a new ExecutionContext) still sees the most-recent reading
            // immediately, instead of waiting for the next Dart push.
            let manager = self.trigger_manager.read().await;
            let state_lock = manager.state();
            let mut state = state_lock.write().await;
            let clear_sky = match (predicted_clear_sky_alt, predicted_clear_sky_az) {
                (Some(alt), Some(az)) => Some((alt, az)),
                _ => None,
            };
            state.update_cloud_motion(
                current_cover_percent,
                predicted_arrival_minutes,
                predicted_opening_minutes,
                predicted_opening_duration_secs,
                clear_sky,
            );
        }
    }

    /// Push the Dart-side weather-safety verdict into the executor.
    ///
    /// The in-sequencer `WeatherUnsafe` trigger keys off the hardware
    /// `safety_is_safe` poll only, so a rig WITHOUT a hardware safety device
    /// never aborts via that trigger even when `weatherSafetyProvider` computed
    /// UNSAFE from the user's configured thresholds + API/cloud sources. This
    /// carries the Dart verdict as an additional unsafe source.
    /// `unsafe_override = Some(true)` => UNSAFE, `Some(false)` => SAFE, `None` =>
    /// abstain (provider disabled / no data). When the executor is idle the
    /// verdict is stashed directly on the trigger manager state so a subsequent
    /// `start()` (which builds a fresh ExecutionContext) sees it immediately
    /// rather than waiting for the next Dart push.
    pub async fn update_weather_verdict(&self, unsafe_override: Option<bool>) {
        tracing::debug!(
            "[SEQ] update_weather_verdict: unsafe_override={:?}",
            unsafe_override
        );
        if let Some(tx) = &self.command_tx {
            let _ = tx
                .send(ExecutorCommand::UpdateWeatherVerdict { unsafe_override })
                .await;
        } else {
            let manager = self.trigger_manager.read().await;
            let state_lock = manager.state();
            let mut state = state_lock.write().await;
            state.update_weather_verdict(unsafe_override);
        }
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
        if let Some(tx) = &self.command_tx {
            let _ = tx
                .send(ExecutorCommand::UpdateLocation {
                    latitude: lat,
                    longitude: lon,
                })
                .await;
        } else {
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
        let applied = {
            let mut manager = self.trigger_manager.write().await;
            manager.set_meridian_flip_config(config)
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
            if let Some(trigger) = mgr.get_trigger_mut("autofocus_interval") {
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
    pub async fn update_sky_brightness(&self, mag: Option<f64>) {
        tracing::debug!("Pushing sky brightness to executor: {:?} mag/arcsec²", mag);
        if let Some(tx) = &self.command_tx {
            let _ = tx.send(ExecutorCommand::UpdateSkyBrightness { mag }).await;
        }
        let _ = self.event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
            what: "sky_brightness".to_string(),
        });
    }

    /// push the composite sky-conditions score that the
    /// `TargetScheduler`'s adaptive-swap logic consults.
    ///
    /// The Dart side (`AdaptiveSwapService`) composes the score from
    /// transparency / seeing / cloud / wind every ~30 s and sends this
    /// update. When the executor is idle the value is stashed onto
    /// the shared `shared_conditions_score` slot so a subsequent
    /// `start()` sees the latest reading immediately; when running,
    /// the command channel routes it through `UpdateConditionsScore`.
    /// Passing `None` clears the slot (telemetry lost).
    pub async fn update_conditions_score(&self, score: Option<crate::scheduling::ConditionsScore>) {
        tracing::debug!(
            "Pushing conditions score to executor: {:?}",
            score.as_ref().map(|s| s.score)
        );
        if let Some(tx) = &self.command_tx {
            let _ = tx
                .send(ExecutorCommand::UpdateConditionsScore {
                    score: score.clone(),
                })
                .await;
        }
        // Always mirror onto the executor-level slot so an idle push is
        // not lost and the dashboard reads from one canonical place.
        {
            let mut slot = self.shared_conditions_score.write().await;
            *slot = score;
        }
        let _ = self.event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
            what: "conditions_score".to_string(),
        });
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
        let score = self.shared_conditions_score.read().await.clone();
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

    /// update the global default sky-brightness
    /// adaptive-exposure config.
    ///
    /// Per-node `ExposureConfig.adaptive_exposure` still wins; this is
    /// the runtime fallback applied to nodes that don't carry their
    /// own block. When a sequence is running the change is forwarded
    /// as an `ExecutorCommand::UpdateDefaultAdaptiveExposure`;
    /// otherwise the value is recorded in the runtime config for the
    /// next `start()`.
    pub async fn update_default_adaptive_exposure(
        &mut self,
        config: Option<crate::scheduling::AdaptiveExposureConfig>,
    ) {
        tracing::info!(
            "Updating default_adaptive_exposure (enabled={})",
            config.as_ref().map(|c| c.enabled).unwrap_or(false)
        );
        {
            let mut rc = self.runtime_config.write();
            rc.default_adaptive_exposure = config.clone();
        }
        if let Some(tx) = &self.command_tx {
            let _ = tx
                .send(ExecutorCommand::UpdateDefaultAdaptiveExposure { config })
                .await;
        }
        let _ = self.event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
            what: "default_adaptive_exposure".to_string(),
        });
    }
}
