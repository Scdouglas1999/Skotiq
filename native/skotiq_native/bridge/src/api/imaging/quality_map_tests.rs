use super::compute_quality_maps_from_linear_data;

fn approx_eq(actual: f64, expected: f64, tolerance: f64) {
    assert!(
        (actual - expected).abs() <= tolerance,
        "expected {expected}, got {actual} (tol={tolerance})"
    );
}

#[test]
fn computes_expected_clip_metrics_for_uniform_black_frame() {
    let data = vec![0.0; 16];
    let result =
        compute_quality_maps_from_linear_data(4, 4, &data, 2, 2, 0, 65535, "live").unwrap();

    approx_eq(result.frame.low_clip_percent, 100.0, 1e-9);
    approx_eq(result.frame.high_clip_percent, 0.0, 1e-9);
    assert_eq!(result.frame.processing_tier, "live");
    assert_eq!(result.tiles.len(), 20); // 2x2 tiles * 5 layers
}

#[test]
fn computes_expected_clip_metrics_for_ramp_frame() {
    let data = (0..16).map(|value| value as f64).collect::<Vec<_>>();
    let result =
        compute_quality_maps_from_linear_data(4, 4, &data, 2, 2, 0, 15, "deferred").unwrap();

    // One sample clipped low (0), one clipped high (15) out of 16 total.
    approx_eq(result.frame.low_clip_percent, 6.25, 1e-9);
    approx_eq(result.frame.high_clip_percent, 6.25, 1e-9);
    assert_eq!(result.frame.processing_tier, "deferred");
    assert_eq!(result.tiles.len(), 20);
}

/// Deterministic normal deviates (xorshift + Box-Muller), so the synthetic
/// sky below is the same on every run.
struct Noise(u64);

impl Noise {
    fn uniform(&mut self) -> f64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        ((self.0 >> 11) as f64 + 0.5) / (1u64 << 53) as f64
    }

    fn normal(&mut self) -> f64 {
        let (u1, u2) = (self.uniform(), self.uniform());
        (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos()
    }
}

/// A sky like the rig's NGC 891 subs at a reduced size: a background of
/// `sky` ADU rising by `gradient` of itself from the left edge to the right,
/// Gaussian noise of `sigma` ADU, and a dense field of stars (a few percent of
/// the pixels well above the sky; about 30 times the rig's star density).
fn star_field(width: usize, height: usize, sky: f64, gradient: f64, sigma: f64) -> Vec<f64> {
    let mut noise = Noise(0x9E37_79B9_7F4A_7C15);
    let mut data: Vec<f64> = (0..width * height)
        .map(|i| {
            let x = (i % width) as f64 / width as f64 - 0.5;
            sky * (1.0 + gradient * x) + sigma * noise.normal()
        })
        .collect();
    let stars = width * height / 4000;
    for _ in 0..stars {
        let cx = noise.uniform() * width as f64;
        let cy = noise.uniform() * height as f64;
        let peak = 20.0 * sigma * (1.0 + 30.0 * noise.uniform().powi(4));
        let r = 1.6_f64;
        for dy in -6i32..=6 {
            for dx in -6i32..=6 {
                let (x, y) = (cx as i32 + dx, cy as i32 + dy);
                if x < 0 || y < 0 || x >= width as i32 || y >= height as i32 {
                    continue;
                }
                let d2 = f64::from(dx * dx + dy * dy);
                data[y as usize * width + x as usize] += peak * (-d2 / (2.0 * r * r)).exp();
            }
        }
    }
    data
}

#[test]
fn gradient_is_measured_on_an_even_grid() {
    // An even grid has no tile straddling the image midline; the gradient
    // must still come out as the 10% across the frame that was put in.
    let (w, h) = (960, 720);
    let data = star_field(w, h, 3000.0, 0.10, 40.0);
    for (rows, cols) in [(12, 16), (24, 32), (4, 6)] {
        let result =
            compute_quality_maps_from_linear_data(w, h, &data, rows, cols, 16, 65520, "deferred")
                .unwrap();
        approx_eq(result.frame.gradient_x, 0.10, 0.01);
        approx_eq(result.frame.gradient_y, 0.0, 0.01);
    }
}

#[test]
fn gradient_points_to_the_brighter_side() {
    let (w, h) = (960, 720);
    let data = star_field(w, h, 3000.0, -0.25, 40.0);
    let result =
        compute_quality_maps_from_linear_data(w, h, &data, 12, 16, 16, 65520, "live").unwrap();
    approx_eq(result.frame.gradient_x, -0.25, 0.02);
}

#[test]
fn noise_is_the_sky_noise_whatever_the_grid() {
    // Stars and the gradient must not leak into the noise: every grid reads
    // the 40 ADU that was put in.
    let (w, h) = (960, 720);
    let data = star_field(w, h, 3000.0, 0.10, 40.0);
    for (rows, cols) in [(24, 32), (12, 16), (7, 9), (4, 6)] {
        let result =
            compute_quality_maps_from_linear_data(w, h, &data, rows, cols, 16, 65520, "deferred")
                .unwrap();
        eprintln!("grid {rows}x{cols}: noise {:.2}", result.frame.noise);
        approx_eq(result.frame.noise, 40.0, 2.0);
        approx_eq(result.frame.background, 3000.0, 15.0);
    }
}

#[test]
fn uniformity_reads_the_background_not_the_stars() {
    let (w, h) = (960, 720);
    let flat = star_field(w, h, 3000.0, 0.0, 40.0);
    let result =
        compute_quality_maps_from_linear_data(w, h, &flat, 12, 16, 16, 65520, "live").unwrap();
    assert!(
        result.frame.uniformity_cv < 0.01,
        "flat sky with stars read as uneven: {}",
        result.frame.uniformity_cv
    );
}
