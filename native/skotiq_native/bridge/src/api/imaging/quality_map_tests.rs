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
