//! Sequence execution engine.
//!
//! This module owns the [`SequenceExecutor`] struct, its constructor, the
//! orchestrating [`SequenceExecutor::start`] method, the sequence-load /
//! totals-calculation helpers, the free-standing recovery / trigger helper
//! functions that the inline executor closures rely on, and the public
//! event / progress / state types.
//!
//! Cohesive concerns are split into sibling submodules:
//!   * [`lifecycle`]    — operator pause/resume/stop/skip/recovery-button.
//!   * [`recovery`]     — recovery state-machine snapshot accessors.
//!   * [`setup`]        — pre-start `set_*` wiring and post-run `reset`.
//!   * [`loading`]      — sequence load + read-only totals/order walks.
//!   * [`runtime_config`] — `update_*` mid-flight config mutators.
//!   * [`checkpoint`]   — crash-recovery save/load/resume surface.
//!   * [`decision`]     — structured-decision logging surface.
//!
//! What is deliberately kept here in `mod.rs`:
//!   * `start()` — the orchestrator. It captures dozens of locals into
//!     spawned tasks; extracting it would require either a giant
//!     parameter struct or making most private fields `pub(super)`,
//!     neither of which is a net win.
//!   * The free-standing helpers (`run_recovery_attempt`,
//!     `build_trigger_autofocus_context`, etc.) are owned here because
//!     the inline `start()` closures are their only callers.

mod checkpoint;
mod decision;
mod lifecycle;
mod loading;
mod recovery;
mod runtime_config;
mod setup;

use crate::device_ops::SharedDeviceOps;
use crate::node::instructions::autofocus::parse_autofocus_detail;
use crate::node::{
    CloudMotionSnapshot, ExecutionContext, Node, ProgressDetail, ProgressUpdate, RuntimeNode,
};
use crate::triggers::{Trigger, TriggerManager, TriggerState};
use crate::{
    NodeDefinition, NodeId, NodeStatus, NodeType, RecoveryAction, SafetyFailMode,
    SequenceDefinition, TriggerType,
};
use futures::FutureExt;
use parking_lot::RwLock as StdRwLock;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::panic::AssertUnwindSafe;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::{broadcast, mpsc, oneshot, watch, RwLock};

pub(crate) const RECOVERY_NODE_TRIGGER_PREFIX: &str = "recovery_node:";

/// Trigger id of a fired obstruction (trees, a building) in front of the
/// telescope. A `ParkAndAbort` fired under this id, like the dawn trigger's,
/// ends the night: the plan's shutdown steps run after the park, and the app
/// reads the id as the run's stop origin to start end-of-night calibration.
pub const OBSTRUCTION_TRIGGER_ID: &str = "obstruction";

/// Standard trigger ids whose `ParkAndAbort` ends the night, not only the run.
pub const END_OF_NIGHT_TRIGGER_IDS: [&str; 2] = ["dawn_approaching", OBSTRUCTION_TRIGGER_ID];
const DEFAULT_SAFETY_CHECK_INTERVAL_SECS: u64 = 30;

/// Summary line of the decision row written when an autofocus does not
/// converge and the run carries on at the pre-autofocus position: a trigger's
/// refocus, an Autofocus node, a recovery node's refocus, an exposure trigger's
/// refocus and the post-flip refocus all write it. The app raises its
/// "Autofocus failed — continuing" notification from this row, so the Replay
/// screen's copy, the notification and the tests that pin the policy cannot
/// drift apart.
pub const AUTOFOCUS_TRIGGER_CONTINUED_SUMMARY: &str =
    "Autofocus failed — continuing with last-good focus";

/// Summary line of the decision row written when a trigger-fired autofocus
/// stopped guiding for its sweep and could not prove guiding running again, so
/// the run is held for the operator instead of exposing unguided.
pub const AUTOFOCUS_TRIGGER_UNGUIDED_HOLD_SUMMARY: &str =
    "Autofocus left the guider stopped — run held, no unguided frames";

/// Default staleness window for the Dart weather verdict. The app re-sends its
/// verdict every minute and on every change, so six minutes is several missed
/// sends, not one late one.
const DEFAULT_WEATHER_VERDICT_STALENESS_SECS: u64 = 360;

/// Default for how long the sky must read safe before a weather hold ends: the
/// app's "required safe duration" until it pushes its own.
pub const DEFAULT_WEATHER_RESUME_AFTER_SAFE_SECS: u64 = 300;

/// How often a weather hold checks the sky.
pub const WEATHER_HOLD_CHECK_SECS: f64 = 15.0;

/// How often a guide-star hold looks for the star again, at most: soon enough
/// that the run resumes shortly after a cloud passes.
pub const GUIDE_STAR_RECHECK_SECS: f64 = 60.0;

/// First wait between attempts to get a stopped mount tracking again. Each
/// failed attempt doubles it, up to [`TRACKING_RECHECK_MAX_SECS`]; the attempts
/// never run out, because nothing else gets the mount tracking.
pub const TRACKING_RECHECK_SECS: f64 = 30.0;
pub const TRACKING_RECHECK_MAX_SECS: f64 = 300.0;

/// The span a weather hold reports as its budget. A hold has no budget and
/// never runs out; this only keeps the attempt counters the recovery events
/// carry finite.
pub const WEATHER_HOLD_NOMINAL_SPAN_SECS: f64 = 12.0 * 3600.0;

/// A weather hold at least this long recenters on the target before imaging
/// again: guided or not, an unguided mount drifts over that time.
pub const WEATHER_HOLD_RECENTER_AFTER_SECS: f64 = 15.0 * 60.0;

mod failure_cause;
mod flip_request;
mod monitoring;
mod preflight;
mod recovery_ops;
mod start;
mod trigger_context;
mod types;

pub use monitoring::*;
pub(crate) use preflight::*;
pub(crate) use recovery_ops::*;
use trigger_context::*;
pub use types::*;

/// The sequence executor manages running a sequence
pub struct SequenceExecutor {
    sequence: Option<SequenceDefinition>,
    state: Arc<RwLock<ExecutorState>>,
    progress: Arc<StdRwLock<SequenceProgress>>,
    command_tx: Option<mpsc::Sender<ExecutorCommand>>,
    /// Completion acknowledgment for the currently spawned executor task.
    /// `stop()` takes and awaits this receiver so native termination is not
    /// reported until instruction cancellation cleanup (including camera
    /// exposure abort) and terminal event emission have finished.
    run_completion_rx: Option<oneshot::Receiver<()>>,
    event_tx: broadcast::Sender<ExecutorEvent>,
    is_cancelled: Arc<AtomicBool>,
    root_node: Option<Box<dyn Node>>,
    /// Device operations handler - None indicates no device ops have been configured.
    /// Device ops MUST be set via set_device_ops() before starting a sequence.
    device_ops: Option<SharedDeviceOps>,
    /// Connected device IDs
    pub camera_id: Option<String>,
    pub mount_id: Option<String>,
    pub focuser_id: Option<String>,
    pub filterwheel_id: Option<String>,
    pub rotator_id: Option<String>,
    pub dome_id: Option<String>,
    pub cover_calibrator_id: Option<String>,
    /// Base save path for images
    pub save_path: Option<std::path::PathBuf>,
    /// Observer location
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    /// Trigger manager for monitoring conditions
    trigger_manager: Arc<RwLock<TriggerManager>>,
    /// Enable/disable trigger monitoring
    pub triggers_enabled: bool,
    /// Checkpoint manager for crash recovery.
    /// stored behind an `Arc` so the streaming-checkpoint task
    /// (spawned inside `start()`) shares the SAME instance — including its
    /// `info_cache` — instead of constructing a second
    /// `CheckpointManager::new(checkpoint_dir)` that bypasses the cache and
    /// causes UI staleness on `has_recoverable_checkpoint`.
    checkpoint_manager: Option<Arc<crate::checkpoint::CheckpointManager>>,
    /// DepthLock verdict source handed to every run's `ExecutionContext`.
    /// Installed by the host via [`Self::set_depth_goal_ops`]; `None` keeps
    /// bound plans count-bounded.
    depth_goal_ops: Option<crate::depth_goal::SharedDepthGoalOps>,
    /// Current checkpoint being updated
    current_checkpoint: Option<crate::checkpoint::SessionCheckpoint>,
    /// `resume_from_checkpoint` prepared the loaded sequence to resume, and
    /// the next `start()` is that resume. Loading another sequence cancels
    /// it; `start()` consumes it.
    resume_prepared: bool,
    /// Safety fail mode - determines behavior when safety devices fail or are unavailable
    pub safety_fail_mode: SafetyFailMode,
    /// Filter focus offsets from equipment profile (filter_name -> offset_steps)
    pub filter_focus_offsets: std::collections::HashMap<String, i32>,
    /// shared runtime configuration. Updated by
    /// `Update{DitherConfig,Location,FilterOffsets}` commands so changes
    /// take effect on the next dither/capture/autofocus without requiring a
    /// sequence reload. Cloned into the spawned executor task so the task
    /// reads the same values the public update_* methods write.
    ///
    /// Why `parking_lot::RwLock` instead of `tokio::sync::RwLock`: the
    /// public `update_*` methods are sync (already wired into the bridge
    /// crate that way) and the lock is only ever held for the duration of
    /// a struct-field assignment. A sync rwlock keeps the bridge call sites
    /// non-`.await` and is free of contention concerns for this access
    /// pattern.
    runtime_config: Arc<StdRwLock<RuntimeConfig>>,
    /// Recovery Mode — shared atomic flags that let the operator
    /// punch through the wait timer ("Try Now") or exit the loop ("Abort")
    /// without blocking on a mutex. Cloned into the spawned executor task
    /// so the recovery-loop driver sees the same atomic the public
    /// `recovery_try_now()` / `recovery_abort()` methods write.
    recovery_signals: Arc<crate::recovery::RecoverySignals>,
    /// Recovery Mode — most recent in-flight `RecoveryContext`.
    /// `None` whenever the executor is not in `Recovering`. Cloned for
    /// the `ExecutorEvent::Recovery*` events so the dashboard banner sees
    /// the same snapshot the executor sees.
    current_recovery: Arc<StdRwLock<Option<crate::recovery::RecoveryContext>>>,
    /// Recovery Mode — log of every completed recovery loop so the
    /// post-session report can render attempts/cause/duration/outcome.
    /// Trimmed at construction-time so a marathon run with hundreds of
    /// recoveries (something is very wrong then…) doesn't blow up memory.
    recovery_history: Arc<StdRwLock<Vec<crate::recovery::RecoveryHistoryEntry>>>,
    /// Replay Debug — structured decision broadcast channel. Every
    /// scheduler pick, trigger firing, recovery transition, frame verdict,
    /// adaptive swap, plugin invocation, manual operator action, and
    /// system event flows through this sender. The bridge layer
    /// subscribes via [`SequenceExecutor::subscribe_decisions`] and routes
    /// the events to the `SequencerEvent::DecisionLogged` typed payload
    /// + the `sequence_decisions` persistence table.
    decision_tx: crate::decision::DecisionSender,
    /// Replay Debug — the currently-active `sequence_runs.id` (set
    /// from the bridge via [`SequenceExecutor::set_active_sequence_run_id`]
    /// after the Dart side inserts the row). Stamped into every emitted
    /// `DecisionEvent` so the replay screen can filter by run without
    /// joining on a wall-clock window.
    active_sequence_run_id: Arc<StdRwLock<Option<i64>>>,
    /// Replay Debug — runtime toggle. When `false`, the executor
    /// short-circuits decision emission entirely (no channel send, no
    /// allocation). Wired to the `decisionLoggingEnabled` setting.
    decision_logging_enabled: Arc<AtomicBool>,
    /// adaptive sky-conditions swap. Stable Arc slots shared
    /// between this struct and the per-run `ExecutionContext`. Holding
    /// them on the executor too lets idle-time pushes (`update_conditions_score`
    /// called before `start()`) survive into the next run AND lets the
    /// dashboard's `current_adaptive_swap_json` reach a snapshot without
    /// needing access to the in-flight context.
    shared_conditions_score: Arc<RwLock<Option<crate::scheduling::ConditionsScore>>>,
    shared_adaptive_swap_state: Arc<RwLock<crate::node::context::AdaptiveSwapRuntimeState>>,
}

impl SequenceExecutor {
    pub fn new() -> Self {
        let (event_tx, _) = broadcast::channel(256);
        let (decision_tx, _) =
            broadcast::channel(crate::decision::DEFAULT_DECISION_CHANNEL_CAPACITY);
        let mut trigger_manager = TriggerManager::new();
        // Seed the standard safety triggers (HFR, weather, altitude limit, meridian
        // flip, etc.) at construction so a sequence loaded without an explicit
        // trigger config — e.g. headless API runs or first-launch users — still has
        // a baseline of unattended-imaging protections.
        trigger_manager.create_standard_triggers();

        Self {
            sequence: None,
            state: Arc::new(RwLock::new(ExecutorState::Idle)),
            progress: Arc::new(StdRwLock::new(SequenceProgress::default())),
            command_tx: None,
            run_completion_rx: None,
            event_tx,
            is_cancelled: Arc::new(AtomicBool::new(false)),
            root_node: None,
            device_ops: None,
            camera_id: None,
            mount_id: None,
            focuser_id: None,
            filterwheel_id: None,
            rotator_id: None,
            dome_id: None,
            cover_calibrator_id: None,
            save_path: None,
            latitude: None,
            longitude: None,
            trigger_manager: Arc::new(RwLock::new(trigger_manager)),
            triggers_enabled: true,
            checkpoint_manager: None,
            depth_goal_ops: None,
            current_checkpoint: None,
            resume_prepared: false,
            safety_fail_mode: SafetyFailMode::default(),
            filter_focus_offsets: std::collections::HashMap::new(),
            runtime_config: Arc::new(StdRwLock::new(RuntimeConfig::default())),
            recovery_signals: Arc::new(crate::recovery::RecoverySignals::new()),
            current_recovery: Arc::new(StdRwLock::new(None)),
            recovery_history: Arc::new(StdRwLock::new(Vec::new())),
            decision_tx,
            active_sequence_run_id: Arc::new(StdRwLock::new(None)),
            shared_conditions_score: Arc::new(RwLock::new(None)),
            shared_adaptive_swap_state: Arc::new(RwLock::new(
                crate::node::context::AdaptiveSwapRuntimeState::default(),
            )),
            // Replay Debug — default ON. The Dart settings layer
            // calls `set_decision_logging_enabled(false)` when the user
            // opts out; the overhead is negligible (one channel send +
            // one DB row per decision, well under 100 rows/min in real
            // sessions) so we ship enabled-by-default.
            decision_logging_enabled: Arc::new(AtomicBool::new(true)),
        }
    }

    async fn prepare_sequence_recovery_triggers(&self) -> Result<HashMap<String, NodeId>, String> {
        let Some(sequence) = &self.sequence else {
            return Ok(HashMap::new());
        };

        let specs = sequence_recovery_trigger_specs(sequence);
        let mut custom_branches = HashMap::new();
        let mut manager = self.trigger_manager.write().await;

        let stale_ids: Vec<String> = manager
            .triggers()
            .iter()
            .filter(|trigger| trigger.id.starts_with(RECOVERY_NODE_TRIGGER_PREFIX))
            .map(|trigger| trigger.id.clone())
            .collect();
        for trigger_id in stale_ids {
            manager.remove_trigger(&trigger_id);
        }

        for spec in specs {
            if let Some(node_id) = &spec.custom_branch_node_id {
                custom_branches.insert(spec.trigger_id.clone(), node_id.clone());
            }

            manager.add_trigger(Trigger::new(
                spec.trigger_id,
                spec.trigger_name,
                spec.trigger_type,
                spec.recovery_action,
            ));
        }

        Ok(custom_branches)
    }

    /// Get the current state
    pub async fn get_state(&self) -> ExecutorState {
        *self.state.read().await
    }

    /// Get the current progress
    pub fn get_progress(&self) -> SequenceProgress {
        self.progress.read().clone()
    }

    /// Emit an event
    fn emit(&self, event: ExecutorEvent) {
        let _ = self.event_tx.send(event);
    }

    /// Set state and emit event
    async fn set_state(&self, state: ExecutorState) {
        *self.state.write().await = state;
        {
            let mut progress = self.progress.write();
            progress.state = state;
        }
        self.emit(ExecutorEvent::StateChanged(state));
    }
}

impl Default for SequenceExecutor {
    fn default() -> Self {
        Self::new()
    }
}

/// Global executor instance
static EXECUTOR: std::sync::OnceLock<Arc<RwLock<SequenceExecutor>>> = std::sync::OnceLock::new();

/// Get the global executor instance
pub fn get_executor() -> &'static Arc<RwLock<SequenceExecutor>> {
    EXECUTOR.get_or_init(|| Arc::new(RwLock::new(SequenceExecutor::new())))
}

/// What a trigger-initiated dither attempt should be recorded as.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DitherTriggerOutcome {
    /// Dither happened; reset the interval.
    Performed,
    /// The rig has no guider, so there is nothing to dither. Reset the interval
    /// anyway — the condition cannot change mid-run, and leaving it unmarked made
    /// the trigger re-fire on every single exposure.
    SkippedNoGuider,
    /// A genuine failure (guide star lost, settle timeout). Keep the interval due
    /// so the next exposure retries, and warn.
    Failed,
}

/// Classify a dither result. Split out from the trigger loop so the three cases
/// are testable without standing up an executor.
pub(crate) fn classify_dither_result(
    status: NodeStatus,
    message: Option<&str>,
) -> DitherTriggerOutcome {
    if status == NodeStatus::Success {
        return DitherTriggerOutcome::Performed;
    }
    if message.is_some_and(crate::device_ops::is_no_guider_configured) {
        return DitherTriggerOutcome::SkippedNoGuider;
    }
    DitherTriggerOutcome::Failed
}

/// What a trigger-fired autofocus failure costs the run, and therefore what the
/// run is allowed to do next.
///
/// Both variants arrive as the same `NodeStatus::Failure`; only the result data
/// separates them (see
/// [`crate::instructions::AUTOFOCUS_GUIDING_NOT_RESTORED_KEY`]).
/// Collapsing them is what let a live run keep exposing 180 s lights after its
/// own log had said `CRITICAL CLEANUP FAILURE: guider accepted resume but did
/// not report guiding` — three frames, all trailed past the grader's limit, all
/// rejected, zero accepted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AutofocusTriggerFailureCost {
    /// The curve fit missed. The focuser is back where it started and the next
    /// frames are at worst slightly soft — cullable in the morning, and cheaper
    /// than spending the rest of a clear night stopped.
    SoftFramesOnly,
    /// The sweep stopped the guider and could not prove it running again. Every
    /// subsequent light is taken on an unguided mount, so every subsequent
    /// light trails. Nothing about waiting fixes this, and no further frame is
    /// worth taking until a human or a guider restart resolves it.
    EveryFrameUnguided,
}

/// Classify a failed trigger-fired autofocus from its result data.
///
/// Pure so the classification is testable without an executor; the marker is
/// stamped by the autofocus cleanup itself, which is the only code that knows
/// it stopped the guider and did not get it back.
pub(crate) fn autofocus_trigger_failure_cost(
    result_data: Option<&serde_json::Value>,
) -> AutofocusTriggerFailureCost {
    let guiding_not_restored = result_data
        .and_then(|data| data.get(crate::instructions::AUTOFOCUS_GUIDING_NOT_RESTORED_KEY))
        .and_then(serde_json::Value::as_bool)
        == Some(true);
    if guiding_not_restored {
        AutofocusTriggerFailureCost::EveryFrameUnguided
    } else {
        AutofocusTriggerFailureCost::SoftFramesOnly
    }
}

/// What the run records and tells the operator when a TRIGGER-fired autofocus
/// stopped the guider and could not restart it.
pub(crate) struct AutofocusUnguidedHold {
    /// Replay row (`SystemEvent`) naming why the run stopped taking frames.
    pub(crate) decision: crate::decision::DecisionEvent,
    /// One-line notice for the run's error feed / push.
    pub(crate) operator_message: String,
}

/// Build the hold record for a trigger autofocus that left the guider stopped.
///
/// Wording rule: say what the run DID (stopped taking frames), what it did NOT
/// do (touch the mount), and what clears it (a human, or restarting the
/// guider). The message the owner actually saw for this failure was `Change
/// Filter failed: Operation cancelled`, which named neither the cause nor the
/// consequence.
pub(crate) fn autofocus_trigger_unguided_hold(
    trigger_id: &str,
    trigger_name: &str,
    reason: &str,
    position_after: Option<i32>,
) -> AutofocusUnguidedHold {
    let decision = crate::decision::DecisionEvent::new(
        crate::decision::DecisionCategory::SystemEvent,
        AUTOFOCUS_TRIGGER_UNGUIDED_HOLD_SUMMARY.to_string(),
        serde_json::json!({
            "trigger_id": trigger_id,
            "trigger_name": trigger_name,
            "reason": reason,
            "focuser_position_after": position_after,
            "held_for_operator": true,
        }),
    );

    let operator_message = format!(
        "Autofocus trigger '{trigger_name}' stopped guiding for its sweep and could not get it \
         back ({reason}). The run is PAUSED before the next frame — an unguided light trails and \
         would only be rejected. Nothing has been moved or closed. Restart guiding and press \
         Resume."
    );

    AutofocusUnguidedHold {
        decision,
        operator_message,
    }
}

/// What the run records and tells the operator when an autofocus does not
/// converge and imaging continues.
pub(crate) struct AutofocusTriggerContinuation {
    /// Replay row (`SystemEvent`) naming the focus the run decided to keep. The
    /// app's "Autofocus failed — continuing" notification is raised from it.
    pub(crate) decision: crate::decision::DecisionEvent,
    /// One-line notice for the run's warnings.
    pub(crate) operator_message: String,
}

/// Build the continuation record for a non-converging trigger autofocus. Lives
/// outside the trigger loop so the policy — continue on the last-good focus,
/// never pause, park or end the run — is testable without standing up an
/// executor.
///
/// `origin_restored` is the `autofocus_origin_restored` marker from the failed
/// result: `Some(true)` the focuser went back to where it started, `Some(false)`
/// the return move failed and the motor is off its origin, `None` the run never
/// moved the focuser at all (e.g. admission rejected).
pub(crate) fn autofocus_trigger_continuation(
    trigger_id: &str,
    trigger_name: &str,
    reason: &str,
    position_before: Option<i32>,
    position_after: Option<i32>,
    origin_restored: Option<bool>,
) -> AutofocusTriggerContinuation {
    autofocus_failure_continuation(
        &format!("Autofocus trigger '{trigger_name}'"),
        serde_json::json!({
            "trigger_id": trigger_id,
            "trigger_name": trigger_name,
        }),
        reason,
        position_before,
        position_after,
        origin_restored,
    )
}

/// The continuation record for any autofocus that did not converge while the
/// run carries on. `source` names it in the operator's notice ("Autofocus
/// 'Refocus'", "Post-flip autofocus"), and the fields of `context` are added to
/// the decision row's details.
pub(crate) fn autofocus_failure_continuation(
    source: &str,
    context: serde_json::Value,
    reason: &str,
    position_before: Option<i32>,
    position_after: Option<i32>,
    origin_restored: Option<bool>,
) -> AutofocusTriggerContinuation {
    let mut details = serde_json::json!({
        "source": source,
        "reason": reason,
        "focuser_position_before": position_before,
        "focuser_position_after": position_after,
        "pre_autofocus_position_restored": origin_restored,
    });
    if let (Some(details), serde_json::Value::Object(context)) = (details.as_object_mut(), context)
    {
        details.extend(context);
    }
    let decision = crate::decision::DecisionEvent::new(
        crate::decision::DecisionCategory::SystemEvent,
        AUTOFOCUS_TRIGGER_CONTINUED_SUMMARY.to_string(),
        details,
    );

    let at_position = position_after
        .map(|p| format!("position {p}"))
        .unwrap_or_else(|| "an unreadable position".to_string());
    let operator_message = match origin_restored {
        Some(false) => format!(
            "{source} did not converge ({reason}) and the focuser could NOT be returned to its \
             pre-autofocus position — it is at {at_position}. Imaging continues, but check \
             focus before trusting these frames."
        ),
        Some(true) => format!(
            "{source} did not converge ({reason}). The focuser was returned to {at_position} \
             and imaging continues on the last-good focus."
        ),
        None => format!(
            "{source} did not converge ({reason}). The focuser is at {at_position} and imaging \
             continues on the last-good focus."
        ),
    };

    AutofocusTriggerContinuation {
        decision,
        operator_message,
    }
}

/// Summary of the decision row written when the software judged something bad
/// — guiding, pointing or settling — and the run carried on because the
/// operator has not asked it to stop for that. The app raises its "Problem
/// noticed — the run continues" notification from this row and matches the
/// text verbatim.
pub const QUALITY_PROBLEM_CONTINUED_SUMMARY: &str = "Problem noticed — the run continues";

/// The continuation record for a quality problem the run carries on through
/// (see [`crate::triggers::TriggerState::stop_on_quality_problems`]). `source`
/// names what noticed it ("Center 'M31'", "Post-flip recenter"), `problem`
/// says what it found, and the fields of `context` are added to the decision
/// row's details.
pub(crate) fn quality_problem_continuation(
    source: &str,
    problem: &str,
    context: serde_json::Value,
) -> AutofocusTriggerContinuation {
    let mut details = serde_json::json!({
        "source": source,
        "problem": problem,
    });
    if let (Some(details), serde_json::Value::Object(context)) = (details.as_object_mut(), context)
    {
        details.extend(context);
    }
    AutofocusTriggerContinuation {
        decision: crate::decision::DecisionEvent::new(
            crate::decision::DecisionCategory::SystemEvent,
            QUALITY_PROBLEM_CONTINUED_SUMMARY.to_string(),
            details,
        ),
        operator_message: format!(
            "{source}: {problem} The run continues. To have problems like this stop the run \
             instead, turn on Stop the run for quality problems in Settings > Sequencer."
        ),
    }
}

#[cfg(test)]
pub(crate) mod scenario_sim_tests;

#[cfg(test)]
mod night_end_sim_tests;

#[cfg(test)]
mod tests;
