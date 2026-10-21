//! `chroma_denoise@1`: the sky's color noise is smoothed, a star keeps its
//! color, lightness never moves, and amount 0 is the identity.

use serde_json::json;

use super::*;
use crate::color_composite::test_scene::{mono, Lcg};

const W: usize = 256;
const H: usize = 256;

/// A neutral sky at 1000 with independent per-channel noise, and one bright
/// orange star at the centre.
fn scene() -> OpImage {
    let mut rng = Lcg::new(4);
    let mut data = vec![0.0_f32; W * H * 3];
    for y in 0..H {
        for x in 0..W {
            let d2 = (x as f64 - 128.0).powi(2) + (y as f64 - 128.0).powi(2);
            let star = 5000.0 * (-d2 / (2.0 * 2.0 * 2.0)).exp();
            let color = [1.4, 1.0, 0.6];
            for c in 0..3 {
                data[(y * W + x) * 3 + c] = (1000.0 + star * color[c] + 10.0 * rng.normal()) as f32;
            }
        }
    }
    let header = mono(1, 1, vec![0.0], "L").header().clone();
    OpImage::new(W as u32, H as u32, 3, data, header).expect("image")
}

fn chroma_sigma(image: &OpImage, channel: usize) -> f64 {
    let d = image.data();
    let values: Vec<f64> = (0..W * H)
        .filter(|i| {
            let (x, y) = (i % W, i / W);
            (x as i64 - 128).abs() > 30 || (y as i64 - 128).abs() > 30
        })
        .map(|i| {
            let y = (d[i * 3] + d[i * 3 + 1] + d[i * 3 + 2]) as f64 / 3.0;
            d[i * 3 + channel] as f64 - y
        })
        .collect();
    let mean = values.iter().sum::<f64>() / values.len() as f64;
    (values.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / values.len() as f64).sqrt()
}

fn star_ratio(image: &OpImage) -> f64 {
    let d = image.data();
    let i = 128 * W + 128;
    (d[i * 3] as f64 - 1000.0) / (d[i * 3 + 2] as f64 - 1000.0)
}

#[test]
fn the_skys_color_noise_is_smoothed_and_a_star_keeps_its_color() {
    let input = scene();
    let out = ChromaDenoiseV1
        .apply(&input, &json!({}), &OpContext::new())
        .expect("apply");
    for c in 0..3 {
        let before = chroma_sigma(&input, c);
        let after = chroma_sigma(&out, c);
        assert!(after < 0.2 * before, "channel {c}: {before} -> {after}");
    }
    let (before, after) = (star_ratio(&input), star_ratio(&out));
    assert!((after / before - 1.0).abs() < 0.01, "{before} -> {after}");
}

#[test]
fn lightness_never_moves() {
    let input = scene();
    let out = ChromaDenoiseV1
        .apply(&input, &json!({"smoothingPx": 12.0}), &OpContext::new())
        .expect("apply");
    for (a, b) in input.data().chunks(3).zip(out.data().chunks(3)) {
        let ya = (a[0] + a[1] + a[2]) as f64 / 3.0;
        let yb = (b[0] + b[1] + b[2]) as f64 / 3.0;
        assert!((ya - yb).abs() < 1e-2, "{ya} {yb}");
    }
}

#[test]
fn amount_zero_is_the_identity_and_bad_params_are_rejected() {
    let input = scene();
    let out = ChromaDenoiseV1
        .apply(&input, &json!({"amount": 0.0}), &OpContext::new())
        .expect("apply");
    assert_eq!(out.data(), input.data());
    assert!(ChromaDenoiseV1
        .validate_params(&json!({"smoothingPx": 0.0}))
        .is_err());
    assert!(ChromaDenoiseV1
        .validate_params(&json!({"protection": 200.0}))
        .is_err());
    assert!(ChromaDenoiseV1
        .validate_params(&json!({"strength": 1.0}))
        .is_err());
    let image = mono(2, 2, vec![1.0; 4], "L");
    assert!(ChromaDenoiseV1
        .apply(&image, &json!({}), &OpContext::new())
        .is_err());
}
