//! Wizard infrastructure: a shared base for stepped automation routines.
//!
//! A *wizard* is a multi-step automation routine following the pattern "for
//! each step in a plan: do work, emit progress, check cancellation, optionally
//! record resumable state, repeat." The four production wizards today are:
//!
//! * `FlatWizard` — iterates exposure trials in a binary search to converge
//!   on a target ADU.
//! * `Mosaic` — validates / computes a panel grid (today: a single
//!   compute step; future: per-panel slew + center + expose).
//! * `PolarAlignment` — measures three sky positions, then enters an
//!   adjustment refinement loop.
//! * `AllSkyPolar` — captures a baseline frame, then loops on drift-pair
//!   refinement.
//!
//! This module provides:
//!
//! * The [`Wizard`] trait — wizards plug in by listing their steps and
//!   describing how to execute one step. Wizards may run a fixed plan
//!   (mosaic, polar alignment) or extend the plan dynamically based on
//!   step results (flat wizard's binary search, all-sky polar's
//!   adjustment loop).
//! * The [`WizardExecutor`] — drives a `Wizard` through its plan,
//!   handling cancellation, progress callbacks, and step-level
//!   checkpointing.
//! * The [`WizardCheckpoint`] schema — JSON-serializable record of
//!   completed step indices for a given wizard instance, lifted into
//!   [`crate::checkpoint::SessionCheckpoint::wizard_states`] so a
//!   sequence that was killed mid-wizard can pick up at the next
//!   uncompleted step on resume.
//!
//! # User-visible behavior
//!
//! Wrapping a wizard in [`WizardExecutor`] **does not change its outputs**.
//! FITS files, UI events, plate-solve callbacks, final `InstructionResult`
//! payload, and step ordering are all preserved. The executor adds:
//!
//! * Uniform `"Step X/Y: <description>"` progress messages.
//! * Pre-step cancellation checks.
//! * Optional persistence of completed step indices through
//!   [`WizardCheckpointSink`].
//!
//! Each wizard remains free to emit its own fine-grained progress
//! callbacks **inside** [`Wizard::execute_step`] (e.g. flat wizard's
//! "Iteration 5/10: testing 0.42s exposure"). The executor's progress
//! emission is in addition to, not in place of, those.
//!
//! # Plugin extensibility
//!
//! A future plugin that wants to author a new wizard implements [`Wizard`]
//! for its config type and delegates to a [`WizardExecutor`]. It then gets
//! progress, cancellation, and resume support "for free" without having
//! to reimplement those concerns. See `wizard_test_support` in this
//! module for an example.

use crate::checkpoint::WizardCheckpoint;
use crate::instructions::InstructionContext;
use async_trait::async_trait;
use std::sync::atomic::Ordering;

/// Trait implemented by every wizard. See module docs for the contract.
///
/// `StepKey` should be `Clone + Send + serde::Serialize + serde::DeserializeOwned`
/// so the executor can persist it inside the checkpoint. We intentionally do
/// **not** require `Eq`/`Hash` because the executor identifies completed steps
/// by their plan index, not by their key value.
#[async_trait]
pub trait Wizard: Send {
    /// Step identifier for this wizard. Typically a small enum or
    /// integer index.
    type StepKey: Clone + Send + Sync + serde::Serialize + serde::de::DeserializeOwned;
    /// Final result type the wizard produces once all steps complete.
    type Outcome: Send;

    /// Human-readable wizard name (used in progress messages and logs).
    fn name(&self) -> &'static str;

    /// Stable identifier used to look this wizard up in a checkpoint.
    /// Different invocations of the same wizard kind share a key — the
    /// checkpoint slot is replaced each run.
    fn checkpoint_key(&self) -> &'static str;

    /// Initial ordered list of steps to execute. Wizards with dynamic
    /// plans (binary search, adjustment loops) return a seed plan here
    /// and extend it via [`WizardStepOutcome::ContinueWithNext`].
    ///
    /// Default implementation ignores `resume_idx`; wizards with
    /// dynamic plans whose total length might exceed the seed-plan
    /// length when resuming MUST override this to grow the seed plan
    /// up to (or past) `resume_idx` so the executor's `while idx <
    /// plan.len()` loop body can re-enter.
    fn plan_steps(&self, resume_idx: usize) -> Vec<Self::StepKey>;

    /// Short description of a step (for progress messages). Default:
    /// "step {index+1}".
    fn describe_step(&self, _step: &Self::StepKey, idx: usize) -> String {
        format!("step {}", idx + 1)
    }

    /// Run a single step. The wizard implementor controls its own
    /// internal state via `&mut self`; the executor only orchestrates.
    ///
    /// `idx` is the zero-based step index within the (possibly
    /// extended) plan. `progress` lets the wizard emit fine-grained
    /// progress messages on top of the executor's step-level emission.
    async fn execute_step(
        &mut self,
        ctx: &InstructionContext,
        step: Self::StepKey,
        idx: usize,
        progress: &dyn WizardProgressReporter,
    ) -> WizardStepOutcome<Self::StepKey>;

    /// Called after the executor's step loop terminates (whether by
    /// completion, early `Done`, or `Failed`). Wizards turn their
    /// accumulated state into the final `Outcome`. On failure paths the
    /// `outcome` parameter carries the terminal status so cleanup logic
    /// (e.g. flat-panel teardown) can run regardless.
    fn finalize(self, status: WizardRunStatus) -> Self::Outcome;
}

/// Status passed to [`Wizard::finalize`] describing how the run ended.
#[derive(Debug, Clone)]
pub enum WizardRunStatus {
    /// All planned steps completed (or a step returned `Done`).
    Completed,
    /// A step returned `Cancelled` or the cancellation token was set
    /// between steps.
    Cancelled,
    /// A step returned `Failed(msg)`.
    Failed(String),
}

impl WizardRunStatus {
    pub fn is_success(&self) -> bool {
        matches!(self, WizardRunStatus::Completed)
    }

    pub fn failure_message(&self) -> Option<&str> {
        match self {
            WizardRunStatus::Failed(msg) => Some(msg.as_str()),
            _ => None,
        }
    }
}

/// Result of running one wizard step.
pub enum WizardStepOutcome<K> {
    /// Step completed; proceed to the next step in the plan.
    Completed,
    /// Step completed; append `next` to the plan and proceed to it.
    /// Used by dynamic-plan wizards (binary search, adjustment loop).
    ContinueWithNext(K),
    /// Step completed and the wizard is done — skip any remaining
    /// planned steps and finalize.
    Done,
    /// Step was cancelled. Executor reports `Cancelled` to caller.
    Cancelled,
    /// Step failed with a user-visible error message. Executor reports
    /// `Failed(msg)` to caller.
    Failed(String),
}

/// Hook invoked by the executor to surface step-level progress to the
/// outer sequencer UI. Implementations typically wrap the existing
/// instruction-level progress callback (`Fn(f64, String)`).
pub trait WizardProgressReporter: Send + Sync {
    /// Emit a progress update. `fraction` is 0.0..=1.0 representing
    /// overall wizard progress. `message` is a UI-ready string.
    fn report(&self, fraction: f64, message: String);
}

/// No-op reporter used in tests or when no callback is wired.
pub struct NoopProgressReporter;
impl WizardProgressReporter for NoopProgressReporter {
    fn report(&self, _fraction: f64, _message: String) {}
}

/// Adapter that bridges the legacy borrowed-closure progress callback
/// shape `Fn(f64, String)` (used throughout `instructions.rs`) to the
/// `WizardProgressReporter` trait. Wizards that are invoked from the
/// legacy dispatcher use this to plug into the executor without
/// allocating or extending the callback's lifetime.
///
/// `fraction` is scaled to 0..=100 before being passed to the
/// underlying callback (legacy callbacks expect percentage).
pub struct BorrowedProgressReporter<'a> {
    pub callback: Option<&'a (dyn Fn(f64, String) + Send + Sync)>,
}

impl<'a> WizardProgressReporter for BorrowedProgressReporter<'a> {
    fn report(&self, fraction: f64, message: String) {
        if let Some(cb) = self.callback {
            cb(fraction * 100.0, message);
        }
    }
}

/// Adapter that wraps a closure-style progress callback (the legacy
/// `Fn(f64, String)` shape used throughout `instructions.rs`).
pub struct ClosureProgressReporter<F>
where
    F: Fn(f64, String) + Send + Sync,
{
    callback: F,
}

impl<F> ClosureProgressReporter<F>
where
    F: Fn(f64, String) + Send + Sync,
{
    pub fn new(callback: F) -> Self {
        Self { callback }
    }
}

impl<F> WizardProgressReporter for ClosureProgressReporter<F>
where
    F: Fn(f64, String) + Send + Sync,
{
    fn report(&self, fraction: f64, message: String) {
        // Why: callers pass `fraction` as 0.0..=1.0 but legacy callbacks
        // expect 0..=100 percentage. Scale here so wizard implementations
        // can think in fractions while callers stay drop-in compatible.
        (self.callback)(fraction * 100.0, message);
    }
}

/// Interface the executor uses to persist wizard-internal step state.
/// Production wires this to the session checkpoint manager; tests
/// substitute an in-memory implementation.
pub trait WizardCheckpointSink: Send + Sync {
    /// Persist that the wizard identified by `checkpoint_key` has
    /// completed steps 0..completed_steps within the current plan.
    fn save(&self, checkpoint: &WizardCheckpoint);

    /// Load the most recent checkpoint for `checkpoint_key`, or None.
    fn load(&self, checkpoint_key: &str) -> Option<WizardCheckpoint>;

    /// Clear any persisted state for `checkpoint_key` (called when the
    /// wizard finishes successfully so a future run starts fresh).
    fn clear(&self, checkpoint_key: &str);
}

/// In-memory checkpoint sink for tests and headless headless runs.
#[derive(Default)]
pub struct MemoryCheckpointSink {
    inner: std::sync::Mutex<std::collections::HashMap<String, WizardCheckpoint>>,
}

impl WizardCheckpointSink for MemoryCheckpointSink {
    fn save(&self, checkpoint: &WizardCheckpoint) {
        let mut map = self.inner.lock().expect("MemoryCheckpointSink mutex");
        map.insert(checkpoint.checkpoint_key.clone(), checkpoint.clone());
    }

    fn load(&self, checkpoint_key: &str) -> Option<WizardCheckpoint> {
        let map = self.inner.lock().expect("MemoryCheckpointSink mutex");
        map.get(checkpoint_key).cloned()
    }

    fn clear(&self, checkpoint_key: &str) {
        let mut map = self.inner.lock().expect("MemoryCheckpointSink mutex");
        map.remove(checkpoint_key);
    }
}

/// Shared "wait until mount finishes slewing" helper used by every
/// wizard that issues a slew. Polls once per second until the mount has
/// stopped (see [`crate::slew_arrival`]: an idle `Slewing` flag read straight
/// after the command is not taken as the end of the slew). Errors out on
/// cancellation or after `timeout_secs`.
///
/// A failed `mount_is_slewing` read counts as "not slewing", so a mount that
/// stops answering ends the wait instead of holding it to the deadline.
pub async fn wait_for_slew_complete(
    ctx: &InstructionContext,
    mount_id: &str,
    timeout_secs: u64,
    timeout_label: &str,
) -> Result<(), String> {
    use crate::slew_arrival::{
        wait_for_slew_arrival, SlewArrivalTimings, SlewSample, SlewWaitError,
    };

    let timings = SlewArrivalTimings {
        poll_interval: std::time::Duration::from_secs(1),
        ..SlewArrivalTimings::goto(std::time::Duration::from_secs(timeout_secs))
    };
    let result = wait_for_slew_arrival(
        None,
        &timings,
        || async {
            SlewSample {
                slewing: Some(
                    ctx.device_ops
                        .mount_is_slewing(mount_id)
                        .await
                        .unwrap_or(false),
                ),
                position: None,
            }
        },
        || {
            ctx.cancellation_token
                .load(std::sync::atomic::Ordering::Relaxed)
        },
        |_| {},
    )
    .await;
    match result {
        Ok(_) => Ok(()),
        Err(SlewWaitError::Cancelled) => Err("Operation cancelled during slew".to_string()),
        Err(SlewWaitError::TimedOut(_)) => Err(format!(
            "{} timed out after {} seconds",
            timeout_label, timeout_secs
        )),
        Err(other) => Err(format!("{timeout_label}: {other}")),
    }
}

/// A `WizardCheckpointSink` that discards everything. Used when no
/// resume support is required (e.g. one-shot UI wizards that run
/// outside a sequence).
pub struct NullCheckpointSink;
impl WizardCheckpointSink for NullCheckpointSink {
    fn save(&self, _checkpoint: &WizardCheckpoint) {}
    fn load(&self, _checkpoint_key: &str) -> Option<WizardCheckpoint> {
        None
    }
    fn clear(&self, _checkpoint_key: &str) {}
}

/// Drives a [`Wizard`] through its plan.
///
/// The executor:
/// 1. Loads any persisted [`WizardCheckpoint`] matching the wizard's
///    `checkpoint_key()` to determine the resume index.
/// 2. Builds the initial plan via [`Wizard::plan_steps`].
/// 3. For each step from `resume_idx` onward:
///    a. Checks the cancellation token.
///    b. Reports "Step X/Y: <description>" via `progress`.
///    c. Awaits [`Wizard::execute_step`].
///    d. Handles the outcome: advances, extends the plan, terminates
///    early, or surfaces a failure.
///    e. Persists the completed step index.
/// 4. Invokes [`Wizard::finalize`] with the terminal status and clears
///    the checkpoint on success.
pub struct WizardExecutor<'a> {
    pub progress: &'a dyn WizardProgressReporter,
    pub checkpoint_sink: &'a dyn WizardCheckpointSink,
}

impl<'a> WizardExecutor<'a> {
    /// Construct an executor with a custom progress reporter and
    /// checkpoint sink. For most callers, [`WizardExecutor::with_progress`]
    /// is more convenient.
    pub fn new(
        progress: &'a dyn WizardProgressReporter,
        checkpoint_sink: &'a dyn WizardCheckpointSink,
    ) -> Self {
        Self {
            progress,
            checkpoint_sink,
        }
    }

    /// Construct an executor that emits progress to the given reporter
    /// and discards any checkpoint state. Equivalent to passing
    /// [`NullCheckpointSink`].
    pub fn with_progress(progress: &'a dyn WizardProgressReporter) -> Self {
        const NULL_SINK: &NullCheckpointSink = &NullCheckpointSink;
        Self {
            progress,
            checkpoint_sink: NULL_SINK,
        }
    }

    /// Run the wizard to completion or termination. Returns the
    /// wizard's finalized outcome plus the terminal status.
    pub async fn run<W: Wizard>(
        self,
        mut wizard: W,
        ctx: &InstructionContext,
    ) -> (W::Outcome, WizardRunStatus) {
        let checkpoint_key = wizard.checkpoint_key();
        let wizard_name = wizard.name();

        // Load checkpoint and determine resume index. A checkpoint without
        // WizardCheckpoint fields produces None, which resumes from step 0.
        let resume_idx = self
            .checkpoint_sink
            .load(checkpoint_key)
            .map(|cp| cp.completed_steps as usize)
            .unwrap_or(0);

        let mut plan = wizard.plan_steps(resume_idx);

        if resume_idx > 0 {
            tracing::info!(
                "Wizard '{}' resuming at step {} of {} (from checkpoint)",
                wizard_name,
                resume_idx + 1,
                plan.len()
            );
        }

        let mut idx = resume_idx;
        let mut terminal: Option<WizardRunStatus> = None;

        while idx < plan.len() {
            // Cancellation check before each step.
            if ctx.cancellation_token.load(Ordering::Relaxed) {
                tracing::info!(
                    "Wizard '{}' cancelled before step {}/{}",
                    wizard_name,
                    idx + 1,
                    plan.len()
                );
                terminal = Some(WizardRunStatus::Cancelled);
                break;
            }

            let step = plan[idx].clone();
            let description = wizard.describe_step(&step, idx);
            // Why: `idx` and `plan.len()` are bounded by realistic step counts
            // (max iterations are u32-bounded); u32 → f64 widening is lossless.
            let fraction = if plan.is_empty() {
                0.0
            } else {
                (idx as f64) / (plan.len() as f64)
            };
            self.progress.report(
                fraction,
                format!(
                    "{}: step {}/{} — {}",
                    wizard_name,
                    idx + 1,
                    plan.len(),
                    description
                ),
            );

            tracing::debug!(
                "Wizard '{}' running step {}/{}: {}",
                wizard_name,
                idx + 1,
                plan.len(),
                description
            );

            let outcome = wizard.execute_step(ctx, step, idx, self.progress).await;

            match outcome {
                WizardStepOutcome::Completed => {
                    idx += 1;
                }
                WizardStepOutcome::ContinueWithNext(next) => {
                    plan.push(next);
                    idx += 1;
                }
                WizardStepOutcome::Done => {
                    idx += 1;
                    tracing::debug!("Wizard '{}' completed early at step {}", wizard_name, idx);
                    // Persist final completion and break.
                    self.persist_checkpoint(checkpoint_key, idx);
                    terminal = Some(WizardRunStatus::Completed);
                    break;
                }
                WizardStepOutcome::Cancelled => {
                    tracing::info!(
                        "Wizard '{}' step {} returned Cancelled",
                        wizard_name,
                        idx + 1
                    );
                    terminal = Some(WizardRunStatus::Cancelled);
                    break;
                }
                WizardStepOutcome::Failed(msg) => {
                    tracing::warn!("Wizard '{}' step {} failed: {}", wizard_name, idx + 1, msg);
                    terminal = Some(WizardRunStatus::Failed(msg));
                    break;
                }
            }

            self.persist_checkpoint(checkpoint_key, idx);
        }

        let status = terminal.unwrap_or(WizardRunStatus::Completed);
        if status.is_success() {
            // Final progress at 100%.
            self.progress
                .report(1.0, format!("{} complete", wizard_name));
            // Clear the checkpoint so a fresh run starts at step 0.
            self.checkpoint_sink.clear(checkpoint_key);
        }
        let outcome = wizard.finalize(status.clone());
        (outcome, status)
    }

    fn persist_checkpoint(&self, key: &'static str, completed_steps: usize) {
        let cp = WizardCheckpoint {
            checkpoint_key: key.to_string(),
            // Why: realistic plan sizes (mosaic <= ~hundreds, binary search <= 10)
            // are far below u32::MAX; usize → u32 saturation is acceptable for
            // the pathological overflow case (saturate to u32::MAX so the next
            // load triggers a re-run from start, the conservative fallback).
            completed_steps: u32::try_from(completed_steps).unwrap_or(u32::MAX),
            timestamp: chrono::Utc::now(),
        };
        self.checkpoint_sink.save(&cp);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    /// Test wizard with a fixed 3-step plan that records visited
    /// steps. Exercises the happy-path executor flow.
    #[derive(Default)]
    struct CountingWizard {
        visited: Vec<u32>,
    }

    #[async_trait]
    impl Wizard for CountingWizard {
        type StepKey = u32;
        type Outcome = Vec<u32>;

        fn name(&self) -> &'static str {
            "CountingWizard"
        }
        fn checkpoint_key(&self) -> &'static str {
            "test::counting"
        }
        fn plan_steps(&self, _resume_idx: usize) -> Vec<u32> {
            vec![10, 20, 30]
        }
        async fn execute_step(
            &mut self,
            _ctx: &InstructionContext,
            step: u32,
            _idx: usize,
            _progress: &dyn WizardProgressReporter,
        ) -> WizardStepOutcome<u32> {
            self.visited.push(step);
            WizardStepOutcome::Completed
        }
        fn finalize(self, _status: WizardRunStatus) -> Vec<u32> {
            self.visited
        }
    }

    /// Wizard that dynamically extends its plan up to a target count
    /// (mirrors flat wizard's binary-search loop).
    struct DynamicWizard {
        max: u32,
        visited: Vec<u32>,
    }

    #[async_trait]
    impl Wizard for DynamicWizard {
        type StepKey = u32;
        type Outcome = Vec<u32>;
        fn name(&self) -> &'static str {
            "DynamicWizard"
        }
        fn checkpoint_key(&self) -> &'static str {
            "test::dynamic"
        }
        fn plan_steps(&self, _resume_idx: usize) -> Vec<u32> {
            vec![0]
        }
        async fn execute_step(
            &mut self,
            _ctx: &InstructionContext,
            step: u32,
            _idx: usize,
            _progress: &dyn WizardProgressReporter,
        ) -> WizardStepOutcome<u32> {
            self.visited.push(step);
            if step + 1 < self.max {
                WizardStepOutcome::ContinueWithNext(step + 1)
            } else {
                WizardStepOutcome::Done
            }
        }
        fn finalize(self, _status: WizardRunStatus) -> Vec<u32> {
            self.visited
        }
    }

    fn dummy_ctx() -> InstructionContext {
        InstructionContext {
            node_id: String::new(),
            target_ra: None,
            target_dec: None,
            target_rotation: None,
            target_name: None,
            current_filter: None,
            current_binning: crate::Binning::One,
            cancellation_token: Arc::new(AtomicBool::new(false)),
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
            device_ops: Arc::new(crate::device_ops::NullDeviceOps),
            trigger_state: None,
            filter_focus_offsets: std::collections::HashMap::new(),
            event_tx: None,
            recovery_request_tx: None,
            device_disconnect_recovery_pending: std::sync::Arc::new(
                std::sync::atomic::AtomicBool::new(false),
            ),
            session_id: String::new(),
            target_id: None,
            mosaic_panel: None,
            current_filter_index: None,
            set_temp_c: None,
            bayer_pattern: None,
            observer_name: None,
            site_elevation_m: None,
            camera_make: None,
            camera_model: None,
            telescope_name: None,
            telescope_focal_length_mm: None,
            telescope_aperture_mm: None,
            last_plate_solve: Arc::new(tokio::sync::RwLock::new(None)),
            hfr_baseline: Arc::new(tokio::sync::RwLock::new(None)),
            hfr_baseline_samples: Arc::new(tokio::sync::RwLock::new(Vec::new())),
            star_count_baselines: Default::default(),
            consecutive_rejects: Arc::new(std::sync::atomic::AtomicU32::new(0)),
            frames_accepted: Arc::new(std::sync::atomic::AtomicU32::new(0)),
            frames_rejected: Arc::new(std::sync::atomic::AtomicU32::new(0)),
            default_quality_check: None,
            reject_folder_path: None,
            defect_map_apply: Arc::new(tokio::sync::RwLock::new(None)),
            // Forensics test scaffolding.
            forensics_history: Arc::new(
                tokio::sync::RwLock::new(std::collections::VecDeque::new()),
            ),
            current_sky_brightness_mag: Arc::new(tokio::sync::RwLock::new(None)),
            cloud_motion_snapshot: Arc::new(tokio::sync::RwLock::new(
                crate::node::context::CloudMotionSnapshot::default(),
            )),
            current_wind_kph: Arc::new(tokio::sync::RwLock::new(None)),
            current_sensor_temp_c: Arc::new(tokio::sync::RwLock::new(None)),
            // Replay Debug — test contexts don't emit decisions.
            decision_tx: None,
            active_sequence_run_id: Arc::new(parking_lot::RwLock::new(None)),
            dither_barrier: None,
            device_retry: crate::instructions::DeviceRetryHandle::single_attempt(),
        }
    }

    #[tokio::test]
    async fn fixed_plan_runs_all_steps_in_order() {
        let wizard = CountingWizard::default();
        let progress = NoopProgressReporter;
        let sink = MemoryCheckpointSink::default();
        let executor = WizardExecutor::new(&progress, &sink);
        let ctx = dummy_ctx();
        let (visited, status) = executor.run(wizard, &ctx).await;
        assert!(matches!(status, WizardRunStatus::Completed));
        assert_eq!(visited, vec![10, 20, 30]);
        // Checkpoint cleared on success.
        assert!(sink.load("test::counting").is_none());
    }

    #[tokio::test]
    async fn dynamic_plan_extends_until_done() {
        let wizard = DynamicWizard {
            max: 5,
            visited: Vec::new(),
        };
        let progress = NoopProgressReporter;
        let sink = MemoryCheckpointSink::default();
        let executor = WizardExecutor::new(&progress, &sink);
        let ctx = dummy_ctx();
        let (visited, status) = executor.run(wizard, &ctx).await;
        assert!(matches!(status, WizardRunStatus::Completed));
        assert_eq!(visited, vec![0, 1, 2, 3, 4]);
    }

    #[tokio::test]
    async fn cancellation_between_steps_is_respected() {
        struct CancellingWizard {
            cancel_after: usize,
            cancel_flag: Arc<AtomicBool>,
            visited: Vec<u32>,
        }
        #[async_trait]
        impl Wizard for CancellingWizard {
            type StepKey = u32;
            type Outcome = Vec<u32>;
            fn name(&self) -> &'static str {
                "Cancel"
            }
            fn checkpoint_key(&self) -> &'static str {
                "test::cancel"
            }
            fn plan_steps(&self, _resume_idx: usize) -> Vec<u32> {
                vec![0, 1, 2, 3, 4]
            }
            async fn execute_step(
                &mut self,
                _ctx: &InstructionContext,
                step: u32,
                idx: usize,
                _progress: &dyn WizardProgressReporter,
            ) -> WizardStepOutcome<u32> {
                self.visited.push(step);
                if idx + 1 == self.cancel_after {
                    self.cancel_flag.store(true, Ordering::Relaxed);
                }
                WizardStepOutcome::Completed
            }
            fn finalize(self, _status: WizardRunStatus) -> Vec<u32> {
                self.visited
            }
        }
        let mut ctx = dummy_ctx();
        let cancel_flag = ctx.cancellation_token.clone();
        let wizard = CancellingWizard {
            cancel_after: 2,
            cancel_flag: cancel_flag.clone(),
            visited: Vec::new(),
        };
        // ctx variable used by reference only; the cancellation token shares
        // storage with cancel_flag via Arc.
        let progress = NoopProgressReporter;
        let sink = MemoryCheckpointSink::default();
        let executor = WizardExecutor::new(&progress, &sink);
        let (visited, status) = executor.run(wizard, &ctx).await;
        assert!(matches!(status, WizardRunStatus::Cancelled));
        // Visited steps 0 and 1 before cancel-flag set; step 2 not run
        // (cancellation is checked at top of loop).
        assert_eq!(visited, vec![0, 1]);
        // bind ctx as used.
        let _ = &mut ctx;
    }

    #[tokio::test]
    async fn resume_starts_at_next_uncompleted_step() {
        let sink = MemoryCheckpointSink::default();
        // Pre-populate checkpoint as if a previous run completed step 0
        // (so completed_steps=1 → resume at index 1).
        sink.save(&WizardCheckpoint {
            checkpoint_key: "test::counting".to_string(),
            completed_steps: 1,
            timestamp: chrono::Utc::now(),
        });

        let wizard = CountingWizard::default();
        let progress = NoopProgressReporter;
        let executor = WizardExecutor::new(&progress, &sink);
        let ctx = dummy_ctx();
        let (visited, status) = executor.run(wizard, &ctx).await;
        assert!(matches!(status, WizardRunStatus::Completed));
        // Step 0 was skipped on resume.
        assert_eq!(visited, vec![20, 30]);
    }

    #[tokio::test]
    async fn failure_propagates_and_keeps_checkpoint() {
        struct FailingWizard;
        #[async_trait]
        impl Wizard for FailingWizard {
            type StepKey = u32;
            type Outcome = ();
            fn name(&self) -> &'static str {
                "Fail"
            }
            fn checkpoint_key(&self) -> &'static str {
                "test::fail"
            }
            fn plan_steps(&self, _resume_idx: usize) -> Vec<u32> {
                vec![0, 1, 2]
            }
            async fn execute_step(
                &mut self,
                _ctx: &InstructionContext,
                _step: u32,
                idx: usize,
                _progress: &dyn WizardProgressReporter,
            ) -> WizardStepOutcome<u32> {
                if idx == 1 {
                    WizardStepOutcome::Failed("synthetic failure".to_string())
                } else {
                    WizardStepOutcome::Completed
                }
            }
            fn finalize(self, _status: WizardRunStatus) {}
        }
        let progress = NoopProgressReporter;
        let sink = MemoryCheckpointSink::default();
        let executor = WizardExecutor::new(&progress, &sink);
        let ctx = dummy_ctx();
        let (_, status) = executor.run(FailingWizard, &ctx).await;
        match status {
            WizardRunStatus::Failed(msg) => assert_eq!(msg, "synthetic failure"),
            other => panic!("expected Failed, got {:?}", other),
        }
        // Step 0 was persisted; step 1 failed so completion stayed at 1.
        let cp = sink.load("test::fail").expect("checkpoint persisted");
        assert_eq!(cp.completed_steps, 1);
    }
}
