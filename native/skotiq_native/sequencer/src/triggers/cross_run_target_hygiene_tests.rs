use super::*;
use crate::{PierSide, RecoveryAction, TriggerType};

#[test]
fn reset_for_new_run_drops_the_previous_runs_target() {
    let mut state = TriggerState::new();
    state.set_target(270.0, 60.0);
    state.set_meridian_target("B".to_string());
    state.current_altitude = Some(10.5);
    state.current_hour_angle = Some(11.18);
    state.next_meridian_flip_time = Some(1);
    state.tracking_limit_detected_at = Some(1);
    state.update_plate_solve(270.1, 60.1, 1.2);

    state.reset_for_new_run();

    assert_eq!(state.target_ra, None);
    assert_eq!(state.target_dec, None);
    assert_eq!(state.current_target_name, None);
    assert_eq!(state.current_altitude, None);
    assert_eq!(state.current_hour_angle, None);
    assert_eq!(state.next_meridian_flip_time, None);
    assert_eq!(state.tracking_limit_detected_at, None);
    assert_eq!(state.last_plate_solve_ra, None);
    assert_eq!(state.last_plate_solve_dec, None);
    assert_eq!(state.last_plate_solve_pixel_scale, None);
}

#[test]
fn a_resumed_run_keeps_the_target_restored_from_its_checkpoint() {
    let mut state = TriggerState::new();
    state.set_target(270.0, 60.0);
    state.set_meridian_target("B".to_string());
    state.restored_from_checkpoint = true;

    state.reset_for_new_run();

    assert_eq!(state.target_ra, Some(270.0));
    assert_eq!(state.target_dec, Some(60.0));
    assert_eq!(state.current_target_name, Some("B".to_string()));
    assert!(
        !state.restored_from_checkpoint,
        "the resume flag is one-shot: the run after the resume must clear the target"
    );

    state.reset_for_new_run();
    assert_eq!(state.target_ra, None);
}

#[tokio::test]
async fn altitude_limit_does_not_fire_for_a_run_with_no_target() {
    // Per-run target state is cleared between runs: a dark/flat sequence with
    // no TargetHeader that inherits the previous run's altitude skips its
    // whole tree milliseconds after start, reporting `completed` with zero
    // frames.
    let mut state = TriggerState::new();
    state.set_target(270.0, 60.0);
    state.current_altitude = Some(10.5);

    let mut previous_run = Trigger::new(
        "altitude_limit",
        "Altitude Limit",
        TriggerType::AltitudeLimit { min_altitude: 30.0 },
        RecoveryAction::NextTarget,
    );
    assert!(
        previous_run.check(&state).await,
        "a genuinely low target must still fire the altitude limit"
    );

    state.reset_for_new_run();

    let mut next_run = Trigger::new(
        "altitude_limit",
        "Altitude Limit",
        TriggerType::AltitudeLimit { min_altitude: 30.0 },
        RecoveryAction::NextTarget,
    );
    assert!(
        !next_run.check(&state).await,
        "a run with no target has no altitude and must not fire the altitude limit"
    );
}

#[tokio::test]
async fn meridian_flip_does_not_fire_for_a_run_with_no_target() {
    // Hour angle comes from the mount, so it keeps arriving even on a
    // target-less run. Without a target the flip drove a real daylight
    // slew to the previous run's coordinates.
    let config = crate::MeridianFlipConfig {
        trigger_method: crate::MeridianTriggerMethod::MinutesPastMeridian,
        minutes_past_meridian: 5.0,
        ..Default::default()
    };
    let mut state = TriggerState::new();
    state.set_target(270.0, 60.0);
    state.update_hour_angle(11.18);
    state.pier_side = Some(PierSide::West);

    let mut previous_run = Trigger::new(
        "meridian_flip",
        "Meridian Flip",
        TriggerType::MeridianFlip {
            config: config.clone(),
        },
        RecoveryAction::MeridianFlip(config.clone()),
    );
    assert!(
        previous_run.check(&state).await,
        "a tracked target past the meridian must still fire the flip"
    );

    state.reset_for_new_run();
    // The mount keeps reporting; the monitor loop refreshes hour angle and
    // pier side every tick regardless of whether a target is set.
    state.update_hour_angle(11.18);
    state.pier_side = Some(PierSide::West);

    let mut next_run = Trigger::new(
        "meridian_flip",
        "Meridian Flip",
        TriggerType::MeridianFlip {
            config: config.clone(),
        },
        RecoveryAction::MeridianFlip(config),
    );
    assert!(
        !next_run.check(&state).await,
        "a run with no target must not flip"
    );
}

/// The mount has to be FOLLOWING the target, not merely named alongside it.
///
/// `current_hour_angle` is the target's, which fixed the flip that armed off a
/// parked mount's home RA. Underneath it sat this: a parked mount whose named
/// target genuinely is past the meridian still armed the flip. That is a
/// calibration block — a TargetHeader with darks under it, mount parked — and
/// the exhausted flip then coerces a run that captured every frame it was asked
/// for into FAILED.
///
/// The Dart countdown banner already refuses to arm on `mount.isParked` or
/// `!mount.isTracking` (`meridian_countdown_provider`), which is how the
/// Imaging screen could say "Meridian flip imminent — handled automatically"
/// while the Sequencer said "attempt 2/4 failed": only one surface asked.
fn parked_calibration_run_state() -> TriggerState {
    let mut state = TriggerState::new();
    // A TargetHeader stamps the target even for a calibration block under it.
    state.set_target(270.0, 60.0);
    // The target really is past the meridian — well beyond the 5-minute gate.
    state.update_hour_angle(1.5);
    state.pier_side = Some(PierSide::West);
    state
}

fn meridian_trigger(config: crate::MeridianFlipConfig) -> Trigger {
    Trigger::new(
        "meridian_flip",
        "Meridian Flip",
        TriggerType::MeridianFlip {
            config: config.clone(),
        },
        RecoveryAction::MeridianFlip(config),
    )
}

#[tokio::test]
async fn meridian_flip_does_not_arm_on_a_parked_mount() {
    let config = crate::MeridianFlipConfig {
        trigger_method: crate::MeridianTriggerMethod::MinutesPastMeridian,
        minutes_past_meridian: 5.0,
        ..Default::default()
    };

    // Control: identical state, mount tracking the target.
    let mut tracking = parked_calibration_run_state();
    tracking.mount_parked = Some(false);
    tracking.mount_is_tracking = Some(true);
    assert!(
        meridian_trigger(config.clone()).check(&tracking).await,
        "a tracked target past the meridian must still fire the flip"
    );

    let mut parked = parked_calibration_run_state();
    parked.mount_parked = Some(true);
    assert!(
        !meridian_trigger(config).check(&parked).await,
        "a parked mount is not following the target; the flip must not arm"
    );
}

#[tokio::test]
async fn meridian_flip_does_not_arm_when_the_mount_is_not_tracking() {
    let config = crate::MeridianFlipConfig {
        trigger_method: crate::MeridianTriggerMethod::MinutesPastMeridian,
        minutes_past_meridian: 5.0,
        ..Default::default()
    };

    let mut idle = parked_calibration_run_state();
    idle.mount_parked = Some(false);
    idle.mount_is_tracking = Some(false);
    assert!(
        !meridian_trigger(config).check(&idle).await,
        "a mount that is not tracking is not following the target; no flip"
    );
}

#[tokio::test]
async fn meridian_flip_hour_angle_threshold_honours_the_same_mount_guards() {
    // The guard has to cover every hour-angle-derived method, or switching the
    // trigger method reopens the hole.
    let config = crate::MeridianFlipConfig {
        trigger_method: crate::MeridianTriggerMethod::HourAngleThreshold,
        hour_angle_threshold: 0.5,
        ..Default::default()
    };

    let mut tracking = parked_calibration_run_state();
    tracking.mount_parked = Some(false);
    tracking.mount_is_tracking = Some(true);
    assert!(
        meridian_trigger(config.clone()).check(&tracking).await,
        "HourAngleThreshold must still fire for a tracked target"
    );

    let mut parked = parked_calibration_run_state();
    parked.mount_parked = Some(true);
    assert!(
        !meridian_trigger(config).check(&parked).await,
        "HourAngleThreshold must not arm on a parked mount either"
    );
}

#[tokio::test]
async fn a_mount_that_never_reports_park_or_tracking_is_unaffected() {
    // Both fields are Option. `None` means the mount never told us, and such a
    // mount must behave exactly as before rather than losing flips entirely.
    let config = crate::MeridianFlipConfig {
        trigger_method: crate::MeridianTriggerMethod::MinutesPastMeridian,
        minutes_past_meridian: 5.0,
        ..Default::default()
    };

    let silent = parked_calibration_run_state();
    assert_eq!(silent.mount_parked, None);
    assert_eq!(silent.mount_is_tracking, None);
    assert!(
        meridian_trigger(config).check(&silent).await,
        "a mount with no park/tracking readings must still be able to flip"
    );
}

#[tokio::test]
async fn on_tracking_limit_hit_is_exempt_from_the_not_tracking_guard() {
    // Tracking having stopped is that method's entire premise; the new guard
    // must not disable it.
    let config = crate::MeridianFlipConfig {
        trigger_method: crate::MeridianTriggerMethod::OnTrackingLimitHit,
        tracking_limit_wait_minutes: 0.0,
        ..Default::default()
    };

    let mut state = parked_calibration_run_state();
    state.mount_tracking_expected = true;
    state.mount_tracking_lost = true;
    state.mount_is_tracking = Some(false);
    state.mount_status_query_failed = false;
    state.mount_slewing = Some(false);
    state.mount_parked = Some(false);
    state.tracking_limit_detected_at = Some(chrono::Utc::now().timestamp() - 600);

    assert!(
        meridian_trigger(config).check(&state).await,
        "OnTrackingLimitHit fires precisely when tracking has stopped"
    );
}

// ---------------------------------------------------------------------------
// AltitudeLimit: the same two questions the meridian flip now asks.
//
// Live, on a solverless machine: a three-frame DARKS block under a parked
// simulated mount logged
//   00:14:59.824  Starting sequence execution
//   00:14:59.832  WARN Trigger fired: Altitude Limit (altitude_limit) - action: NextTarget
// eight milliseconds in, and the Session Report of the completed run said
// "Trigger fires 1". The altitude it judged was correct — it is the TARGET's,
// computed by `executor::monitoring::target_sky_state`, and M4 really was at
// 16.6° against the default 30° floor. What was wrong is that it acted at all:
// nothing about a dark, bias or flat depends on where the tube is pointing,
// and the mount was parked.
// ---------------------------------------------------------------------------

fn altitude_trigger(min_altitude: f64) -> Trigger {
    Trigger::new(
        "altitude_limit",
        "Altitude Limit",
        TriggerType::AltitudeLimit { min_altitude },
        RecoveryAction::NextTarget,
    )
}

/// The observed run: target below the floor, mount parked, darks underneath.
fn low_target_state() -> TriggerState {
    let mut state = parked_calibration_run_state();
    // M4's altitude at the moment of the observed run, against the 30° default.
    state.current_altitude = Some(16.6);
    state
}

#[tokio::test]
async fn altitude_limit_does_not_fire_on_a_parked_mount() {
    // Control: same low target, mount actually tracking it — the trigger's
    // whole reason to exist, and it must still fire.
    let mut tracking = low_target_state();
    tracking.mount_parked = Some(false);
    tracking.mount_is_tracking = Some(true);
    assert!(
        altitude_trigger(30.0).check(&tracking).await,
        "a tracked target below the floor is exactly what AltitudeLimit is for"
    );

    let mut parked = low_target_state();
    parked.mount_parked = Some(true);
    assert!(
        !altitude_trigger(30.0).check(&parked).await,
        "a parked mount is not following the target; skipping to the next one \
         answers a question nobody asked"
    );
}

#[tokio::test]
async fn altitude_limit_does_not_fire_when_the_mount_is_not_tracking() {
    let mut idle = low_target_state();
    idle.mount_parked = Some(false);
    idle.mount_is_tracking = Some(false);
    assert!(
        !altitude_trigger(30.0).check(&idle).await,
        "a mount that has stopped tracking is not following the target"
    );
}

#[tokio::test]
async fn a_mount_that_never_reports_park_or_tracking_keeps_altitude_protection() {
    let silent = low_target_state();
    assert_eq!(silent.mount_parked, None);
    assert_eq!(silent.mount_is_tracking, None);
    assert!(
        altitude_trigger(30.0).check(&silent).await,
        "None is 'the mount never said', not 'the mount is parked' — a driver \
         that publishes neither must not silently lose altitude protection"
    );
}

#[tokio::test]
async fn altitude_limit_still_judges_the_target_not_the_mount() {
    // The mount's own pointing never reaches this trigger: `current_altitude`
    // is the target's. A tracking mount whose target is comfortably high must
    // not fire however low the tube itself happens to be sitting.
    let mut high_target = parked_calibration_run_state();
    high_target.mount_parked = Some(false);
    high_target.mount_is_tracking = Some(true);
    high_target.current_altitude = Some(64.0);
    assert!(
        !altitude_trigger(30.0).check(&high_target).await,
        "a target above the floor must not fire"
    );

    // And with no target-derived altitude at all (no site, or no target yet)
    // there is nothing to judge, so nothing fires.
    let mut unknown = parked_calibration_run_state();
    unknown.mount_parked = Some(false);
    unknown.mount_is_tracking = Some(true);
    unknown.current_altitude = None;
    assert!(
        !altitude_trigger(30.0).check(&unknown).await,
        "an unknown altitude is not a low altitude"
    );
}
