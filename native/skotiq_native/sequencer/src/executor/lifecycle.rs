//! Operator-driven lifecycle commands on the [`SequenceExecutor`].
//!
//! Each public entry here is the single canonical way the bridge / UI tells
//! a running executor to change state mid-flight (pause, resume, stop, skip,
//! jump to a specific node, reply to a plugin node, drive the recovery loop
//! manually). Every method follows the same pattern:
//!
//!   1. Forward the operator intent over the command channel
//!      (`ExecutorCommand::…`) so the spawned executor task picks it up on
//!      its next iteration.
//!   2. Mirror the action onto the structured-decision log via
//!      [`SequenceExecutor::emit_manual_intervention`] so the post-session
//!      Replay screen can render an audit trail of operator actions.
//!
//! What is deliberately NOT here:
//!   * Steady-state config pushes (`update_dither_config`, `update_location`,
//!     …) — those live in `runtime_config.rs` because they mutate the
//!     [`RuntimeConfig`] handle rather than driving the executor task.
//!   * Recovery state-machine accessors (`current_recovery`,
//!     `recovery_history`) — those live in `recovery.rs`. The operator
//!     `recovery_try_now` / `recovery_abort` *commands* live here because
//!     they are lifecycle gestures (drive the loop), not state reads.

use super::{ExecutorCommand, SequenceExecutor};
use crate::NodeId;
use std::sync::atomic::Ordering;

impl SequenceExecutor {
    /// Pause the sequence. The currently-running instruction (e.g. an in-
    /// flight exposure) continues to completion; the next container's
    /// tree-walk step honours the pause by blocking on `resume_notify`.
    ///
    /// Invariant: idempotent — calling `pause()` on an already-paused
    /// sequence is a no-op (the channel send is dropped silently by the
    /// command loop's `Pause` arm).
    pub async fn pause(&self) -> Result<(), String> {
        if let Some(tx) = &self.command_tx {
            tx.send(ExecutorCommand::Pause)
                .await
                .map_err(|e| e.to_string())?;
        }
        self.emit_manual_intervention("pause", serde_json::json!({}));
        Ok(())
    }

    /// Resume from a `Paused` state. The executor task wakes via the shared
    /// `resume_notify` and the node tree picks up at the next walk step.
    pub async fn resume(&self) -> Result<(), String> {
        if let Some(tx) = &self.command_tx {
            tx.send(ExecutorCommand::Resume)
                .await
                .map_err(|e| e.to_string())?;
        }
        self.emit_manual_intervention("resume", serde_json::json!({}));
        Ok(())
    }

    /// Stop the sequence. Sets the shared cancellation flag *before* sending
    /// the channel command so the active instruction enters its hardware
    /// cancellation path immediately, then waits for the supervised executor
    /// task to finish that cleanup before confirming termination. Only after
    /// that acknowledgment is the local `command_tx` dropped.
    pub async fn stop(&mut self) -> Result<(), String> {
        self.stop_with_origin(None).await
    }

    /// [`Self::stop`] with the CALLER'S identity. The stop decision is what
    /// the dashboard's stop row claims "Stopped by request" off, and the
    /// scheduler drives this same path on unattended re-plans — an autopilot
    /// stop must not wear the operator's evidence.
    /// `origin` of `None` or `"operator"` is a human; `"scheduler"` is the
    /// autopilot.
    pub async fn stop_with_origin(&mut self, origin: Option<&str>) -> Result<(), String> {
        self.is_cancelled.store(true, Ordering::Release);

        if let Some(tx) = &self.command_tx {
            let _ = tx.send(ExecutorCommand::Stop).await;
        }

        match origin {
            Some("scheduler") => {
                // Not a manual intervention: record it as the system event
                // it is, under the normal decision-logging gate (autopilot
                // noise may be silenced; operator evidence may not).
                self.emit_lifecycle_system_decision(
                    "Autopilot: stop",
                    serde_json::json!({ "origin": "scheduler", "action": "stop" }),
                );
            }
            Some(other) if other != "operator" => {
                // Any other named system origin (e.g. a failed-launch
                // rollback): a stop nobody commanded. Gated system event,
                // and the feed's stop row stays cause-neutral.
                self.emit_lifecycle_system_decision(
                    "System: stop",
                    serde_json::json!({ "origin": other, "action": "stop" }),
                );
            }
            // None / "operator": a human's stop — the one decision that is
            // never silenceable, because it is the only evidence the stop
            // was human rather than a safety abort.
            _ => self.emit_manual_intervention("stop", serde_json::json!({})),
        }

        let completion_result = if let Some(completion_rx) = self.run_completion_rx.take() {
            completion_rx.await.map_err(|_| {
                "Executor task ended without confirming hardware cancellation cleanup".to_string()
            })
        } else {
            Ok(())
        };
        self.command_tx = None;
        completion_result
    }

    /// Replay Debug — emit a [`crate::decision::DecisionCategory::ManualIntervention`]
    /// event with the supplied action tag (`pause`, `resume`, `stop`,
    /// `skip`, `skip_to_node`, `recovery_try_now`, `recovery_abort`).
    /// Direct broadcast — does not go through the command channel so even
    /// idle / pre-start invocations are logged (mostly a no-op then, but
    /// the audit trail is honest).
    ///
    /// `pub(super)` because the lifecycle methods in this file are the
    /// only legitimate callers — runtime-config mutators in
    /// `runtime_config.rs` emit their own `RuntimeConfigUpdated` event
    /// instead.
    pub(super) fn emit_manual_intervention(&self, action: &str, details: serde_json::Value) {
        // The "stop" decision is the ONLY event that distinguishes an
        // operator's stop from a safety abort (every cancellation path emits
        // the same cancel-notice pair), and the dashboard's stop row claims
        // "Stopped by request" solely off it. Evidence of an operator action
        // must not be silenceable by the decision-logging preference, or a
        // press with logging off renders byte-identical to an unattended
        // weather abort.
        if action != "stop" && !self.decision_logging_enabled() {
            return;
        }
        let summary = format!("Operator: {}", action);
        let mut full = details;
        if let serde_json::Value::Object(ref mut m) = full {
            m.insert(
                "action".to_string(),
                serde_json::Value::String(action.to_string()),
            );
        } else {
            full = serde_json::json!({ "action": action, "data": full });
        }
        let ev = crate::decision::DecisionEvent {
            timestamp: chrono::Utc::now(),
            category: crate::decision::DecisionCategory::ManualIntervention,
            summary,
            details: full,
            node_id: None,
            sequence_run_id: self.active_sequence_run_id(),
        };
        let _ = self.decision_tx.send(ev);
    }

    /// Replay Debug — emit a [`crate::decision::DecisionCategory::SystemEvent`]
    /// decision from a lifecycle method. Unlike the operator's stop
    /// decision this respects the decision-logging gate: it records what
    /// the SYSTEM did, not evidence of a human action.
    fn emit_lifecycle_system_decision(&self, summary: &str, details: serde_json::Value) {
        if !self.decision_logging_enabled() {
            return;
        }
        let ev = crate::decision::DecisionEvent {
            timestamp: chrono::Utc::now(),
            category: crate::decision::DecisionCategory::SystemEvent,
            summary: summary.to_string(),
            details,
            node_id: None,
            sequence_run_id: self.active_sequence_run_id(),
        };
        let _ = self.decision_tx.send(ev);
    }

    /// Dart side reports the verdict of a plugin node
    /// that the executor previously dispatched via
    /// `ExecutorEvent::PluginNodeRequested`. The matching pending
    /// oneshot (registered by `PluginNodeInstruction::execute`) is
    /// resolved with the supplied verdict and the awaiting instruction
    /// future returns Success or Failure.
    ///
    /// `structured_detail_json` is optional; when present it is parsed
    /// as `serde_json::Value` and surfaced via the final
    /// `ProgressDetail::PluginNode` event. Invalid JSON is logged at
    /// warn and dropped (the verdict still applies).
    ///
    /// Returns an error if the executor is not running (no command
    /// channel) — callers MUST handle this rather than silently dropping
    /// a verdict that would otherwise time out the Rust-side oneshot.
    pub async fn plugin_node_finished(
        &self,
        node_id: NodeId,
        success: bool,
        message: Option<String>,
        structured_detail_json: Option<String>,
    ) -> Result<(), String> {
        if let Some(tx) = &self.command_tx {
            tx.send(ExecutorCommand::PluginNodeFinished {
                node_id,
                success,
                message,
                structured_detail_json,
            })
            .await
            .map_err(|e| e.to_string())?;
            Ok(())
        } else {
            Err("Executor is not running".to_string())
        }
    }

    /// Skip the current instruction / container. The tree-walk advances past
    /// the running node on its next step; an in-flight exposure burst is
    /// allowed to land before the skip takes effect.
    pub async fn skip(&self) -> Result<(), String> {
        if let Some(tx) = &self.command_tx {
            tx.send(ExecutorCommand::Skip)
                .await
                .map_err(|e| e.to_string())?;
        }
        self.emit_manual_intervention("skip", serde_json::json!({}));
        Ok(())
    }

    // Recovery Mode — operator-driven loop controls

    /// Operator pressed "Try Now" on the dashboard banner — punch through
    /// the wait timer and fire the next recovery attempt immediately. No-op
    /// when the executor is not in `Recovering`.
    pub async fn recovery_try_now(&self) -> Result<(), String> {
        // Direct atomic write so even an executor without an active
        // command channel still observes the request (e.g. tests).
        self.recovery_signals.request_try_now();
        if let Some(tx) = &self.command_tx {
            tx.send(ExecutorCommand::RecoveryTryNow)
                .await
                .map_err(|e| e.to_string())?;
        }
        self.emit_manual_intervention("recovery_try_now", serde_json::json!({}));
        Ok(())
    }

    /// Operator pressed "Abort" on the dashboard banner — exit the recovery
    /// loop and transition the executor to `Failed`. No-op when the
    /// executor is not in `Recovering`.
    pub async fn recovery_abort(&self) -> Result<(), String> {
        self.recovery_signals.request_abort();
        if let Some(tx) = &self.command_tx {
            tx.send(ExecutorCommand::RecoveryAbort)
                .await
                .map_err(|e| e.to_string())?;
        }
        self.emit_manual_intervention("recovery_abort", serde_json::json!({}));
        Ok(())
    }

    /// Jump execution to the node with the given id, marking preceding sibling
    /// nodes as Skipped. Honoured on the next container's tree-walk step; the
    /// currently-running instruction (e.g. an exposure burst) continues to
    /// completion first.
    ///
    /// Errors when the executor is not running, because the request would
    /// otherwise be dropped without the caller knowing.
    pub async fn skip_to_node(&self, node_id: NodeId) -> Result<(), String> {
        let node_id_for_decision = node_id.clone();
        if let Some(tx) = &self.command_tx {
            tx.send(ExecutorCommand::SkipToNode(node_id))
                .await
                .map_err(|e| e.to_string())?;
        } else {
            return Err("Executor is not running".to_string());
        }
        self.emit_manual_intervention(
            "skip_to_node",
            serde_json::json!({ "target_node_id": node_id_for_decision }),
        );
        Ok(())
    }
}
