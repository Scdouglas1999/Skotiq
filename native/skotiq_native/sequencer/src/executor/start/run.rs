//! One run of a loaded sequence.
//!
//! [`Run`] holds what the run's tasks share: the state cell and control
//! flags, the rig, the settings, the trigger manager, the recovery handles,
//! the checkpoint writer, the plan it executes, and the two protocols that
//! used to be loose flags: how the run is torn down ([`Teardown`]) and what
//! outside the node tree can fail it ([`OutsideFailures`]). The node tree's
//! `ExecutionContext` takes its shared handles from here.

use super::*;
use crate::node::context::{AdaptiveSwapRuntimeState, PluginNodeReply};
use crate::node::resume::ResumeRecord;
use crate::recovery::{RecoveryCause, RecoveryContext, RecoveryHistoryEntry, RecoverySignals};
use crate::scheduling::integration_budget::BudgetRegistry;
use crate::scheduling::BudgetRegistrySnapshot;
use std::sync::atomic::AtomicU64;

/// How long the last frames' plate solves may take after the plan finished.
const FINAL_FRAME_ASSESSMENT_SECS: u64 = 120;

/// The run's decision log. Every row is stamped with the run id.
#[derive(Clone)]
pub(crate) struct DecisionLog {
    pub tx: crate::decision::DecisionSender,
    pub run_id: Arc<StdRwLock<Option<i64>>>,
    /// The operator's "decision logging" setting. Lifecycle rows honor it.
    pub enabled: Arc<AtomicBool>,
}

impl DecisionLog {
    pub(crate) fn send(&self, mut decision: crate::decision::DecisionEvent) {
        decision.sequence_run_id = *self.run_id.read();
        let _ = self.tx.send(decision);
    }

    /// A "sequence started / completed / failed / cancelled" row.
    pub(crate) fn lifecycle(&self, phase: &str, extra: serde_json::Value) {
        emit_lifecycle_decision(&self.tx, &self.run_id, &self.enabled, phase, extra);
    }
}

/// Where a flip that left the mount on its old side is latched, so the run's
/// verdict cannot read `completed` while the mount is not where the run
/// thinks it is.
#[derive(Clone, Default)]
pub(crate) struct FlipFailureLatch {
    failed: Arc<AtomicBool>,
    failure: Arc<StdRwLock<Option<String>>>,
}

impl FlipFailureLatch {
    /// Latch a failure. The newest one is the run's cause: an older one has
    /// either been retried or describes a mount that has moved since.
    pub(crate) fn latch(&self, message: impl FnOnce() -> String) {
        self.failed.store(true, Ordering::Release);
        *self.failure.write() = Some(message());
    }

    /// A later flip reached the new pier side, so no earlier failure says
    /// where the mount is. On 2026-11-03 the window flip failed with the mount
    /// still west, the flip after the resume reached the east side, and the
    /// run that then finished its plan was filed failed with "still West".
    pub(crate) fn clear(&self) {
        self.failed.store(false, Ordering::Release);
        *self.failure.write() = None;
    }

    pub(crate) fn is_latched(&self) -> bool {
        self.failed.load(Ordering::Acquire)
    }

    pub(crate) fn message(&self) -> Option<String> {
        self.failure.read().clone()
    }
}

/// What can fail a run from outside its node tree. The tree can walk to its
/// end while any of these is set; the verdict reads them.
#[derive(Clone, Default)]
pub(crate) struct OutsideFailures {
    /// Recovery spent its budget on a real fault (not an operator abort).
    pub recovery_gave_up: Arc<AtomicBool>,
    pub meridian_flip: FlipFailureLatch,
}

/// The recovery ladder's shared state.
pub(crate) struct RecoveryHandles {
    pub signals: Arc<RecoverySignals>,
    pub current: Arc<StdRwLock<Option<RecoveryContext>>>,
    pub history: Arc<StdRwLock<Vec<RecoveryHistoryEntry>>>,
    /// Counts finished recovery cycles, so an instruction can tell "recovery
    /// already finished" from "no driver ever engaged".
    pub generation: Arc<AtomicU64>,
    /// The devices a disconnect recovery reconnects.
    pub reconnect_device_ids: Vec<String>,
}

/// What the run executes, read once from the sequence it was built from.
#[derive(Default)]
pub(crate) struct RunPlan {
    pub sequence: Option<SequenceDefinition>,
    /// Recovery-node trigger id to the node that handles it.
    pub custom_recovery_branches: Arc<HashMap<String, String>>,
    /// The terminal message names the root.
    pub root_display_name: String,
    /// Instructions the tree holds but can never reach.
    pub unreachable_instruction_names: Vec<String>,
    /// Authored display name per node. A node the operator never named has
    /// no entry: publishing "" prints a blank where a client shows the name.
    pub node_display_names: HashMap<NodeId, String>,
    /// Duration and filter of every exposure node.
    pub exposure_nodes: Arc<HashMap<NodeId, (f64, Option<String>)>>,
    /// Name and coordinates of every target node. An unnamed target has no
    /// entry: its frames are labeled "untargeted" and a made-up name would
    /// put another spelling on the wire.
    pub target_nodes: Arc<HashMap<NodeId, (String, f64, f64)>>,
}

impl RunPlan {
    pub(crate) fn new(
        sequence: Option<SequenceDefinition>,
        root_display_name: String,
        custom_recovery_branches: HashMap<String, String>,
        unreachable_instruction_names: Vec<String>,
    ) -> Self {
        let nodes = sequence
            .as_ref()
            .map(|sequence| sequence.nodes.as_slice())
            .unwrap_or_default();
        let node_display_names = nodes
            .iter()
            .filter(|node| !node.name.trim().is_empty())
            .map(|node| (node.id.clone(), node.name.clone()))
            .collect();
        let exposure_nodes = nodes
            .iter()
            .filter_map(|node| match &node.node_type {
                NodeType::TakeExposure(config) => Some((
                    node.id.clone(),
                    (config.duration_secs, config.filter.clone()),
                )),
                _ => None,
            })
            .collect();
        let target_nodes = nodes
            .iter()
            .filter_map(|node| match &node.node_type {
                NodeType::TargetHeader(config) | NodeType::TargetGroup(config)
                    if !config.target_name.trim().is_empty() =>
                {
                    Some((
                        node.id.clone(),
                        (
                            config.target_name.clone(),
                            config.ra_hours,
                            config.dec_degrees,
                        ),
                    ))
                }
                _ => None,
            })
            .collect();
        Self {
            sequence,
            custom_recovery_branches: Arc::new(custom_recovery_branches),
            root_display_name,
            unreachable_instruction_names,
            node_display_names,
            exposure_nodes: Arc::new(exposure_nodes),
            target_nodes: Arc::new(target_nodes),
        }
    }
}

/// How a run is taken down.
///
/// A trigger that ends the run by parking runs inside the trigger monitor
/// while the node tree is still executing, so the two sides hand over in
/// steps:
///
///   cancel -> node cleanup and exposure abort -> quiesced -> park / close -> done
///
/// The node tree's side stays pending after its cleanup until the sweep
/// reports done, so nothing drops the monitor halfway through the park. A
/// trigger action in flight when the tree ends is waited for the same way,
/// and the last frames' assessments are drained before a clean finish.
pub(crate) struct Teardown {
    park_and_abort: Arc<AtomicBool>,
    execution_quiesced: watch::Sender<bool>,
    park_and_abort_done: watch::Sender<bool>,
    /// Set for the length of a trigger action (flip, dither, autofocus ...).
    pub trigger_action_in_flight: Arc<AtomicBool>,
    finish_frames: watch::Sender<bool>,
}

impl Default for Teardown {
    fn default() -> Self {
        Self {
            park_and_abort: Arc::new(AtomicBool::new(false)),
            execution_quiesced: watch::channel(false).0,
            park_and_abort_done: watch::channel(false).0,
            trigger_action_in_flight: Arc::new(AtomicBool::new(false)),
            finish_frames: watch::channel(false).0,
        }
    }
}

impl Teardown {
    /// A trigger's park-and-abort sweep decided how this run ends.
    pub(crate) fn parked_by_trigger(&self) -> bool {
        self.park_and_abort.load(Ordering::Acquire)
    }

    /// The trigger side of the park handshake.
    pub(crate) fn park_signals(&self) -> ParkSignals {
        ParkSignals {
            park_and_abort: self.park_and_abort.clone(),
            done: self.park_and_abort_done.clone(),
            execution_quiesced: self.execution_quiesced.subscribe(),
        }
    }

    pub(crate) fn park_done(&self) -> watch::Receiver<bool> {
        self.park_and_abort_done.subscribe()
    }

    pub(crate) fn finish_frames(&self) -> watch::Receiver<bool> {
        self.finish_frames.subscribe()
    }

    /// A task driven without a node tree has nothing to wait for.
    #[cfg(test)]
    pub(crate) fn node_tree_has_ended(&self) {
        self.execution_quiesced.send_replace(true);
    }

    /// The node tree has returned and its exposure is aborted. If a trigger
    /// is parking the rig, wait until that sweep is done.
    async fn node_tree_ended(&self, mut park_done: watch::Receiver<bool>) {
        self.execution_quiesced.send_replace(true);
        if self.parked_by_trigger() {
            if let Err(error) = park_done.wait_for(|done| *done).await {
                tracing::warn!(
                    "Park-and-abort handshake: the completion signal was dropped \
                     before the safe-state sweep reported done ({}); ending \
                     execution without waiting — verify the rig is parked",
                    error
                );
            }
        }
    }
}

/// The handshake with the run supervisor for an action that ends the run by
/// parking.
pub(crate) struct ParkSignals {
    /// Set before the node tree is cancelled, so the supervisor reports the
    /// run as parked and aborted.
    pub park_and_abort: Arc<AtomicBool>,
    pub done: watch::Sender<bool>,
    pub execution_quiesced: watch::Receiver<bool>,
}

impl ParkSignals {
    /// Cancel the node tree and wait until its exposure has been aborted, so
    /// nothing moves or closes under a live integration.
    pub(crate) async fn stop_node_tree(&mut self, is_cancelled: &Arc<AtomicBool>) {
        cancel_and_wait_for_execution(is_cancelled, &mut self.execution_quiesced).await;
    }

    pub(crate) fn parking_begins(&self) {
        self.park_and_abort.store(true, Ordering::Release);
    }

    pub(crate) fn parked(&self) {
        self.done.send_replace(true);
    }
}

/// Handles of the executor that outlive a run and that the run's node tree
/// shares.
pub(crate) struct ExecutorShared {
    pub depth_goal_ops: Option<crate::depth_goal::SharedDepthGoalOps>,
    pub defect_map_apply: Arc<RwLock<Option<DefectMapApplyState>>>,
    pub adaptive_swap_state: Arc<RwLock<AdaptiveSwapRuntimeState>>,
}

pub(crate) struct Run {
    pub control: RunControl,
    pub resume_notify: Arc<tokio::sync::Notify>,
    pub skip_current_step: Arc<AtomicBool>,
    pub skip_to_next_target: Arc<AtomicBool>,
    pub skip_to_node: Arc<StdRwLock<Option<NodeId>>>,
    pub plugin_node_pending: Arc<RwLock<HashMap<NodeId, oneshot::Sender<PluginNodeReply>>>>,
    pub rig: RunRig,
    pub config: RunConfigStore,
    pub sky: SkyFeed,
    pub shared: ExecutorShared,
    pub device_ops: SharedDeviceOps,
    pub triggers: Arc<RwLock<TriggerManager>>,
    pub decisions: DecisionLog,
    pub recovery: RecoveryHandles,
    pub checkpoint: Option<Arc<CheckpointWriter>>,
    pub plan: RunPlan,
    pub teardown: Teardown,
    pub outside_failures: OutsideFailures,
    pub budget_registry: BudgetRegistry,
    pub smart_exposure_states: Arc<RwLock<HashMap<NodeId, crate::SmartExposureCheckpoint>>>,
    pub resume: ResumeRecord,
}

/// What a resumed run takes over from its checkpoint, and what the operator
/// staged for this start.
#[derive(Default)]
pub(crate) struct RunSeed {
    pub staging: RunStaging,
    pub budget: Option<BudgetRegistrySnapshot>,
    pub smart_exposure: Option<HashMap<NodeId, crate::SmartExposureCheckpoint>>,
}

impl Run {
    /// What every instruction of this run shares: the node tree's steps, the
    /// trigger actions and the recovery driver's moves alike. Built once per
    /// run, so all of them write to the same decision log, ask the same
    /// recovery driver, wait at the same dither barrier and stamp frames with
    /// the same session.
    pub(super) async fn instruction_shared(
        &self,
        recovery_requests: mpsc::Sender<RecoveryCause>,
    ) -> crate::instructions::RunShared {
        let slots = self.config.slots();
        let mut shared = crate::instructions::RunShared::new(self.device_ops.clone());
        shared.rig = self.rig.clone();
        shared.trigger_state = Some(self.triggers.read().await.state());
        shared.event_tx = Some(self.control.state.events().clone());
        shared.recovery_request_tx = Some(recovery_requests);
        shared.decision_tx = Some(self.decisions.tx.clone());
        shared.active_sequence_run_id = self.decisions.run_id.clone();
        // One id per start, so `SK-SESID` names this run and no other.
        shared.identity.session_id = uuid::Uuid::new_v4().to_string();
        shared.settings = Some(self.config.clone());
        shared.take_settings();
        shared.conditions.sky_brightness_mag = self.sky.sky_brightness_mag.clone();
        shared.conditions.cloud_motion = self.sky.cloud_motion.clone();
        shared.defect_map_apply = self.shared.defect_map_apply.clone();
        shared.device_retry = slots.device_retry.clone();
        // A secondary capture loop armed before this start shares its dither
        // barrier with the run.
        shared.dither_barrier = crate::dual_rig::active_barrier();
        shared
    }

    /// The node tree's context, wired to this run.
    pub(super) async fn build_context(
        &self,
        started: std::time::Instant,
        recovery_requests: mpsc::Sender<RecoveryCause>,
    ) -> ExecutionContext {
        let config = self.config.snapshot();
        let slots = self.config.slots();
        let mut context = ExecutionContext::new("root".to_string(), self.device_ops.clone());
        context.run = self.instruction_shared(recovery_requests).await;

        context.is_cancelled = self.control.is_cancelled.clone();
        context.is_paused = self.control.is_paused.clone();
        context.resume_notify = self.resume_notify.clone();
        context.skip_current_step = self.skip_current_step.clone();
        context.skip_to_next_target = self.skip_to_next_target.clone();
        context.skip_to_node = self.skip_to_node.clone();
        context.plugin_node_pending = self.plugin_node_pending.clone();
        context.recovery_generation = self.recovery.generation.clone();
        context.budget_registry = self.budget_registry.clone();
        context.smart_exposure_states = self.smart_exposure_states.clone();
        context.resume = self.resume.clone();

        context.current_transparency = self.sky.transparency.clone();
        context.transparency_backup_plan = self.sky.transparency_backup.clone();
        context.current_conditions_score = self.sky.conditions_score.clone();
        context.adaptive_swap_state = self.shared.adaptive_swap_state.clone();
        context.depth_goal_ops = self.shared.depth_goal_ops.clone();
        context.default_adaptive_exposure = slots.default_adaptive_exposure.clone();
        context.safety_fail_mode = slots.safety_fail_mode.clone();
        context.max_sun_altitude_degrees = config.max_sun_altitude();

        context.progress_callback = Some(build_progress_callback(ProgressCallbackArgs {
            exposure_node_metadata: self.plan.exposure_nodes.clone(),
            // A burst a resume continues has its frames counted already.
            node_frame_progress: Arc::new(StdRwLock::new(self.resume.snapshot().frames.in_pass)),
            node_integration_credited: Arc::default(),
            node_names: Arc::new(StdRwLock::new(self.plan.node_display_names.clone())),
            run_state: self.control.state.clone(),
            start_time: started,
            started_nodes: Arc::default(),
            target_node_metadata: self.plan.target_nodes.clone(),
        }));
        context
    }

    /// Run the sequence to its end and publish how it ended.
    pub(crate) async fn execute(
        self: Arc<Self>,
        mut root_node: Box<dyn Node>,
        commands: mpsc::Receiver<ExecutorCommand>,
        seed: RunSeed,
    ) {
        let started = std::time::Instant::now();
        // One recovery at a time: a full channel is how a second request
        // learns the run is already recovering. The senders live with the
        // node tree and the trigger monitor, so the driver ends with them.
        let (recovery_tx, recovery_rx) = mpsc::channel(4);
        let mut context = self.build_context(started, recovery_tx.clone()).await;

        seed.staging
            .seed_budget(&self.budget_registry, seed.budget)
            .await;
        let grading_active = context
            .run
            .grading
            .default_quality_check
            .as_ref()
            .is_some_and(|check| check.is_active());
        tracing::info!(
            "Executor started: session_id={}, observer={:?}, telescope={:?}, grading_active={}",
            context.run.identity.session_id,
            context.run.identity.observer_name,
            context.run.identity.telescope_name,
            grading_active
        );
        self.decisions.lifecycle(
            "started",
            serde_json::json!({
                "session_id": context.run.identity.session_id.clone(),
                "grading_active": grading_active,
            }),
        );
        if let Some(states) = seed.smart_exposure {
            self.smart_exposure_states.write().await.extend(states);
        }

        // The context the trigger monitor and the shutdown steps run
        // instructions against: this run's, as it stands before the tree runs.
        let side_context = context.clone();
        // Subscribed before the tree runs and followed as the run goes: a
        // receiver drained at the end keeps only the last events of the night.
        let failure_collector =
            crate::executor::failure_cause::FailureCollector::spawn(self.control.state.subscribe());

        let tree_result = self
            .supervise(
                &mut root_node,
                &mut context,
                side_context.clone(),
                commands,
                recovery_tx,
                recovery_rx,
            )
            .await;
        let (result, unreachable_reason) = self.verdict(tree_result);
        // The reason is settled by what happened up to here. The shutdown
        // steps that put the rig away next are cleanup: a Park that succeeds
        // there does not mean the run carried on past its fault.
        let failure = failure_collector.finish(unreachable_reason).await;
        self.put_rig_away(result, &side_context).await;
        let guider_left_running = self.end_the_runs_guiding(result).await;
        self.finalize(result, failure, started, guider_left_running)
            .await;
    }

    /// Drive the node tree with the run's other tasks until the tree has
    /// ended and nothing a trigger started is still moving the rig.
    async fn supervise(
        self: &Arc<Self>,
        root_node: &mut Box<dyn Node>,
        context: &mut ExecutionContext,
        side_context: ExecutionContext,
        commands: mpsc::Receiver<ExecutorCommand>,
        recovery_tx: mpsc::Sender<RecoveryCause>,
        recovery_rx: mpsc::Receiver<RecoveryCause>,
    ) -> NodeStatus {
        let is_cancelled = &self.control.is_cancelled;
        let state = &self.control.state;

        let park_done = self.teardown.park_done();
        let execution = async {
            let result = root_node.execute(context).await;
            self.teardown.node_tree_ended(park_done).await;
            result
        };
        let command_handler = run_command_handler(self.clone(), commands);
        let checkpoint_stream = run_checkpoint_stream(self.clone());
        let recovery_driver =
            run_recovery_driver(self.clone(), side_context.run.clone(), recovery_rx);

        // A hung poll looks like a healthy monitor to the select below, so
        // the watchdog turns "stalled" into "exited", which fails closed.
        let (heartbeat_tx, heartbeat_rx) = watch::channel(0_u64);
        let poll_loop =
            run_trigger_monitor_poll_loop(self.clone(), side_context, recovery_tx, heartbeat_tx);
        let trigger_monitor = async {
            tokio::pin!(poll_loop);
            tokio::select! {
                fired = &mut poll_loop => fired,
                () = trigger_monitor_stall_watchdog(
                    heartbeat_rx,
                    self.teardown.trigger_action_in_flight.clone(),
                    std::time::Duration::from_secs(TRIGGER_MONITOR_STALL_TIMEOUT_SECS),
                ) => {
                    let message = format!(
                        "Safety monitoring stalled: the trigger monitor has not \
                         completed a poll cycle in {TRIGGER_MONITOR_STALL_TIMEOUT_SECS}s, \
                         so weather, altitude, drift, tracking-loss, dome and meridian \
                         protection are no longer being enforced. A device driver is \
                         most likely not returning."
                    );
                    tracing::error!("{}", message);
                    state.emit(ExecutorEvent::Error { message });
                    Vec::new()
                }
            }
        };

        // Every branch but the tree's own first cancels and then DRAINS the
        // tree: dropping it would skip the active instruction's cancellation
        // and leave a camera integrating after Stop was confirmed.
        tokio::pin!(execution);
        tokio::pin!(trigger_monitor);
        let mut monitor_finished = false;
        let mut result = tokio::select! {
            _ = command_handler => {
                is_cancelled.store(true, Ordering::Release);
                (&mut execution).await
            },
            result = &mut execution => result,
            _ = checkpoint_stream => {
                is_cancelled.store(true, Ordering::Release);
                (&mut execution).await
            },
            _ = recovery_driver => {
                is_cancelled.store(true, Ordering::Release);
                (&mut execution).await
            },
            _triggers = &mut trigger_monitor => {
                monitor_finished = true;
                // An unattended run depends on the monitor for weather,
                // altitude and drift limits; without it nothing may expose.
                if !is_cancelled.load(Ordering::Relaxed) {
                    tracing::error!(
                        "Safety monitoring (trigger monitor) exited unexpectedly! \
                         Cancelling sequence to prevent unmonitored execution."
                    );
                    is_cancelled.store(true, Ordering::Relaxed);
                    state.emit(ExecutorEvent::Error {
                        message: "Safety monitoring failed — sequence aborted. \
                                  The trigger monitor exited unexpectedly."
                            .to_string(),
                    });
                    let _ = (&mut execution).await;
                    NodeStatus::Failure
                } else {
                    (&mut execution).await
                }
            },
        };

        // The tree ending does not mean the rig is settled: a meridian flip
        // can be mid-retry. Keep driving the monitor until the action ends, so
        // its outcome is applied. A Stop cancels the action within moments.
        let in_flight = &self.teardown.trigger_action_in_flight;
        if in_flight.load(Ordering::Acquire) {
            tracing::warn!(
                "Node tree finished while a trigger recovery action is still \
                 running; waiting up to {}s for it to complete before ending the run",
                TRIGGER_ACTION_QUIESCE_MAX_SECS
            );
            let deadline = tokio::time::Instant::now()
                + std::time::Duration::from_secs(TRIGGER_ACTION_QUIESCE_MAX_SECS);
            while in_flight.load(Ordering::Acquire) {
                tokio::select! {
                    _ = &mut trigger_monitor => {
                        monitor_finished = true;
                        break;
                    },
                    _ = tokio::time::sleep_until(deadline) => {
                        result = NodeStatus::Failure;
                        let message = format!(
                            "Trigger recovery exceeded its {TRIGGER_ACTION_QUIESCE_MAX_SECS}s end-of-run budget; cancelling and allowing up to {TRIGGER_CLEANUP_BUDGET_SECS}s for equipment restoration."
                        );
                        tracing::error!("{}", message);
                        state.emit(ExecutorEvent::Error { message });
                        monitor_finished =
                            cancel_trigger_monitor_with_cleanup(is_cancelled, &mut trigger_monitor)
                                .await;
                        if !monitor_finished {
                            let message = "Recovery cleanup timed out; equipment restoration is unverified. Check the mount and filter before another run.".to_string();
                            tracing::error!("{}", message);
                            state.emit(ExecutorEvent::Error { message });
                        }
                        break;
                    }
                    _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => {}
                }
            }
            if !in_flight.load(Ordering::Acquire) {
                tracing::info!("In-flight trigger recovery action quiesced; ending run");
            }
        }

        // The last science frame can still be queued or solving when its node
        // ends. Its assessment is finished first, with every action disabled.
        if !monitor_finished
            && result == NodeStatus::Success
            && !is_cancelled.load(Ordering::Acquire)
        {
            self.teardown.finish_frames.send_replace(true);
            if tokio::time::timeout(
                std::time::Duration::from_secs(FINAL_FRAME_ASSESSMENT_SECS),
                &mut trigger_monitor,
            )
            .await
            .is_err()
            {
                state.emit(ExecutorEvent::Warning {
                    message: format!("Final frame plate solves did not finish within {FINAL_FRAME_ASSESSMENT_SECS} seconds; some saved frames have no drift assessment."),
                });
            }
        }
        result
    }

    /// What the run amounts to, given how its tree ended and what failed
    /// outside the tree. Returns the status and, when the plan itself could
    /// not have run in full, the reason.
    fn verdict(&self, tree_result: NodeStatus) -> (NodeStatus, Option<String>) {
        let mut result = tree_result;

        // A give-up cancels the tree, which would read as a plain cancel.
        if self
            .outside_failures
            .recovery_gave_up
            .load(Ordering::Relaxed)
        {
            result = NodeStatus::Failure;
        }

        // The mount is not where the sequence assumed, so every frame after
        // the failed flip is suspect. A flip that retried and then reached
        // the new side cleared the latch and does not fail the run.
        if self.outside_failures.meridian_flip.is_latched() && result != NodeStatus::Failure {
            tracing::error!(
                "Sequence finished with {:?} but a meridian flip FAILED during the \
                 run; recording the run as a failure",
                result
            );
            result = NodeStatus::Failure;
        }

        // A tree that walked to its end but holds instructions it can never
        // reach did not do what the sequence says.
        let unreachable = &self.plan.unreachable_instruction_names;
        if !unreachable.is_empty() && matches!(result, NodeStatus::Success | NodeStatus::Skipped) {
            let message = unreachable_instructions_message(unreachable);
            tracing::error!(
                "Sequence finished with {:?} but never executed part of its tree; \
                 recording the run as a failure. {}",
                result,
                message
            );
            self.control.state.emit(ExecutorEvent::Error {
                message: message.clone(),
            });
            return (NodeStatus::Failure, Some(message));
        }
        (result, None)
    }

    /// A run that failed, or that a skip ended early, still puts the rig away
    /// the way its plan says. A trigger's park sweep already decided the
    /// rig's end state, and after a Stop the rig is the operator's.
    async fn put_rig_away(&self, result: NodeStatus, side_context: &ExecutionContext) {
        if !matches!(result, NodeStatus::Failure | NodeStatus::Skipped)
            || self.teardown.parked_by_trigger()
        {
            return;
        }
        let Some(sequence) = self.plan.sequence.as_ref() else {
            return;
        };
        let state = &self.control.state;
        let statuses = state.read_progress(|progress| progress.node_statuses.clone());
        state.set_message("The run ended early: putting the rig away");
        night_end::run_unreached_shutdown_steps(
            sequence,
            side_context,
            &side_context.run.device_ops,
            &statuses,
        )
        .await;
    }

    /// A stopped run ends the guiding it started. Guiding the run did not
    /// start (the operator's, from before the run) is not the run's to end.
    /// A trigger that parked the rig has already stopped the guider. Returns
    /// what the operator needs to hear about a guider that is still guiding.
    async fn end_the_runs_guiding(&self, result: NodeStatus) -> Option<String> {
        if result != NodeStatus::Cancelled || self.teardown.parked_by_trigger() {
            return None;
        }
        let trigger_state = self.triggers.read().await.state();
        let ours = trigger_state.read().await.guiding.is_enabled();
        let ops = &self.device_ops;
        if !ours {
            let guiding = matches!(ops.guider_get_status().await, Ok(status) if status.is_guiding);
            return guiding.then(|| {
                "The guider is still guiding: it was started outside this run.".to_string()
            });
        }
        ops.guider_note_stop_reason(Some(crate::GuidingStopReason::RunStopped))
            .await;
        let stopped = ops.guider_stop().await;
        {
            let mut state = trigger_state.write().await;
            state.set_guiding_enabled(false);
            state.guiding.set_resume_pending(false);
        }
        match stopped {
            Ok(()) | Err(crate::device_ops::DeviceError::NO_GUIDER) => None,
            Err(error) => {
                tracing::warn!("[GUIDING] The guider did not stop with the run: {error}");
                Some(format!(
                    "The guider did not stop and may still be guiding: {error}."
                ))
            }
        }
    }

    /// The run's one finalization: store the terminal state with the run's
    /// own verdict as its message, close the checkpoint, publish the terminal
    /// events, and announce the state last. `guider_left_running` is added to
    /// the verdict of a stopped run whose guider still guides.
    async fn finalize(
        &self,
        result: NodeStatus,
        mut failure: crate::executor::failure_cause::RunFailureReport,
        started: std::time::Instant,
        guider_left_running: Option<String>,
    ) {
        let state = &self.control.state;
        let final_state = executor_state_for_result(result);
        // The message is composed from the status the root returned, so it
        // cannot disagree with the state: the tree keeps emitting progress
        // after the root is done.
        let mut verdict = terminal_verdict_message(result, &self.plan.root_display_name);
        if let Some(note) = guider_left_running {
            // Also told in the run's log, where a client reads how the run ended.
            self.control.warning(note.clone());
            verdict = format!("{verdict}. {note}");
        }
        let terminal = state.store(final_state, |progress| {
            progress.message = Some(verdict);
            progress.elapsed_secs = started.elapsed().as_secs_f64();
        });

        self.close_checkpoint(result).await;

        let elapsed_secs = started.elapsed().as_secs_f64();
        match result {
            NodeStatus::Success | NodeStatus::Skipped => {
                state.emit(ExecutorEvent::SequenceCompleted);
                self.decisions.lifecycle(
                    "completed",
                    serde_json::json!({
                        "elapsed_secs": elapsed_secs,
                        "final_state": format!("{:?}", final_state),
                    }),
                );
            }
            NodeStatus::Failure => {
                // The reason is the structural refusal if there is one, else
                // the FIRST fault, never a cancelled cleanup step: see
                // `executor::failure_cause`.
                if failure.cause.is_none() && self.outside_failures.meridian_flip.is_latched() {
                    failure.cause = self.outside_failures.meridian_flip.message();
                }
                if failure.cascade.len() > 1 {
                    tracing::info!(
                        "Run failure cascade ({} links, cause first): {}",
                        failure.cascade.len(),
                        failure.cascade.join(" | ")
                    );
                }
                // "Failed: <root name>" names a container and gives no
                // reason; a run that has a reason reports the reason.
                if let Some(reason) = failure.cause.as_deref() {
                    state.set_message(reason);
                }
                let error = failure
                    .cause
                    .unwrap_or_else(|| "Sequence failed".to_string());
                state.emit(ExecutorEvent::SequenceFailed {
                    error: error.clone(),
                });
                self.decisions.lifecycle(
                    "failed",
                    serde_json::json!({ "elapsed_secs": elapsed_secs, "error": error }),
                );
            }
            NodeStatus::Cancelled => {
                state.emit(ExecutorEvent::Error {
                    message: "Sequence cancelled".into(),
                });
                self.decisions.lifecycle(
                    "cancelled",
                    serde_json::json!({ "elapsed_secs": elapsed_secs }),
                );
            }
            NodeStatus::Pending | NodeStatus::Running => {}
        }

        terminal.announce();
    }

    /// A run that did not finish keeps its checkpoint, with how it ended and
    /// the progress it reached. A finished run's checkpoint stays on disk for
    /// the session report and stops being resumable.
    async fn close_checkpoint(&self, result: NodeStatus) {
        let Some(writer) = &self.checkpoint else {
            return;
        };
        let run_end = match result {
            NodeStatus::Success | NodeStatus::Skipped => {
                match writer.mark_completed() {
                    Ok(()) => {
                        tracing::debug!("Checkpoint marked completed on normal sequence finish")
                    }
                    Err(e) => tracing::error!(
                        "Failed to mark checkpoint completed after a normal \
                         sequence finish: {} — a stale 'resume?' banner may \
                         appear on next launch",
                        e
                    ),
                }
                return;
            }
            _ if self.teardown.parked_by_trigger() => crate::checkpoint::RunEnd::EndedEarly,
            NodeStatus::Failure => crate::checkpoint::RunEnd::Failed,
            NodeStatus::Cancelled => crate::checkpoint::RunEnd::Stopped,
            NodeStatus::Pending | NodeStatus::Running => return,
        };
        let (exposures, integration_secs) = self.control.state.read_progress(|progress| {
            (
                progress.completed_exposures,
                progress.completed_integration_secs,
            )
        });
        match writer
            .record_run_end(run_end, exposures, integration_secs)
            .await
        {
            Ok(()) => tracing::info!(
                "Checkpoint records the run as {} after {} exposures",
                run_end.as_str(),
                exposures
            ),
            Err(e) => tracing::warn!(
                "Could not record how the run ended in its checkpoint: {}",
                e
            ),
        }
    }
}

/// Run `run` to its end. A panic inside it must not read as a live run: the
/// tree is gone and device state unknown, so the run is published as failed.
pub(crate) async fn supervised(state: RunCell, run: impl std::future::Future<Output = ()>) {
    let Err(panic_payload) = AssertUnwindSafe(run).catch_unwind().await else {
        return;
    };
    let panic_msg = if let Some(s) = panic_payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = panic_payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "Unknown panic".to_string()
    };
    tracing::error!(
        target: "supervisor",
        "sequencer_executor panicked; sequence aborted: {panic_msg}"
    );
    let failed = state.store(ExecutorState::Failed, |_| {});
    state.emit(ExecutorEvent::SequenceFailed {
        error: format!("Sequencer panicked: {panic_msg}"),
    });
    failed.announce();
}

#[cfg(test)]
impl Run {
    /// A run with nothing attached and default settings, for driving one of
    /// its tasks alone. Tests set the fields they care about before sharing
    /// it.
    pub(crate) fn detached(device_ops: SharedDeviceOps, state: RunCell) -> Self {
        let (decisions, _) = broadcast::channel(16);
        let config = RunConfigStore::default();
        Self {
            control: RunControl {
                state,
                is_cancelled: Arc::default(),
                is_paused: Arc::default(),
            },
            resume_notify: Arc::default(),
            skip_current_step: Arc::default(),
            skip_to_next_target: Arc::default(),
            skip_to_node: Arc::default(),
            plugin_node_pending: Arc::default(),
            rig: RunRig::default(),
            sky: SkyFeed::new(),
            shared: ExecutorShared {
                depth_goal_ops: None,
                defect_map_apply: Arc::default(),
                adaptive_swap_state: Arc::default(),
            },
            device_ops,
            triggers: Arc::new(RwLock::new(TriggerManager::new())),
            decisions: DecisionLog {
                tx: decisions,
                run_id: Arc::default(),
                enabled: config.slots().decision_logging_enabled.clone(),
            },
            config,
            recovery: RecoveryHandles {
                signals: Arc::new(RecoverySignals::new()),
                current: Arc::default(),
                history: Arc::default(),
                generation: Arc::default(),
                reconnect_device_ids: Vec::new(),
            },
            checkpoint: None,
            plan: RunPlan::default(),
            teardown: Teardown::default(),
            outside_failures: OutsideFailures::default(),
            budget_registry: BudgetRegistry::new(),
            smart_exposure_states: Arc::default(),
            resume: ResumeRecord::default(),
        }
    }
}
