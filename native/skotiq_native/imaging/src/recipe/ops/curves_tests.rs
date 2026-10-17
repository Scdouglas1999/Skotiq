//! `curves@1`: determinism, the identity curve, the control points the curve
//! passes through, monotonicity, and the payloads that are refused.

use std::sync::Arc;

use serde_json::json;

use super::*;
use crate::recipe::testkit::{
    assert_deterministic, assert_pixels_identical, assert_wcs_identical, synthetic_star_field,
    wcs_header,
};
use crate::recipe::{
    validate, OpRegistry, Recipe, RecipeAuthor, RecipeError, RecipeStep, RenderOptions, StepOutcome,
};

/// ADU the synthetic field is divided by to reach the display domain the
/// stretched stage works in.
const DISPLAY_SCALE: f64 = 25_000.0;

/// The registry this build ships, which carries the operation under test.
fn registry() -> OpRegistry {
    OpRegistry::builtin().expect("the builtin list registers cleanly")
}

/// A one-step recipe over the operation under test.
fn recipe_with(params: Value) -> Recipe {
    let mut recipe = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    recipe
        .steps
        .push(RecipeStep::new(CurvesV1.id(), CurvesV1.version()).with_params(params));
    recipe
}

/// A synthetic star field mapped into the display domain.
fn display_field(width: u32, height: u32, channels: u32, seed: u64) -> OpImage {
    let base = synthetic_star_field(width, height, channels, seed);
    let data: Vec<f32> = base
        .data()
        .iter()
        .map(|&value| (value as f64 / DISPLAY_SCALE).clamp(0.0, 1.0) as f32)
        .collect();
    base.with_data(data)
        .expect("the display frame keeps its geometry")
}

/// A one-pixel colour frame, so a single triple can be reasoned about exactly.
fn swatch(r: f32, g: f32, b: f32) -> OpImage {
    OpImage::new(1, 1, 3, vec![r, g, b], wcs_header(1, 1, 3))
        .expect("the swatch geometry is consistent")
}

/// A shadow-lifting curve payload.
fn lift() -> Value {
    json!({ "x": [0.0, 0.25, 0.75, 1.0], "y": [0.0, 0.45, 0.9, 1.0] })
}

#[test]
fn a_render_is_byte_identical_over_odd_and_even_geometries_and_both_channel_counts() {
    for (width, height, channels) in [(64, 48, 1), (65, 49, 1), (64, 48, 3), (65, 49, 3)] {
        let base = Arc::new(display_field(width, height, channels, 606));
        let out = assert_deterministic(
            &recipe_with(lift()),
            &base,
            &registry(),
            &OpContext::new(),
            RenderOptions::full(),
        )
        .unwrap_or_else(|e| panic!("{width}x{height}x{channels} renders: {e}"));
        assert_eq!(out.report.steps[0].outcome, StepOutcome::Applied);
        assert_eq!(out.image.channels(), channels);
    }
}

#[test]
fn the_diagonal_curve_is_an_exact_clone() {
    for channels in [1u32, 3] {
        for mode in [MODE_LUMINANCE, MODE_PER_CHANNEL] {
            let base = display_field(64, 48, channels, 61);
            let out = CurvesV1
                .apply(
                    &base,
                    &json!({ "mode": mode, "x": [0.0, 0.5, 1.0], "y": [0.0, 0.5, 1.0] }),
                    &OpContext::new(),
                )
                .expect("the diagonal curve renders");
            assert_pixels_identical(&out, &base, mode);
            assert_wcs_identical(&out, &base, mode);
        }
    }
}

#[test]
fn an_absent_payload_is_the_identity() {
    let base = display_field(64, 48, 3, 62);
    let out = CurvesV1
        .apply(&base, &json!({}), &OpContext::new())
        .expect("the default curve renders");
    assert_pixels_identical(&out, &base, "default payload");
}

#[test]
fn the_curve_passes_through_its_control_points() {
    let curve = Curve::new(vec![0.0, 0.25, 0.75, 1.0], vec![0.0, 0.45, 0.90, 1.0]);
    for (x, y) in [(0.0, 0.0), (0.25, 0.45), (0.75, 0.90), (1.0, 1.0)] {
        assert!(
            (curve.eval(x) - y).abs() < 1e-12,
            "the curve must pass through ({x}, {y}), found {}",
            curve.eval(x)
        );
    }
}

#[test]
fn the_curve_never_folds_even_on_a_step_that_would_make_a_spline_overshoot() {
    // A near-vertical middle segment is what makes an ordinary cubic spline
    // overshoot below the previous knot and above the next one. The
    // Fritsch–Carlson tangent limit is what stops it.
    let curve = Curve::new(vec![0.0, 0.50, 0.52, 1.0], vec![0.0, 0.05, 0.95, 1.0]);
    let mut previous = f64::NEG_INFINITY;
    for step in 0..=2000 {
        let x = step as f64 / 2000.0;
        let y = curve.eval(x);
        assert!(
            y >= previous - 1e-12,
            "the curve descends at x = {x}: {previous} then {y}"
        );
        assert!(
            (-1e-12..=1.0 + 1e-12).contains(&y),
            "the curve leaves the display domain at x = {x}: {y}"
        );
        previous = y;
    }
}

#[test]
fn luminance_mode_keeps_the_channel_ratios_and_per_channel_mode_does_not() {
    let base = swatch(0.60, 0.40, 0.20);
    let luminance = CurvesV1
        .apply(&base, &lift(), &OpContext::new())
        .expect("the luminance curve renders");
    let per_channel = CurvesV1
        .apply(
            &base,
            &json!({
                "mode": MODE_PER_CHANNEL,
                "x": [0.0, 0.25, 0.75, 1.0],
                "y": [0.0, 0.45, 0.9, 1.0],
            }),
            &OpContext::new(),
        )
        .expect("the per-channel curve renders");

    let source_ratio = 0.60_f64 / 0.40;
    let luminance_ratio = luminance.data()[0] as f64 / luminance.data()[1] as f64;
    assert!(
        (luminance_ratio - source_ratio).abs() < 1e-4,
        "a luminance curve must keep the red-to-green ratio: {source_ratio} vs {luminance_ratio}"
    );

    let per_channel_ratio = per_channel.data()[0] as f64 / per_channel.data()[1] as f64;
    assert!(
        (per_channel_ratio - source_ratio).abs() > 1e-3,
        "a per-channel curve moves the ratio, which is what it is for: {per_channel_ratio}"
    );
    // Both modes lift the frame: the curve is above the diagonal here.
    assert!(luminance.data()[0] > base.data()[0]);
    assert!(per_channel.data()[0] > base.data()[0]);
}

#[test]
fn a_mono_master_takes_the_curve_directly_in_either_mode() {
    let base = OpImage::new(1, 1, 1, vec![0.25_f32], wcs_header(1, 1, 1))
        .expect("the mono swatch geometry is consistent");
    for mode in [MODE_LUMINANCE, MODE_PER_CHANNEL] {
        let out = CurvesV1
            .apply(
                &base,
                &json!({
                    "mode": mode,
                    "x": [0.0, 0.25, 0.75, 1.0],
                    "y": [0.0, 0.45, 0.9, 1.0],
                }),
                &OpContext::new(),
            )
            .expect("the mono curve renders");
        assert!(
            (out.data()[0] as f64 - 0.45).abs() < 1e-6,
            "{mode}: a control point maps to its own output, found {}",
            out.data()[0]
        );
    }
}

#[test]
fn a_channel_layout_the_curve_has_no_luminance_for_is_refused() {
    let two = OpImage::new(2, 2, 2, vec![0.5_f32; 8], wcs_header(2, 2, 2))
        .expect("the two-channel frame geometry is consistent");
    assert_eq!(
        CurvesV1
            .apply(&two, &lift(), &OpContext::new())
            .unwrap_err(),
        OpError::UnsupportedChannels {
            op_id: "curves",
            op_version: 1,
            channels: 2,
            expected: "a mono master with 1 channel or a colour master with 3",
        }
    );
}

#[test]
fn a_curve_that_folds_is_rejected() {
    assert!(matches!(
        CurvesV1.validate_params(&json!({
            "x": [0.0, 0.5, 1.0],
            "y": [0.0, 0.8, 0.4],
        })),
        Err(OpError::ParamRange { key, .. }) if key == "y"
    ));
}

#[test]
fn control_point_inputs_must_strictly_increase() {
    assert!(matches!(
        CurvesV1.validate_params(&json!({
            "x": [0.0, 0.5, 0.5, 1.0],
            "y": [0.0, 0.4, 0.6, 1.0],
        })),
        Err(OpError::ParamRange { key, .. }) if key == "x"
    ));
    assert!(matches!(
        CurvesV1.validate_params(&json!({
            "x": [0.0, 0.7, 0.3, 1.0],
            "y": [0.0, 0.4, 0.6, 1.0],
        })),
        Err(OpError::ParamRange { key, .. }) if key == "x"
    ));
}

#[test]
fn a_curve_that_does_not_span_the_display_domain_is_rejected() {
    assert!(matches!(
        CurvesV1.validate_params(&json!({ "x": [0.1, 1.0], "y": [0.0, 1.0] })),
        Err(OpError::ParamRange { key, .. }) if key == "x"
    ));
    assert!(matches!(
        CurvesV1.validate_params(&json!({ "x": [0.0, 0.9], "y": [0.0, 1.0] })),
        Err(OpError::ParamRange { key, .. }) if key == "x"
    ));
}

#[test]
fn the_two_control_point_lists_must_be_the_same_length() {
    assert!(matches!(
        CurvesV1.validate_params(&json!({
            "x": [0.0, 0.5, 1.0],
            "y": [0.0, 1.0],
        })),
        Err(OpError::ParamRange { key, .. }) if key == "y"
    ));
}

#[test]
fn a_control_point_list_of_the_wrong_shape_is_rejected() {
    assert!(matches!(
        CurvesV1.validate_params(&json!({ "x": [0.0], "y": [0.0] })),
        Err(OpError::ParamRange { key, .. }) if key == "x"
    ));
    assert!(matches!(
        CurvesV1.validate_params(&json!({ "x": 0.5, "y": [0.0, 1.0] })),
        Err(OpError::ParamType { key, .. }) if key == "x"
    ));
    assert!(matches!(
        CurvesV1.validate_params(&json!({ "x": [0.0, 1.5], "y": [0.0, 1.0] })),
        Err(OpError::ParamRange { key, .. }) if key == "x"
    ));
}

#[test]
fn an_unknown_mode_and_an_unknown_parameter_are_rejected() {
    assert!(matches!(
        CurvesV1.validate_params(&json!({ "mode": "rgb" })),
        Err(OpError::ParamRange { key, .. }) if key == "mode"
    ));
    assert_eq!(
        CurvesV1.validate_params(&json!({ "points": [0.0, 1.0] })),
        Err(OpError::UnknownParam {
            op_id: "curves",
            op_version: 1,
            key: "points".to_string(),
        })
    );
}

#[test]
fn a_payload_that_is_not_an_object_is_rejected() {
    assert_eq!(
        CurvesV1.validate_params(&json!(true)),
        Err(OpError::ParamsNotObject {
            op_id: "curves",
            op_version: 1,
            found: "a boolean",
        })
    );
}

#[test]
fn the_astrometry_and_the_frame_metadata_survive() {
    let base = display_field(64, 48, 3, 63);
    let out = CurvesV1
        .apply(&base, &lift(), &OpContext::new())
        .expect("the frame renders");
    assert_wcs_identical(&out, &base, "the curve keeps the plate");
    assert_eq!(out.header().get_string("OBJECT"), Some("M31"));
    assert_eq!(out.header().get_string("FILTER"), Some("L"));
    assert_eq!(
        out.header().get_string("DATE-OBS"),
        Some("2026-08-16T02:11:04")
    );
    assert_eq!(out.header().get_float("EXPTIME"), Some(300.0));
    assert_eq!(out.header().get_int("NAXIS1"), Some(64));
}

#[test]
fn a_raised_cancel_flag_aborts_the_operation() {
    let base = display_field(64, 48, 3, 64);
    let ctx = OpContext::new();
    ctx.request_cancel();
    assert_eq!(
        CurvesV1.apply(&base, &lift(), &ctx).unwrap_err(),
        OpError::Cancelled
    );
}

#[test]
fn the_operation_emits_stretched_data_and_a_linear_step_may_not_follow_it() {
    assert_eq!(CurvesV1.stage(), OpStage::Stretched);
    let registry = registry();

    let mut good = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    good.steps.push(RecipeStep::new("background_extract", 1));
    good.steps.push(
        RecipeStep::new("stretch", 1).with_params(json!({ "blackPoint": 0.0, "whitePoint": 1.0 })),
    );
    good.steps.push(RecipeStep::new("curves", 1));
    validate(&good, &registry).expect("a curve after the stretch validates");

    let mut bad = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    bad.steps.push(RecipeStep::new("curves", 1));
    bad.steps.push(RecipeStep::new("color_calibrate", 1));
    assert!(matches!(
        validate(&bad, &registry),
        Err(RecipeError::StageOrder { .. })
    ));
}

#[test]
fn a_render_is_byte_identical_at_every_thread_count() {
    let base = display_field(96, 80, 3, 0x000C_7EAD);
    let reference = rayon::ThreadPoolBuilder::new()
        .num_threads(1)
        .build()
        .expect("a single-threaded pool builds")
        .install(|| CurvesV1.apply(&base, &lift(), &OpContext::new()))
        .expect("the single-threaded render succeeds");

    for threads in [2usize, 3, 8, 16] {
        let out = rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .build()
            .expect("the pool builds")
            .install(|| CurvesV1.apply(&base, &lift(), &OpContext::new()))
            .unwrap_or_else(|e| panic!("the {threads}-thread render succeeds: {e}"));
        assert_pixels_identical(&out, &reference, &format!("{threads} threads"));
    }
}
