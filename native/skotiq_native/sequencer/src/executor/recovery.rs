//! Read access to the recovery state machine: the ladder in flight and the
//! history of finished ones. The ladder itself is the recovery driver task;
//! the operator's "Try now" and "Abort" are in `lifecycle.rs`, and the
//! ladder's cadence is an operator setting in `runtime_config.rs`.

use super::SequenceExecutor;

impl SequenceExecutor {
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
}
