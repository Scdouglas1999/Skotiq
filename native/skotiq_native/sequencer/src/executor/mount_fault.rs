//! Holding a run for a mount fault.
//!
//! The device layer watches the mount for motion nobody commanded and for a
//! position the mount can no longer vouch for (see the bridge's
//! `device_manager::motion_guard`). Either one makes every frame worthless
//! and every automatic move dangerous, so the run is paused, not ended: the
//! operator recovers the mount and resumes. This is the run's half of that.

use super::*;

impl SequenceExecutor {
    /// Pause a running run because its mount moved on its own or lost its
    /// position.
    ///
    /// The run's guiding is stopped the way the run's own moves stop it, so
    /// it is never read as a lost guide star and starts again on a fresh star
    /// after the run recenters. The frame exposing now is rejected when it
    /// finishes, and the next light frame first centers on the target.
    ///
    /// Returns `Ok(false)` when there is no run to hold.
    pub async fn hold_for_mount_fault(&self, message: &str) -> Result<bool, String> {
        let state = *self.state.read().await;
        if !matches!(
            state,
            ExecutorState::Running | ExecutorState::Paused | ExecutorState::Recovering
        ) {
            return Ok(false);
        }
        let trigger_state = self.trigger_manager.read().await.state();
        let run_guiding = {
            let mut ts = trigger_state.write().await;
            ts.mount_fault_at = Some(chrono::Utc::now().timestamp());
            ts.mount_fault_recenter_pending = true;
            ts.guiding.is_enabled()
        };
        if let Some(tx) = &self.command_tx {
            tx.send(ExecutorCommand::Pause)
                .await
                .map_err(|e| e.to_string())?;
        }
        if run_guiding {
            if let Some(ops) = &self.device_ops {
                crate::instructions::stop_an_active_guider(
                    ops,
                    "mount fault",
                    crate::GuidingStopReason::MountFault,
                )
                .await;
            }
            let mut ts = trigger_state.write().await;
            ts.set_guiding_enabled(false);
            ts.set_guide_star_lost(false);
            ts.guiding.set_resume_pending(true);
        }
        {
            let mut progress = self.progress.write();
            progress.message = Some(format!("Paused: {message}"));
        }
        // No executor error: an error reads as the run failing, and the
        // device layer already raised the alarm with what the mount did.
        self.emit_manual_intervention("mount_fault_hold", serde_json::json!({ "reason": message }));
        Ok(true)
    }
}
