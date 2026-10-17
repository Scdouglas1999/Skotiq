//! `stretch@1`: the transfer function against its closed forms, the identity
//! order, and the auto-parameter formula.

use std::sync::Arc;

use serde_json::json;

use super::*;
use crate::recipe::testkit::{
    assert_deterministic, assert_pixels_identical, assert_wcs_identical, synthetic_star_field,
};
use crate::recipe::{OpRegistry, Recipe, RecipeAuthor, RecipeStep, RenderOptions, StepOutcome};

/// Agreement demanded of the closed forms, in `f64`.
const ANALYTIC_TOLERANCE: f64 = 1e-12;

/// The registry this build ships, which carries the operation under test.
fn registry() -> OpRegistry {
    OpRegistry::builtin().expect("the builtin list registers cleanly")
}

/// A one-step recipe over the operation under test.
fn recipe_with(params: Value) -> Recipe {
    let mut recipe = Recipe::new("rec", "master-1", RecipeAuthor::Autopilot);
    recipe
        .steps
        .push(RecipeStep::new(StretchV1.id(), StretchV1.version()).with_params(params));
    recipe
}

/// `image` with every sample mapped onto `[0, 1]` by its own extremes, so the
/// black-point/white-point pair `(0, 1)` is an exact affine identity.
fn unit_scaled(image: &OpImage) -> OpImage {
    let mut lowest = f64::INFINITY;
    let mut highest = f64::NEG_INFINITY;
    for value in image.data() {
        lowest = lowest.min(*value as f64);
        highest = highest.max(*value as f64);
    }
    let span = highest - lowest;
    let scaled: Vec<f32> = image
        .data()
        .iter()
        .map(|value| (((*value as f64 - lowest) / span) as f32).clamp(0.0, 1.0))
        .collect();
    image
        .with_data(scaled)
        .expect("rescaling keeps the geometry")
}

/// Value at fractional rank `q` of a sorted copy of the samples.
fn sample_quantile(image: &OpImage, q: f64) -> f64 {
    let mut values: Vec<f64> = image.data().iter().map(|v| *v as f64).collect();
    values.sort_unstable_by(f64::total_cmp);
    percentile_nearest_rank(&values, q)
}

#[test]
fn the_hyperbolic_family_matches_its_closed_form() {
    // b = 1, SP = 0 integrates to arm(t) = t / (1 + D·t), which normalises to
    // Y(x) = x·(1 + D) / (1 + D·x).
    for d in [0.25_f64, 1.0, 4.0, 37.5] {
        let curve = Curve::new(d, 1.0, 0.0);
        for step in 0..=20 {
            let x = step as f64 / 20.0;
            let expected = x * (1.0 + d) / (1.0 + d * x);
            assert!(
                (curve.eval(x) - expected).abs() < ANALYTIC_TOLERANCE,
                "D={d} x={x}: {} vs {expected}",
                curve.eval(x)
            );
        }
    }
}

#[test]
fn the_exponential_family_matches_its_closed_form() {
    // b = 0, SP = 0 integrates to arm(t) = (1 − e^{−D·t}) / D, which normalises
    // to Y(x) = (1 − e^{−D·x}) / (1 − e^{−D}).
    for d in [0.5_f64, 2.0, 9.0] {
        let curve = Curve::new(d, 0.0, 0.0);
        for step in 0..=20 {
            let x = step as f64 / 20.0;
            let expected = (1.0 - (-d * x).exp()) / (1.0 - (-d).exp());
            assert!(
                (curve.eval(x) - expected).abs() < ANALYTIC_TOLERANCE,
                "D={d} x={x}: {} vs {expected}",
                curve.eval(x)
            );
        }
    }
}

#[test]
fn the_square_root_family_matches_its_closed_form() {
    // b = 2, SP = 0 gives arm(t) = (1 − (1 + 2·D·t)^{−1/2}) / D.
    for d in [0.75_f64, 3.0] {
        let curve = Curve::new(d, 2.0, 0.0);
        for step in 0..=20 {
            let x = step as f64 / 20.0;
            let numerator = 1.0 - (1.0 + 2.0 * d * x).powf(-0.5);
            let denominator = 1.0 - (1.0 + 2.0 * d).powf(-0.5);
            let expected = numerator / denominator;
            assert!(
                (curve.eval(x) - expected).abs() < ANALYTIC_TOLERANCE,
                "D={d} x={x}: {} vs {expected}",
                curve.eval(x)
            );
        }
    }
}

#[test]
fn the_transfer_pins_both_endpoints_and_rises_monotonically() {
    for d in [0.0_f64, 0.5, 3.0, 25.0, 100.0] {
        for b in [-5.0_f64, -1.0, 0.0, 1.0, 6.0, 15.0] {
            for symmetry in [0.0_f64, 0.25, 0.5, 1.0] {
                let curve = Curve::new(d, b, symmetry);
                assert!(
                    curve.eval(0.0).abs() < ANALYTIC_TOLERANCE,
                    "D={d} b={b} SP={symmetry}: black stays at 0"
                );
                assert!(
                    (curve.eval(1.0) - 1.0).abs() < ANALYTIC_TOLERANCE,
                    "D={d} b={b} SP={symmetry}: white stays at 1"
                );
                let mut previous = f64::NEG_INFINITY;
                for step in 0..=100 {
                    let y = curve.eval(step as f64 / 100.0);
                    assert!(
                        y >= previous - ANALYTIC_TOLERANCE,
                        "D={d} b={b} SP={symmetry}: the curve never falls"
                    );
                    assert!(
                        (-ANALYTIC_TOLERANCE..=1.0 + ANALYTIC_TOLERANCE).contains(&y),
                        "D={d} b={b} SP={symmetry}: the curve stays inside [0, 1]"
                    );
                    previous = y;
                }
            }
        }
    }
}

#[test]
fn a_central_symmetry_point_gives_a_curve_symmetric_about_the_midpoint() {
    for (d, b) in [(2.0_f64, 0.0_f64), (5.0, 1.0), (1.5, -2.0)] {
        let curve = Curve::new(d, b, 0.5);
        assert!(
            (curve.eval(0.5) - 0.5).abs() < ANALYTIC_TOLERANCE,
            "D={d} b={b}: the symmetry point maps to the midpoint"
        );
        for step in 1..=10 {
            let offset = step as f64 / 20.0;
            let sum = curve.eval(0.5 + offset) + curve.eval(0.5 - offset);
            assert!(
                (sum - 1.0).abs() < ANALYTIC_TOLERANCE,
                "D={d} b={b} offset={offset}: the two arms mirror"
            );
        }
    }
}

#[test]
fn the_exponential_form_is_the_limit_of_the_power_form() {
    let exponential = Curve::new(3.0, 0.0, 0.2);
    let nearly = Curve::new(3.0, 1e-6, 0.2);
    for step in 0..=20 {
        let x = step as f64 / 20.0;
        assert!(
            (exponential.eval(x) - nearly.eval(x)).abs() < 1e-6,
            "x={x}: the b -> 0 limit is continuous"
        );
    }
}

#[test]
fn a_negative_local_intensity_saturates_at_a_finite_distance() {
    // b = -2, D = 5: the arm reaches its ceiling at t = 1 / (|b|·D) = 0.1.
    let curve = Curve::new(5.0, -2.0, 0.0);
    let at_saturation = curve.eval(0.1);
    assert!((at_saturation - 1.0).abs() < ANALYTIC_TOLERANCE);
    assert!((curve.eval(0.5) - 1.0).abs() < ANALYTIC_TOLERANCE);
    assert!(curve.eval(0.05) < 1.0);
}

#[test]
fn zero_intensity_over_the_unit_range_is_an_exact_clone() {
    let base = unit_scaled(&synthetic_star_field(64, 48, 3, 17));
    let out = StretchV1
        .apply(
            &base,
            &json!({ "blackPoint": 0.0, "whitePoint": 1.0, "d": 0.0 }),
            &OpContext::new(),
        )
        .expect("the identity transfer renders");
    assert_pixels_identical(&out, &base, "D = 0 over [0, 1]");
    assert_wcs_identical(&out, &base, "D = 0 over [0, 1]");
}

#[test]
fn a_render_is_byte_identical_over_odd_and_even_geometries_and_both_channel_counts() {
    for (width, height, channels) in [(64, 48, 1), (65, 49, 1), (64, 48, 3), (65, 49, 3)] {
        let base = Arc::new(synthetic_star_field(width, height, channels, 606));
        let recipe = recipe_with(json!({
            "blackPoint": 700.0,
            "whitePoint": 5000.0,
            "d": 3.0,
            "b": 1.5,
            "symmetryPoint": 0.1,
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
        for value in out.image.data() {
            assert!(
                (0.0..=1.0).contains(value),
                "{width}x{height}x{channels}: the stretched sample {value} stays in [0, 1]"
            );
        }
    }
}

#[test]
fn the_operation_emits_the_stretched_stage() {
    assert_eq!(StretchV1.stage(), OpStage::Stretched);
}

#[test]
fn the_astrometry_and_the_session_keywords_survive() {
    let base = synthetic_star_field(64, 48, 1, 19);
    let out = StretchV1
        .apply(
            &base,
            &json!({ "blackPoint": 700.0, "whitePoint": 5000.0 }),
            &OpContext::new(),
        )
        .expect("the frame renders");
    assert_wcs_identical(&out, &base, "stretch");
    assert_eq!(out.header().get_string("OBJECT"), Some("M31"));
    assert_eq!(out.header().get_string("FILTER"), Some("L"));
    assert_eq!(
        out.header().get_string("DATE-OBS"),
        Some("2026-08-16T02:11:04")
    );
    assert_eq!(out.header().get_float("EXPTIME"), Some(300.0));
}

#[test]
fn a_raised_cancel_flag_aborts_the_operation() {
    let base = synthetic_star_field(64, 48, 1, 20);
    let ctx = OpContext::new();
    ctx.request_cancel();
    assert!(matches!(
        StretchV1.apply(
            &base,
            &json!({ "blackPoint": 0.0, "whitePoint": 1.0 }),
            &ctx
        ),
        Err(OpError::Cancelled)
    ));
}

#[test]
fn an_unknown_parameter_is_rejected() {
    assert_eq!(
        StretchV1.validate_params(&json!({
            "blackPoint": 0.0,
            "whitePoint": 1.0,
            "shadowProtection": 0.1,
        })),
        Err(OpError::UnknownParam {
            op_id: "stretch",
            op_version: 1,
            key: "shadowProtection".to_string(),
        })
    );
}

#[test]
fn the_normalisation_points_are_required() {
    assert_eq!(
        StretchV1.validate_params(&json!({ "d": 2.0 })),
        Err(OpError::MissingParam {
            op_id: "stretch",
            op_version: 1,
            key: "blackPoint".to_string(),
        })
    );
    assert_eq!(
        StretchV1.validate_params(&json!({ "blackPoint": 0.0 })),
        Err(OpError::MissingParam {
            op_id: "stretch",
            op_version: 1,
            key: "whitePoint".to_string(),
        })
    );
}

#[test]
fn a_parameter_of_the_wrong_type_is_rejected() {
    assert!(matches!(
        StretchV1.validate_params(&json!({ "blackPoint": "zero", "whitePoint": 1.0 })),
        Err(OpError::ParamType { key, .. }) if key == "blackPoint"
    ));
}

#[test]
fn a_parameter_outside_its_range_is_rejected() {
    assert!(matches!(
        StretchV1.validate_params(&json!({ "blackPoint": 0.0, "whitePoint": 1.0, "d": 101.0 })),
        Err(OpError::ParamRange { key, .. }) if key == "d"
    ));
    assert!(matches!(
        StretchV1.validate_params(&json!({ "blackPoint": 0.0, "whitePoint": 1.0, "b": -6.0 })),
        Err(OpError::ParamRange { key, .. }) if key == "b"
    ));
    assert!(matches!(
        StretchV1.validate_params(
            &json!({ "blackPoint": 0.0, "whitePoint": 1.0, "symmetryPoint": 1.5 })
        ),
        Err(OpError::ParamRange { key, .. }) if key == "symmetryPoint"
    ));
}

#[test]
fn a_white_point_at_or_below_the_black_point_is_rejected() {
    assert!(matches!(
        StretchV1.validate_params(&json!({ "blackPoint": 500.0, "whitePoint": 500.0 })),
        Err(OpError::ParamRange { key, .. }) if key == "whitePoint"
    ));
    assert!(matches!(
        StretchV1.validate_params(&json!({ "blackPoint": 500.0, "whitePoint": 100.0 })),
        Err(OpError::ParamRange { key, .. }) if key == "whitePoint"
    ));
}

#[test]
fn a_payload_that_is_not_an_object_is_rejected() {
    assert_eq!(
        StretchV1.validate_params(&json!("auto")),
        Err(OpError::ParamsNotObject {
            op_id: "stretch",
            op_version: 1,
            found: "a string",
        })
    );
}

#[test]
fn auto_parameters_lift_the_measured_background_to_the_target() {
    let base = synthetic_star_field(96, 96, 1, 55);
    let auto = auto_params(&base).expect("the frame has a measurable background");
    assert_eq!(auto.b, 0.0);
    assert_eq!(auto.symmetry_point, 0.0);
    assert!(auto.white_point > auto.black_point);
    assert!(auto.d > 0.0);

    StretchV1
        .validate_params(&auto.to_params())
        .expect("the auto parameters are a valid payload");
    let out = StretchV1
        .apply(&base, &auto.to_params(), &OpContext::new())
        .expect("the auto parameters render");

    let background = sample_quantile(&out, 0.5);
    assert!(
        (background - AUTO_TARGET_BACKGROUND).abs() < 1e-3,
        "the background lands on the target: {background}"
    );
}

#[test]
fn auto_parameters_are_reported_rather_than_invented_for_an_unmeasurable_frame() {
    let flat = OpImage::new(
        16,
        16,
        1,
        vec![1234.0_f32; 256],
        crate::fits::FitsHeader::new(),
    )
    .expect("a flat frame is a valid image");
    assert!(matches!(
        auto_params(&flat),
        Err(OpError::Failed {
            op_id: "stretch",
            ..
        })
    ));
}
