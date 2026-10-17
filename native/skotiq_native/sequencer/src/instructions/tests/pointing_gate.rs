//! `pointing_gate` tests — moved verbatim out of the former single `instructions::tests`
//! module (release-pass C3 mechanical split). Shared fixtures stay in the parent
//! `tests` module and reach here through `use super::*;`.

use super::*;

#[tokio::test]
async fn slew_to_unset_target_never_commands_the_mount() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let ctx = pointing_ctx(ops.clone(), "New Target", (0.0, 0.0)).await;
    let cfg = SlewConfig {
        use_target_coords: true,
        ..SlewConfig::default()
    };

    let result = execute_slew(&cfg, &ctx, None).await;

    assert_eq!(
        result.status,
        NodeStatus::Failure,
        "an unset target must not slew"
    );
    assert_eq!(
        recovery_code_of(&result).as_deref(),
        Some(UNSET_TARGET_RECOVERY_CODE),
        "rejection must be attributable to the unset target, got {:?}",
        result.message
    );
    assert_eq!(
        ops.mount_slew_calls.load(Ordering::SeqCst),
        0,
        "the mount must never be commanded to the RA 0h / Dec +0° placeholder"
    );
}

#[tokio::test]
async fn center_on_unset_target_never_commands_the_mount() {
    let ops = Arc::new(ScriptedDomeRotatorOps::new());
    let ctx = pointing_ctx(ops.clone(), "New Target", (0.0, 0.0)).await;
    let cfg = CenterConfig {
        use_target_coords: true,
        ..CenterConfig::default()
    };

    let result = execute_center(&cfg, &ctx, None).await;

    assert_eq!(
        result.status,
        NodeStatus::Failure,
        "an unset target must not center"
    );
    assert_eq!(
        recovery_code_of(&result).as_deref(),
        Some(UNSET_TARGET_RECOVERY_CODE),
        "rejection must be attributable to the unset target, got {:?}",
        result.message
    );
    assert_eq!(
        ops.mount_slew_calls.load(Ordering::SeqCst),
        0,
        "the mount must never be commanded to the RA 0h / Dec +0° placeholder"
    );
    assert_eq!(
        ops.camera_exposure_calls.load(Ordering::SeqCst),
        0,
        "the gate must fire before a plate-solve exposure is spent"
    );
}

#[tokio::test]
async fn slew_to_a_real_target_still_commands_the_mount() {
    // Guards the inversion: the gate must reject the placeholder and
    // nothing else, including a target one nudge away from it.
    let ops =
        Arc::new(ScriptedDomeRotatorOps::new().with_scripted_mount_coordinates(0.0001, 0.0001));
    let ctx = pointing_ctx(ops.clone(), "Deliberate Origin", (0.0001, 0.0001)).await;
    let cfg = SlewConfig {
        use_target_coords: true,
        ..SlewConfig::default()
    };

    let result = execute_slew(&cfg, &ctx, None).await;

    assert_ne!(
        recovery_code_of(&result).as_deref(),
        Some(UNSET_TARGET_RECOVERY_CODE),
        "a deliberately-set pointing must not read as the unset placeholder"
    );
    assert_eq!(
        ops.mount_slew_calls.load(Ordering::SeqCst),
        1,
        "a target with real coordinates must still slew"
    );
}
