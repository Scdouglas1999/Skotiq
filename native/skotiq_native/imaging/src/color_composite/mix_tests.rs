use super::*;
use crate::color_composite::test_scene::Lcg;

fn sky_with_stars(n: usize, pedestal: f64, noise: f64, seed: u64) -> (Vec<f32>, Vec<usize>) {
    let mut rng = Lcg::new(seed);
    let mut plane: Vec<f32> = (0..n)
        .map(|_| (pedestal + noise * rng.normal()) as f32)
        .collect();
    let mut stars = Vec::new();
    for i in (0..n).step_by(97) {
        let flux = 500.0 + 4_000.0 * rng.unit();
        plane[i] += flux as f32;
        stars.push(i);
    }
    (plane, stars)
}

#[test]
fn the_flux_fit_reads_the_signal_not_the_sky() {
    let n = 200_000;
    let (x, _) = sky_with_stars(n, 1000.0, 20.0, 3);
    let mut rng = Lcg::new(9);
    // y = 2.5·x + 100 for the signal, with independent sky noise on top.
    let y: Vec<f32> = x
        .iter()
        .map(|v| (2.5 * *v as f64 + 100.0 + 30.0 * rng.normal()) as f32)
        .collect();
    let fit = robust_fit(&x, &y).expect("a fit");
    assert!((fit.scale - 2.5).abs() < 0.02, "{fit:?}");
    assert!((fit.offset - 100.0).abs() < 25.0, "{fit:?}");

    // Least squares over the same pixels is pulled toward zero by the sky.
    let mx = x.iter().map(|v| *v as f64).sum::<f64>() / n as f64;
    let my = y.iter().map(|v| *v as f64).sum::<f64>() / n as f64;
    let sxy: f64 = x
        .iter()
        .zip(&y)
        .map(|(a, b)| (*a as f64 - mx) * (*b as f64 - my))
        .sum();
    let sxx: f64 = x.iter().map(|a| (*a as f64 - mx).powi(2)).sum();
    assert!(
        sxy / sxx < fit.scale,
        "least squares is the lower bound here"
    );
}

#[test]
fn a_fit_with_no_shared_signal_is_refused() {
    let mut rng = Lcg::new(1);
    let x: Vec<f32> = (0..10_000).map(|_| (100.0 + rng.normal()) as f32).collect();
    let y: Vec<f32> = (0..10_000).map(|_| (200.0 + rng.normal()) as f32).collect();
    assert!(robust_fit(&x, &y).is_none());
}

#[test]
fn the_luminance_sets_lightness_and_the_rgb_sets_color() {
    let (w, h) = (32usize, 32usize);
    let n = w * h;
    let r = vec![300.0_f32; n];
    let g = vec![200.0_f32; n];
    let b = vec![100.0_f32; n];
    let l: Vec<f32> = (0..n).map(|i| 100.0 + i as f32).collect();
    let [ro, go, bo] = apply_luminance([&r, &g, &b], &l, w, h, [1.0; 3]);
    for i in 0..n {
        let mean = (ro[i] + go[i] + bo[i]) / 3.0;
        assert!((mean - l[i]).abs() < 1e-3 * l[i], "pixel {i}");
        assert!((ro[i] / go[i] - 1.5).abs() < 1e-4);
        assert!((bo[i] / go[i] - 0.5).abs() < 1e-4);
    }
}

#[test]
fn the_luminance_layer_is_continuous_near_zero_color() {
    let n = 64;
    let r: Vec<f32> = (0..n).map(|i| i as f32 * 0.01).collect();
    let g = r.clone();
    let b = r.clone();
    let l = vec![50.0_f32; n];
    let [ro, ..] = apply_luminance([&r, &g, &b], &l, n, 1, [0.0; 3]);
    // Grey in, grey out at every brightness, through both branches.
    for value in ro {
        assert!((value - 50.0).abs() < 1e-3, "{value}");
    }
}

#[test]
fn sessions_are_averaged_by_inverse_noise_variance() {
    let mut rng = Lcg::new(5);
    let quiet: Vec<f32> = (0..50_000)
        .map(|_| (100.0 + 1.0 * rng.normal()) as f32)
        .collect();
    let noisy: Vec<f32> = (0..50_000)
        .map(|_| (200.0 + 3.0 * rng.normal()) as f32)
        .collect();
    let mean = weighted_mean(&[quiet, noisy]);
    let avg = mean.iter().map(|v| *v as f64).sum::<f64>() / mean.len() as f64;
    // Weights 1 : 1/9 put the mean at 100 + 100·(1/9)/(10/9) = 110.
    assert!((avg - 110.0).abs() < 1.0, "{avg}");
}

#[test]
fn blur_preserves_a_flat_plane_and_its_total() {
    let plane = vec![7.0_f32; 40 * 30];
    let out = gaussian_blur(&plane, 40, 30, 2.0);
    assert!(out.iter().all(|v| (v - 7.0).abs() < 1e-4));
    let mut spike = vec![0.0_f32; 41 * 41];
    spike[20 * 41 + 20] = 1.0;
    let out = gaussian_blur(&spike, 41, 41, 1.5);
    let total: f32 = out.iter().sum();
    assert!((total - 1.0).abs() < 1e-4, "{total}");
}

#[test]
fn matching_sigmas_bring_every_channel_to_the_widest_profile() {
    let m = psf_match_sigmas([2.0, 2.5, 1.5]);
    assert!((m[1]).abs() < 1e-12);
    assert!((m[0] - (2.5f64.powi(2) - 2.0f64.powi(2)).sqrt()).abs() < 1e-9);
    assert!((m[2] - (2.5f64.powi(2) - 1.5f64.powi(2)).sqrt()).abs() < 1e-9);
}
