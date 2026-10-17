//! The checkpoint streamer: writes a resumable checkpoint on a fixed cadence
//! while the run executes, and once more when the run stops.

use super::*;

pub(super) struct CheckpointStreamArgs {
    pub is_cancelled_for_checkpoint: Arc<AtomicBool>,
    pub park_and_abort_done_for_checkpoint: watch::Receiver<bool>,
    pub park_and_abort_for_checkpoint: Arc<AtomicBool>,
    pub progress_for_checkpoint: Arc<StdRwLock<SequenceProgress>>,
    pub state_for_checkpoint: Arc<RwLock<ExecutorState>>,
    pub streaming_budget_registry: crate::scheduling::integration_budget::BudgetRegistry,
    pub streaming_camera_id: Option<String>,
    pub streaming_checkpoint_manager: Option<Arc<crate::checkpoint::CheckpointManager>>,
    pub streaming_filter_focus_offsets: HashMap<String, i32>,
    pub streaming_filterwheel_id: Option<String>,
    pub streaming_focuser_id: Option<String>,
    pub streaming_latitude: Option<f64>,
    pub streaming_longitude: Option<f64>,
    pub streaming_mount_id: Option<String>,
    pub streaming_rotator_id: Option<String>,
    pub streaming_runtime_config: Arc<StdRwLock<RuntimeConfig>>,
    pub streaming_save_path: Option<std::path::PathBuf>,
    pub streaming_sequence: Option<SequenceDefinition>,
    pub streaming_smart_exposure_states:
        Arc<RwLock<HashMap<NodeId, crate::SmartExposureCheckpoint>>>,
    pub streaming_triggers_enabled: bool,
    pub trigger_manager_for_checkpoint: Arc<RwLock<TriggerManager>>,
}

pub(super) async fn run_checkpoint_stream(args: CheckpointStreamArgs) {
    let CheckpointStreamArgs {
        is_cancelled_for_checkpoint,
        mut park_and_abort_done_for_checkpoint,
        park_and_abort_for_checkpoint,
        progress_for_checkpoint,
        state_for_checkpoint,
        streaming_budget_registry,
        streaming_camera_id,
        streaming_checkpoint_manager,
        streaming_filter_focus_offsets,
        streaming_filterwheel_id,
        streaming_focuser_id,
        streaming_latitude,
        streaming_longitude,
        streaming_mount_id,
        streaming_rotator_id,
        streaming_runtime_config,
        streaming_save_path,
        streaming_sequence,
        streaming_smart_exposure_states,
        streaming_triggers_enabled,
        trigger_manager_for_checkpoint,
    } = args;
    // Reuse the executor's Arc<CheckpointManager>: a second instance would
    // fork info_cache, so this task and the executor would disagree about
    // what has been checkpointed.
    let Some(checkpoint_mgr) = streaming_checkpoint_manager else {
        std::future::pending::<()>().await;
        return;
    };
    let Some(sequence) = streaming_sequence else {
        std::future::pending::<()>().await;
        return;
    };

    let mut interval = tokio::time::interval(std::time::Duration::from_secs(30));

    loop {
        interval.tick().await;

        if is_cancelled_for_checkpoint.load(Ordering::Acquire) {
            if park_and_abort_for_checkpoint.load(Ordering::Acquire) {
                if let Err(error) = park_and_abort_done_for_checkpoint
                    .wait_for(|done| *done)
                    .await
                {
                    tracing::warn!(
                        "Checkpoint stream: the park-and-abort completion signal was dropped \
                         before the safe-state sweep reported done ({}); stopping checkpoints \
                         without the handshake",
                        error
                    );
                }
            }
            break;
        }

        let exec_state = *state_for_checkpoint.read().await;
        // checkpoint mid-recovery too so a process
        // crash during a long recovery loop doesn't lose the
        // accepted-frame totals from before the failure.
        if !matches!(
            exec_state,
            ExecutorState::Running | ExecutorState::Paused | ExecutorState::Recovering
        ) {
            continue;
        }

        let prog = progress_for_checkpoint.read().clone();
        let mut checkpoint = crate::checkpoint::SessionCheckpoint::new(sequence.clone());
        checkpoint.node_statuses = prog.node_statuses.clone();
        checkpoint.current_node = prog.current_node_id.clone();
        checkpoint.executor_state = exec_state;
        checkpoint.completed_exposures = prog.completed_exposures;
        checkpoint.completed_integration_secs = prog.completed_integration_secs;
        checkpoint.is_active = true;
        checkpoint.set_devices(
            streaming_camera_id.clone(),
            streaming_mount_id.clone(),
            streaming_focuser_id.clone(),
            streaming_filterwheel_id.clone(),
            streaming_rotator_id.clone(),
        );
        checkpoint.set_location(streaming_latitude, streaming_longitude);
        checkpoint.set_save_path(streaming_save_path.clone());

        let trigger_state = {
            let manager = trigger_manager_for_checkpoint.read().await;
            manager.state()
        };
        let trigger_state = trigger_state.read().await;
        checkpoint.set_trigger_state(crate::checkpoint::TriggerStateSnapshot::from_state(
            &trigger_state,
            streaming_runtime_config.read().safety_fail_mode,
            streaming_triggers_enabled,
            streaming_filter_focus_offsets.clone(),
        ));

        // snapshot per-target budget
        // accounting so pause/resume preserves completed
        // integration time per filter.
        checkpoint.budget_states = streaming_budget_registry.snapshot().await;

        // snapshot the SmartExposure map so
        // a process crash mid-rotation can resume on the
        // right filter at the right frame index. We clone
        // the inner HashMap under the lock then drop the
        // lock immediately so the SmartExposure instruction
        // can keep writing fresh state between batches
        // without contending on the streaming task.
        checkpoint.smart_exposure_states = {
            let guard = streaming_smart_exposure_states.read().await;
            guard.clone()
        };

        // The wizard and scheduler slots live in no registry
        // this task holds — their owners write them straight
        // through the shared CheckpointManager (see
        // `SessionWizardCheckpointSink`). Building a fresh
        // SessionCheckpoint here would wipe a mosaic panel's
        // resume slot every 30 seconds, so carry both maps
        // forward from disk exactly as the public writer does.
        if let Ok(Some(existing)) = checkpoint_mgr.load() {
            checkpoint.wizard_states = existing.wizard_states;
            checkpoint.scheduler_states = existing.scheduler_states;
        }

        match checkpoint_mgr.save(&checkpoint) {
            Ok(()) => tracing::debug!(
                "Streaming checkpoint saved ({} exposures, {:.1}s integration)",
                checkpoint.completed_exposures,
                checkpoint.completed_integration_secs
            ),
            Err(e) => tracing::warn!("Streaming checkpoint save failed: {}", e),
        }
    }
}
