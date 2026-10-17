//! Recovery Mode — snapshot accessors and runtime-config push for
//! the recovery state machine.
//!
//! The recovery loop itself runs inside the spawned executor task (see
//! the recovery-driver block in `mod.rs::start()`) — this file only
//! holds the small public surface the bridge / UI / tests use to read
//! the live state and push new defaults into the
//! [`crate::recovery::RecoveryRuntimeConfig`] slot.
//!
//! Layout note: the *operator* recovery gestures (`recovery_try_now`,
//! `recovery_abort`) live in `lifecycle.rs` because they are lifecycle
//! commands that drive the loop, not state reads. The clean split is:
//!
//!   * `recovery.rs` (this file): read state + push defaults.
//!   * `lifecycle.rs`           : "Try Now" / "Abort" buttons.
//!   * `mod.rs::start()`        : the actual retry-loop driver task.

use super::{ExecutorCommand, ExecutorEvent, SequenceExecutor};
use std::sync::Arc;

impl SequenceExecutor {
    /// Push updated recovery defaults (retry interval, max duration,
    /// stop-tracking flag, …) into the executor's runtime config.
    ///
    /// Cross-axis note: this method writes to `runtime_config` (the
    /// `runtime_config.rs` axis owns most other `update_*` mutators)
    /// but lives here because the value is recovery-specific and the
    /// next recovery entry is the only consumer. Putting it under
    /// `recovery` keeps the recovery surface coherent.
    ///
    /// Idempotent — a running executor receives the value via
    /// `ExecutorCommand::UpdateRecoveryConfig` so the next recovery
    /// entry honours it; an idle executor only sees the change on the
    /// next `start()`.
    pub async fn update_recovery_config(&mut self, config: crate::recovery::RecoveryRuntimeConfig) {
        tracing::info!(
            "Updating recovery defaults: interval={:.0}s, max_duration={:.0}s, stop_tracking={}, audible={}, park_and_close_on_give_up={}",
            config.retry_interval_secs,
            config.max_duration_secs,
            config.stop_tracking_during_recovery,
            config.audible_alert_when_entered,
            config.park_and_close_when_recovery_gives_up,
        );
        {
            let mut rc = self.runtime_config.write();
            rc.recovery = config.clone();
        }
        if let Some(tx) = &self.command_tx {
            let _ = tx
                .send(ExecutorCommand::UpdateRecoveryConfig { config })
                .await;
        }
        let _ = self.event_tx.send(ExecutorEvent::RuntimeConfigUpdated {
            what: "recovery_config".to_string(),
        });
    }

    /// Snapshot of the current in-flight recovery context. `None` when the
    /// executor is not in `Recovering`. Returned by-value so callers can
    /// inspect without holding the lock — useful for the Run Dashboard
    /// banner which polls this every redraw.
    pub fn current_recovery(&self) -> Option<crate::recovery::RecoveryContext> {
        self.current_recovery.read().clone()
    }

    /// Cloned recovery history. Every completed recovery loop is appended
    /// here; the post-session report pulls from this Vec. The history is
    /// trimmed at construction so a marathon session with hundreds of
    /// recoveries (something is very wrong then) doesn't blow up memory.
    pub fn recovery_history(&self) -> Vec<crate::recovery::RecoveryHistoryEntry> {
        self.recovery_history.read().clone()
    }

    /// Shared handle to the recovery signals atomic. Exposed for tests
    /// that need to inject `request_try_now()` / `request_abort()`
    /// without going through the command channel, and for the spawned
    /// executor task that reads the same atomic the operator gestures
    /// write.
    pub fn recovery_signals_handle(&self) -> Arc<crate::recovery::RecoverySignals> {
        self.recovery_signals.clone()
    }
}
