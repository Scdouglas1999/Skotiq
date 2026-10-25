//! `park` / `unpark` tests. Shared fixtures stay in the parent `tests` module
//! and reach here through `use super::*;`.

use super::*;

/// Owner decision (2026-08-14): the autopilot prefixes every dispatched
/// sequence with `Unpark`, so an already-tracking mount would be handed a
/// release-the-axes command mid-run. Unpark is now conditional on the
/// mount reporting parked.
#[tokio::test]
async fn unpark_is_a_logged_no_op_when_the_mount_is_not_parked() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_mount_parked(false));
    let mut ctx = ctx_with_ops(ops.clone()).await;
    ctx.mount_id = Some("mount-1".to_string());

    let result = execute_unpark(&ctx).await;

    assert_eq!(result.status, NodeStatus::Success);
    assert_eq!(result.message.as_deref(), Some("Mount already unparked"));
    assert_eq!(
        ops.mount_unpark_calls.load(Ordering::SeqCst),
        0,
        "an unparked mount must never be sent Unpark"
    );
}

#[tokio::test]
async fn unpark_runs_when_the_mount_reports_parked() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_mount_parked(true));
    let mut ctx = ctx_with_ops(ops.clone()).await;
    ctx.mount_id = Some("mount-1".to_string());

    let result = execute_unpark(&ctx).await;

    assert_eq!(result.status, NodeStatus::Success);
    assert_eq!(result.message.as_deref(), Some("Mount unparked"));
    assert_eq!(ops.mount_unpark_calls.load(Ordering::SeqCst), 1);
}

/// A parked-state read that fails must not skip the unpark: unparking an
/// already-unparked mount is the milder outcome of the two.
#[tokio::test]
async fn unpark_still_runs_when_the_parked_state_cannot_be_read() {
    let ops =
        Arc::new(ScriptedDomeRotatorOps::new().with_mount_is_parked_error("AtPark not supported"));
    let mut ctx = ctx_with_ops(ops.clone()).await;
    ctx.mount_id = Some("mount-1".to_string());

    let result = execute_unpark(&ctx).await;

    assert_eq!(result.status, NodeStatus::Success);
    assert_eq!(ops.mount_unpark_calls.load(Ordering::SeqCst), 1);
}

/// Small enough that the no-motion case finishes quickly.
fn fast_home_timing() -> HomeTiming {
    HomeTiming {
        motion_start_window: Duration::from_millis(80),
        timeout: Duration::from_secs(5),
        poll_interval: Duration::from_millis(10),
    }
}

async fn home_ctx(ops: Arc<ScriptedDomeRotatorOps>) -> InstructionContext {
    let mut ctx = ctx_with_ops(ops).await;
    ctx.mount_id = Some("mount-1".to_string());
    ctx
}

#[tokio::test]
async fn home_issues_find_home_once_and_waits_for_the_mount_to_arrive() {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_mount_parked(false)
            .with_mount_slewing_states(vec![true, true, false]),
    );
    let ctx = home_ctx(ops.clone()).await;

    let result = execute_home_mount_with(&ctx, fast_home_timing()).await;

    assert_eq!(result.status, NodeStatus::Success);
    assert_eq!(result.message.as_deref(), Some("Mount at home"));
    assert_eq!(ops.mount_find_home_calls.load(Ordering::SeqCst), 1);
    assert!(
        ops.mount_slew_state_calls.load(Ordering::SeqCst) >= 3,
        "home must wait for the slew to end, not return on the command ack"
    );
    assert_eq!(ops.mount_unpark_calls.load(Ordering::SeqCst), 0);
}

/// A parked mount fails the node: homing must never unpark it on its own.
#[tokio::test]
async fn home_refuses_a_parked_mount_without_unparking_or_homing_it() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_mount_parked(true));
    let ctx = home_ctx(ops.clone()).await;

    let result = execute_home_mount_with(&ctx, fast_home_timing()).await;

    assert_eq!(result.status, NodeStatus::Failure);
    assert_eq!(
        result.message.as_deref(),
        Some("Mount is parked. Unpark it before sending it home.")
    );
    assert_eq!(ops.mount_find_home_calls.load(Ordering::SeqCst), 0);
    assert_eq!(ops.mount_unpark_calls.load(Ordering::SeqCst), 0);
}

/// The NYX-101 case: the driver accepts FindHome and the mount never moves.
#[tokio::test]
async fn home_fails_when_the_driver_accepts_it_but_the_mount_never_moves() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_mount_slewing_states(vec![false]));
    let ctx = home_ctx(ops.clone()).await;

    let result = execute_home_mount_with(&ctx, fast_home_timing()).await;

    assert_eq!(result.status, NodeStatus::Failure);
    assert_eq!(
        result.message.as_deref(),
        Some("The mount's driver accepted Home but the mount didn't move.")
    );
    assert_eq!(ops.mount_find_home_calls.load(Ordering::SeqCst), 1);
    assert_eq!(ops.mount_abort_calls.load(Ordering::SeqCst), 1);
}

/// A driver that cannot report AtHome is judged on the slew ending, and says
/// that it could not confirm the result.
#[tokio::test]
async fn home_succeeds_unconfirmed_when_the_driver_does_not_report_at_home() {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_mount_slewing_states(vec![true, false])
            .with_at_home(Err("AtHome not implemented".to_string())),
    );
    let ctx = home_ctx(ops.clone()).await;

    let result = execute_home_mount_with(&ctx, fast_home_timing()).await;

    assert_eq!(result.status, NodeStatus::Success);
    assert_eq!(
        result.message.as_deref(),
        Some("Mount stopped after homing; the driver cannot confirm it is at home")
    );
}

#[tokio::test]
async fn home_fails_when_the_mount_stops_away_from_home() {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_mount_slewing_states(vec![true, false])
            .with_at_home(Ok(false)),
    );
    let ctx = home_ctx(ops.clone()).await;

    let result = execute_home_mount_with(&ctx, fast_home_timing()).await;

    assert_eq!(result.status, NodeStatus::Failure);
    assert_eq!(
        result.message.as_deref(),
        Some("The mount stopped but does not report being at home")
    );
}

#[tokio::test]
async fn cancelling_a_home_aborts_the_mount() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_mount_slewing_states(vec![true]));
    let ctx = home_ctx(ops.clone()).await;
    let cancel = ctx.cancellation_token.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(100)).await;
        cancel.store(true, Ordering::SeqCst);
    });

    let result = execute_home_mount_with(&ctx, fast_home_timing()).await;

    assert_eq!(result.status, NodeStatus::Cancelled);
    assert_eq!(ops.mount_find_home_calls.load(Ordering::SeqCst), 1);
    assert_eq!(ops.mount_abort_calls.load(Ordering::SeqCst), 1);
}

#[test]
fn a_stopped_mount_does_not_read_as_moving_whether_or_not_it_tracks() {
    // Tracking: RA fixed while the hour angle advances 10 minutes.
    assert!(!pointing_moved((5.0, 30.0), (5.0, 30.0), 600.0));
    // Not tracking: RA advances with sidereal time, hour angle fixed.
    let drift = 600.0 * 1.002_737_909_35 / 3600.0;
    assert!(!pointing_moved((5.0, 30.0), (5.0 + drift, 30.0), 600.0));
    // Same across the 24h wrap.
    assert!(!pointing_moved(
        (23.99, 30.0),
        ((23.99 + drift) % 24.0, 30.0),
        600.0
    ));
}

#[test]
fn a_dec_change_or_a_joint_ra_and_hour_angle_change_reads_as_moving() {
    assert!(pointing_moved((5.0, 30.0), (5.0, 30.5), 1.0));
    assert!(pointing_moved((5.0, 30.0), (6.0, 30.0), 1.0));
    assert!(pointing_moved((23.9, 30.0), (0.2, 30.0), 1.0));
}

#[test]
fn home_mount_node_type_round_trips_through_the_wire_tag() {
    let parsed: crate::NodeType =
        serde_json::from_str(r#"{"type":"HomeMount"}"#).expect("HomeMount must deserialize");
    assert!(matches!(parsed, crate::NodeType::HomeMount));
    assert_eq!(
        serde_json::to_string(&crate::NodeType::HomeMount).unwrap(),
        r#"{"type":"HomeMount"}"#
    );
    assert!(crate::node::registry::registry()
        .build(&crate::NodeType::HomeMount)
        .is_some());
}

/// A home is the run's own move, and the tracking stop it leaves behind is
/// the run's own: it must never read as a lost-tracking event.
#[tokio::test]
async fn homing_is_never_read_as_lost_tracking() {
    let ops = Arc::new(
        ScriptedDomeRotatorOps::new()
            .with_mount_parked(false)
            .with_mount_slewing_states(vec![true, true, false]),
    );
    let mut ctx = home_ctx(ops.clone()).await;
    let mut state = crate::triggers::TriggerState::new();
    state.set_mount_tracking_expected(true);
    state.mount_is_tracking = Some(true);
    let state = Arc::new(tokio::sync::RwLock::new(state));
    ctx.trigger_state = Some(state.clone());

    let result = execute_home_mount_with(&ctx, fast_home_timing()).await;
    assert_eq!(result.status, NodeStatus::Success);

    let mut state = state.write().await;
    assert!(!state.guiding.in_motion());
    assert!(!state.tracking.is_expected());
    // The mount reads tracking off after the home: no loss.
    assert!(!crate::executor::apply_mount_tracking_poll(
        &mut state, false
    ));
    assert!(!state.tracking.is_lost());
}
