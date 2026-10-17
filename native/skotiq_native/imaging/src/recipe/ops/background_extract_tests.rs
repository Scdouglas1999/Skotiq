//! `background_extract@1`: determinism, the identity order, what the fit does
//! not touch, and the flux-scale contract.

use std::sync::Arc;

use serde_json::json;

use super::*;
use crate::fits::FitsHeader;
use crate::recipe::testkit::{
    assert_deterministic, assert_pixels_identical, assert_wcs_identical, synthetic_star_field,
    wcs_header, Lcg,
};
use crate::recipe::{OpRegistry, Recipe, RecipeAuthor, RecipeStep, RenderOptions, StepOutcome};

/// The registry this build ships, which carries the operation under test.
fn registry() -> OpRegistry {
    OpRegistry::builtin().expect("the builtin list registers cleanly")
}

/// A one-step recipe over the operation under test.
fn recipe_with(params: Value) -> Recipe {
    let mut recipe = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    recipe.steps.push(
        RecipeStep::new(BackgroundExtractV1.id(), BackgroundExtractV1.version())
            .with_params(params),
    );
    recipe
}

/// A frame with a known linear ramp across x on a known sky pedestal, plus
/// reproducible noise. No stars, so the fit sees only the gradient.
fn ramped_sky(width: u32, height: u32, channels: u32, pedestal: f64, ramp: f64) -> OpImage {
    let w = width as usize;
    let h = height as usize;
    let c = channels as usize;
    let mut rng = Lcg::new(7);
    let mut data = vec![0.0_f32; w * h * c];
    for y in 0..h {
        for x in 0..w {
            let level = pedestal + ramp * (x as f64 / (w as f64 - 1.0));
            for channel in 0..c {
                let noise = (rng.next_unit() - 0.5) * 4.0;
                data[(y * w + x) * c + channel] = (level + noise) as f32;
            }
        }
    }
    OpImage::new(
        width,
        height,
        channels,
        data,
        wcs_header(width, height, channels),
    )
    .expect("the ramped sky geometry is consistent")
}

/// Mean of every sample.
fn mean(image: &OpImage) -> f64 {
    image.data().iter().map(|v| *v as f64).sum::<f64>() / image.len() as f64
}

/// Spread of the per-column means: how much gradient is left across x.
fn column_mean_spread(image: &OpImage) -> f64 {
    let width = image.width() as usize;
    let height = image.height() as usize;
    let channels = image.channels() as usize;
    let mut lowest = f64::INFINITY;
    let mut highest = f64::NEG_INFINITY;
    for x in 0..width {
        let mut total = 0.0;
        for y in 0..height {
            for channel in 0..channels {
                total += image.data()[(y * width + x) * channels + channel] as f64;
            }
        }
        let column = total / (height * channels) as f64;
        lowest = lowest.min(column);
        highest = highest.max(column);
    }
    highest - lowest
}

#[test]
fn a_render_is_byte_identical_over_odd_and_even_geometries_and_both_channel_counts() {
    for (width, height, channels) in [(64, 48, 1), (65, 49, 1), (64, 48, 3), (65, 49, 3)] {
        let base = Arc::new(synthetic_star_field(width, height, channels, 909));
        let recipe = recipe_with(json!({ "modelOrder": 1 }));
        let out = assert_deterministic(
            &recipe,
            &base,
            &registry(),
            &OpContext::new(),
            RenderOptions::full(),
        )
        .unwrap_or_else(|e| panic!("{width}x{height}x{channels} renders: {e}"));
        assert_eq!(
            out.report.steps[0].outcome,
            StepOutcome::Applied,
            "{width}x{height}x{channels}: the step ran"
        );
    }
}

#[test]
fn a_render_is_byte_identical_at_every_thread_count() {
    // The fit reaches star detection, a per-box median lattice and a per-row
    // subtraction, all of which run under rayon. A reduction whose split tree
    // followed the pool size would show up here as a last-bit difference.
    let base = synthetic_star_field(96, 96, 3, 1301);
    let params = json!({ "modelOrder": 2 });
    let reference = rayon::ThreadPoolBuilder::new()
        .num_threads(1)
        .build()
        .expect("a single-threaded pool builds")
        .install(|| BackgroundExtractV1.apply(&base, &params, &OpContext::new()))
        .expect("the single-threaded render succeeds");

    for threads in [2usize, 3, 8, 16] {
        let out = rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .build()
            .expect("the pool builds")
            .install(|| BackgroundExtractV1.apply(&base, &params, &OpContext::new()))
            .unwrap_or_else(|e| panic!("the {threads}-thread render succeeds: {e}"));
        assert_pixels_identical(&out, &reference, &format!("{threads} threads"));
    }
}

#[test]
fn the_default_parameters_render_deterministically() {
    let base = Arc::new(synthetic_star_field(96, 96, 1, 4242));
    let recipe = recipe_with(json!({}));
    assert_deterministic(
        &recipe,
        &base,
        &registry(),
        &OpContext::new(),
        RenderOptions::full(),
    )
    .expect("the default parameters render");
}

#[test]
fn model_order_zero_is_an_exact_clone() {
    let base = synthetic_star_field(64, 48, 3, 31);
    let out = BackgroundExtractV1
        .apply(&base, &json!({ "modelOrder": 0 }), &OpContext::new())
        .expect("a constant surface renders");
    assert_pixels_identical(&out, &base, "modelOrder 0");
    assert_wcs_identical(&out, &base, "modelOrder 0");
}

#[test]
fn a_gradient_leaves_the_frame_and_the_sky_pedestal_stays() {
    let base = ramped_sky(96, 72, 1, 800.0, 300.0);
    let before_spread = column_mean_spread(&base);
    let before_mean = mean(&base);
    assert!(
        before_spread > 250.0,
        "the test frame carries a gradient: {before_spread}"
    );

    let out = BackgroundExtractV1
        .apply(&base, &json!({ "modelOrder": 1 }), &OpContext::new())
        .expect("the ramp is fitted");

    let after_spread = column_mean_spread(&out);
    assert!(
        after_spread < before_spread * 0.02,
        "the gradient is removed: {before_spread} -> {after_spread}"
    );
    let after_mean = mean(&out);
    assert!(
        (after_mean - before_mean).abs() < 5.0,
        "the sky pedestal survives: {before_mean} -> {after_mean}"
    );
    assert!(
        after_mean > 700.0,
        "the frame is not flattened to zero: {after_mean}"
    );
}

#[test]
fn channels_are_fitted_independently_and_never_bleed_into_each_other() {
    let source = synthetic_star_field(64, 48, 3, 77);
    let width = source.width() as usize;
    let height = source.height() as usize;
    let mut data = source.data().to_vec();
    // Make channels 1 and 2 identical and leave channel 0 different, so an
    // output difference between 1 and 2 could only come from cross-channel
    // contamination.
    for pixel in 0..width * height {
        data[pixel * 3 + 2] = data[pixel * 3 + 1];
    }
    let base = source
        .with_data(data)
        .expect("the twinned frame keeps its geometry");

    let out = BackgroundExtractV1
        .apply(&base, &json!({ "modelOrder": 1 }), &OpContext::new())
        .expect("the twinned frame renders");

    for pixel in 0..width * height {
        assert_eq!(
            out.data()[pixel * 3 + 1].to_bits(),
            out.data()[pixel * 3 + 2].to_bits(),
            "pixel {pixel}: identical input channels render identically"
        );
    }
}

#[test]
fn the_astrometry_and_the_session_keywords_survive() {
    let base = synthetic_star_field(64, 48, 1, 5);
    let out = BackgroundExtractV1
        .apply(&base, &json!({ "modelOrder": 1 }), &OpContext::new())
        .expect("the frame renders");

    assert_wcs_identical(&out, &base, "background extraction");
    assert_eq!(out.width(), base.width());
    assert_eq!(out.height(), base.height());
    assert_eq!(out.header().get_string("OBJECT"), Some("M31"));
    assert_eq!(out.header().get_string("FILTER"), Some("L"));
    assert_eq!(
        out.header().get_string("DATE-OBS"),
        Some("2026-08-16T02:11:04")
    );
    assert_eq!(out.header().get_float("EXPTIME"), Some(300.0));
    assert!(out.wcs().is_some(), "the solution still reads back");
}

#[test]
fn a_raised_cancel_flag_aborts_the_operation() {
    let base = synthetic_star_field(64, 48, 1, 6);
    let ctx = OpContext::new();
    ctx.request_cancel();
    assert!(matches!(
        BackgroundExtractV1.apply(&base, &json!({}), &ctx),
        Err(OpError::Cancelled)
    ));
}

#[test]
fn an_unknown_parameter_is_rejected() {
    assert_eq!(
        BackgroundExtractV1.validate_params(&json!({ "gridSpacing": 32 })),
        Err(OpError::UnknownParam {
            op_id: "background_extract",
            op_version: 1,
            key: "gridSpacing".to_string(),
        })
    );
}

#[test]
fn a_parameter_of_the_wrong_type_is_rejected() {
    assert!(matches!(
        BackgroundExtractV1.validate_params(&json!({ "modelOrder": "two" })),
        Err(OpError::ParamType { key, .. }) if key == "modelOrder"
    ));
    assert!(matches!(
        BackgroundExtractV1.validate_params(&json!({ "sampleSpacing": true })),
        Err(OpError::ParamType { key, .. }) if key == "sampleSpacing"
    ));
}

#[test]
fn a_parameter_outside_its_range_is_rejected() {
    assert!(matches!(
        BackgroundExtractV1.validate_params(&json!({ "modelOrder": 7 })),
        Err(OpError::ParamRange { key, .. }) if key == "modelOrder"
    ));
    assert!(matches!(
        BackgroundExtractV1.validate_params(&json!({ "sampleSpacing": 4.0 })),
        Err(OpError::ParamRange { key, .. }) if key == "sampleSpacing"
    ));
    assert!(matches!(
        BackgroundExtractV1.validate_params(&json!({ "exclusionPercentile": 1.5 })),
        Err(OpError::ParamRange { key, .. }) if key == "exclusionPercentile"
    ));
}

#[test]
fn a_payload_that_is_not_an_object_is_rejected() {
    assert_eq!(
        BackgroundExtractV1.validate_params(&json!([1, 2])),
        Err(OpError::ParamsNotObject {
            op_id: "background_extract",
            op_version: 1,
            found: "an array",
        })
    );
}

#[test]
fn a_surface_the_samples_cannot_determine_is_reported_rather_than_fitted() {
    // Six boxes per axis is 36 samples; a degree-6 surface needs 28 terms and
    // the exclusion quantile alone removes more than the margin.
    let base = synthetic_star_field(64, 48, 1, 8);
    assert!(matches!(
        BackgroundExtractV1.apply(&base, &json!({ "modelOrder": 6 }), &OpContext::new()),
        Err(OpError::Failed {
            op_id: "background_extract",
            ..
        })
    ));
}

#[test]
fn a_field_too_crowded_for_the_lattice_is_reported_and_a_denser_lattice_rescues_it() {
    // A star every 17 pixels puts every default-spacing box inside a masked
    // disk. The operation says so instead of fitting a surface through stars,
    // and a denser lattice — smaller boxes, more of them — finds the sky
    // between them.
    let base = synthetic_star_field(240, 240, 1, 9);
    let crowded = BackgroundExtractV1.apply(&base, &json!({}), &OpContext::new());
    let Err(OpError::Failed { reason, .. }) = crowded else {
        panic!("a fully masked lattice is reported, not fitted");
    };
    assert!(
        reason.contains("star masking") && reason.contains("sampleSpacing"),
        "the reason names the stage and the lever: {reason}"
    );

    BackgroundExtractV1
        .apply(&base, &json!({ "sampleSpacing": 8.0 }), &OpContext::new())
        .expect("a denser lattice finds sky between the stars");
}

#[test]
fn the_sample_lattice_is_the_same_at_every_preview_level() {
    // Halving the frame and the spacing together lays the same lattice over the
    // same sky, which is what makes a preview look like the full render.
    assert_eq!(grid_for(1000, 800, 64.0), grid_for(500, 400, 32.0));
    assert_eq!(grid_for(1000, 800, 64.0), grid_for(250, 200, 16.0));
}

#[test]
fn an_empty_header_still_renders() {
    let base = OpImage::new(32, 32, 1, vec![1000.0_f32; 32 * 32], FitsHeader::new())
        .expect("a flat frame is a valid image");
    let out = BackgroundExtractV1
        .apply(&base, &json!({ "modelOrder": 0 }), &OpContext::new())
        .expect("a frame with no astrometry renders");
    assert_pixels_identical(&out, &base, "flat frame, constant surface");
}
