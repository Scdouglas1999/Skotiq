//! The run's trigger monitor: one tick per second, in four stages.
//!
//! 1. [`polling`] reads the devices and publishes the readings into the
//!    trigger state.
//! 2. [`TriggerManager::check_all`] evaluates every trigger.
//! 3. [`policy`] applies the operator's settings and the run's [`RunMode`],
//!    and dispatches only what may act, which is what starts a trigger's
//!    cooldown.
//! 4. [`dispatch`] hands each dispatch to its action handler in [`actions`],
//!    running it to completion before the next tick.

use super::*;
use crate::triggers::{GuiderObservation, RunMode};

mod actions;
mod dispatch;
mod policy;
mod polling;

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
    let calibration_run = args.sequence_for_custom_recovery_triggers.as_ref()
        .is_some_and(super::calibration_run::is_calibration_only);
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
    let mut dispatcher = Dispatcher::new(args).await;

    let mut check_interval = tokio::time::interval(std::time::Duration::from_secs(1));
    let mut heartbeat: u64 = 0;
    loop {
        check_interval.tick().await;
        // Proof of life for the stall watchdog, before the state gate so a
        // paused run still reports a live monitor.
        heartbeat = heartbeat.wrapping_add(1);
        let _ = heartbeat_tx.send(heartbeat);

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

        // The action handlers take the trigger-state lock themselves, so the
        // manager lock is released before they run.
        let park_policy = runtime_config.read().park_policy;
        let run_hold = trigger_manager.read().await.state().read().await.run.hold();
        let Some(mode) = RunMode::new(tick_state, run_hold) else {
            continue;
        };
        let dispatches = {
            let mut manager = trigger_manager.write().await;
            let fired = manager.check_all().await;
            let (stop_on_quality_problems, weather_advisory_only) = {
                let state = manager.state();
                let state = state.read().await;
                (state.stop_on_quality_problems, state.weather_unsafe_is_advisory_only())
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
