//! Replay Debug — structured decision logging surface on the
//! [`SequenceExecutor`].
//!
//! The executor broadcasts a typed `DecisionEvent` for every scheduler
//! pick, trigger firing, recovery transition, frame verdict, plugin
//! invocation, manual operator action, and lifecycle phase. The bridge
//! layer subscribes via [`SequenceExecutor::subscribe_decisions`] and
//! routes events to two sinks:
//!
//!   1. The unified `SkotiqEvent` stream as
//!      `SequencerEvent::DecisionLogged` (for live UI overlays).
//!   2. The `sequence_decisions` Drift table (for the post-run Replay
//!      screen).
//!
//! This file holds the small accessor / mutator methods that control the
//! sender, the active run-id stamp, and the runtime enable toggle. The
//! actual emit sites are scattered across the executor task, the
//! scheduler, the recovery driver, and the instruction nodes — they call
//! [`SequenceExecutor::emit_decision`] or use a clone of the sender
//! obtained from [`SequenceExecutor::decision_sender`].
//!
//! Not here: the `ManualIntervention` events emitted by operator-driven
//! lifecycle commands live in `lifecycle.rs::emit_manual_intervention` —
//! they're scoped narrowly so the broader `emit_decision` API stays the
//! single entry point for everything else.

use super::SequenceExecutor;
use std::sync::atomic::Ordering;

impl SequenceExecutor {
    /// Subscribe to the structured decision channel. Used by the bridge
    /// to bridge decisions onto the unified `SkotiqEvent` stream as
    /// `SequencerEvent::DecisionLogged` and to persist into the
    /// `sequence_decisions` Drift table.
    ///
    /// Each subscriber gets its own back-pressure buffer
    /// (`DEFAULT_DECISION_CHANNEL_CAPACITY` slots); a slow consumer that
    /// lags is dropped to `Lagged` rather than back-pressuring upstream
    /// emit sites.
    pub fn subscribe_decisions(&self) -> crate::decision::DecisionReceiver {
        self.decision_tx.subscribe()
    }

    /// Clone of the decision sender so emit sites outside the executor
    /// (instruction nodes, scheduler, recovery driver) can push events
    /// without touching the executor lock. The sender is `Clone`-cheap
    /// and the executor never lifts the channel; closure of the sender
    /// is observed by subscribers as `RecvError::Closed` on shutdown.
    pub fn decision_sender(&self) -> crate::decision::DecisionSender {
        self.decision_tx.clone()
    }

    /// Stamp every subsequent decision with the supplied
    /// `sequence_runs.id`. Called by the bridge once the Dart side has
    /// inserted the row (a few ms after `start()`). Pass `None` to
    /// clear the stamp (idle / between runs).
    ///
    /// The stamp is only authoritative for events that don't already
    /// carry a `sequence_run_id`; emitters that compose the event
    /// themselves can override it.
    pub fn set_active_sequence_run_id(&self, run_id: Option<i64>) {
        let mut guard = self.active_sequence_run_id.write();
        *guard = run_id;
    }

    /// Read the currently-active sequence_runs id. `None` between runs.
    pub fn active_sequence_run_id(&self) -> Option<i64> {
        *self.active_sequence_run_id.read()
    }

    /// Runtime toggle for decision emission. When `false`, every emit
    /// site short-circuits before allocating an event. Wired to the
    /// `decisionLoggingEnabled` app setting.
    pub fn set_decision_logging_enabled(&self, enabled: bool) {
        self.decision_logging_enabled
            .store(enabled, Ordering::Relaxed);
    }

    /// Read the runtime toggle. Cheap atomic load — safe to call from
    /// every emit site.
    pub fn decision_logging_enabled(&self) -> bool {
        self.decision_logging_enabled.load(Ordering::Relaxed)
    }

    /// Emit a decision into the broadcast channel. Stamps the active
    /// run id (if any) so persistence can write the FK without
    /// recomputing.
    ///
    /// Returns `true` when at least one subscriber accepted the event.
    /// Returns `false` when logging is disabled, the channel has no
    /// subscribers, or the channel is closed. Callers DO NOT need to
    /// check the return value — the persistence subscriber is the
    /// source of truth and a lost broadcast slot is recovered on the
    /// next emit.
    pub fn emit_decision(&self, mut event: crate::decision::DecisionEvent) -> bool {
        if !self.decision_logging_enabled() {
            return false;
        }
        if event.sequence_run_id.is_none() {
            event.sequence_run_id = self.active_sequence_run_id();
        }
        self.decision_tx.send(event).is_ok()
    }
}
