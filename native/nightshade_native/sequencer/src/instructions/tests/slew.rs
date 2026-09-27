//! `slew` tests — moved verbatim out of the former single `instructions::tests`
//! module (release-pass C3 mechanical split). Shared fixtures stay in the parent
//! `tests` module and reach here through `use super::*;`.

use super::*;

#[test]
fn test_normalize_ra_diff_hours_no_wrap() {
    // Simple cases with no wraparound
    assert!((normalize_ra_diff_hours(1.0) - 1.0).abs() < 0.0001);
    assert!((normalize_ra_diff_hours(-1.0) - (-1.0)).abs() < 0.0001);
    assert!((normalize_ra_diff_hours(11.0) - 11.0).abs() < 0.0001);
    assert!((normalize_ra_diff_hours(-11.0) - (-11.0)).abs() < 0.0001);
}

#[test]
fn test_normalize_ra_diff_hours_wraparound() {
    // Wraparound cases: 23h to 1h should be 2h diff, not 22h
    assert!((normalize_ra_diff_hours(22.0) - (-2.0)).abs() < 0.0001);
    assert!((normalize_ra_diff_hours(-22.0) - 2.0).abs() < 0.0001);

    // 13 hours should wrap to -11 hours (shorter path)
    assert!((normalize_ra_diff_hours(13.0) - (-11.0)).abs() < 0.0001);
    assert!((normalize_ra_diff_hours(-13.0) - 11.0).abs() < 0.0001);

    // Edge case: exactly 12 hours
    assert!((normalize_ra_diff_hours(12.0).abs() - 12.0).abs() < 0.0001);
}

#[test]
fn test_validate_slew_position_success() {
    // Exact match
    assert!(validate_slew_position(12.0, 45.0, 12.0, 45.0, 1.0 / 60.0).is_ok());

    // Within tolerance (less than 1 arcminute = 1/60 degree)
    let small_diff = 0.5 / 60.0; // 0.5 arcminute
    let ra_diff_hours = small_diff / 15.0; // Convert degrees to hours
    assert!(validate_slew_position(
        12.0,
        45.0,
        12.0 + ra_diff_hours,
        45.0 + small_diff,
        1.0 / 60.0
    )
    .is_ok());
}

#[test]
fn test_validate_slew_position_ra_failure() {
    // RA exceeds tolerance (2 arcminutes when tolerance is 1)
    let large_diff_hours = (2.0 / 60.0) / 15.0; // 2 arcminutes in hours
    let result = validate_slew_position(12.0, 45.0, 12.0 + large_diff_hours, 45.0, 1.0 / 60.0);
    assert!(result.is_err());
    assert!(result.unwrap_err().contains("did not reach target"));
}

#[test]
fn test_validate_slew_position_dec_failure() {
    // Dec exceeds tolerance
    let large_diff_deg = 2.0 / 60.0; // 2 arcminutes
    let result = validate_slew_position(12.0, 45.0, 12.0, 45.0 + large_diff_deg, 1.0 / 60.0);
    assert!(result.is_err());
    assert!(result.unwrap_err().contains("did not reach target"));
}

#[test]
fn test_validate_slew_position_ra_wraparound() {
    // Test RA wraparound: target at 0.1h, actual at 23.9h should be 0.2h diff = 3 degrees
    // This is well within tolerance (we'll use a generous tolerance for this test)
    let tolerance = 5.0; // 5 degrees
    assert!(validate_slew_position(0.1, 45.0, 23.9, 45.0, tolerance).is_ok());

    // With 1 arcminute tolerance, 0.2h = 3 degrees should fail
    let result = validate_slew_position(0.1, 45.0, 23.9, 45.0, 1.0 / 60.0);
    assert!(result.is_err());
}

/// Regression: a slew that lands exactly on target must not be reported as a
/// miss because the mount reads back in a different epoch than the target is
/// held in.
///
/// The owner's OnStep mount, 2026-09-14: the sequence asked for NGC7380 at
/// J2000 RA 22.7892h / Dec 58.1324°, the device layer precessed that to
/// JNOW 22.8070h / 58.2738° on the way out, the mount arrived at 22.8069h /
/// 58.2739° — within 0.4" — and the old validation compared the JNOW read-back
/// against the J2000 target and failed by RA 16.00' / Dec 8.49'. Every sequence
/// containing a target node died on its first slew. It could not show up in a
/// simulator run because the simulator is exempt from the conversion, so both
/// sides of that comparison were J2000 there.
mod readback_frame {
    use crate::instructions::slew::{validate_slew_position, SLEW_POSITION_TOLERANCE_DEG};

    /// The measured numbers from that night.
    const TARGET_J2000: (f64, f64) = (22.7892, 58.1324);
    const TARGET_JNOW: (f64, f64) = (22.8070, 58.2738);
    const MOUNT_REPORTED: (f64, f64) = (22.8069, 58.2739);

    #[test]
    fn comparing_a_jnow_readback_against_a_j2000_target_is_what_broke() {
        let wrong = validate_slew_position(
            TARGET_J2000.0,
            TARGET_J2000.1,
            MOUNT_REPORTED.0,
            MOUNT_REPORTED.1,
            SLEW_POSITION_TOLERANCE_DEG,
        );
        assert!(
            wrong.is_err(),
            "this is the defect being regressed against: the frames differ by ~22', so the \
             mismatched comparison must fail — if this ever passes, the epoch policy changed \
             and the fix in execute_slew needs revisiting"
        );
    }

    #[test]
    fn validating_in_the_mounts_own_frame_accepts_the_same_slew() {
        validate_slew_position(
            TARGET_JNOW.0,
            TARGET_JNOW.1,
            MOUNT_REPORTED.0,
            MOUNT_REPORTED.1,
            SLEW_POSITION_TOLERANCE_DEG,
        )
        .expect("a slew landing within 0.4\" of the commanded position must validate");
    }

    /// The fix must not blunt the check: a mount that really did stop short
    /// still fails, even when both sides are in the same frame.
    #[test]
    fn a_genuine_miss_still_fails_in_the_correct_frame() {
        let miss = validate_slew_position(
            TARGET_JNOW.0,
            TARGET_JNOW.1,
            TARGET_JNOW.0 + 0.2, // 3° of RA short
            TARGET_JNOW.1 + 1.0,
            SLEW_POSITION_TOLERANCE_DEG,
        );
        assert!(miss.is_err(), "a 3-degree miss must still be reported");
    }
}

/// `execute_slew` end to end with a mount whose read-back frame differs from
/// the target's. The `readback_frame` tests above pin the comparison; these
/// pin that the instruction actually makes it in the mount's frame. Validating
/// against the raw target instead (the 2026-09-14 defect) left every test in
/// the crate green, because every test double reads back in J2000.
mod slew_arrival {
    use super::*;

    /// The 2026-09-14 numbers: the J2000 target, where the device layer said
    /// that target is in the mount's frame, and where the mount reported it
    /// had arrived.
    const TARGET_J2000: (f64, f64) = (22.7892, 58.1324);
    const TARGET_JNOW: (f64, f64) = (22.8070, 58.2738);
    const MOUNT_REPORTED: (f64, f64) = (22.8069, 58.2739);

    async fn slew_with(
        ops: ScriptedDomeRotatorOps,
    ) -> (InstructionResult, Arc<ScriptedDomeRotatorOps>) {
        let ops = Arc::new(ops);
        let ctx = pointing_ctx(ops.clone(), "NGC 7380", TARGET_J2000).await;
        let cfg = SlewConfig {
            use_target_coords: true,
            ..SlewConfig::default()
        };
        (execute_slew(&cfg, &ctx, None).await, ops)
    }

    #[tokio::test]
    async fn a_slew_that_landed_is_verified_in_the_mounts_own_frame() {
        let (result, ops) = slew_with(
            ScriptedDomeRotatorOps::new()
                .with_scripted_mount_coordinates(MOUNT_REPORTED.0, MOUNT_REPORTED.1)
                .with_scripted_readback_frame(Ok(TARGET_JNOW)),
        )
        .await;

        assert_eq!(
            result.status,
            NodeStatus::Success,
            "a mount within 0.4\" of the target must not fail the run: {:?}",
            result.message
        );
        assert!(
            result
                .message
                .as_deref()
                .unwrap_or("")
                .contains("(verified)"),
            "{:?}",
            result.message
        );
        assert_eq!(ops.mount_slew_calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn a_mount_that_stopped_short_fails_with_a_position_mismatch() {
        let (result, _) = slew_with(
            ScriptedDomeRotatorOps::new()
                .with_scripted_mount_coordinates(TARGET_JNOW.0 + 0.2, TARGET_JNOW.1)
                .with_scripted_readback_frame(Ok(TARGET_JNOW)),
        )
        .await;

        assert_eq!(result.status, NodeStatus::Failure);
        assert_eq!(
            recovery_code_of(&result).as_deref(),
            Some("SLEW_POSITION_MISMATCH")
        );
    }

    #[tokio::test]
    async fn an_unknown_frame_reports_the_slew_unverified_rather_than_failed() {
        let (result, _) = slew_with(
            ScriptedDomeRotatorOps::new()
                .with_scripted_mount_coordinates(MOUNT_REPORTED.0, MOUNT_REPORTED.1)
                .with_scripted_readback_frame(Err("driver type unknown".to_string())),
        )
        .await;

        assert_eq!(result.status, NodeStatus::Success);
        let message = result.message.unwrap_or_default();
        assert!(message.contains("not verified"), "{message}");
        assert!(!message.contains("(verified)"), "{message}");
    }

    #[tokio::test]
    async fn a_slew_to_custom_coordinates_goes_where_it_was_told() {
        // Park positions, flat-panel pointing and alignment moves use custom
        // coordinates; the daylight test only proves they are not gated.
        let ops =
            Arc::new(ScriptedDomeRotatorOps::new().with_scripted_mount_coordinates(3.25, 12.5));
        let ctx = pointing_ctx(ops.clone(), "NGC 7380", TARGET_J2000).await;
        let cfg = SlewConfig {
            use_target_coords: false,
            custom_ra: Some(3.25),
            custom_dec: Some(12.5),
        };

        let result = execute_slew(&cfg, &ctx, None).await;

        assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);
        assert_eq!(ops.mount_slew_calls.load(Ordering::SeqCst), 1);
    }
}
