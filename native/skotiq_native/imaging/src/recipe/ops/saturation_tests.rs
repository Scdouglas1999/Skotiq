//! `saturation@1`: determinism, the identity, the direction of the boost, and
//! the luminance it must not move.

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
        .push(RecipeStep::new(SaturationV1.id(), SaturationV1.version()).with_params(params));
    recipe
}

/// A synthetic star field mapped into the display domain.
fn display_field(width: u32, height: u32, seed: u64) -> OpImage {
    let base = synthetic_star_field(width, height, 3, seed);
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

/// Rec. 709 luminance of a triple.
fn luma(r: f64, g: f64, b: f64) -> f64 {
    LUMA_R * r + LUMA_G * g + LUMA_B * b
}

#[test]
fn a_render_is_byte_identical_over_odd_and_even_geometries() {
    for (width, height) in [(64u32, 48u32), (65, 49)] {
        let base = Arc::new(display_field(width, height, 505));
        let out = assert_deterministic(
            &recipe_with(json!({ "amount": 0.6 })),
            &base,
            &registry(),
            &OpContext::new(),
            RenderOptions::full(),
        )
        .unwrap_or_else(|e| panic!("{width}x{height} renders: {e}"));
        assert_eq!(out.report.steps[0].outcome, StepOutcome::Applied);
        assert_eq!(out.image.width(), width);
        assert_eq!(out.image.height(), height);
    }
}

#[test]
fn zero_amount_is_an_exact_clone() {
    let base = display_field(64, 48, 51);
    let out = SaturationV1
        .apply(&base, &json!({ "amount": 0.0 }), &OpContext::new())
        .expect("a zero-amount step renders");
    assert_pixels_identical(&out, &base, "amount 0");
    assert_wcs_identical(&out, &base, "amount 0");
}

#[test]
fn a_positive_amount_pushes_the_channels_away_from_luminance() {
    let base = swatch(0.60, 0.45, 0.35);
    let out = SaturationV1
        .apply(
            &base,
            &json!({ "amount": 1.0, "protection": 0.0 }),
            &OpContext::new(),
        )
        .expect("the swatch renders");
    let before = luma(0.60, 0.45, 0.35);
    for channel in 0..3 {
        let source = base.data()[channel] as f64;
        let found = out.data()[channel] as f64;
        assert!(
            (found - before).abs() > (source - before).abs(),
            "channel {channel} must move away from luminance: {source} -> {found} about {before}"
        );
    }
}

#[test]
fn a_full_desaturation_collapses_the_channels_onto_luminance() {
    let base = swatch(0.60, 0.45, 0.35);
    let out = SaturationV1
        .apply(
            &base,
            &json!({ "amount": -1.0, "protection": 0.0 }),
            &OpContext::new(),
        )
        .expect("the swatch renders");
    let expected = luma(0.60, 0.45, 0.35);
    for channel in 0..3 {
        assert!(
            (out.data()[channel] as f64 - expected).abs() < 1e-6,
            "channel {channel} must land on luminance: {} vs {expected}",
            out.data()[channel]
        );
    }
}

#[test]
fn the_boost_moves_color_and_not_brightness() {
    let base = display_field(64, 48, 52);
    let out = SaturationV1
        .apply(
            &base,
            &json!({ "amount": 0.8, "protection": 0.0 }),
            &OpContext::new(),
        )
        .expect("the frame renders");
    for pixel in 0..base.pixel_count() {
        let before = luma(
            base.data()[pixel * 3] as f64,
            base.data()[pixel * 3 + 1] as f64,
            base.data()[pixel * 3 + 2] as f64,
        );
        let after = luma(
            out.data()[pixel * 3] as f64,
            out.data()[pixel * 3 + 1] as f64,
            out.data()[pixel * 3 + 2] as f64,
        );
        assert!(
            (after - before).abs() < 1e-5,
            "pixel {pixel}: luminance moved from {before} to {after}"
        );
    }
}

#[test]
fn full_protection_withdraws_the_boost_at_both_ends_of_the_range() {
    // A near-black and a near-white swatch keep their colour; a mid-tone one
    // does not, so the protection is a function of luminance and not a constant.
    for (r, g, b) in [(0.02_f32, 0.01_f32, 0.005_f32), (0.99, 0.98, 0.995)] {
        let base = swatch(r, g, b);
        let out = SaturationV1
            .apply(
                &base,
                &json!({ "amount": 2.0, "protection": 1.0 }),
                &OpContext::new(),
            )
            .expect("the swatch renders");
        for channel in 0..3 {
            let source = base.data()[channel] as f64;
            let found = out.data()[channel] as f64;
            assert!(
                (found - source).abs() < 0.01,
                "channel {channel} at the end of the range must be nearly untouched: {source} -> {found}"
            );
        }
    }

    let mid = swatch(0.55, 0.50, 0.45);
    let out = SaturationV1
        .apply(
            &mid,
            &json!({ "amount": 2.0, "protection": 1.0 }),
            &OpContext::new(),
        )
        .expect("the swatch renders");
    assert!(
        (out.data()[0] as f64 - 0.55).abs() > 0.02,
        "a mid-tone must still be boosted"
    );
}

#[test]
fn a_mono_master_is_refused_rather_than_returned_unchanged() {
    let mono = OpImage::new(8, 8, 1, vec![0.5_f32; 64], wcs_header(8, 8, 1))
        .expect("the mono frame geometry is consistent");
    assert_eq!(
        SaturationV1
            .apply(&mono, &json!({ "amount": 1.0 }), &OpContext::new())
            .unwrap_err(),
        OpError::UnsupportedChannels {
            op_id: "saturation",
            op_version: 1,
            channels: 1,
            expected: "a colour master with 3 channels",
        }
    );
}

#[test]
fn the_astrometry_and_the_frame_metadata_survive() {
    let base = display_field(64, 48, 53);
    let out = SaturationV1
        .apply(&base, &json!({ "amount": 0.5 }), &OpContext::new())
        .expect("the frame renders");
    assert_wcs_identical(&out, &base, "the boost keeps the plate");
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
    let base = display_field(64, 48, 54);
    let ctx = OpContext::new();
    ctx.request_cancel();
    assert_eq!(
        SaturationV1
            .apply(&base, &json!({ "amount": 0.5 }), &ctx)
            .unwrap_err(),
        OpError::Cancelled
    );
}

#[test]
fn an_unknown_parameter_is_rejected() {
    assert_eq!(
        SaturationV1.validate_params(&json!({ "saturation": 1.0 })),
        Err(OpError::UnknownParam {
            op_id: "saturation",
            op_version: 1,
            key: "saturation".to_string(),
        })
    );
}

#[test]
fn a_parameter_of_the_wrong_type_is_rejected() {
    assert!(matches!(
        SaturationV1.validate_params(&json!({ "amount": [1.0] })),
        Err(OpError::ParamType { key, .. }) if key == "amount"
    ));
}

#[test]
fn a_parameter_outside_its_range_is_rejected() {
    assert!(matches!(
        SaturationV1.validate_params(&json!({ "amount": -2.0 })),
        Err(OpError::ParamRange { key, .. }) if key == "amount"
    ));
    assert!(matches!(
        SaturationV1.validate_params(&json!({ "protection": 1.5 })),
        Err(OpError::ParamRange { key, .. }) if key == "protection"
    ));
}

#[test]
fn a_payload_that_is_not_an_object_is_rejected() {
    assert_eq!(
        SaturationV1.validate_params(&json!(null)),
        Err(OpError::ParamsNotObject {
            op_id: "saturation",
            op_version: 1,
            found: "null",
        })
    );
}

#[test]
fn the_operation_emits_stretched_data_and_a_linear_step_may_not_follow_it() {
    assert_eq!(SaturationV1.stage(), OpStage::Stretched);
    let registry = registry();

    let mut good = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    good.steps.push(
        RecipeStep::new("stretch", 1).with_params(json!({ "blackPoint": 0.0, "whitePoint": 1.0 })),
    );
    good.steps.push(RecipeStep::new("saturation", 1));
    validate(&good, &registry).expect("a boost after the stretch validates");

    let mut bad = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    bad.steps.push(RecipeStep::new("saturation", 1));
    bad.steps
        .push(RecipeStep::new("crop", 1).with_params(json!({ "width": 8, "height": 8 })));
    assert!(matches!(
        validate(&bad, &registry),
        Err(RecipeError::StageOrder { .. })
    ));
}

#[test]
fn a_render_is_byte_identical_at_every_thread_count() {
    let base = display_field(96, 80, 0x05A7);
    let params = json!({ "amount": 0.8 });
    let reference = rayon::ThreadPoolBuilder::new()
        .num_threads(1)
        .build()
        .expect("a single-threaded pool builds")
        .install(|| SaturationV1.apply(&base, &params, &OpContext::new()))
        .expect("the single-threaded render succeeds");

    for threads in [2usize, 3, 8, 16] {
        let out = rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .build()
            .expect("the pool builds")
            .install(|| SaturationV1.apply(&base, &params, &OpContext::new()))
            .unwrap_or_else(|e| panic!("the {threads}-thread render succeeds: {e}"));
        assert_pixels_identical(&out, &reference, &format!("{threads} threads"));
    }
}
