//! `scnr@1`: the identity, PixInsight's two neutral references, lightness
//! preservation, and the channel gate.

use serde_json::json;

use super::*;
use crate::color_composite::test_scene::mono;

fn pixels(values: &[[f32; 3]]) -> OpImage {
    let header = mono(1, 1, vec![0.0], "L").header().clone();
    let data: Vec<f32> = values.iter().flatten().copied().collect();
    OpImage::new(values.len() as u32, 1, 3, data, header).expect("image")
}

fn run(values: &[[f32; 3]], params: serde_json::Value) -> Vec<[f32; 3]> {
    let out = ScnrV1
        .apply(&pixels(values), &params, &OpContext::new())
        .expect("apply");
    out.data().chunks(3).map(|c| [c[0], c[1], c[2]]).collect()
}

#[test]
fn green_is_limited_to_the_average_of_red_and_blue() {
    let out = run(
        &[[100.0, 300.0, 200.0], [100.0, 120.0, 300.0]],
        json!({"preserveLightness": false}),
    );
    assert_eq!(out[0], [100.0, 150.0, 200.0]);
    // Green already below the neutral reference is left alone.
    assert_eq!(out[1], [100.0, 120.0, 300.0]);
}

#[test]
fn maximum_neutral_limits_green_to_the_larger_of_red_and_blue() {
    let out = run(
        &[[100.0, 300.0, 200.0]],
        json!({"neutral": "maximum", "preserveLightness": false}),
    );
    assert_eq!(out[0], [100.0, 200.0, 200.0]);
}

#[test]
fn amount_blends_toward_the_reference_and_zero_is_the_identity() {
    let half = run(
        &[[100.0, 300.0, 200.0]],
        json!({"amount": 0.5, "preserveLightness": false}),
    );
    assert_eq!(half[0], [100.0, 225.0, 200.0]);
    let none = run(&[[100.0, 300.0, 200.0]], json!({"amount": 0.0}));
    assert_eq!(none[0], [100.0, 300.0, 200.0]);
}

#[test]
fn lightness_is_preserved_by_default() {
    let out = run(&[[100.0, 300.0, 200.0]], json!({}));
    let mean = out[0].iter().map(|v| *v as f64).sum::<f64>() / 3.0;
    assert!((mean - 200.0).abs() < 1e-3, "{out:?}");
    assert!(out[0][1] < out[0][0].max(out[0][2]), "{out:?}");
}

#[test]
fn a_mono_image_is_refused_and_bad_params_are_rejected() {
    let image = mono(2, 2, vec![1.0; 4], "L");
    assert!(matches!(
        ScnrV1.apply(&image, &json!({}), &OpContext::new()),
        Err(OpError::UnsupportedChannels { .. })
    ));
    assert!(ScnrV1.validate_params(&json!({"amount": 1.5})).is_err());
    assert!(ScnrV1
        .validate_params(&json!({"neutral": "green"}))
        .is_err());
    assert!(ScnrV1.validate_params(&json!({"extra": 1})).is_err());
}
