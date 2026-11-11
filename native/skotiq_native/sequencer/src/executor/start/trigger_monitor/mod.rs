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

/// Run the monitor until a trigger ends the run or the run is cancelled.
/// Returns every firing that was acted on. Never returns for a run with
/// triggers disabled, so the run does not read it as a monitor that died.
pub(super) async fn run_trigger_monitor_poll_loop(
    run: Arc<Run>,
    custom_branch_context: ExecutionContext,
    recovery_requests: mpsc::Sender<crate::recovery::RecoveryCause>,
    heartbeat_tx: watch::Sender<u64>,
) -> Vec<(String, RecoveryAction)> {
    if !run.triggers_enabled {
        std::future::pending::<()>().await;
        return Vec::new();
    }
    let sequence = run.plan.sequence.as_ref();
    let explicit_end = sequence.is_some_and(super::explicit_end::owns_dawn_end);
    let calibration_run = sequence.is_some_and(super::calibration_run::is_calibration_only);
    let finish_frames = run.teardown.finish_frames();
    let run_state = run.control.state.clone();
    let is_cancelled = run.control.is_cancelled.clone();
    let trigger_manager = run.triggers.clone();
    let runtime_config = run.config.clone();
    let mut poller = DevicePoller::new(
        run.device_ops.clone(),
        run.triggers.clone(),
        run.config.clone(),
        run_state.events().clone(),
        &run.rig,
    );
    let mut frame_watch = frame_watch::FrameWatchStage::new(
        run_state.subscribe(),
        run.device_ops.clone(),
        run.plan.sequence.clone(),
    );
    let mut dispatcher = Dispatcher::new(&run, custom_branch_context, recovery_requests).await;

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
        let tick_state = run_state.get();
        if RunMode::new(tick_state, None).is_none() {
            continue;
        }
        if is_cancelled.load(Ordering::Relaxed) {
            break;
        }

        poller.poll(tick_state).await;

        dispatcher.update_tracking_limit_hold(calibration_run).await;
        let tick_state = run_state.get();

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
                    state.stops_on_quality_problems(),
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
