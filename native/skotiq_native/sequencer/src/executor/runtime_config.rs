//! The settings surface of the [`SequenceExecutor`]: what the app pushes.
//!
//! Four kinds of thing arrive here, and each has one home:
//!
//!   * Operator settings: the one [`RunConfig`], which the app sends whole
//!     through [`super::ExecutorHandle::apply_run_config`]. Idle or running, the
//!     path is the same, and a changed section is announced once as
//!     `ExecutorEvent::RuntimeConfigUpdated`.
//!   * The next start's staging ([`RunStaging`]): the integration carry-over.
//!   * The live sky feed ([`SkyFeed`] and the weather readings on the trigger
//!     state): written straight to the slot the run reads.
//!   * The defect map: a resource the host loads and hands over.
//!
//! Device ids, the save path and the device handlers are wiring, not
//! settings; they are in [`super::setup`].

use super::{DefectMapApplyState, ExecutorEvent, RunConfigStore, SequenceExecutor};
use crate::node::context::{CloudMotionSnapshot, TransparencyBackupPlan};
use std::collections::HashMap;

impl SequenceExecutor {
    /// The store the run's tasks read the settings from.
    pub fn run_config_store(&self) -> RunConfigStore {
        self.settings.clone()
    }

    /// The observing site, or `None`s when it is not configured.
    pub fn observer_location(&self) -> (Option<f64>, Option<f64>) {
        let config = self.settings.read();
        (config.latitude, config.longitude)
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

    /// The defect map applied to lights during capture, loaded by the host;
    /// `None` turns correction off. Applies from the next exposure.
    pub async fn update_defect_map(&self, state: Option<DefectMapApplyState>) {
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

    /// The latest sky-brightness reading, for adaptive exposure; `None` when
    /// the tracker has lost lock.
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
