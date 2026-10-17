//! The meridian-flip trigger evaluated at its own seam: `Trigger::check`
//! against a `TriggerState` whose hour angle is the target's.
//!
//! Written from the D1 sim-night failure of 2026-08-17, where a target 1.5h
//! east of the meridian was flipped four minutes into the run (see
//! `executor::tests::runtime_tests::the_published_hour_angle_belongs_to_the_target_not_the_mount`
//! for the input that made it fire). These pin the DECISION: whatever the
//! monitor publishes, an east target is never a flip, and the window opens
//! exactly where the operator configured it.

use crate::{
    MeridianFlipConfig, MeridianTriggerMethod, PierSide, RecoveryAction, Trigger, TriggerState,
    TriggerType,
};

const EVERY_PIER_SIDE: [Option<PierSide>; 4] = [
    None,
    Some(PierSide::Unknown),
    Some(PierSide::West),
    Some(PierSide::East),
];

/// A trigger armed exactly as `create_standard_triggers` arms the real one,
/// with the method and threshold under test.
fn flip_trigger(method: MeridianTriggerMethod, threshold: f64) -> Trigger {
    let config = MeridianFlipConfig {
        trigger_method: method,
        minutes_past_meridian: threshold,
        hour_angle_threshold: threshold,
        ..Default::default()
    };
    Trigger::new(
        "meridian_flip",
        "Meridian Flip",
        TriggerType::MeridianFlip {
            config: config.clone(),
        },
        RecoveryAction::MeridianFlip(config),
    )
}

/// A run in progress: a target is stamped (the trigger refuses to evaluate
/// without one) and the monitor has published the target's hour angle.
fn state_with_target_hour_angle(
    hour_angle_hours: f64,
    pier_side: Option<PierSide>,
) -> TriggerState {
    let mut state = TriggerState::new();
    state.set_target(62.23, 40.0);
    state.set_meridian_target("D1 Simulated Field".to_string());
    state.current_hour_angle = Some(hour_angle_hours);
    state.pier_side = pier_side;
    state
}

/// The regression itself: HA -1.50h, the harness target, must not flip — on
/// ANY pier side, including the `Unknown` the simulator reports and the `West`
/// a real ASCOM GEM reports while pointing east of the meridian. Both flip
/// methods that read an hour angle are covered, because they carried
/// independent copies of the same comparison.
#[tokio::test]
async fn an_east_target_never_fires_whatever_the_pier_side_says() {
    for (method, threshold) in [
        (MeridianTriggerMethod::MinutesPastMeridian, 5.0),
        (MeridianTriggerMethod::HourAngleThreshold, 5.0 / 60.0),
    ] {
        for pier in EVERY_PIER_SIDE {
            let mut trigger = flip_trigger(method, threshold);
            let state = state_with_target_hour_angle(-1.5, pier);
            assert!(
                !trigger.check(&state).await,
                "{method:?} fired on a target 1.5h EAST of the meridian with pier {pier:?}"
            );
        }
    }
}

/// The most permissive configuration the UI offers — flip the instant the
/// target transits — still refuses an east target. A zero threshold is where
/// an `abs()`-shaped window would be at its loudest.
#[tokio::test]
async fn a_zero_threshold_still_refuses_an_east_target() {
    for pier in EVERY_PIER_SIDE {
        let mut trigger = flip_trigger(MeridianTriggerMethod::MinutesPastMeridian, 0.0);
        let state = state_with_target_hour_angle(-0.001, pier);
        assert!(
            !trigger.check(&state).await,
            "a zero-minute window fired east of the meridian with pier {pier:?}"
        );
    }
}

/// Inside the window, west of the meridian: fires. HA +0.02h is 1.2 minutes
/// past transit against a 1-minute window.
#[tokio::test]
async fn a_target_inside_the_window_fires() {
    for pier in [None, Some(PierSide::Unknown), Some(PierSide::West)] {
        let mut trigger = flip_trigger(MeridianTriggerMethod::MinutesPastMeridian, 1.0);
        let state = state_with_target_hour_angle(0.02, pier);
        assert!(
            trigger.check(&state).await,
            "a target 1.2 min past the meridian must fire a 1-minute window (pier {pier:?})"
        );
    }
}

/// `pierEast` is the side a flip LANDS on. A mount already there does not
/// flip again, however far past the meridian the target is — this is the one
/// case where pier side legitimately overrides the hour angle.
#[tokio::test]
async fn a_mount_already_on_the_post_flip_side_does_not_flip_again() {
    let mut trigger = flip_trigger(MeridianTriggerMethod::MinutesPastMeridian, 1.0);
    let state = state_with_target_hour_angle(2.0, Some(PierSide::East));
    assert!(!trigger.check(&state).await);
}

/// Short of the window: the target is genuinely past the meridian, but not by
/// as much as the operator asked for. 4.9 minutes against a 5-minute window.
#[tokio::test]
async fn a_target_short_of_the_window_waits() {
    let mut trigger = flip_trigger(MeridianTriggerMethod::MinutesPastMeridian, 5.0);
    let state = state_with_target_hour_angle(4.9 / 60.0, Some(PierSide::West));
    assert!(!trigger.check(&state).await);
}

/// The boundary is inclusive: "5 minutes past the meridian" fires AT five
/// minutes.
#[tokio::test]
async fn the_configured_boundary_is_inclusive() {
    let mut trigger = flip_trigger(MeridianTriggerMethod::MinutesPastMeridian, 5.0);
    let state = state_with_target_hour_angle(5.0 / 60.0, Some(PierSide::West));
    assert!(trigger.check(&state).await);
}

/// No hour angle published yet (no target entered, or no observing site) means
/// the trigger cannot evaluate and must stay silent rather than assume.
#[tokio::test]
async fn an_unpublished_hour_angle_never_fires() {
    let mut trigger = flip_trigger(MeridianTriggerMethod::MinutesPastMeridian, 5.0);
    let mut state = state_with_target_hour_angle(2.0, Some(PierSide::West));
    state.current_hour_angle = None;
    assert!(!trigger.check(&state).await);
}
