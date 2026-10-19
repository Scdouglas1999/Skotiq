//! The operator's "flip now" during a run.
//!
//! A standalone flip is refused while a sequence runs (two engines commanding
//! one mount is how pier crashes happen), so the running sequence offers this
//! instead: it marks the request on the shared trigger state, and the meridian
//! trigger fires it at the next safe point through its own flip action. See
//! `triggers/manual_flip.rs` for what the trigger does with the request.

use super::*;
use std::time::Duration;

/// How long the mount gets to answer whether it can flip.
const CAN_FLIP_PROBE_TIMEOUT: Duration = Duration::from_secs(10);

impl SequenceExecutor {
    /// Ask the running sequence to flip at its next safe point.
    ///
    /// Returns `Err` with an operator-facing reason when the flip cannot run:
    /// no run, a paused run, the meridian trigger off or cooling down from a
    /// flip, a mount that cannot flip, or a target the trigger would refuse
    /// (see [`crate::triggers::TriggerState::manual_flip_refusal`]). On `Ok`
    /// the flip has been queued, not performed; its outcome arrives as the
    /// usual `MeridianFlipOutcome` event.
    pub async fn request_meridian_flip(&self) -> Result<(), String> {
        match *self.state.read().await {
            ExecutorState::Running => {}
            ExecutorState::Paused => {
                return Err(
                    "The run is paused. Resume it first; a paused run moves nothing.".to_string(),
                )
            }
            state => {
                return Err(format!(
                    "No sequence is running (it is {state:?}), so there is no run to flip."
                ))
            }
        }
        if !self.triggers_enabled {
            return Err(
                "Triggers are off for this run, so its meridian flip cannot run.".to_string(),
            );
        }
        let Some(mount_id) = self.mount_id.clone() else {
            return Err("This run has no mount.".to_string());
        };

        let trigger_state = {
            let manager = self.trigger_manager.read().await;
            let Some(trigger) = manager.get_trigger("meridian_flip").filter(|t| t.enabled) else {
                return Err("The run's meridian flip trigger is turned off.".to_string());
            };
            if trigger.is_in_cooldown() {
                return Err(match trigger.cooldown_secs {
                    Some(secs) => {
                        format!("A meridian flip ran less than {} minutes ago.", secs / 60)
                    }
                    None => "A meridian flip ran moments ago.".to_string(),
                });
            }
            manager.state()
        };

        if let Some(reason) = trigger_state.read().await.manual_flip_refusal() {
            return Err(reason);
        }

        // The same capability question the flip executor asks before it moves
        // anything, asked now so the operator hears the answer.
        if let Some(ops) = &self.device_ops {
            match tokio::time::timeout(CAN_FLIP_PROBE_TIMEOUT, ops.mount_can_flip(&mount_id)).await
            {
                Ok(Ok(true)) => {}
                Ok(Ok(false)) => {
                    return Err("The mount cannot slew, so it cannot flip.".to_string())
                }
                Ok(Err(error)) => return Err(format!("The mount cannot flip: {error}")),
                Err(_) => {
                    return Err(
                        "The mount did not answer whether it can flip within 10 s.".to_string()
                    )
                }
            }
        }

        let (target, hour_angle) = {
            let mut state = trigger_state.write().await;
            // Re-checked under the write lock: the monitor may have moved the
            // target or completed a flip while the mount was being asked.
            if let Some(reason) = state.manual_flip_refusal() {
                return Err(reason);
            }
            state.meridian_flip_requested = true;
            (state.current_target_name.clone(), state.current_hour_angle)
        };
        tracing::info!(
            "[MERIDIAN] Operator requested a flip now for {:?} (hour angle {:?}h)",
            target,
            hour_angle
        );
        self.emit_manual_intervention(
            "request_meridian_flip",
            serde_json::json!({ "target": target, "hour_angle_hours": hour_angle }),
        );
        Ok(())
    }
}
