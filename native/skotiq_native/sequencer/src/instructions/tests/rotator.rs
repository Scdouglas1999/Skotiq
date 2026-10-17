//! `rotator` tests — moved verbatim out of the former single `instructions::tests`
//! module (release-pass C3 mechanical split). Shared fixtures stay in the parent
//! `tests` module and reach here through `use super::*;`.

use super::*;

#[test]
fn rotator_angle_diff_handles_360_wrap() {
    // Shortest signed distance, wrapping at 360.
    assert!((rotator_angle_diff(10.0, 350.0) - 20.0).abs() < 1e-9);
    assert!((rotator_angle_diff(350.0, 10.0) - -20.0).abs() < 1e-9);
    assert!((rotator_angle_diff(0.0, 0.0)).abs() < 1e-9);
    // 179 vs 181 is a 2° gap (not 358°).
    assert!((rotator_angle_diff(179.0, 181.0) - -2.0).abs() < 1e-9);
    // Exactly opposite resolves to -180 (boundary).
    assert!((rotator_angle_diff(0.0, 180.0) - -180.0).abs() < 1e-9);
}

#[test]
fn normalize_rotator_angle_wraps_into_unit_circle() {
    assert!((normalize_rotator_angle(370.0) - 10.0).abs() < 1e-9);
    assert!((normalize_rotator_angle(-10.0) - 350.0).abs() < 1e-9);
    assert!((normalize_rotator_angle(0.0)).abs() < 1e-9);
    // Non-finite collapses to 0 rather than poisoning the move target.
    assert_eq!(normalize_rotator_angle(f64::NAN), 0.0);
    assert_eq!(normalize_rotator_angle(f64::INFINITY), 0.0);
}

// dome-rotator-verify: rotator move is MOVE-AND-VERIFY

/// The rotator move polls the achieved angle until it is within
/// tolerance of the target. The driver `rotator_move_to` only ISSUES
/// the move on ASCOM/Alpaca/INDI, so the instruction must poll
/// `rotator_get_angle` (the "is it there yet" verify) before reporting
/// success. Here the rotator is still off-target for the first two
/// polls and only arrives on the third — success must therefore have
/// required at least two verifying polls.
///
/// A fire-and-forget move returns success after the single move call,
/// polling `rotator_get_angle` zero times.
///
/// `start_paused = true` drives the verify loop's `tokio::time::sleep`
/// off the test's virtual clock (auto-advanced when all tasks are idle)
/// instead of racing real wall-time threads. The scripted angles advance
/// one entry per `rotator_get_angle` call, so the interleaving is fully
/// deterministic: poll 1 → 0°, poll 2 → 0°, poll 3 → 45° (arrived). This
/// removes the prior flake where the non-paused wall-clock sleep raced a
/// concurrent `start_paused` test under the multi-threaded runner.
#[tokio::test(start_paused = true)]
async fn test_rotator_move_verified_polls_until_arrival() {
    // Off-target (0°, 0°) then arrives at 45°.
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_rotator_angles(vec![0.0, 0.0, 45.0]));
    let ctx = ctx_with_ops(ops.clone()).await;
    let cfg = RotatorConfig {
        target_angle: 45.0,
        relative: false,
    };

    let result = execute_rotator_move(&cfg, &ctx, None).await;

    assert_eq!(
        result.status,
        NodeStatus::Success,
        "rotator should report success once it reaches the target: {:?}",
        result.message
    );
    assert_eq!(
        ops.rotator_move_to_calls.load(Ordering::SeqCst),
        1,
        "the move must be issued exactly once"
    );
    assert!(
        ops.rotator_get_angle_calls.load(Ordering::SeqCst) >= 2,
        "the instruction must POLL the achieved angle at least twice \
             before declaring success (move-and-verify), got {}",
        ops.rotator_get_angle_calls.load(Ordering::SeqCst)
    );
}

/// A rotator that issues the move but never reaches the target (motor
/// jam / stall) must FAIL CLOSED, not silently report success — a
/// jammed rotator otherwise leaves the camera at the wrong PA and the
/// next exposure smears field rotation across the frame.
///
/// `start_paused` lets tokio auto-advance the virtual clock past the
/// internal poll sleeps so the bounded timeout is reached without the
/// test waiting real wall-time.
#[tokio::test(start_paused = true)]
async fn test_rotator_move_fails_when_target_never_reached() {
    // Always reports 0° — never reaches the 45° target.
    let ops = Arc::new(ScriptedDomeRotatorOps::new().with_rotator_angles(vec![0.0]));
    let ctx = ctx_with_ops(ops.clone()).await;
    let cfg = RotatorConfig {
        target_angle: 45.0,
        relative: false,
    };

    let result = execute_rotator_move(&cfg, &ctx, None).await;

    assert_eq!(
        result.status,
        NodeStatus::Failure,
        "a rotator that never reaches the target must fail closed"
    );
    assert!(
        ops.rotator_get_angle_calls.load(Ordering::SeqCst) >= 2,
        "the timeout must be reached by repeated verification polls"
    );
}
