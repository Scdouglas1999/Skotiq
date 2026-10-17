use super::*;

/// DepthLock goal-state changes and ingestion outcomes.
///
/// Every automatic completion is explained through the sequencer's own
/// `DepthGoalCompleted` event; these carry the measurement side — what each
/// analysis concluded, which frames were refused and why, and when the
/// analysis queue had to shed work — so a remote client can render progress
/// and reliability without polling the goal store.
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum DepthLockEvent {
    /// A goal revision's committed analysis changed.
    GoalUpdated {
        goal_id: String,
        revision: u64,
        filter_name: String,
        /// `insufficientEvidence` | `collecting` | `confirmationPending` |
        /// `achieved` | `unreliable`.
        state: String,
        score: Option<f64>,
        conservative_score: Option<f64>,
        threshold: f64,
        uncertainty_adu: Option<f64>,
        coverage: f64,
        evidence_frames: u32,
        confirmation_frames: u32,
        reason: String,
        automatic_completion: bool,
        /// Exposures still needed (threshold plus confirmation), when the
        /// noise model can say; `None` before anything is measurable or
        /// when the goal is unreachable at its floor.
        frames_remaining: Option<u32>,
        reachable: bool,
    },
    /// A saved frame could not become evidence for a goal. The reason is
    /// the ingestion layer's own explanation, written for the operator.
    EvidenceRejected {
        goal_id: String,
        revision: u64,
        source_path: String,
        reason: String,
    },
    /// Analysis work was shed because the bounded queue was full. Raw
    /// saving and safety are unaffected; the frame stays on disk and can be
    /// re-ingested.
    AnalysisDropped { source_path: String, reason: String },
    /// A goal was created, revised, removed or had its preferences changed
    /// (`change` names which).
    GoalChanged {
        goal_id: String,
        revision: u64,
        change: String,
    },
}
