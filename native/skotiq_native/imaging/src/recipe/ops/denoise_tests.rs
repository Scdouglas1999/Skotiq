//! `denoise@1`: determinism, the exact cases, the noise it actually removes,
//! and the luminance it leaves alone.

use std::sync::Arc;

use serde_json::json;

use super::*;
use crate::recipe::testkit::{
    assert_deterministic, assert_pixels_identical, assert_wcs_identical, synthetic_star_field,
    wcs_header, Lcg,
};
use crate::recipe::{
    validate, OpRegistry, Recipe, RecipeAuthor, RecipeError, RecipeStep, RenderOptions, StepOutcome,
};

/// The registry this build ships, which carries the operation under test.
fn registry() -> OpRegistry {
    OpRegistry::builtin().expect("the builtin list registers cleanly")
}

/// A one-step recipe over the operation under test.
fn recipe_with(params: Value) -> Recipe {
    let mut recipe = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    recipe
        .steps
        .push(RecipeStep::new(DenoiseV1.id(), DenoiseV1.version()).with_params(params));
    recipe
}

/// A frame at one exact level everywhere.
///
/// `800` is a multiple of 16, so every tap of the B3-spline kernel lands on an
/// exactly representable product and the low-pass of a flat plane is that plane
/// bit-for-bit.
fn flat(width: u32, height: u32, channels: u32, level: f32) -> OpImage {
    let samples = (width as usize) * (height as usize) * (channels as usize);
    OpImage::new(
        width,
        height,
        channels,
        vec![level; samples],
        wcs_header(width, height, channels),
    )
    .expect("the flat frame geometry is consistent")
}

/// A flat frame plus deterministic Gaussian noise, so the noise the operation
/// removes is the only thing in it.
fn noisy(width: u32, height: u32, channels: u32, level: f64, sigma: f64, seed: u64) -> OpImage {
    let samples = (width as usize) * (height as usize) * (channels as usize);
    let mut rng = Lcg::new(seed);
    let mut data = vec![0.0_f32; samples];
    for value in data.iter_mut() {
        let u1 = rng.next_unit().max(1e-12);
        let u2 = rng.next_unit();
        let gaussian = (-2.0 * u1.ln()).sqrt() * (std::f64::consts::TAU * u2).cos();
        *value = (level + gaussian * sigma) as f32;
    }
    OpImage::new(
        width,
        height,
        channels,
        data,
        wcs_header(width, height, channels),
    )
    .expect("the noisy frame geometry is consistent")
}

/// Sample standard deviation of one channel of an image.
fn channel_deviation(image: &OpImage, channel: usize) -> f64 {
    let channels = image.channels() as usize;
    let values: Vec<f64> = image
        .data()
        .iter()
        .skip(channel)
        .step_by(channels)
        .map(|&value| value as f64)
        .collect();
    let mean = values.iter().sum::<f64>() / values.len() as f64;
    (values.iter().map(|v| (v - mean) * (v - mean)).sum::<f64>() / values.len() as f64).sqrt()
}

#[test]
fn a_render_is_byte_identical_over_odd_and_even_geometries_and_both_channel_counts() {
    for (width, height, channels) in [(64, 48, 1), (65, 49, 1), (64, 48, 3), (65, 49, 3)] {
        let base = Arc::new(synthetic_star_field(width, height, channels, 707));
        let out = assert_deterministic(
            &recipe_with(json!({ "scaleCount": 3 })),
            &base,
            &registry(),
            &OpContext::new(),
            RenderOptions::full(),
        )
        .unwrap_or_else(|e| panic!("{width}x{height}x{channels} renders: {e}"));
        assert_eq!(out.report.steps[0].outcome, StepOutcome::Applied);
        assert_eq!(out.image.width(), width);
        assert_eq!(out.image.height(), height);
        assert_eq!(out.image.channels(), channels);
    }
}

#[test]
fn zero_strength_is_an_exact_clone() {
    for channels in [1u32, 3] {
        let base = synthetic_star_field(48, 40, channels, 71);
        let out = DenoiseV1
            .apply(&base, &json!({ "strength": 0.0 }), &OpContext::new())
            .expect("a zero-strength step renders");
        assert_pixels_identical(&out, &base, "strength 0");
        assert_wcs_identical(&out, &base, "strength 0");
    }
}

#[test]
fn a_zero_threshold_with_no_chroma_smoothing_shrinks_nothing() {
    // The correction is accumulated as `soft(w) − w`, which is exactly zero at a
    // zero threshold, so the operation cannot perturb a sample it has nothing to
    // shrink even at full strength.
    for channels in [1u32, 3] {
        let base = synthetic_star_field(48, 40, channels, 72);
        let out = DenoiseV1
            .apply(
                &base,
                &json!({ "thresholdSigma": 0.0, "chromaStrength": 0.0, "strength": 1.0 }),
                &OpContext::new(),
            )
            .expect("a zero-threshold step renders");
        assert_pixels_identical(&out, &base, "thresholdSigma 0");
    }
}

#[test]
fn a_flat_frame_comes_back_unchanged() {
    // A flat plane has no detail at any scale and no chroma, so both the
    // threshold and the chroma smoothing have nothing to act on.
    for channels in [1u32, 3] {
        let base = flat(40, 33, channels, 800.0);
        let out = DenoiseV1
            .apply(&base, &json!({}), &OpContext::new())
            .expect("a flat frame renders");
        assert_pixels_identical(&out, &base, "flat frame");
    }
}

#[test]
fn noise_is_measurably_removed() {
    let base = noisy(96, 96, 1, 800.0, 20.0, 0x1501);
    let before = channel_deviation(&base, 0);
    let out = DenoiseV1
        .apply(
            &base,
            &json!({ "scaleCount": 4, "thresholdSigma": 3.0, "strength": 1.0 }),
            &OpContext::new(),
        )
        .expect("the noisy frame renders");
    let after = channel_deviation(&out, 0);
    assert!(
        after < before * 0.5,
        "noise must fall well below its input level: {before} -> {after}"
    );
}

#[test]
fn a_higher_threshold_removes_more() {
    let base = noisy(96, 96, 1, 800.0, 20.0, 0x03E5);
    let gentle = DenoiseV1
        .apply(&base, &json!({ "thresholdSigma": 1.0 }), &OpContext::new())
        .expect("the gentle step renders");
    let aggressive = DenoiseV1
        .apply(&base, &json!({ "thresholdSigma": 6.0 }), &OpContext::new())
        .expect("the aggressive step renders");
    assert!(
        channel_deviation(&aggressive, 0) < channel_deviation(&gentle, 0),
        "a higher threshold must leave less noise"
    );
}

#[test]
fn chroma_smoothing_moves_color_without_moving_luminance() {
    // Every channel takes the same luminance correction, and the chroma
    // correction sums to zero across channels by construction, so the mean
    // across channels survives the chroma pass.
    let base = noisy(64, 64, 3, 800.0, 20.0, 0x0C40);
    let out = DenoiseV1
        .apply(
            &base,
            &json!({ "thresholdSigma": 0.0, "chromaStrength": 1.0, "strength": 1.0 }),
            &OpContext::new(),
        )
        .expect("the chroma pass renders");

    let mut moved = false;
    for pixel in 0..base.pixel_count() {
        let before: f64 = (0..3).map(|c| base.data()[pixel * 3 + c] as f64).sum();
        let after: f64 = (0..3).map(|c| out.data()[pixel * 3 + c] as f64).sum();
        assert!(
            (after - before).abs() < 1e-2,
            "pixel {pixel}: luminance moved from {before} to {after}"
        );
        moved |= out.data()[pixel * 3].to_bits() != base.data()[pixel * 3].to_bits();
    }
    assert!(moved, "the chroma pass must actually change the channels");
}

#[test]
fn the_astrometry_and_the_frame_metadata_survive() {
    let base = synthetic_star_field(48, 40, 3, 73);
    let out = DenoiseV1
        .apply(&base, &json!({}), &OpContext::new())
        .expect("the frame renders");
    assert_wcs_identical(&out, &base, "the denoise keeps the plate");
    assert_eq!(out.header().get_string("OBJECT"), Some("M31"));
    assert_eq!(out.header().get_string("FILTER"), Some("L"));
    assert_eq!(
        out.header().get_string("DATE-OBS"),
        Some("2026-08-16T02:11:04")
    );
    assert_eq!(out.header().get_float("EXPTIME"), Some(300.0));
    assert_eq!(out.header().get_int("NAXIS1"), Some(48));
    assert_eq!(out.header().get_int("NAXIS2"), Some(40));
}

#[test]
fn a_raised_cancel_flag_aborts_the_operation() {
    let base = synthetic_star_field(64, 64, 3, 74);
    let ctx = OpContext::new();
    ctx.request_cancel();
    assert_eq!(
        DenoiseV1.apply(&base, &json!({}), &ctx).unwrap_err(),
        OpError::Cancelled
    );
}

#[test]
fn an_unknown_parameter_is_rejected() {
    assert_eq!(
        DenoiseV1.validate_params(&json!({ "scales": 3 })),
        Err(OpError::UnknownParam {
            op_id: "denoise",
            op_version: 1,
            key: "scales".to_string(),
        })
    );
}

#[test]
fn a_parameter_of_the_wrong_type_is_rejected() {
    assert!(matches!(
        DenoiseV1.validate_params(&json!({ "scaleCount": 3.5 })),
        Err(OpError::ParamType { key, .. }) if key == "scaleCount"
    ));
    assert!(matches!(
        DenoiseV1.validate_params(&json!({ "strength": true })),
        Err(OpError::ParamType { key, .. }) if key == "strength"
    ));
}

#[test]
fn a_parameter_outside_its_range_is_rejected() {
    assert!(matches!(
        DenoiseV1.validate_params(&json!({ "scaleCount": 0 })),
        Err(OpError::ParamRange { key, .. }) if key == "scaleCount"
    ));
    assert!(matches!(
        DenoiseV1.validate_params(&json!({ "scaleCount": 9 })),
        Err(OpError::ParamRange { key, .. }) if key == "scaleCount"
    ));
    assert!(matches!(
        DenoiseV1.validate_params(&json!({ "strength": 1.5 })),
        Err(OpError::ParamRange { key, .. }) if key == "strength"
    ));
    assert!(matches!(
        DenoiseV1.validate_params(&json!({ "chromaStrength": -0.1 })),
        Err(OpError::ParamRange { key, .. }) if key == "chromaStrength"
    ));
}

#[test]
fn a_payload_that_is_not_an_object_is_rejected() {
    assert_eq!(
        DenoiseV1.validate_params(&json!(7)),
        Err(OpError::ParamsNotObject {
            op_id: "denoise",
            op_version: 1,
            found: "a number",
        })
    );
}

#[test]
fn the_operation_emits_linear_data_and_is_refused_after_a_stretch() {
    assert_eq!(DenoiseV1.stage(), OpStage::Linear);
    let registry = registry();
    let stretch_params = json!({ "blackPoint": 0.0, "whitePoint": 1.0 });

    let mut good = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    good.steps.push(RecipeStep::new("denoise", 1));
    good.steps
        .push(RecipeStep::new("stretch", 1).with_params(stretch_params.clone()));
    validate(&good, &registry).expect("a denoise above the stretch validates");

    let mut bad = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    bad.steps
        .push(RecipeStep::new("stretch", 1).with_params(stretch_params));
    bad.steps.push(RecipeStep::new("denoise", 1));
    assert!(matches!(
        validate(&bad, &registry),
        Err(RecipeError::StageOrder { .. })
    ));
}

#[test]
fn the_mirror_border_folds_indices_back_into_the_frame() {
    assert_eq!(mirror(-1, 8), 1);
    assert_eq!(mirror(-2, 8), 2);
    assert_eq!(mirror(0, 8), 0);
    assert_eq!(mirror(7, 8), 7);
    assert_eq!(mirror(8, 8), 6);
    assert_eq!(mirror(9, 8), 5);
    assert_eq!(mirror(3, 1), 0);
}

#[test]
fn a_render_is_byte_identical_at_every_thread_count() {
    // Both convolution passes and the per-channel recombination run under
    // rayon. A reduction whose split tree followed the pool size would show up
    // here as a last-bit difference.
    let base = synthetic_star_field(96, 96, 3, 0xD3A1);
    let params = json!({ "scaleCount": 4 });
    let reference = rayon::ThreadPoolBuilder::new()
        .num_threads(1)
        .build()
        .expect("a single-threaded pool builds")
        .install(|| DenoiseV1.apply(&base, &params, &OpContext::new()))
        .expect("the single-threaded render succeeds");

    for threads in [2usize, 3, 8, 16] {
        let out = rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .build()
            .expect("the pool builds")
            .install(|| DenoiseV1.apply(&base, &params, &OpContext::new()))
            .unwrap_or_else(|e| panic!("the {threads}-thread render succeeds: {e}"));
        assert_pixels_identical(&out, &reference, &format!("{threads} threads"));
    }
}

#[test]
fn a_preview_level_renders_the_same_scales_over_its_own_pixels() {
    // The wavelet scales are octaves of render-level pixels, so a preview
    // thresholds the noise its own level carries rather than a scaled copy of
    // the full render's.
    let full = synthetic_star_field(96, 80, 3, 75);
    let half = crate::recipe::downsample_2x(&full).expect("the level-1 image builds");
    let preview = OpContext::new().at_level(1);
    let out = DenoiseV1
        .apply(&half, &json!({}), &preview)
        .expect("the preview renders");
    assert_eq!(out.width(), half.width());
    assert_eq!(out.height(), half.height());
    assert_wcs_identical(&out, &half, "the preview keeps the level-1 plate");

    let again = DenoiseV1
        .apply(&half, &json!({}), &preview)
        .expect("the preview renders again");
    assert_pixels_identical(&out, &again, "a repeated preview render");
}
