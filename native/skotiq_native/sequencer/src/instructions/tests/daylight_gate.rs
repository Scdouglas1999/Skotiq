//! `daylight_gate` tests — moved verbatim out of the former single `instructions::tests`
//! module (release-pass C3 mechanical split). Shared fixtures stay in the parent
//! `tests` module and reach here through `use super::*;`.

use super::*;

// Pure helper: daylight_gate_block_reason

#[test]
fn daylight_gate_blocks_when_sun_above_max() {
    let sun_alt = live_sun_alt();
    // Threshold 5° BELOW the live Sun altitude => Sun is "up" relative to
    // the configured max => must block.
    let reason = daylight_gate_block_reason(Some(TEST_LAT), Some(TEST_LON), sun_alt - 5.0, "test");
    assert!(
        reason.is_some(),
        "Sun {sun_alt:.1}° above max {:.1}° must block",
        sun_alt - 5.0
    );
}

#[test]
fn daylight_gate_allows_when_sun_below_max() {
    let sun_alt = live_sun_alt();
    // Threshold 5° ABOVE the live Sun altitude => Sun is "down" relative to
    // the configured max => must allow.
    let reason = daylight_gate_block_reason(Some(TEST_LAT), Some(TEST_LON), sun_alt + 5.0, "test");
    assert!(
        reason.is_none(),
        "Sun {sun_alt:.1}° below max {:.1}° must NOT block",
        sun_alt + 5.0
    );
}

#[test]
fn daylight_gate_abstains_without_location() {
    // No observer location => cannot compute Sun altitude => abstain
    // (never fabricate a block that would wedge a location-less rig). Even
    // with an absurdly low threshold the gate must NOT block here.
    assert!(daylight_gate_block_reason(None, Some(TEST_LON), -90.0, "test").is_none());
    assert!(daylight_gate_block_reason(Some(TEST_LAT), None, -90.0, "test").is_none());
    assert!(daylight_gate_block_reason(None, None, -90.0, "test").is_none());
}

/// An operator who skips the optional site step must not be judged against
/// Null Island. The persisted site arrives as `Some(0, 0)`; computing a real
/// Greenwich Sun altitude from it refuses every light frame of the night with
/// a message blaming the Sun rather than the missing setting. (0, 0) must read
/// as "no site".
#[test]
fn daylight_gate_treats_null_island_as_no_location() {
    assert!(
        daylight_gate_block_reason(Some(0.0), Some(0.0), -90.0, "test").is_none(),
        "an unset site must abstain, not fabricate a Sun altitude for 0N 0E"
    );
}

#[test]
fn daylight_gate_falls_back_to_default_on_non_finite_max() {
    // A NaN threshold must not silently disable the gate: it falls back to
    // DEFAULT_MAX_SUN_ALTITUDE_DEGREES. We can only assert the finite
    // fallback path is taken consistently with the default comparison.
    let sun_alt = live_sun_alt();
    let nan_reason = daylight_gate_block_reason(Some(TEST_LAT), Some(TEST_LON), f64::NAN, "test");
    let default_reason = daylight_gate_block_reason(
        Some(TEST_LAT),
        Some(TEST_LON),
        DEFAULT_MAX_SUN_ALTITUDE_DEGREES,
        "test",
    );
    assert_eq!(
            nan_reason.is_some(),
            default_reason.is_some(),
            "NaN max must behave exactly like the default ({sun_alt:.1}° vs {DEFAULT_MAX_SUN_ALTITUDE_DEGREES:.1}°)"
        );
}

#[test]
fn calibration_frame_types_do_not_require_darkness() {
    for frame_type in ["Bias", "Dark", "Flat", "DarkFlat"] {
        assert!(
            !frame_type_requires_darkness(frame_type),
            "{frame_type} is a calibration frame and must remain legal in daylight"
        );
    }
    assert!(frame_type_requires_darkness("Light"));
    assert!(frame_type_requires_darkness("light"));
}

#[tokio::test]
async fn slew_to_target_rejected_when_sun_up() {
    let sun_alt = live_sun_alt();
    let ctx = slew_ctx(sun_alt - 5.0).await; // Sun above max → block
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
    let sun_alt = live_sun_alt();
    // Mount NOT parked + science target set + Sun up → on-sky light → block.
    let ctx = expose_ctx(Arc::new(NullDeviceOps), Some((5.5, 22.0)), sun_alt - 5.0).await;
    let result = execute_exposure(&one_light(), &ctx, |_, _, _| {}).await;
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
            frame_type: frame_type.to_string(),
            ..ExposureConfig::default()
        };
        let result = execute_exposure(&config, &ctx, |_, _, _| {}).await;
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
            frame_type: frame_type.to_string(),
            ..ExposureConfig::default()
        };
        let result = execute_exposure(&config, &ctx, |_, _, _| {}).await;
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
    let sun_alt = live_sun_alt();
    // Mount NOT parked + no target group + Sun up → still an on-sky light.
    let ctx = expose_ctx(Arc::new(NullDeviceOps), None, sun_alt - 5.0).await;
    let result = execute_exposure(&one_light(), &ctx, |_, _, _| {}).await;
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
    let result = execute_exposure(&one_light(), &ctx, |_, _, _| {}).await;
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
    let result = execute_exposure(&one_light(), &ctx, |_, _, _| {}).await;
    assert!(
        !is_daylight_block(&result),
        "on-sky LIGHT exposure must clear the daylight gate at night; got {:?}",
        result.message
    );
}
