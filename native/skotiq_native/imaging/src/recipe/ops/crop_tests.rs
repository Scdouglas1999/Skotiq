//! `crop@1`: determinism, the identity rect, the astrometry shift, and the
//! coverage-map proposal.

use std::sync::Arc;

use serde_json::json;

use super::*;
use crate::recipe::ops::background_extract::BackgroundExtractV1;
use crate::recipe::testkit::{
    assert_deterministic, assert_pixels_identical, assert_wcs_identical, synthetic_star_field,
    wcs_header,
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
        .push(RecipeStep::new(CropV1.id(), CropV1.version()).with_params(params));
    recipe
}

/// A frame whose outer `margin` pixels are the registration fill (`0.0`) or
/// `NaN`, and whose interior carries a known level.
fn bordered(width: u32, height: u32, channels: u32, margin: usize, fill: f32) -> OpImage {
    let w = width as usize;
    let h = height as usize;
    let c = channels as usize;
    let mut data = vec![0.0_f32; w * h * c];
    for y in 0..h {
        for x in 0..w {
            let inside = x >= margin && y >= margin && x + margin < w && y + margin < h;
            let value = if inside { 900.0 } else { fill };
            for channel in 0..c {
                data[(y * w + x) * c + channel] = value;
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
    .expect("the bordered frame geometry is consistent")
}

#[test]
fn a_render_is_byte_identical_over_odd_and_even_geometries_and_both_channel_counts() {
    for (width, height, channels) in [(64, 48, 1), (65, 49, 1), (64, 48, 3), (65, 49, 3)] {
        let base = Arc::new(synthetic_star_field(width, height, channels, 303));
        let recipe = recipe_with(json!({
            "x": 5,
            "y": 3,
            "width": width - 11,
            "height": height - 7,
        }));
        let out = assert_deterministic(
            &recipe,
            &base,
            &registry(),
            &OpContext::new(),
            RenderOptions::full(),
        )
        .unwrap_or_else(|e| panic!("{width}x{height}x{channels} renders: {e}"));
        assert_eq!(out.report.steps[0].outcome, StepOutcome::Applied);
        assert_eq!(out.image.width(), width - 11);
        assert_eq!(out.image.height(), height - 7);
        assert_eq!(out.image.channels(), channels);
    }
}

#[test]
fn a_rect_covering_the_whole_frame_is_an_exact_clone() {
    let base = synthetic_star_field(64, 48, 3, 41);
    let out = CropV1
        .apply(
            &base,
            &json!({ "x": 0, "y": 0, "width": 64, "height": 48 }),
            &OpContext::new(),
        )
        .expect("the full rect renders");
    assert_pixels_identical(&out, &base, "full-frame crop");
    assert_wcs_identical(&out, &base, "full-frame crop");
}

#[test]
fn the_cropped_samples_are_the_source_samples() {
    let base = synthetic_star_field(64, 48, 3, 42);
    let (x0, y0, width, height) = (7usize, 5usize, 33usize, 21usize);
    let out = CropV1
        .apply(
            &base,
            &json!({ "x": x0, "y": y0, "width": width, "height": height }),
            &OpContext::new(),
        )
        .expect("the rect renders");

    let channels = base.channels() as usize;
    let source_width = base.width() as usize;
    for y in 0..height {
        for x in 0..width {
            for channel in 0..channels {
                let expected =
                    base.data()[((y + y0) * source_width + (x + x0)) * channels + channel];
                let found = out.data()[(y * width + x) * channels + channel];
                assert_eq!(
                    expected.to_bits(),
                    found.to_bits(),
                    "sample ({x}, {y}, {channel}) comes through verbatim"
                );
            }
        }
    }
}

#[test]
fn the_reference_pixel_moves_by_the_crop_origin_and_the_plate_does_not() {
    let base = synthetic_star_field(64, 48, 3, 43);
    let (x0, y0) = (7.0_f64, 5.0_f64);
    let out = CropV1
        .apply(
            &base,
            &json!({ "x": 7, "y": 5, "width": 33, "height": 21 }),
            &OpContext::new(),
        )
        .expect("the rect renders");

    assert_eq!(
        out.header().get_float("CRPIX1"),
        base.header().get_float("CRPIX1").map(|v| v - x0)
    );
    assert_eq!(
        out.header().get_float("CRPIX2"),
        base.header().get_float("CRPIX2").map(|v| v - y0)
    );
    for key in ["CRVAL1", "CRVAL2", "CD1_1", "CD1_2", "CD2_1", "CD2_2"] {
        assert_eq!(
            out.header().get_float(key),
            base.header().get_float(key),
            "{key} describes the plate, not the framing"
        );
    }
    assert_eq!(out.header().get_int("NAXIS1"), Some(33));
    assert_eq!(out.header().get_int("NAXIS2"), Some(21));
    assert_eq!(out.header().get_int("NAXIS3"), Some(3));
    assert_eq!(out.header().get_string("OBJECT"), Some("M31"));
    assert_eq!(out.header().get_string("FILTER"), Some("L"));
    assert_eq!(
        out.header().get_string("DATE-OBS"),
        Some("2026-08-16T02:11:04")
    );
    assert_eq!(out.header().get_float("EXPTIME"), Some(300.0));

    // The same sky sits under the moved reference pixel: a source pixel and its
    // cropped counterpart project to the same world coordinate.
    let before = base.wcs().expect("the base carries a solution");
    let after = out.wcs().expect("the crop carries a solution");
    let (ra_before, dec_before) = before.pixel_to_world(20.0, 15.0);
    let (ra_after, dec_after) = after.pixel_to_world(20.0 - x0, 15.0 - y0);
    assert!((ra_before - ra_after).abs() < 1e-12);
    assert!((dec_before - dec_after).abs() < 1e-12);
}

#[test]
fn a_preview_level_crops_the_same_region() {
    // Full resolution 64x48 with a rect at (8, 8) sized 32x24; level 1 is the
    // same sky at half the pixels, so the rect halves with it.
    let half = synthetic_star_field(32, 24, 1, 44);
    let out = CropV1
        .apply(
            &half,
            &json!({ "x": 8, "y": 8, "width": 32, "height": 24 }),
            &OpContext::new().at_level(1),
        )
        .expect("the rect renders at level 1");
    assert_eq!(out.width(), 16);
    assert_eq!(out.height(), 12);
    assert_eq!(
        out.header().get_float("CRPIX1"),
        half.header().get_float("CRPIX1").map(|v| v - 4.0)
    );
}

#[test]
fn a_rect_reaching_past_the_frame_is_cropped_to_what_exists() {
    let base = synthetic_star_field(64, 48, 1, 45);
    let out = CropV1
        .apply(
            &base,
            &json!({ "x": 60, "y": 40, "width": 100, "height": 100 }),
            &OpContext::new(),
        )
        .expect("the overhanging rect renders");
    assert_eq!(out.width(), 4);
    assert_eq!(out.height(), 8);
}

#[test]
fn a_clamped_rect_keeps_its_pixels_and_states_the_adjustment() {
    // A recipe written over a 1920x1080 master, replayed over a 64x48 one. The
    // pixels are the determinism contract and do not move; what changes is that
    // the step no longer reports "applied" and nothing else.
    let base = synthetic_star_field(64, 48, 1, 61);
    let applied = CropV1
        .apply_measured(
            &base,
            &json!({ "x": 0, "y": 0, "width": 1920, "height": 1080 }),
            &OpContext::new(),
        )
        .expect("the oversized rect renders");
    assert_eq!(applied.image.width(), 64);
    assert_eq!(applied.image.height(), 48);
    let measured = applied.measurement.expect("the clamp is reported");
    let clamp = &measured["clampedToImage"];
    assert_eq!(clamp["imageWidth"], json!(64));
    assert_eq!(clamp["imageHeight"], json!(48));
    assert_eq!(
        clamp["requested"],
        json!({"x": 0, "y": 0, "width": 1920, "height": 1080})
    );
    assert_eq!(
        clamp["applied"],
        json!({"x": 0, "y": 0, "width": 64, "height": 48})
    );
    assert_eq!(
        clamp["recipeRect"],
        json!({"x": 0, "y": 0, "width": 1920, "height": 1080})
    );
}

#[test]
fn a_rect_that_fits_reports_no_adjustment() {
    // The control the clamped case has to be distinguishable from: an exact
    // rect, and the whole frame, both measure nothing.
    let base = synthetic_star_field(64, 48, 1, 62);
    for params in [
        json!({ "x": 16, "y": 12, "width": 32, "height": 24 }),
        json!({ "x": 0, "y": 0, "width": 64, "height": 48 }),
    ] {
        let applied = CropV1
            .apply_measured(&base, &params, &OpContext::new())
            .expect("the in-fit rect renders");
        assert!(
            applied.measurement.is_none(),
            "a rect that fits describes its result in full: {params}"
        );
    }
}

#[test]
fn the_whole_frame_at_a_preview_level_is_not_reported_as_an_adjustment() {
    // The far edge ceils, so a rect ending exactly on the image can land one
    // pixel past a downsampled level's own size. That single pixel is the
    // rounding the intersection exists for, and calling it an adjustment would
    // put a warning on every preview of a correct recipe.
    let base = synthetic_star_field(33, 25, 1, 63);
    for level in 1..=2 {
        let applied = CropV1
            .apply_measured(
                &base,
                &json!({ "x": 0, "y": 0, "width": 33, "height": 25 }),
                &OpContext::new().at_level(level),
            )
            .expect("the whole-frame rect renders at every level");
        assert!(
            applied.measurement.is_none(),
            "level {level} rounding is not an adjustment"
        );
    }
}

#[test]
fn the_clamp_is_reported_through_the_render_report() {
    // The step-outcome channel is what the badge, the sidecar and the exported
    // HISTORY read, so the measurement has to survive the render, not just the
    // operation.
    let base = Arc::new(synthetic_star_field(64, 48, 1, 64));
    let recipe = recipe_with(json!({ "x": 0, "y": 0, "width": 1920, "height": 1080 }));
    let mut cache = crate::recipe::RenderCache::new(1 << 20);
    let output = crate::recipe::render(
        &recipe,
        &base,
        &registry(),
        &mut cache,
        &OpContext::new(),
        RenderOptions::full(),
    )
    .expect("the clamped recipe renders");
    assert_eq!(output.report.steps[0].outcome, StepOutcome::Applied);
    let measured = output.report.steps[0]
        .measurement
        .as_ref()
        .expect("the render report carries the clamp");
    assert_eq!(measured["clampedToImage"]["applied"]["width"], json!(64));
}

#[test]
fn the_pre_render_fit_answers_what_the_render_would_do() {
    // One intersection, two callers: the warning an editor shows before a render
    // and the rectangle the render produces have to be the same rectangle.
    let fit = crop_fit(
        &json!({ "x": 0, "y": 0, "width": 1920, "height": 1080 }),
        64,
        48,
    )
    .expect("the payload parses");
    assert!(fit.clamped());
    assert!(!fit.origin_outside());
    assert_eq!(
        fit.applied,
        CropRect {
            x: 0,
            y: 0,
            width: 64,
            height: 48
        }
    );
    assert!(fit.statement().contains("does not fit the 64x48 image"));

    let exact = crop_fit(
        &json!({ "x": 16, "y": 12, "width": 32, "height": 24 }),
        64,
        48,
    )
    .expect("the payload parses");
    assert!(!exact.clamped());
    assert!(!exact.origin_outside());

    let outside = crop_fit(&json!({ "x": 64, "y": 0, "width": 8, "height": 8 }), 64, 48)
        .expect("the payload parses");
    assert!(outside.origin_outside());
    assert!(outside.statement().contains("lies outside the 64x48 image"));
}

#[test]
fn an_origin_outside_the_frame_is_reported_rather_than_clamped() {
    let base = synthetic_star_field(64, 48, 1, 46);
    assert!(matches!(
        CropV1.apply(
            &base,
            &json!({ "x": 64, "y": 0, "width": 8, "height": 8 }),
            &OpContext::new()
        ),
        Err(OpError::Failed { op_id: "crop", .. })
    ));
    assert!(matches!(
        CropV1.apply(
            &base,
            &json!({ "x": 0, "y": 48, "width": 8, "height": 8 }),
            &OpContext::new()
        ),
        Err(OpError::Failed { op_id: "crop", .. })
    ));
}

#[test]
fn an_out_of_bounds_report_stays_in_one_coordinate_space() {
    // The rectangle is scaled to the render level before it is applied, but the
    // refusal used to print the recipe's full-resolution origin against the
    // level's dimensions: at level 3 that read as a 5000 px offset checked
    // against a 240 px frame — a 20x overshoot where the real one is 2.6x.
    // The level-3 image the renderer hands the op: the 1920x1080 master
    // downsampled by 8.
    let base = synthetic_star_field(240, 135, 1, 51);
    let params = json!({ "x": 5000, "y": 5000, "width": 100, "height": 100 });

    let reason = match CropV1.apply(&base, &params, &OpContext::new().at_level(3)) {
        Err(OpError::Failed { reason, .. }) => reason,
        other => panic!("an origin off the frame must be refused: {other:?}"),
    };

    // 5000 * 0.125 = 625, against the level-3 image, which is 240x135.
    assert!(
        reason.contains("crop origin (625, 625)") && reason.contains("240x135"),
        "the compared origin and the image must be in the same space: {reason}"
    );
    // The recipe's own numbers stay in the message, labelled as the other space.
    assert!(
        reason.contains("full-resolution origin (5000, 5000)"),
        "the operator's own parameters must still be named: {reason}"
    );
}

#[test]
fn a_raised_cancel_flag_aborts_the_operation() {
    let base = synthetic_star_field(64, 48, 1, 47);
    let ctx = OpContext::new();
    ctx.request_cancel();
    assert!(matches!(
        CropV1.apply(
            &base,
            &json!({ "x": 0, "y": 0, "width": 32, "height": 32 }),
            &ctx
        ),
        Err(OpError::Cancelled)
    ));
}

#[test]
fn an_unknown_parameter_is_rejected() {
    assert_eq!(
        CropV1.validate_params(&json!({ "width": 8, "height": 8, "margin": 2 })),
        Err(OpError::UnknownParam {
            op_id: "crop",
            op_version: 1,
            key: "margin".to_string(),
        })
    );
}

#[test]
fn the_extents_are_required() {
    assert_eq!(
        CropV1.validate_params(&json!({ "x": 4, "y": 4 })),
        Err(OpError::MissingParam {
            op_id: "crop",
            op_version: 1,
            key: "width".to_string(),
        })
    );
    assert_eq!(
        CropV1.validate_params(&json!({ "width": 8 })),
        Err(OpError::MissingParam {
            op_id: "crop",
            op_version: 1,
            key: "height".to_string(),
        })
    );
}

#[test]
fn a_parameter_of_the_wrong_type_is_rejected() {
    assert!(matches!(
        CropV1.validate_params(&json!({ "x": -4, "width": 8, "height": 8 })),
        Err(OpError::ParamType { key, .. }) if key == "x"
    ));
    assert!(matches!(
        CropV1.validate_params(&json!({ "width": "8", "height": 8 })),
        Err(OpError::ParamType { key, .. }) if key == "width"
    ));
}

#[test]
fn a_parameter_outside_its_range_is_rejected() {
    assert!(matches!(
        CropV1.validate_params(&json!({ "width": 0, "height": 8 })),
        Err(OpError::ParamRange { key, .. }) if key == "width"
    ));
    assert!(matches!(
        CropV1.validate_params(&json!({ "width": 8, "height": 2_000_000 })),
        Err(OpError::ParamRange { key, .. }) if key == "height"
    ));
}

#[test]
fn a_payload_that_is_not_an_object_is_rejected() {
    assert_eq!(
        CropV1.validate_params(&json!(null)),
        Err(OpError::ParamsNotObject {
            op_id: "crop",
            op_version: 1,
            found: "null",
        })
    );
}

#[test]
fn the_linear_stage_ops_are_refused_after_the_stretch() {
    // The stage declarations are what the ordering rule reads: a crop or a
    // gradient fit below a stretch would be working on display-domain data.
    let registry = registry();
    assert_eq!(CropV1.stage(), OpStage::Linear);
    assert_eq!(BackgroundExtractV1.stage(), OpStage::Linear);

    let stretch_params = json!({ "blackPoint": 0.0, "whitePoint": 1.0 });
    let mut good = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    good.steps.push(RecipeStep::new("background_extract", 1));
    good.steps
        .push(RecipeStep::new("crop", 1).with_params(json!({ "width": 8, "height": 8 })));
    good.steps
        .push(RecipeStep::new("stretch", 1).with_params(stretch_params.clone()));
    validate(&good, &registry).expect("linear steps above the stretch validate");

    let mut bad = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    bad.steps
        .push(RecipeStep::new("stretch", 1).with_params(stretch_params));
    bad.steps
        .push(RecipeStep::new("crop", 1).with_params(json!({ "width": 8, "height": 8 })));
    assert!(matches!(
        validate(&bad, &registry),
        Err(RecipeError::StageOrder { .. })
    ));
}

#[test]
fn a_fully_covered_frame_proposes_itself() {
    let base = synthetic_star_field(64, 48, 3, 48);
    assert_eq!(
        auto_rect(&base),
        Some(CropRect {
            x: 0,
            y: 0,
            width: 64,
            height: 48,
        })
    );
}

#[test]
fn a_zero_filled_registration_border_is_proposed_away() {
    let base = bordered(64, 48, 1, 3, 0.0);
    assert_eq!(
        auto_rect(&base),
        Some(CropRect {
            x: 3,
            y: 3,
            width: 58,
            height: 42,
        })
    );
}

#[test]
fn a_nan_registration_border_is_proposed_away() {
    let base = bordered(65, 49, 3, 2, f32::NAN);
    assert_eq!(
        auto_rect(&base),
        Some(CropRect {
            x: 2,
            y: 2,
            width: 61,
            height: 45,
        })
    );
}

#[test]
fn an_entirely_uncovered_frame_proposes_nothing() {
    let base = OpImage::new(16, 16, 1, vec![0.0_f32; 256], wcs_header(16, 16, 1))
        .expect("an all-fill frame is a valid image");
    assert_eq!(auto_rect(&base), None);
}

#[test]
fn a_proposed_rect_is_a_valid_payload_that_renders() {
    let base = bordered(64, 48, 1, 4, 0.0);
    let rect = auto_rect(&base).expect("the interior survives");
    CropV1
        .validate_params(&rect.to_params())
        .expect("the proposal is a valid payload");
    let out = CropV1
        .apply(&base, &rect.to_params(), &OpContext::new())
        .expect("the proposal renders");
    assert_eq!(out.width(), rect.width);
    assert_eq!(out.height(), rect.height);
    for value in out.data() {
        assert_eq!(*value, 900.0, "only covered samples survive the proposal");
    }
}
