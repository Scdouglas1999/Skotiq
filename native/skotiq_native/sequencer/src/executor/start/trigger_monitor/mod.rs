//! The run's trigger monitor: one tick per second, in five stages.
//!
//! 1. [`polling`] reads the devices and publishes the readings into the
//!    trigger state.
//! 2. [`frame_watch`] judges the frames saved since the last tick and acts
//!    between frames on what it finds.
//! 3. [`TriggerManager::check_all`] evaluates every trigger.
//! 4. [`policy`] applies the operator's settings and the run's [`RunMode`],
//!    and dispatches only what may act, which is what starts a trigger's
//!    cooldown.
//! 5. [`dispatch`] hands each dispatch to its action handler in [`actions`],
//!    running it to completion before the next tick.

use super::*;
use crate::triggers::{GuiderObservation, RunMode};

mod actions;
mod dispatch;
mod frame_watch;
#[cfg(test)]
mod frame_watch_tests;
mod policy;
mod polling;
mod tracking_limit;

use dispatch::{Dispatcher, Flow};
use policy::{select_dispatches, DispatchPolicy};
use polling::DevicePoller;

/// Everything the poll loop reads from the run it belongs to.
pub(super) struct TriggerMonitorArgs {
    pub active_run_id_for_decisions: Arc<StdRwLock<Option<i64>>>,
    pub cloud_motion_for_recovery: Arc<RwLock<CloudMotionSnapshot>>,
    pub custom_recovery_branches_for_triggers: Arc<HashMap<String, String>>,
    pub custom_recovery_context_for_triggers: ExecutionContext,
    pub decision_tx_for_lifecycle: crate::decision::DecisionSender,
    pub device_ops_for_triggers: SharedDeviceOps,
    pub event_tx_clone2: broadcast::Sender<ExecutorEvent>,
    pub execution_quiesced_for_triggers: watch::Receiver<bool>,
    pub heartbeat_tx: watch::Sender<u64>,
    pub is_cancelled_clone: Arc<AtomicBool>,
    pub is_paused_for_triggers: Arc<AtomicBool>,
    pub meridian_flip_failed_for_triggers: Arc<AtomicBool>,
    pub meridian_flip_failure_for_triggers: Arc<StdRwLock<Option<String>>>,
    pub park_and_abort_done_for_triggers: watch::Sender<bool>,
    pub park_and_abort_for_triggers: Arc<AtomicBool>,
    pub progress_for_triggers: Arc<StdRwLock<SequenceProgress>>,
    pub recovery_request_tx: mpsc::Sender<crate::recovery::RecoveryCause>,
    pub runtime_config: Arc<StdRwLock<RuntimeConfig>>,
    pub sequence_for_custom_recovery_triggers: Option<SequenceDefinition>,
    pub skip_to_next_target_for_triggers: Arc<AtomicBool>,
    pub skip_to_node_for_recovery: Arc<StdRwLock<Option<NodeId>>>,
    pub state_clone: Arc<RwLock<ExecutorState>>,
    pub transparency_backup_for_recovery:
        Arc<RwLock<Option<crate::node::context::TransparencyBackupPlan>>>,
    pub trigger_action_context: TriggerActionContext,
    pub trigger_action_in_flight_for_triggers: Arc<AtomicBool>,
    pub trigger_manager: Arc<RwLock<TriggerManager>>,
    pub triggers_enabled: bool,
    pub finish_frames: watch::Receiver<bool>,
}

/// Run the monitor until a trigger ends the run or the run is cancelled.
/// Returns every firing that was acted on.
pub(super) async fn run_trigger_monitor_poll_loop(
    args: TriggerMonitorArgs,
) -> Vec<(String, RecoveryAction)> {
    if !args.triggers_enabled {
        // Hold this task open so the `try_join!` below still waits on the
        // other branches; an immediate return would short-circuit them.
        std::future::pending::<()>().await;
        return Vec::new();
    }
    let explicit_end = args
        .sequence_for_custom_recovery_triggers
        .as_ref()
        .is_some_and(super::explicit_end::owns_dawn_end);
    let calibration_run = args
        .sequence_for_custom_recovery_triggers
        .as_ref()
        .is_some_and(super::calibration_run::is_calibration_only);
    let finish_frames = args.finish_frames.clone();
    let executor_state = args.state_clone.clone();
    let is_cancelled = args.is_cancelled_clone.clone();
    let heartbeat_tx = args.heartbeat_tx.clone();
    let trigger_manager = args.trigger_manager.clone();
    let runtime_config = args.runtime_config.clone();
    let mut poller = DevicePoller::new(
        args.device_ops_for_triggers.clone(),
        args.trigger_manager.clone(),
        args.runtime_config.clone(),
        args.event_tx_clone2.clone(),
        &args.trigger_action_context,
    );
    let mut frame_watch = frame_watch::FrameWatchStage::new(
        args.event_tx_clone2.subscribe(),
        args.device_ops_for_triggers.clone(),
        args.sequence_for_custom_recovery_triggers.clone(),
    );
    let mut dispatcher = Dispatcher::new(args).await;

    let mut check_interval = monitor_interval();
    let mut heartbeat: u64 = 0;
    loop {
        check_interval.tick().await;
        // Proof of life for the stall watchdog, before the state gate so a
        // paused run still reports a live monitor.
        heartbeat = heartbeat.wrapping_add(1);
        let _ = heartbeat_tx.send(heartbeat);
        if is_cancelled.load(Ordering::Relaxed) {
            break;
        }
        if *finish_frames.borrow() {
            if frame_watch.finish_tick(&dispatcher).await {
                break;
            }
            continue;
        }

        // A held run still has a telescope under the open sky, so the monitor
        // keeps polling and evaluating while it is paused or recovering; what
        // a firing may then do is decided by `RunMode::may_act`. Idle,
        // stopping and finished runs have nothing to watch.
        let tick_state = *executor_state.read().await;
        if RunMode::new(tick_state, None).is_none() {
            continue;
        }
        if is_cancelled.load(Ordering::Relaxed) {
            break;
        }

        poller.poll(tick_state).await;

        dispatcher.update_tracking_limit_hold(calibration_run).await;
        let tick_state = *executor_state.read().await;

        // The action handlers take the trigger-state lock themselves, so the
        // manager lock is released before they run.
        let park_policy = runtime_config.read().park_policy;
        let run_hold = trigger_manager.read().await.state().read().await.run.hold();
        let Some(mode) = RunMode::new(tick_state, run_hold) else {
            continue;
        };
        if let Some(fired) = frame_watch.tick(&mut dispatcher, mode).await {
            return fired;
        }
        let dispatches = {
            let mut manager = trigger_manager.write().await;
            let fired = manager.check_all().await;
            let (stop_on_quality_problems, weather_advisory_only) = {
                let state = manager.state();
                let state = state.read().await;
                (
                    state.stop_on_quality_problems,
                    state.weather_unsafe_is_advisory_only(),
                )
            };
            select_dispatches(
                &mut manager,
                fired,
                mode,
                DispatchPolicy {
                    explicit_end,
                    calibration_run,
                    park_policy,
                    stop_on_quality_problems,
                    weather_advisory_only,
                },
            )
        };

        if let Flow::Terminate(fired) = dispatcher.run_tick(mode, dispatches).await {
            return fired;
        }
    }
    dispatcher.into_fired()
}

fn monitor_interval() -> tokio::time::Interval {
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(1));
    // Recovery actions can take minutes. Poll current device state once when
    // they finish; replaying missed ticks floods the guider with stale work.
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    interval
}

#[cfg(test)]
mod cadence_tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn slow_recovery_does_not_replay_hundreds_of_device_polls() {
        let mut interval = monitor_interval();
        interval.tick().await;
        // A five-minute autofocus/flip owns this task before it resumes polling.
        tokio::time::advance(std::time::Duration::from_secs(300)).await;
        interval.tick().await;
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(500), interval.tick())
                .await
                .is_err(),
            "missed status polls must not be replayed in a burst"
        );
    }
}
