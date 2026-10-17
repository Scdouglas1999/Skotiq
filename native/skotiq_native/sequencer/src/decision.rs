//! Replay Debug: structured decision logging.
//!
//! Every executor decision is captured as a [`DecisionEvent`] and broadcast
//! on a dedicated tokio channel. The bridge layer consumes these, publishes
//! them to the unified [`SkotiqEvent`] stream as
//! `SequencerEvent::DecisionLogged`, and persists every row into the
//! `sequence_decisions` Drift table.
//!
//! The persisted log powers the Replay screen: a chronological feed of
//! every scheduler pick, trigger firing, recovery transition, budget
//! milestone, adaptive swap, frame verdict, plugin invocation, manual
//! operator action, and system event for a run. Filters + search +
//! time-range scrubbing let the user reconstruct "why did X happen at Y?"
//! retrospectively.
//!
//! # Design contract
//!
//! - Decisions are emitted in addition to (not instead of) the existing
//!   `ExecutorEvent::*` and `ProgressDetail::*` payloads. Loud-fail policy:
//!   we never substitute or hide a decision — every existing UI continues
//!   to work, and the replay log is a *forensic record*.
//! - Each event carries a UTC timestamp, a categorical label, a short
//!   human-readable summary, and an opaque structured `details` payload
//!   (a `serde_json::Value`) for the "View details" panel.
//! - Channel-send failures are silently dropped (the channel is best-effort
//!   for a UI subscriber); persistence is the source of truth.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;
use tokio::sync::broadcast;

/// Categories of decision the executor records for replay.
///
/// Wire-stable: variants are persisted by name into the
/// `sequence_decisions.category` column. The Dart side reflects this enum
/// via [`DecisionCategory.wire_key`] / [`DecisionCategory::from_wire_key`]
/// — adding variants is safe; renaming is not.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum DecisionCategory {
    /// TargetScheduler picked target X over a candidate list with scores.
    SchedulerPick,
    /// A trigger watchdog (HFR drift, guiding lost, time-of-day, etc.) fired
    /// and the executor ran its action.
    TriggerFired,
    /// The executor entered the Recovery state machine (or
    /// transitioned phase within it: Waiting → Attempting → Recovered → GaveUp).
    RecoveryEntered,
    /// A integration budget reached its configured target — either
    /// the per-filter cap or the whole-target total.
    BudgetMet,
    /// conditions-based adaptive target swap.
    AdaptiveSwap,
    /// grading accepted a frame.
    FrameAccepted,
    /// grading rejected a frame (with reason + metrics).
    FrameRejected,
    /// plugin node was dispatched.
    PluginNodeInvoked,
    /// Manual operator action: Pause, Resume, Skip, Try Now, Abort, etc.
    ManualIntervention,
    /// System event: sequence started/completed/failed, weather change,
    /// safety trigger, or any cross-cutting state transition we want in
    /// the replay timeline.
    SystemEvent,
}

impl DecisionCategory {
    /// Stable string identifier used by the persistence layer and the FRB
    /// wire format. snake_case so Dart can use it as a Map key directly.
    pub fn wire_key(&self) -> &'static str {
        match self {
            DecisionCategory::SchedulerPick => "scheduler_pick",
            DecisionCategory::TriggerFired => "trigger_fired",
            DecisionCategory::RecoveryEntered => "recovery_entered",
            DecisionCategory::BudgetMet => "budget_met",
            DecisionCategory::AdaptiveSwap => "adaptive_swap",
            DecisionCategory::FrameAccepted => "frame_accepted",
            DecisionCategory::FrameRejected => "frame_rejected",
            DecisionCategory::PluginNodeInvoked => "plugin_node_invoked",
            DecisionCategory::ManualIntervention => "manual_intervention",
            DecisionCategory::SystemEvent => "system_event",
        }
    }

    /// Inverse of [`Self::wire_key`]. Returns `None` on an unknown key — the
    /// caller decides whether to log + skip or treat as a hard error.
    pub fn from_wire_key(s: &str) -> Option<Self> {
        match s {
            "scheduler_pick" => Some(DecisionCategory::SchedulerPick),
            "trigger_fired" => Some(DecisionCategory::TriggerFired),
            "recovery_entered" => Some(DecisionCategory::RecoveryEntered),
            "budget_met" => Some(DecisionCategory::BudgetMet),
            "adaptive_swap" => Some(DecisionCategory::AdaptiveSwap),
            "frame_accepted" => Some(DecisionCategory::FrameAccepted),
            "frame_rejected" => Some(DecisionCategory::FrameRejected),
            "plugin_node_invoked" => Some(DecisionCategory::PluginNodeInvoked),
            "manual_intervention" => Some(DecisionCategory::ManualIntervention),
            "system_event" => Some(DecisionCategory::SystemEvent),
            _ => None,
        }
    }
}

/// A single decision recorded during sequence execution.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DecisionEvent {
    /// UTC timestamp the decision was made.
    pub timestamp: DateTime<Utc>,
    /// Category bucket — drives the filter chips on the replay screen.
    pub category: DecisionCategory,
    /// One-line human-readable summary ("TargetScheduler picked M27 (78/100)").
    pub summary: String,
    /// Structured details for the "View details" panel — opaque JSON the
    /// emit site authors. Stored verbatim in the DB and round-tripped to
    /// the Dart side without parsing.
    pub details: JsonValue,
    /// Optional node id this decision is associated with (the scheduler
    /// node, the target header, the exposure node, etc.). The Dart replay
    /// view uses this to deep-link to the node in the sequence tree.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub node_id: Option<String>,
    /// Optional sequence_run_id the decision belongs to. `None` for
    /// decisions emitted outside a live run (we never persist those, but
    /// the typed field is preserved for upcoming offline replay tooling).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sequence_run_id: Option<i64>,
}

impl DecisionEvent {
    /// Convenience constructor for the common case of "now + category +
    /// summary + details".
    pub fn new(category: DecisionCategory, summary: impl Into<String>, details: JsonValue) -> Self {
        Self {
            timestamp: Utc::now(),
            category,
            summary: summary.into(),
            details,
            node_id: None,
            sequence_run_id: None,
        }
    }

    /// Attach a node id (builder-style).
    pub fn with_node(mut self, node_id: impl Into<String>) -> Self {
        self.node_id = Some(node_id.into());
        self
    }

    /// Attach a sequence_run_id (builder-style).
    pub fn with_run(mut self, run_id: i64) -> Self {
        self.sequence_run_id = Some(run_id);
        self
    }
}

/// Default decision channel capacity. Decisions are low-frequency compared
/// to the executor event bus (a few per minute even in heavy nights), so a
/// 1024-slot ring is comfortably above worst case.
pub const DEFAULT_DECISION_CHANNEL_CAPACITY: usize = 1024;

/// Convenience type for the broadcast channel carrying [`DecisionEvent`]s.
pub type DecisionSender = broadcast::Sender<DecisionEvent>;
/// Receiver counterpart.
pub type DecisionReceiver = broadcast::Receiver<DecisionEvent>;

/// Best-effort emit. Drops on full channel / no receivers — never panics.
///
/// Returns `true` when the event made it into the channel, `false`
/// otherwise. Both outcomes are normal (no subscriber → false; subscriber
/// lagged → false on the *next* recv). The caller does NOT need to check
/// the return value; the persistence path runs from a dedicated subscriber
/// that bridges to the DB.
pub fn emit_decision(sender: &Option<DecisionSender>, event: DecisionEvent) -> bool {
    let Some(tx) = sender.as_ref() else {
        return false;
    };
    tx.send(event).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn category_wire_key_round_trip() {
        for cat in [
            DecisionCategory::SchedulerPick,
            DecisionCategory::TriggerFired,
            DecisionCategory::RecoveryEntered,
            DecisionCategory::BudgetMet,
            DecisionCategory::AdaptiveSwap,
            DecisionCategory::FrameAccepted,
            DecisionCategory::FrameRejected,
            DecisionCategory::PluginNodeInvoked,
            DecisionCategory::ManualIntervention,
            DecisionCategory::SystemEvent,
        ] {
            let key = cat.wire_key();
            let back = DecisionCategory::from_wire_key(key).expect("known key");
            assert_eq!(cat, back, "round-trip {:?}", cat);
        }
    }

    #[test]
    fn unknown_category_key_returns_none() {
        assert!(DecisionCategory::from_wire_key("not_a_real_category").is_none());
    }

    #[test]
    fn decision_event_builder_attaches_node_and_run() {
        let ev = DecisionEvent::new(
            DecisionCategory::SchedulerPick,
            "picked M31",
            serde_json::json!({ "target_id": "m31" }),
        )
        .with_node("scheduler-1")
        .with_run(42);
        assert_eq!(ev.node_id.as_deref(), Some("scheduler-1"));
        assert_eq!(ev.sequence_run_id, Some(42));
    }

    #[test]
    fn emit_decision_no_sender_returns_false() {
        let none: Option<DecisionSender> = None;
        let ev = DecisionEvent::new(
            DecisionCategory::SystemEvent,
            "no sender",
            serde_json::Value::Null,
        );
        assert!(!emit_decision(&none, ev));
    }

    #[test]
    fn emit_decision_no_receivers_returns_false() {
        let (tx, _) = broadcast::channel::<DecisionEvent>(4);
        // Drop the receiver immediately by not binding it; new() returns
        // sender alone — the subscribe-less case yields no receivers.
        let tx_opt = Some(tx);
        let ev = DecisionEvent::new(
            DecisionCategory::SystemEvent,
            "no subscribers",
            serde_json::Value::Null,
        );
        assert!(!emit_decision(&tx_opt, ev));
    }

    #[test]
    fn emit_decision_with_subscriber_delivers() {
        let (tx, mut rx) = broadcast::channel::<DecisionEvent>(4);
        let tx_opt = Some(tx);
        let ev = DecisionEvent::new(
            DecisionCategory::FrameAccepted,
            "frame 1/10 accepted",
            serde_json::json!({ "hfr": 1.8 }),
        );
        assert!(emit_decision(&tx_opt, ev));
        let received = rx.try_recv().expect("event delivered");
        assert_eq!(received.category, DecisionCategory::FrameAccepted);
        assert_eq!(received.summary, "frame 1/10 accepted");
        assert_eq!(received.details["hfr"], serde_json::json!(1.8));
    }
}
