//! The pre-meridian hold: stop tracking before the meridian, flip after it.
//!
//! Runs on tokio's paused clock with the target's hour angle driven from it,
//! and a stand-in for the trigger monitor that does what the real one does
//! each second: read the mount's tracking and the guider, publish the hour
//! angle, and evaluate the standard triggers through a real `TriggerManager`.

use super::*;

const THRESHOLD_MIN: f64 = 20.0;
const PAUSE_BEFORE_MIN: f64 = 20.0;
const SIDEREAL_RATE: f64 = 1.002_737_909;

type HourAngle = Arc<dyn Fn() -> Option<f64> + Send + Sync>;

/// The target's hour angle, in hours, `start_min` minutes from the meridian
/// when the clock starts and moving at the sidereal rate from there.
fn hour_angle_from(start_min: f64) -> HourAngle {
    let t0 = tokio::time::Instant::now();
    Arc::new(move || Some((start_min + t0.elapsed().as_secs_f64() / 60.0 * SIDEREAL_RATE) / 60.0))
}

struct Rig {
    ec: crate::node::context::ExecutionContext,
    ops: Arc<ScriptedDomeRotatorOps>,
    manager: crate::triggers::TriggerManager,
}

/// The owner's rig as it was on 2026-10-21: guiding, tracking on the pre-flip
/// side, the standard triggers armed with the flip at 20 min past and, unless
/// `pause_before` is 0, tracking to stop 20 min before.
async fn rig(pause_before: f64, start_ha_min: f64) -> Rig {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_guiding(true)
            .with_guider_rms(0.5),
    );
    let mut manager = crate::triggers::TriggerManager::new();
    manager.create_standard_triggers();
    assert!(manager.set_meridian_flip_config(crate::MeridianFlipConfig {
        minutes_past_meridian: THRESHOLD_MIN,
        pause_before_meridian_minutes: pause_before,
        ..crate::MeridianFlipConfig::default()
    }));
    manager.sync_state_from_config().await;
    {
        let state = manager.state();
        let mut state = state.write().await;
        state.set_meridian_target("NGC 891".to_string());
        state.target.target_ra = Some(35.6);
        state.target.target_dec = Some(42.35);
        state.target.current_hour_angle = Some(start_ha_min / 60.0);
        state.telemetry.pier_side = Some(crate::PierSide::West);
        state.telemetry.mount_parked = Some(false);
        state.telemetry.mount_is_tracking = Some(true);
        state.set_mount_tracking_expected(true);
        state.set_guiding_enabled(true);
    }

    let mut ec = crate::node::context::ExecutionContext::new_for_test("hold-node".to_string());
    ec.run.device_ops = ops.clone();
    ec.run.rig.camera_id = Some("camera-1".to_string());
    ec.run.rig.mount_id = Some("mount-1".to_string());
    ec.run.rig.longitude = Some(-80.0);
    ec.run.rig.latitude = Some(40.0);
    ec.run.trigger_state = Some(manager.state());
    Rig { ec, ops, manager }
}

/// One firing the stand-in monitor saw: trigger id, the target's hour angle in
/// minutes, and whether the run was holding for the meridian then.
type Firing = (String, f64, bool);

/// Stand in for the executor's trigger monitor until `stop` is raised. A
/// meridian flip it fires (and the real monitor would act on, the run not
/// being held) takes a minute and leaves the mount on the other side.
fn spawn_monitor(
    mut manager: crate::triggers::TriggerManager,
    ops: Arc<ScriptedDomeRotatorOps>,
    hour_angle: HourAngle,
    stop: Arc<AtomicBool>,
) -> tokio::task::JoinHandle<Vec<Firing>> {
    tokio::spawn(async move {
        let state = manager.state();
        let mut firings = Vec::new();
        while !stop.load(Ordering::SeqCst) {
            let tracking = ops
                .tracking_commands
                .lock()
                .unwrap()
                .last()
                .copied()
                .unwrap_or(true);
            let guiding = ops.guiding.load(Ordering::SeqCst);
            let ha = hour_angle();
            let held = {
                let mut s = state.write().await;
                s.target.current_hour_angle = ha;
                // The monitor's tracking poll.
                if crate::executor::apply_mount_tracking_poll(&mut s, tracking) {
                    s.tracking.mark_lost();
                }
                s.telemetry.mount_is_tracking = Some(tracking);
                // The monitor's guide-star poll.
                if s.guiding.motion_depth() > 0 || guiding {
                    s.set_guide_star_lost(false);
                } else if s.guiding.is_enabled() {
                    s.set_guide_star_lost(true);
                }
                s.run.is_held_by_run()
            };
            let ha_min = ha.unwrap_or(f64::NAN) * 60.0;
            for firing in manager.check_all().await {
                let id = firing.trigger_id().to_string();
                firings.push((id.clone(), ha_min, held));
                if id == "meridian_flip" && !held {
                    sleep(Duration::from_secs(60)).await;
                    let mut s = state.write().await;
                    s.telemetry.pier_side = Some(crate::PierSide::East);
                    s.mark_flip_performed();
                }
            }
            sleep(Duration::from_secs(1)).await;
        }
        firings
    })
}

fn collect_messages() -> (
    Arc<Mutex<Vec<String>>>,
    impl Fn(&str) + Send + Sync + 'static,
) {
    let messages = Arc::new(Mutex::new(Vec::new()));
    let sink = messages.clone();
    (messages, move |message: &str| {
        sink.lock().unwrap().push(message.to_string())
    })
}

/// (a) and (b): a 90 s frame 21 minutes before the meridian would end inside
/// the 20-minute window, so the run stops the guider and tracking and holds,
/// with neither a lost-tracking nor a lost-guide-star trigger firing for the
/// stop it made itself. At 20 minutes past, tracking comes back on, the flip
/// trigger fires, and the frame waits for the flip to finish.
#[tokio::test(start_paused = true)]
async fn a_frame_ending_inside_the_window_holds_with_tracking_off_until_the_flip() {
    let Rig { ec, ops, manager } = rig(PAUSE_BEFORE_MIN, -21.0).await;
    let trigger_state = manager.state();
    let hour_angle = hour_angle_from(-21.0);
    let stop = Arc::new(AtomicBool::new(false));
    let monitor = spawn_monitor(manager, ops.clone(), hour_angle.clone(), stop.clone());

    let (messages, status) = collect_messages();
    let control = BurstControl {
        frames_taken: 0,
        pause: ec.pause_gate(),
        status: Some(&status),
    };
    let mut ctx = ec.to_instruction_context("hold-node").await;
    ctx.target_name = Some("NGC 891".to_string());
    let ha = hour_angle.clone();
    let gate = wait_for_meridian_flip_window_at(&ctx, 90.0, &control, &move || ha()).await;
    let released_ha_min = hour_angle().unwrap() * 60.0;
    stop.store(true, Ordering::SeqCst);
    let firings = monitor.await.expect("monitor");

    assert!(
        gate.is_none(),
        "the frame proceeds after the flip: {gate:?}"
    );
    assert_eq!(
        *ops.tracking_commands.lock().unwrap(),
        vec![false, true],
        "tracking stops for the hold and comes back on for the flip"
    );
    assert_eq!(
        ops.guider_stop_calls.load(Ordering::SeqCst),
        1,
        "the guider is stopped before the mount stands still"
    );
    for (id, ha_min, _) in &firings {
        assert!(
            id != "mount_tracking_lost" && id != "guide_star_lost",
            "{id} fired at hour angle {ha_min:+.1} min for the run's own hold"
        );
    }
    let flips: Vec<&Firing> = firings
        .iter()
        .filter(|(id, _, _)| id == "meridian_flip")
        .collect();
    let (_, flip_ha_min, flip_held) = flips.first().expect("the flip trigger fired");
    assert!(
        *flip_ha_min >= THRESHOLD_MIN && !flip_held,
        "the flip fired at {flip_ha_min:+.1} min (held: {flip_held}), not at the threshold"
    );
    assert!(
        released_ha_min >= THRESHOLD_MIN + 1.0,
        "the frame went at {released_ha_min:+.1} min, before the minute-long flip finished"
    );

    let state = trigger_state.read().await;
    assert!(!state.run.is_held_by_run());
    assert_eq!(state.guiding.motion_depth(), 0, "the hold's move ended");
    assert!(
        state.guiding.is_enabled() && ops.guiding.load(Ordering::SeqCst),
        "guiding the run had started is running and armed again"
    );
    drop(state);

    let messages = messages.lock().unwrap();
    assert!(
        messages.iter().any(|m| m.starts_with(
            "Stopped tracking 21 min before the meridian; the flip runs \
                                   when NGC 891 is 20 min past it (at about "
        )),
        "the operator is told the hold began and when the flip runs: {messages:?}"
    );
    assert!(
        messages.iter().any(|m| m
            == "NGC 891 is 20 min past the meridian; tracking is back on and the flip starts."),
        "the operator is told the hold ended: {messages:?}"
    );
}

/// A run that starts with the target already inside the window holds at once,
/// whatever the frame length.
#[tokio::test(start_paused = true)]
async fn a_run_that_starts_inside_the_window_holds_at_once() {
    let Rig {
        ec,
        ops,
        manager: _manager,
    } = rig(PAUSE_BEFORE_MIN, 5.0).await;
    let hour_angle = hour_angle_from(5.0);
    let control = BurstControl {
        frames_taken: 0,
        pause: ec.pause_gate(),
        status: None,
    };
    let ctx = ec.to_instruction_context("hold-node").await;
    let cancel = ctx.cancellation_token.clone();
    let canceller = tokio::spawn(async move {
        sleep(Duration::from_secs(30)).await;
        cancel.store(true, Ordering::SeqCst);
    });
    let gate = wait_for_meridian_flip_window_at(&ctx, 1.0, &control, &move || hour_angle()).await;
    canceller.await.unwrap();
    assert!(gate.is_some());
    assert_eq!(*ops.tracking_commands.lock().unwrap(), vec![false]);
}

/// (c): with the hold off, or a frame that ends before tracking is due to
/// stop, or a target already past the flip threshold, nothing changes: no
/// tracking command, no guider stop, and the frame is not held here.
#[tokio::test(start_paused = true)]
async fn no_hold_when_it_is_off_or_the_frame_ends_first_or_the_flip_is_due() {
    for (pause_before, start_ha_min, exposure_secs) in [
        (0.0, -21.0, 90.0),
        (PAUSE_BEFORE_MIN, -25.0, 90.0),
        (PAUSE_BEFORE_MIN, -60.0, 300.0),
    ] {
        let Rig {
            ec,
            ops,
            manager: _manager,
        } = rig(pause_before, start_ha_min).await;
        let hour_angle = hour_angle_from(start_ha_min);
        let control = BurstControl::default();
        let ctx = ec.to_instruction_context("hold-node").await;
        let started = tokio::time::Instant::now();
        let gate =
            wait_for_meridian_flip_window_at(&ctx, exposure_secs, &control, &move || hour_angle())
                .await;
        assert!(gate.is_none());
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "held {:?} (pause before {pause_before}, start {start_ha_min} min, {exposure_secs} s)",
            started.elapsed()
        );
        assert!(ops.tracking_commands.lock().unwrap().is_empty());
        assert_eq!(ops.guider_stop_calls.load(Ordering::SeqCst), 0);
    }

    // Past the threshold the flip trigger owns the flip, as before: the gate
    // holds for it (and here, with no monitor to fire it, runs out its bound)
    // without touching tracking.
    let Rig {
        ec,
        ops,
        manager: _manager,
    } = rig(PAUSE_BEFORE_MIN, 25.0).await;
    let hour_angle = hour_angle_from(25.0);
    let ctx = ec.to_instruction_context("hold-node").await;
    let _ = wait_for_meridian_flip_window_at(&ctx, 90.0, &BurstControl::default(), &move || {
        hour_angle()
    })
    .await;
    assert!(ops.tracking_commands.lock().unwrap().is_empty());
    assert_eq!(ops.guider_stop_calls.load(Ordering::SeqCst), 0);
}

/// (d): a run stopped during the hold ends it cleanly: the instruction reports
/// the cancel, the run's move and hold flag are cleared, and tracking is left
/// off rather than driven towards the tripod with nobody watching.
#[tokio::test(start_paused = true)]
async fn a_run_cancelled_during_the_hold_ends_it_cleanly() {
    let Rig { ec, ops, manager } = rig(PAUSE_BEFORE_MIN, -21.0).await;
    let trigger_state = manager.state();
    let hour_angle = hour_angle_from(-21.0);
    let (messages, status) = collect_messages();
    let control = BurstControl {
        frames_taken: 0,
        pause: ec.pause_gate(),
        status: Some(&status),
    };
    let ctx = ec.to_instruction_context("hold-node").await;
    let cancel = ctx.cancellation_token.clone();
    let canceller = tokio::spawn(async move {
        sleep(Duration::from_secs(10 * 60)).await;
        cancel.store(true, Ordering::SeqCst);
    });
    let gate = wait_for_meridian_flip_window_at(&ctx, 90.0, &control, &move || hour_angle()).await;
    canceller.await.unwrap();

    let result = gate.expect("a cancelled hold ends the instruction");
    assert_eq!(result.status, NodeStatus::Cancelled);
    assert_eq!(*ops.tracking_commands.lock().unwrap(), vec![false]);
    let state = trigger_state.read().await;
    assert!(!state.run.is_held_by_run());
    assert_eq!(state.guiding.motion_depth(), 0);
    drop(state);
    assert!(messages
        .lock()
        .unwrap()
        .iter()
        .any(|m| m == "The run stopped during the pre-meridian hold; mount tracking is left off."));
}

/// The hold's own stop is never a tracking loss, even when the monitor's poll
/// lands between the stop command and the hold recording it: the poll that
/// sees tracking go from on to off while the run holds keeps the loss
/// baseline disarmed, and the first `true` after the hold arms it again.
#[test]
fn a_tracking_poll_during_the_hold_is_not_a_loss() {
    let mut state = crate::triggers::TriggerState::new();
    state.set_mount_tracking_expected(true);
    state.telemetry.mount_is_tracking = Some(true);
    state.run.begin_hold(crate::triggers::RunHold::PreMeridian);

    assert!(!crate::executor::apply_mount_tracking_poll(
        &mut state, false
    ));
    assert!(!state.tracking.is_expected());
    state.telemetry.mount_is_tracking = Some(false);

    state.run.end_hold();
    assert!(!crate::executor::apply_mount_tracking_poll(
        &mut state, true
    ));
    assert!(
        state.tracking.is_expected(),
        "the first tracking reading after the hold arms the baseline again"
    );
    state.telemetry.mount_is_tracking = Some(true);
    assert!(
        crate::executor::apply_mount_tracking_poll(&mut state, false),
        "a loss after the hold is still a loss"
    );
}

const M1_RA_HOURS: f64 = 5.5755;
const M1_DEC: f64 = 22.0145;

/// The rig of 2026-11-16 02:16 on the scenario simulator: a guider that stops
/// and guides as it is told, a simulated mount on pier West that turns over
/// when slewed, and the flip settings the owner ran (stop tracking 20 min
/// before the meridian, flip 20 min past it, recenter and resume guiding on).
struct FlipNight {
    ops: Arc<crate::executor::scenario_sim_tests::ScriptedDeviceOps>,
    /// The light frame's context.
    ctx: InstructionContext,
    manager: crate::triggers::TriggerManager,
    flip_config: crate::MeridianFlipConfig,
}

async fn flip_night(start_ha_min: f64) -> FlipNight {
    use crate::executor::scenario_sim_tests::{ScriptedDeviceOps, SimMount};
    let ops = Arc::new(ScriptedDeviceOps::new());
    ops.flip_on_slew.store(true, Ordering::SeqCst);
    ops.guider_follows_commands.store(true, Ordering::SeqCst);
    ops.guiding.store(true, Ordering::SeqCst);
    let mut mount = SimMount::tracking_at(M1_RA_HOURS, M1_DEC);
    mount.settle_secs = 3.0;
    ops.attach_sim_mount(mount);

    let flip_config = crate::MeridianFlipConfig {
        minutes_past_meridian: THRESHOLD_MIN,
        pause_before_meridian_minutes: PAUSE_BEFORE_MIN,
        auto_center: true,
        resume_guiding: true,
        max_retries: 0,
        ..crate::MeridianFlipConfig::default()
    };
    let mut manager = crate::triggers::TriggerManager::new();
    manager.create_standard_triggers();
    assert!(manager.set_meridian_flip_config(flip_config.clone()));
    manager.sync_state_from_config().await;
    {
        let state = manager.state();
        let mut state = state.write().await;
        state.set_meridian_target("M1".to_string());
        state.target.target_ra = Some(M1_RA_HOURS * 15.0);
        state.target.target_dec = Some(M1_DEC);
        state.target.current_hour_angle = Some(start_ha_min / 60.0);
        state.telemetry.pier_side = Some(crate::PierSide::West);
        state.telemetry.mount_parked = Some(false);
        state.telemetry.mount_is_tracking = Some(true);
        state.set_mount_tracking_expected(true);
        state.set_guiding_enabled(true);
    }

    let mut ec = crate::node::context::ExecutionContext::new_for_test("m1-lights".to_string());
    ec.run.device_ops = ops.clone();
    ec.run.rig.camera_id = Some("camera".to_string());
    ec.run.rig.mount_id = Some("mount".to_string());
    ec.run.trigger_state = Some(manager.state());
    let mut ctx = ec.to_instruction_context("m1-lights").await;
    ctx.target_name = Some("M1".to_string());
    ctx.target_ra = Some(M1_RA_HOURS);
    ctx.target_dec = Some(M1_DEC);
    FlipNight {
        ops,
        ctx,
        manager,
        flip_config,
    }
}

/// Stand in for the trigger monitor, as [`spawn_monitor`] does, but a flip it
/// fires is the real one: the flip executor on the simulated mount, run in
/// the monitor's task as the trigger action runs it.
async fn spawn_monitor_running_flips(
    night: &mut FlipNight,
    hour_angle: HourAngle,
    stop: Arc<AtomicBool>,
) -> tokio::task::JoinHandle<Vec<crate::meridian_flip_executor::FlipResult>> {
    let ops = night.ops.clone();
    let run = night.ctx.run.clone();
    let flip_config = night.flip_config.clone();
    let mut manager = std::mem::take(&mut night.manager);
    let flip_ctx = crate::meridian_flip_executor::FlipContext::for_instruction(&night.ctx, None)
        .await
        .expect("the run has a mount and a target");
    tokio::spawn(async move {
        let state = manager.state();
        let mut flips = Vec::new();
        while !stop.load(Ordering::SeqCst) {
            let tracking = ops.sim_mount().is_some_and(|mount| mount.axes_tracking());
            let guiding = ops.guiding.load(Ordering::SeqCst);
            let held = {
                let mut s = state.write().await;
                s.target.current_hour_angle = hour_angle();
                if crate::executor::apply_mount_tracking_poll(&mut s, tracking) {
                    s.tracking.mark_lost();
                }
                s.telemetry.mount_is_tracking = Some(tracking);
                if s.guiding.motion_depth() > 0 || guiding {
                    s.set_guide_star_lost(false);
                } else if s.guiding.is_enabled() {
                    s.set_guide_star_lost(true);
                }
                s.run.is_held_by_run()
            };
            for firing in manager.check_all().await {
                if firing.trigger_id() == "meridian_flip" && !held {
                    let mut executor = crate::meridian_flip_executor::MeridianFlipExecutor::in_run(
                        flip_config.clone(),
                        run.clone(),
                    );
                    flips.push(executor.execute(&flip_ctx).await);
                }
            }
            sleep(Duration::from_secs(1)).await;
        }
        flips
    })
}

/// The calls the simulator saw from `from` on, and where the first that
/// `wanted` matches is.
fn first_call(calls: &[String], from: usize, wanted: impl Fn(&str) -> bool) -> Option<usize> {
    calls
        .iter()
        .enumerate()
        .skip(from)
        .find(|(_, call)| wanted(call))
        .map(|(index, _)| index)
}

fn starts_guiding(call: &str) -> bool {
    call == "guider_start" || call == "guider_select_fresh_star"
}

/// D4 on the rig (2026-11-16 02:16): the frame held for the flip was let go
/// the moment the flip had turned the mount over and, picking guiding up
/// after the hold, started it on a fresh star while the flip was still
/// confirming tracking. The recenter's sync and correction slews then ran
/// under a guiding PHD2, which pulled the mount back toward its lock point
/// after each one, and the recenter did not converge.
///
/// Guiding stops before the flip slew, stays stopped through every centering
/// solve, sync and correction slew, and is started again only once the
/// centering has converged.
#[tokio::test(start_paused = true)]
async fn guiding_stays_stopped_through_the_flip_and_its_recenter() {
    let mut night = flip_night(-21.0).await;
    // The first solve after the flip is 0.6° off, the next 0.04°, then on
    // target: two corrections, as on the rig.
    night
        .ops
        .solve_dec_offsets_deg
        .lock()
        .unwrap()
        .extend([0.6, 0.04, 0.0]);
    let ops = night.ops.clone();
    let trigger_state = night.manager.state();
    let hour_angle = hour_angle_from(-21.0);
    let stop = Arc::new(AtomicBool::new(false));
    let monitor = spawn_monitor_running_flips(&mut night, hour_angle.clone(), stop.clone()).await;
    let ctx = night.ctx;

    let control = BurstControl::default();
    let ha = hour_angle.clone();
    let gate = wait_for_meridian_flip_window_at(&ctx, 90.0, &control, &move || ha()).await;
    assert!(gate.is_none(), "the frame proceeds after the flip: {gate:?}");
    stop.store(true, Ordering::SeqCst);
    let flips = monitor.await.expect("monitor");

    assert!(
        matches!(
            flips.as_slice(),
            [crate::meridian_flip_executor::FlipResult::Success { .. }]
        ),
        "{flips:?}"
    );
    let calls = ops.calls();
    let flip_slew = first_call(&calls, 0, |c| c.starts_with("mount_slew:")).expect("the flip slewed");
    assert!(
        first_call(&calls, 0, |c| c == "guider_stop").is_some_and(|stop| stop < flip_slew),
        "guiding stops before the flip slew: {calls:?}"
    );
    let last_solve = calls
        .iter()
        .rposition(|c| c == "plate_solve")
        .expect("the flip recentered");
    let last_move = calls
        .iter()
        .rposition(|c| c.starts_with("mount_slew:") || c.starts_with("mount_sync:"))
        .unwrap();
    assert_eq!(
        calls.iter().filter(|c| c.starts_with("mount_sync:")).count(),
        2,
        "two corrections: {calls:?}"
    );
    let restart = first_call(&calls, flip_slew, starts_guiding).expect("guiding was started again");
    assert!(
        restart > last_solve && restart > last_move,
        "guiding restarted at call {restart}, before the recenter converged (last solve \
         {last_solve}, last move {last_move}): {calls:?}"
    );
    assert_eq!(
        ops.moves_while_guiding.load(Ordering::SeqCst),
        0,
        "a sync or slew ran while the guider guided: {calls:?}"
    );
    assert!(ops.guiding.load(Ordering::SeqCst));
    let state = trigger_state.read().await;
    assert!(state.guiding.is_enabled(), "the run's guiding is armed again");
    assert!(!state.guiding.resume_pending());
    assert_eq!(state.guiding.motion_depth(), 0);
}
