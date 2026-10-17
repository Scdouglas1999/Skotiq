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
