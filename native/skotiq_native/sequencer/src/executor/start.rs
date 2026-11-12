//! [`SequenceExecutor::start`] — the run supervisor: preflight, the spawned
//! executor future, the command handler, the checkpoint streamer, the
//! recovery driver, the trigger monitor, and the join/finalize tail.

use super::*;

mod calibration_run;
mod checkpoint_stream;
mod command_handler;
mod explicit_end;
pub(crate) mod night_end;
mod preflight;
mod progress_callback;
mod recovery_driver;
mod run;
mod run_setup;
mod stale_end_times;
mod trigger_monitor;

use checkpoint_stream::run_checkpoint_stream;
use command_handler::run_command_handler;
use preflight::PreflightOutcome;
use progress_callback::{build_progress_callback, ProgressCallbackArgs};
use recovery_driver::run_recovery_driver;
pub(crate) use run::{DecisionLog, FlipFailureLatch, ParkSignals, Run};
use run::{ExecutorShared, OutsideFailures, RecoveryHandles, RunPlan, RunSeed, Teardown};
use trigger_monitor::run_trigger_monitor_poll_loop;

/// The run's terminal message: the verdict the ROOT node returned, named after
/// the root node.
///
/// The verb follows the status the root actually reported, and the run's
/// `state` is derived from that same status
/// ([`executor_state_for_result`]), so the two can never contradict each
/// other on `/api/sequencer/status`.
fn terminal_verdict_message(result: NodeStatus, root_display_name: &str) -> String {
    let verb = match result {
        NodeStatus::Success => "Completed",
        NodeStatus::Failure => "Failed",
        NodeStatus::Cancelled => "Cancelled",
        NodeStatus::Skipped => "Skipped",
        // Not reachable: `result` is the terminal status of the root node.
        // Kept exhaustive so a new NodeStatus variant fails to compile here
        // rather than silently reporting the wrong verb.
        NodeStatus::Pending | NodeStatus::Running => "Finished",
    };
    format!("{}: {}", verb, root_display_name)
}

impl SequenceExecutor {
    /// Start executing the sequence.
    ///
    /// Re-invocable within one app launch: a finished run parks the executor in
    /// a terminal state (`Completed`, `Failed`, `Cancelled`), and an explicit
    /// start from there means "run it again", so preflight recycles to `Idle`
    /// and the run proceeds. Busy states (`Running`, `Paused`, `Stopping`,
    /// `Recovering`) are refused: resetting there would abandon a live run.
    pub async fn start(&mut self) -> Result<(), String> {
        let PreflightOutcome {
            device_ops,
            unreachable_instruction_names,
        } = self.preflight_start().await?;
        let custom_recovery_branches = self.prepare_sequence_recovery_triggers().await?;

        self.is_cancelled.store(false, Ordering::Relaxed);
        let (command_tx, commands) = mpsc::channel::<ExecutorCommand>(32);
        self.command_tx = Some(command_tx);
        let (run_completion_tx, run_completion_rx) = watch::channel(false);
        self.run_completion_rx = Some(run_completion_rx);

        self.run_state.transition(ExecutorState::Running);

        self.prepare_run_triggers().await;
        // A checkpoint's node states belong to the resume that
        // `resume_from_checkpoint` prepared, and to no later start.
        let checkpoint_to_restore = if std::mem::take(&mut self.resume_prepared) {
            self.current_checkpoint.take()
        } else {
            self.current_checkpoint = None;
            None
        };
        let root_node = self
            .root_node
            .take()
            .ok_or("No root node available - sequence may not be properly loaded".to_string())?;

        let frames = checkpoint_to_restore
            .as_ref()
            .map(crate::node::resume::BurstFrames::from_checkpoint)
            .unwrap_or_default();
        let seed = RunSeed {
            staging: std::mem::take(&mut self.staging),
            budget: checkpoint_to_restore
                .as_ref()
                .map(|checkpoint| checkpoint.budget_states.clone()),
            smart_exposure: checkpoint_to_restore
                .map(|checkpoint| checkpoint.smart_exposure_states),
        };
        self.sky.begin_run().await;
        // A Try now or Abort left from an earlier run must not fire this
        // run's first recovery.
        self.recovery_signals.arm();

        let run = self.build_run(
            device_ops,
            &*root_node,
            custom_recovery_branches,
            unreachable_instruction_names,
            frames,
        );
        let run = Arc::new(run);
        self.run = Some(run.clone());

        let state = self.run_state.clone();
        tokio::spawn(async move {
            run::supervised(state, run.execute(root_node, commands, seed)).await;
            run_completion_tx.send_replace(true);
        });

        Ok(())
    }

    /// The run about to start, with the executor's handles and the rig and
    /// settings as they stand now.
    fn build_run(
        &self,
        device_ops: SharedDeviceOps,
        root_node: &dyn Node,
        custom_recovery_branches: HashMap<String, NodeId>,
        unreachable_instruction_names: Vec<String>,
        frames: crate::node::resume::BurstFrames,
    ) -> Run {
        let config = self.settings.snapshot();
        let control = RunControl {
            state: self.run_state.clone(),
            is_cancelled: self.is_cancelled.clone(),
            is_paused: Arc::new(AtomicBool::new(false)),
        };
        let rig = RunRig {
            camera_id: self.camera_id.clone(),
            mount_id: self.mount_id.clone(),
            focuser_id: self.focuser_id.clone(),
            filterwheel_id: self.filterwheel_id.clone(),
            rotator_id: self.rotator_id.clone(),
            dome_id: self.dome_id.clone(),
            cover_calibrator_id: self.cover_calibrator_id.clone(),
            save_path: self.save_path.clone(),
            latitude: config.latitude,
            longitude: config.longitude,
            filter_focus_offsets: config.filter_focus_offsets,
        };

        let budget_registry = crate::scheduling::integration_budget::BudgetRegistry::new();
        let smart_exposure_states = Arc::new(RwLock::new(HashMap::new()));
        // A resumed run's loops and bursts start from where its checkpoint
        // recorded them.
        let mut loop_passes_finished = HashMap::new();
        root_node.snapshot_loop_iterations(&mut loop_passes_finished);
        let resume =
            crate::node::resume::ResumeRecord::new(root_node, loop_passes_finished, frames);

        let checkpoint = match (&self.checkpoint_manager, &self.sequence) {
            (Some(manager), Some(sequence)) => Some(Arc::new(CheckpointWriter::new(
                manager.clone(),
                CheckpointSources {
                    run_state: self.run_state.clone(),
                    execution_order: self.build_execution_order(sequence),
                    sequence: sequence.clone(),
                    rig: rig.clone(),
                    settings: self.settings.clone(),
                    trigger_manager: self.trigger_manager.clone(),
                    budget_registry: budget_registry.clone(),
                    smart_exposure_states: smart_exposure_states.clone(),
                    resume: resume.clone(),
                },
            ))),
            _ => None,
        };

        let reconnect_device_ids = rig.connected_device_ids();
        Run {
            control,
            resume_notify: Arc::new(tokio::sync::Notify::new()),
            skip_current_step: Arc::new(AtomicBool::new(false)),
            skip_to_next_target: Arc::new(AtomicBool::new(false)),
            skip_to_node: Arc::new(StdRwLock::new(None)),
            plugin_node_pending: Arc::new(RwLock::new(HashMap::new())),
            rig,
            config: self.settings.clone(),
            sky: self.sky.clone(),
            shared: ExecutorShared {
                depth_goal_ops: self.depth_goal_ops.clone(),
                defect_map_apply: self.defect_map_apply.clone(),
                adaptive_swap_state: self.shared_adaptive_swap_state.clone(),
            },
            device_ops,
            triggers: self.trigger_manager.clone(),
            decisions: DecisionLog {
                tx: self.decision_tx.clone(),
                run_id: self.active_sequence_run_id.clone(),
                enabled: self.settings.slots().decision_logging_enabled.clone(),
            },
            recovery: RecoveryHandles {
                signals: self.recovery_signals.clone(),
                current: self.current_recovery.clone(),
                history: self.recovery_history.clone(),
                generation: Arc::new(std::sync::atomic::AtomicU64::new(0)),
                reconnect_device_ids,
            },
            checkpoint,
            plan: RunPlan::new(
                self.sequence.clone(),
                root_node.name().to_string(),
                custom_recovery_branches,
                unreachable_instruction_names,
            ),
            teardown: Teardown::default(),
            outside_failures: OutsideFailures::default(),
            budget_registry,
            smart_exposure_states,
            resume,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The terminal message states what the ROOT did. Reporting a night that
    /// imaged as "Skipped" — or one that failed as "Completed" — is the same
    /// class of lie whichever direction it points in, and every remote client
    /// renders this string next to `state`.
    #[test]
    fn the_terminal_verdict_follows_the_status_the_root_returned() {
        assert_eq!(
            terminal_verdict_message(NodeStatus::Success, "Night root"),
            "Completed: Night root"
        );
        assert_eq!(
            terminal_verdict_message(NodeStatus::Skipped, "Night root"),
            "Skipped: Night root"
        );
        assert_eq!(
            terminal_verdict_message(NodeStatus::Failure, "Night root"),
            "Failed: Night root"
        );
        assert_eq!(
            terminal_verdict_message(NodeStatus::Cancelled, "Night root"),
            "Cancelled: Night root"
        );
    }
}
