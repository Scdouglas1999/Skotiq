//! The star list `api_detect_stars_in_file` returns follows the caller's own
//! eccentricity ceiling, so the science pipeline's PSF field map, which asks
//! for 0.95, can show a trailed field.

use super::*;
use skotiq_imaging::{FitsHeader, ImageData, PixelType};

/// A field of identical stars with a sky of 1000 ADU, each an elliptical
/// Gaussian with the given axis sigmas (major along +x).
fn field(sigma_major: f64, sigma_minor: f64) -> ImageData {
    let (width, height) = (360u32, 300u32);
    let mut pixels = vec![1000.0f64; (width * height) as usize];
    for gy in 0..5 {
        for gx in 0..6 {
            let (cx, cy) = (40.0 + 55.0 * gx as f64, 40.0 + 55.0 * gy as f64);
            for y in 0..height {
                for x in 0..width {
                    let dx = (x as f64 - cx) / sigma_major;
                    let dy = (y as f64 - cy) / sigma_minor;
                    let r2 = dx * dx + dy * dy;
                    if r2 < 60.0 {
                        pixels[(y * width + x) as usize] += 8000.0 * (-0.5 * r2).exp();
                    }
                }
            }
        }
    }
    // Deterministic noise so the detector sees a realistic background.
    let mut state = 12345u64;
    let mut data = Vec::with_capacity(pixels.len() * 2);
    for p in pixels {
        state = state
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let u = ((state >> 33) as f64) / (1u64 << 31) as f64 - 0.5;
        let value = (p + 20.0 * u).round().clamp(0.0, 65535.0) as u16;
        data.extend_from_slice(&value.to_le_bytes());
    }
    ImageData {
        width,
        height,
        channels: 1,
        pixel_type: PixelType::U16,
        data,
    }
}

fn write(dir: &tempfile::TempDir, image: &ImageData) -> String {
    let path = dir.path().join("field.fits");
    let mut header = FitsHeader::new();
    header.set_float("EXPTIME", 60.0);
    skotiq_imaging::write_fits(&path, image, &header).expect("write fixture FITS");
    path.to_string_lossy().into_owned()
}

/// The config `DefaultScienceBackend.measureStars` sends.
fn science_config() -> StarDetectionConfigApi {
    StarDetectionConfigApi {
        detection_sigma: 4.0,
        min_area: 4,
        max_area: 1024,
        max_eccentricity: 0.95,
        saturation_limit: 65520,
        hfr_radius: 6,
        min_hfr: Some(0.6),
        min_snr: Some(4.0),
        max_sharpness: Some(100.0),
    }
}

fn median(mut values: Vec<f64>) -> f64 {
    values.sort_by(f64::total_cmp);
    values[values.len() / 2]
}

#[tokio::test]
async fn a_field_measurement_sees_trailed_stars() {
    // 2:1 trails: eccentricity sqrt(1 - 0.25) = 0.87, past the 0.7
    // working-star ceiling and inside the 0.95 the science pipeline asks for.
    let dir = tempfile::tempdir().unwrap();
    let path = write(&dir, &field(4.0, 2.0));
    let result = api_detect_stars_in_file(path, Some(science_config()))
        .await
        .unwrap();
    assert!(
        result.stars.len() >= 20,
        "the trailed stars must come back, got {}",
        result.stars.len()
    );
    assert_eq!(result.star_count as usize, result.stars.len());
    let ecc = median(result.stars.iter().map(|s| s.eccentricity).collect());
    assert!(
        ecc > 0.8,
        "median eccentricity {ecc:.3} must show the 0.87 trail, not the 0.7 ceiling"
    );
}

#[tokio::test]
async fn the_default_config_still_returns_round_stars_only() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(&dir, &field(4.0, 2.0));
    let result = api_detect_stars_in_file(path, None).await.unwrap();
    assert!(result.stars.iter().all(|s| s.eccentricity <= 0.7));
}
