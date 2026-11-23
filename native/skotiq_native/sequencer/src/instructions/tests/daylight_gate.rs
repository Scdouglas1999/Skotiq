//! Tests of the daylight gate instructions; the shared fixtures are in the parent module.

use super::*;

// Pure helper: daylight_gate_block_reason

/// Local solar noon (`hours_after_noon` 0) or midnight (12) at
/// TEST_LAT/TEST_LON on the June solstice: the Sun near +73° or near -26°.
fn site_time(hours_after_noon: f64) -> chrono::DateTime<chrono::Utc> {
    let noon_utc = 12.0 - TEST_LON / 15.0;
    let base = chrono::DateTime::parse_from_rfc3339("2026-06-21T00:00:00Z")
        .unwrap()
        .with_timezone(&chrono::Utc);
    let hours = (noon_utc + hours_after_noon).rem_euclid(24.0);
    base + chrono::Duration::seconds((hours * 3600.0) as i64)
}

fn gate_at(max_sun_alt: f64, now: chrono::DateTime<chrono::Utc>) -> Option<String> {
    daylight_gate_block_reason(Some(TEST_LAT), Some(TEST_LON), max_sun_alt, "test", now)
}

#[test]
fn daylight_gate_blocks_when_sun_above_max() {
    let noon = site_time(0.0);
    let sun_alt = crate::node::context::current_sun_altitude_degrees(TEST_LAT, TEST_LON, noon);
    assert!(sun_alt > 60.0, "noon Sun {sun_alt:.1}°");
    assert!(gate_at(DEFAULT_MAX_SUN_ALTITUDE_DEGREES, noon).is_some());
    assert!(
        gate_at(sun_alt - 0.5, noon).is_some(),
        "Sun {sun_alt:.1}° above the maximum must block"
    );
}

#[test]
fn daylight_gate_allows_when_sun_below_max() {
    let midnight = site_time(12.0);
    let sun_alt = crate::node::context::current_sun_altitude_degrees(TEST_LAT, TEST_LON, midnight);
    assert!(sun_alt < -18.0, "midnight Sun {sun_alt:.1}°");
    assert!(gate_at(DEFAULT_MAX_SUN_ALTITUDE_DEGREES, midnight).is_none());
    let noon = site_time(0.0);
    let noon_alt = crate::node::context::current_sun_altitude_degrees(TEST_LAT, TEST_LON, noon);
    assert!(
        gate_at(noon_alt + 0.5, noon).is_none(),
        "Sun {noon_alt:.1}° below the maximum must not block"
    );
}

#[test]
fn daylight_gate_abstains_without_location() {
    // No observer location => cannot compute Sun altitude => abstain
    // (never fabricate a block that would wedge a location-less rig). Even
    // with an absurdly low threshold the gate must NOT block here.
    assert!(
        daylight_gate_block_reason(None, Some(TEST_LON), -90.0, "test", chrono::Utc::now())
            .is_none()
    );
    assert!(
        daylight_gate_block_reason(Some(TEST_LAT), None, -90.0, "test", chrono::Utc::now())
            .is_none()
    );
    assert!(daylight_gate_block_reason(None, None, -90.0, "test", chrono::Utc::now()).is_none());
}

/// An operator who skips the optional site step must not be judged against
/// Null Island. The persisted site arrives as `Some(0, 0)`; computing a real
/// Greenwich Sun altitude from it refuses every light frame of the night with
/// a message blaming the Sun rather than the missing setting. (0, 0) must read
/// as "no site".
#[test]
fn daylight_gate_treats_null_island_as_no_location() {
    assert!(
        daylight_gate_block_reason(Some(0.0), Some(0.0), -90.0, "test", chrono::Utc::now())
            .is_none(),
        "an unset site must abstain, not fabricate a Sun altitude for 0N 0E"
    );
}

#[test]
fn daylight_gate_falls_back_to_default_on_non_finite_max() {
    // A NaN threshold must not silently disable the gate: it falls back to
    // DEFAULT_MAX_SUN_ALTITUDE_DEGREES, which blocks at noon and allows at
    // midnight.
    for max in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        assert!(gate_at(max, site_time(0.0)).is_some(), "{max} at noon");
        assert!(gate_at(max, site_time(12.0)).is_none(), "{max} at midnight");
    }
}

#[test]
fn only_a_light_waits_for_darkness() {
    use crate::FrameType;
    for frame_type in [
        FrameType::Bias,
        FrameType::Dark,
        FrameType::Flat,
        FrameType::DarkFlat,
        FrameType::Snapshot,
    ] {
        assert!(
            !frame_type.is_science(),
            "{frame_type:?} must remain legal in daylight"
        );
    }
    assert!(FrameType::Light.is_science());
}

#[tokio::test]
async fn slew_to_target_rejected_when_sun_up() {
    // A limit the Sun never reaches: a slew waits for dark only when dark is
    // coming within MAX_DARKNESS_WAIT, so this one is refused at once.
    let ctx = slew_ctx(-95.0).await;
    let cfg = SlewConfig {
        use_target_coords: true,
        ..SlewConfig::default()
    };
    let result = execute_slew(&cfg, &ctx, None).await;
    assert!(
        is_daylight_block(&result),
        "slew to science target must be daylight-blocked when Sun is up; got {:?}",
        result.message
    );
}

#[tokio::test]
async fn slew_to_target_allowed_when_sun_down() {
    let sun_alt = live_sun_alt();
    let ctx = slew_ctx(sun_alt + 5.0).await; // Sun below max → allow
    let cfg = SlewConfig {
        use_target_coords: true,
        ..SlewConfig::default()
    };
    let result = execute_slew(&cfg, &ctx, None).await;
    // It may still fail downstream slew-position validation against the
    // NullDeviceOps fixed coordinates, but it must NOT be a daylight block.
    assert!(
        !is_daylight_block(&result),
        "slew must clear the daylight gate at night; got daylight block: {:?}",
        result.message
    );
}

#[tokio::test]
async fn slew_to_custom_coords_not_gated_in_daylight() {
    // A park/flat-panel/alignment slew to CUSTOM coordinates is not an
    // on-sky science pointing and must never be daylight-gated, even with
    // a threshold far below the live Sun altitude.
    let sun_alt = live_sun_alt();
    let ctx = slew_ctx(sun_alt - 30.0).await;
    let cfg = SlewConfig {
        use_target_coords: false,
        custom_ra: Some(12.0),
        custom_dec: Some(45.0),
    };
    let result = execute_slew(&cfg, &ctx, None).await;
    assert!(
        !is_daylight_block(&result),
        "custom-coordinate slew must never be daylight-gated; got {:?}",
        result.message
    );
}

#[tokio::test]
async fn light_exposure_on_target_rejected_when_sun_up() {
    // Mount NOT parked + science target set + Sun up → on-sky light → block.
    // The limit is one the Sun never reaches, so the frame is refused rather
    // than waiting for dark.
    let ctx = expose_ctx(Arc::new(NullDeviceOps), Some((5.5, 22.0)), -95.0).await;
    let result = expose_burst(&one_light(), &ctx, |_, _, _| {}).await;
    assert!(
        is_daylight_block(&result),
        "on-sky LIGHT exposure must be daylight-blocked when Sun is up; got {:?}",
        result.message
    );
}

#[tokio::test]
async fn target_header_calibration_frames_are_exempt_from_daylight_gate() {
    let sun_alt = live_sun_alt();
    let ctx = expose_ctx(Arc::new(NullDeviceOps), Some((5.5, 22.0)), sun_alt - 30.0).await;

    for frame_type in ["Bias", "Dark", "Flat", "DarkFlat"] {
        let config = ExposureConfig {
            count: 0,
            frame_type: crate::FrameType::from_name(frame_type).expect("a frame type"),
            ..ExposureConfig::default()
        };
        let result = expose_burst(&config, &ctx, |_, _, _| {}).await;
        assert!(
            !is_daylight_block(&result),
            "{frame_type} below a TargetHeader must remain legal in daylight: {:?}",
            result.message
        );
    }
}

#[tokio::test]
async fn calibration_exposure_without_target_not_gated_in_daylight() {
    let sun_alt = live_sun_alt();
    // No target coordinates AND a calibration frame type → daytime
    // flats/darks/bias stay legal even with a daytime-blocking threshold.
    let ops: Arc<dyn DeviceOps> = Arc::new(NullDeviceOps);
    let ctx = expose_ctx(ops, None, sun_alt - 30.0).await;
    for frame_type in ["Bias", "Dark", "Flat", "DarkFlat"] {
        let config = ExposureConfig {
            count: 0,
            frame_type: crate::FrameType::from_name(frame_type).expect("a frame type"),
            ..ExposureConfig::default()
        };
        let result = expose_burst(&config, &ctx, |_, _, _| {}).await;
        assert!(
            !is_daylight_block(&result),
            "a no-target {frame_type} exposure must never be daylight-gated; got {:?}",
            result.message
        );
    }
}

/// The gate must key off the FRAME TYPE, not off whether a TargetHeader
/// happens to exist or `ctx.target_ra`/`target_dec` are set: a bare "Take
/// Exposures" LIGHT node dropped at the top level of a sequence is exactly as
/// much an on-sky capture as the same node nested under a target.
#[tokio::test]
async fn untargeted_light_exposure_rejected_when_sun_up() {
    // Mount NOT parked + no target group + Sun up → still an on-sky light.
    let ctx = expose_ctx(Arc::new(NullDeviceOps), None, -95.0).await;
    let result = expose_burst(&one_light(), &ctx, |_, _, _| {}).await;
    assert!(
        is_daylight_block(&result),
        "a targetless LIGHT exposure must be daylight-blocked when Sun is up; got {:?}",
        result.message
    );
}

#[tokio::test]
async fn parked_rig_target_exposure_not_gated_in_daylight() {
    let sun_alt = live_sun_alt();
    // Target set BUT mount parked (e.g. a dark library built inside a
    // target subtree while parked) → not on-sky → allow.
    let ops: Arc<dyn DeviceOps> = Arc::new(ScriptedDomeRotatorOps::new().with_mount_parked(true));
    let ctx = expose_ctx(ops, Some((5.5, 22.0)), sun_alt - 30.0).await;
    let result = expose_burst(&one_light(), &ctx, |_, _, _| {}).await;
    assert!(
        !is_daylight_block(&result),
        "a parked-rig exposure must never be daylight-gated; got {:?}",
        result.message
    );
}

#[tokio::test]
async fn light_exposure_on_target_allowed_when_sun_down() {
    let sun_alt = live_sun_alt();
    // Mount not parked + target set + Sun below max → allowed past the gate.
    let ctx = expose_ctx(Arc::new(NullDeviceOps), Some((5.5, 22.0)), sun_alt + 5.0).await;
    let result = expose_burst(&one_light(), &ctx, |_, _, _| {}).await;
    assert!(
        !is_daylight_block(&result),
        "on-sky LIGHT exposure must clear the daylight gate at night; got {:?}",
        result.message
    );
}

// minutes_until_dark: the slew waits for an evening, never for a morning.

fn utc(text: &str) -> chrono::DateTime<chrono::Utc> {
    chrono::DateTime::parse_from_rfc3339(text)
        .unwrap()
        .with_timezone(&chrono::Utc)
}

/// The owner's site, where a run started at 17:52 EST on 2026-11-03 was
/// refused with the Sun at -11.1°, a few minutes before the -12° limit.
const RIG_LAT: f64 = 39.9719;
const RIG_LON: f64 = -75.3576;

#[test]
fn evening_twilight_is_minutes_from_dark() {
    let minutes = minutes_until_dark(
        RIG_LAT,
        RIG_LON,
        -12.0,
        utc("2026-11-03T22:52:19Z"),
        MAX_DARKNESS_WAIT,
    )
    .expect("dark is coming within minutes");
    assert!((1..=10).contains(&minutes), "{minutes} min");
}

#[test]
fn a_dark_sky_is_zero_minutes_from_dark() {
    let minutes = minutes_until_dark(
        RIG_LAT,
        RIG_LON,
        -12.0,
        utc("2026-11-04T03:00:00Z"),
        MAX_DARKNESS_WAIT,
    );
    assert_eq!(minutes, Some(0));
}

#[test]
fn morning_twilight_never_waits_for_dark() {
    // 05:45 EST: the Sun is rising through twilight and the next dark is
    // that evening, far beyond the wait.
    let minutes = minutes_until_dark(
        RIG_LAT,
        RIG_LON,
        -12.0,
        utc("2026-11-04T10:45:00Z"),
        MAX_DARKNESS_WAIT,
    );
    assert_eq!(minutes, None);
}

#[test]
fn an_afternoon_start_is_beyond_the_wait() {
    // 14:00 EST: dark is about four and a half hours away.
    let minutes = minutes_until_dark(
        RIG_LAT,
        RIG_LON,
        -12.0,
        utc("2026-11-03T19:00:00Z"),
        MAX_DARKNESS_WAIT,
    );
    assert_eq!(minutes, None);
}

/// The gate reads the Sun at the run's clock, not the wall clock: the same
/// site refuses at local noon and lets the slew go at local midnight.
#[tokio::test(start_paused = true)]
async fn the_darkness_wait_reads_the_run_clock() {
    for (when, waits_or_refuses) in [(site_time(0.0), true), (site_time(12.0), false)] {
        let mut ctx = slew_ctx(DEFAULT_MAX_SUN_ALTITUDE_DEGREES).await;
        ctx.run.clock = crate::scheduling::MockClock::at(&when.to_rfc3339());
        ctx.cancellation_token.store(true, Ordering::SeqCst);
        let blocked = wait_for_darkness(&ctx, "test", None).await;
        assert_eq!(blocked.is_some(), waits_or_refuses, "{when}: {blocked:?}");
    }
}
