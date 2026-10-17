//! `star_reduce@1`: determinism, the identity, the byte-identical background,
//! and the reduction the amount actually drives.

use std::sync::Arc;

use serde_json::json;

use super::*;
use crate::recipe::testkit::{
    assert_deterministic, assert_pixels_identical, assert_wcs_identical, synthetic_star_field,
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
        .push(RecipeStep::new(StarReduceV1.id(), StarReduceV1.version()).with_params(params));
    recipe
}

/// A synthetic star field mapped into the display domain, which is what a
/// stretched-stage operation reads.
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

/// The mask the operation builds for one payload, re-derived the same way.
fn mask_for(image: &OpImage, threshold_sigma: f64, dilate: f64) -> Vec<f32> {
    let ctx = OpContext::new();
    let config = StarDetectionConfig {
        detection_sigma: threshold_sigma,
        max_sharpness: 1.0,
        min_area: 3,
        min_hfr: 0.5,
        max_eccentricity: 1.0,
        ..StarDetectionConfig::default()
    };
    let detected = star_detect::detect(image, &config, &ctx).expect("detection runs");
    build_mask(
        &detected,
        image.width() as usize,
        image.height() as usize,
        dilate,
        FEATHER_PX,
        &ctx,
    )
    .expect("the mask builds")
}

/// The brightest sample in one channel, with its pixel index.
fn brightest(image: &OpImage, channel: usize) -> (usize, f32) {
    let channels = image.channels() as usize;
    let mut best = (0usize, f32::NEG_INFINITY);
    for (pixel, value) in image
        .data()
        .iter()
        .skip(channel)
        .step_by(channels)
        .enumerate()
    {
        if *value > best.1 {
            best = (pixel, *value);
        }
    }
    best
}

#[test]
fn a_render_is_byte_identical_over_odd_and_even_geometries_and_both_channel_counts() {
    for (width, height, channels) in [(96, 80, 1), (97, 81, 1), (96, 80, 3), (97, 81, 3)] {
        let base = Arc::new(display_field(width, height, channels, 909));
        let out = assert_deterministic(
            &recipe_with(json!({ "amount": 0.7 })),
            &base,
            &registry(),
            &OpContext::new(),
            RenderOptions::full(),
        )
        .unwrap_or_else(|e| panic!("{width}x{height}x{channels} renders: {e}"));
        assert_eq!(out.report.steps[0].outcome, StepOutcome::Applied);
        assert_eq!(out.image.width(), width);
        assert_eq!(out.image.channels(), channels);
    }
}

#[test]
fn zero_amount_is_an_exact_clone() {
    for channels in [1u32, 3] {
        let base = display_field(96, 80, channels, 91);
        let out = StarReduceV1
            .apply(&base, &json!({ "amount": 0.0 }), &OpContext::new())
            .expect("a zero-amount step renders");
        assert_pixels_identical(&out, &base, "amount 0");
        assert_wcs_identical(&out, &base, "amount 0");
    }
}

#[test]
fn every_sample_outside_the_star_mask_is_byte_identical() {
    let base = display_field(96, 80, 3, 92);
    let out = StarReduceV1
        .apply(&base, &json!({ "amount": 0.8 }), &OpContext::new())
        .expect("the frame renders");
    let mask = mask_for(&base, MASK_THRESHOLD_SIGMA_DEFAULT, MASK_DILATE_DEFAULT);
    assert!(
        mask.iter().any(|&weight| weight > 0.0),
        "the mask must select something, or this test proves nothing"
    );

    let channels = base.channels() as usize;
    for (pixel, &weight) in mask.iter().enumerate() {
        if weight > 0.0 {
            continue;
        }
        for channel in 0..channels {
            let index = pixel * channels + channel;
            assert_eq!(
                out.data()[index].to_bits(),
                base.data()[index].to_bits(),
                "sample {index} sits outside the mask and must be byte-identical"
            );
        }
    }
}

#[test]
fn a_star_peak_falls_and_falls_further_with_a_larger_amount() {
    let base = display_field(96, 80, 1, 93);
    let (pixel, before) = brightest(&base, 0);

    let gentle = StarReduceV1
        .apply(&base, &json!({ "amount": 0.3 }), &OpContext::new())
        .expect("the gentle step renders");
    let aggressive = StarReduceV1
        .apply(&base, &json!({ "amount": 0.9 }), &OpContext::new())
        .expect("the aggressive step renders");

    let gentle_peak = gentle.data()[pixel];
    let aggressive_peak = aggressive.data()[pixel];
    assert!(
        gentle_peak < before,
        "the star peak must fall: {before} -> {gentle_peak}"
    );
    assert!(
        aggressive_peak < gentle_peak,
        "a larger amount must reduce further: {gentle_peak} -> {aggressive_peak}"
    );
}

#[test]
fn a_frame_with_no_detected_star_comes_back_unchanged() {
    // An empty mask leaves every sample on the verbatim path, so a frame the
    // detector finds nothing in is passed through rather than eroded.
    let base = OpImage::new(
        48,
        40,
        1,
        vec![0.25_f32; 48 * 40],
        crate::recipe::testkit::wcs_header(48, 40, 1),
    )
    .expect("the flat frame geometry is consistent");
    let out = StarReduceV1
        .apply(&base, &json!({ "amount": 1.0 }), &OpContext::new())
        .expect("the flat frame renders");
    assert_pixels_identical(&out, &base, "a frame with no star");
}

#[test]
fn the_astrometry_and_the_frame_metadata_survive() {
    let base = display_field(96, 80, 3, 94);
    let out = StarReduceV1
        .apply(&base, &json!({ "amount": 0.6 }), &OpContext::new())
        .expect("the frame renders");
    assert_wcs_identical(&out, &base, "the reduction keeps the plate");
    assert_eq!(out.header().get_string("OBJECT"), Some("M31"));
    assert_eq!(out.header().get_string("FILTER"), Some("L"));
    assert_eq!(
        out.header().get_string("DATE-OBS"),
        Some("2026-08-16T02:11:04")
    );
    assert_eq!(out.header().get_float("EXPTIME"), Some(300.0));
    assert_eq!(out.header().get_int("NAXIS1"), Some(96));
}

#[test]
fn a_raised_cancel_flag_aborts_the_operation() {
    let base = display_field(96, 80, 3, 95);
    let ctx = OpContext::new();
    ctx.request_cancel();
    assert_eq!(
        StarReduceV1
            .apply(&base, &json!({ "amount": 0.5 }), &ctx)
            .unwrap_err(),
        OpError::Cancelled
    );
}

#[test]
fn an_unknown_parameter_is_rejected() {
    assert_eq!(
        StarReduceV1.validate_params(&json!({ "strength": 0.5 })),
        Err(OpError::UnknownParam {
            op_id: "star_reduce",
            op_version: 1,
            key: "strength".to_string(),
        })
    );
}

#[test]
fn a_parameter_of_the_wrong_type_is_rejected() {
    assert!(matches!(
        StarReduceV1.validate_params(&json!({ "amount": "0.5" })),
        Err(OpError::ParamType { key, .. }) if key == "amount"
    ));
}

#[test]
fn a_parameter_outside_its_range_is_rejected() {
    assert!(matches!(
        StarReduceV1.validate_params(&json!({ "amount": 1.5 })),
        Err(OpError::ParamRange { key, .. }) if key == "amount"
    ));
    assert!(matches!(
        StarReduceV1.validate_params(&json!({ "maskThresholdSigma": 0.5 })),
        Err(OpError::ParamRange { key, .. }) if key == "maskThresholdSigma"
    ));
    assert!(matches!(
        StarReduceV1.validate_params(&json!({ "maskDilatePx": 64.0 })),
        Err(OpError::ParamRange { key, .. }) if key == "maskDilatePx"
    ));
}

#[test]
fn a_payload_that_is_not_an_object_is_rejected() {
    assert_eq!(
        StarReduceV1.validate_params(&json!("amount")),
        Err(OpError::ParamsNotObject {
            op_id: "star_reduce",
            op_version: 1,
            found: "a string",
        })
    );
}

#[test]
fn the_operation_emits_stretched_data_and_a_linear_step_may_not_follow_it() {
    assert_eq!(StarReduceV1.stage(), OpStage::Stretched);
    let registry = registry();
    let stretch_params = json!({ "blackPoint": 0.0, "whitePoint": 1.0 });

    let mut good = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    good.steps
        .push(RecipeStep::new("stretch", 1).with_params(stretch_params));
    good.steps.push(RecipeStep::new("star_reduce", 1));
    good.steps.push(RecipeStep::new("saturation", 1));
    validate(&good, &registry).expect("a reduction after the stretch validates");

    let mut bad = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    bad.steps.push(RecipeStep::new("star_reduce", 1));
    bad.steps.push(RecipeStep::new("denoise", 1));
    assert!(matches!(
        validate(&bad, &registry),
        Err(RecipeError::StageOrder { .. })
    ));
}

#[test]
fn the_feather_falls_from_one_to_zero_across_its_ring() {
    assert_eq!(disk_weight(0.0, 3.0, 6.0), 1.0);
    assert_eq!(disk_weight(3.0, 3.0, 6.0), 1.0);
    assert_eq!(disk_weight(6.0, 3.0, 6.0), 0.0);
    assert_eq!(disk_weight(9.0, 3.0, 6.0), 0.0);
    assert!((disk_weight(4.5, 3.0, 6.0) - 0.5).abs() < 1e-6);
    assert!(disk_weight(3.5, 3.0, 6.0) > disk_weight(5.5, 3.0, 6.0));
    assert_eq!(disk_weight(4.0, 3.0, 3.0), 0.0);
}

#[test]
fn the_erosion_shrinks_a_bright_blob_from_its_edge() {
    let width = 11usize;
    let height = 11usize;
    let mut plane = vec![100.0_f64; width * height];
    for y in 3..=7 {
        for x in 3..=7 {
            plane[y * width + x] = 5000.0;
        }
    }
    let eroded = erode(&plane, width, height, 1, &OpContext::new()).expect("the erosion runs");
    assert_eq!(eroded[5 * width + 3], 100.0, "an edge sample erodes away");
    assert_eq!(eroded[5 * width + 5], 5000.0, "the interior stays");
}

#[test]
fn a_render_is_byte_identical_at_every_thread_count() {
    // Star detection, the mask union, the erosion and the composite all run
    // under rayon. A reduction whose split tree followed the pool size would
    // show up here as a last-bit difference.
    let base = display_field(96, 80, 3, 0x0005_7EAD);
    let params = json!({ "amount": 0.7 });
    let reference = rayon::ThreadPoolBuilder::new()
        .num_threads(1)
        .build()
        .expect("a single-threaded pool builds")
        .install(|| StarReduceV1.apply(&base, &params, &OpContext::new()))
        .expect("the single-threaded render succeeds");

    for threads in [2usize, 3, 8, 16] {
        let out = rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .build()
            .expect("the pool builds")
            .install(|| StarReduceV1.apply(&base, &params, &OpContext::new()))
            .unwrap_or_else(|e| panic!("the {threads}-thread render succeeds: {e}"));
        assert_pixels_identical(&out, &reference, &format!("{threads} threads"));
    }
}

#[test]
fn a_preview_level_scales_the_pixel_parameters_with_it() {
    // The mask dilation, the feather and the erosion radius are in pixels at
    // full resolution, so a preview over a downsampled level has to shrink them
    // or it would reduce a region twice the size the full render does.
    let full = display_field(96, 80, 3, 96);
    let half = crate::recipe::downsample_2x(&full).expect("the level-1 image builds");
    let preview = OpContext::new().at_level(1);
    let out = StarReduceV1
        .apply(&half, &json!({ "amount": 0.7 }), &preview)
        .expect("the preview renders");
    assert_eq!(out.width(), half.width());
    assert_eq!(out.height(), half.height());
    assert_wcs_identical(&out, &half, "the preview keeps the level-1 plate");

    let mask = mask_for(
        &half,
        MASK_THRESHOLD_SIGMA_DEFAULT,
        MASK_DILATE_DEFAULT * preview.scale(),
    );
    let channels = half.channels() as usize;
    for (pixel, &weight) in mask.iter().enumerate() {
        if weight > 0.0 {
            continue;
        }
        for channel in 0..channels {
            let index = pixel * channels + channel;
            assert_eq!(
                out.data()[index].to_bits(),
                half.data()[index].to_bits(),
                "preview sample {index} sits outside the mask and must be byte-identical"
            );
        }
    }
}
