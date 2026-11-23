//! Tests of the wait time instructions; the shared fixtures are in the parent module.

use super::*;

// Wait node with no condition

/// An unconfigured Wait node must fail rather than return Success in
/// microseconds: the canonical use is "wait until astronomical dark", so
/// skipping it starts the run in daylight.
#[tokio::test]
async fn wait_time_without_any_condition_fails() {
    let ctx = crate::node::context::ExecutionContext::new_for_test("test-node".to_string())
        .to_instruction_context("test-node")
        .await;

    let result = execute_wait_time(&WaitTimeConfig::default(), &ctx, None).await;

    assert_eq!(
        result.status,
        NodeStatus::Failure,
        "a Wait node with neither a time nor a twilight condition must not report Success"
    );
    let msg = result.message.unwrap_or_default();
    assert!(
        msg.contains("no wait condition"),
        "the failure must name the missing configuration, got: {msg}"
    );
}

/// A twilight wait at a site 40° N, 75° W on 2026-11-22, with the run's
/// clock at `now`: how long it waited and how it ended.
async fn wait_for_dark_at(now: chrono::DateTime<chrono::Utc>) -> (Duration, InstructionResult) {
    let mut ctx = crate::node::context::ExecutionContext::new_for_test("test-node".to_string())
        .to_instruction_context("test-node")
        .await;
    ctx.run.rig.latitude = Some(40.0);
    ctx.run.rig.longitude = Some(-75.0);
    ctx.run.clock = crate::scheduling::MockClock::from_datetime(now);
    let config = WaitTimeConfig {
        wait_for_twilight: Some(TwilightType::Astronomical),
        ..WaitTimeConfig::default()
    };
    let started = tokio::time::Instant::now();
    let result = execute_wait_time(&config, &ctx, None).await;
    (started.elapsed(), result)
}

fn astronomical_dusk() -> chrono::DateTime<chrono::Utc> {
    use chrono::TimeZone;
    let noon = chrono::Utc
        .with_ymd_and_hms(2026, 11, 22, 12, 0, 0)
        .unwrap();
    let dusk = crate::solar::time_of_sun_altitude_at(
        40.0,
        -75.0,
        -18.0,
        crate::solar::SunCrossing::Setting,
        &noon,
    );
    chrono::DateTime::from_timestamp(dusk, 0).unwrap()
}

/// Reached two hours after astronomical dusk, it is already dark: the wait
/// ends at once instead of waiting for the next evening.
#[tokio::test(start_paused = true)]
async fn a_twilight_wait_reached_after_dark_ends_at_once() {
    let (waited, result) = wait_for_dark_at(astronomical_dusk() + chrono::Duration::hours(2)).await;
    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);
    assert_eq!(waited, Duration::ZERO);
}

/// Reached in the afternoon, it waits for this evening's dusk.
#[tokio::test(start_paused = true)]
async fn a_twilight_wait_reached_in_daylight_waits_for_dusk() {
    let dusk = astronomical_dusk();
    let (waited, result) = wait_for_dark_at(dusk - chrono::Duration::hours(3)).await;
    assert_eq!(result.status, NodeStatus::Success, "{:?}", result.message);
    // The crossing is computed for the day the wait starts, a few seconds
    // from the one computed at noon.
    assert!(
        waited.abs_diff(Duration::from_secs(3 * 3600)) < Duration::from_secs(60),
        "{waited:?}"
    );
}
