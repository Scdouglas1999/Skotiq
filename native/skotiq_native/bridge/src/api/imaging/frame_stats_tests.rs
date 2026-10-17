//! The one stats block every capture path publishes to the last-image cache.
//!
//! Guards the shape of [`frame_stats_result`], which exists because the three
//! paths that store a frame each built the struct by hand and one of them left
//! `hfr` and `fwhm` out: every sequencer frame answered
//! `GET /api/camera/last-image` with a real star count beside `hfr: null` while
//! the same frames' HFR was measured, logged and written to `captured_images`.
//! The web dashboard's Camera panel rendered "HFR --" for a whole night.

use super::*;

/// A synthetic frame carrying `count` Gaussian stars of the given sigma on a
/// flat pedestal — enough for the real detector to find and measure.
fn star_frame(width: u32, height: u32, count: u32, sigma: f64) -> skotiq_imaging::ImageData {
    let w = width as usize;
    let h = height as usize;
    let mut pixels = vec![500u16; w * h];
    let columns = (count as f64).sqrt().ceil() as u32;
    for index in 0..count {
        let cx = f64::from(width) * (f64::from(index % columns) + 0.5) / f64::from(columns);
        let cy = f64::from(height) * (f64::from(index / columns) + 0.5) / f64::from(columns);
        let reach = (sigma * 4.0).ceil() as i32;
        for dy in -reach..=reach {
            for dx in -reach..=reach {
                let x = cx as i32 + dx;
                let y = cy as i32 + dy;
                if x < 0 || y < 0 || x >= width as i32 || y >= height as i32 {
                    continue;
                }
                let r2 = f64::from(dx * dx + dy * dy);
                let amplitude = 20_000.0 * (-r2 / (2.0 * sigma * sigma)).exp();
                let slot = &mut pixels[y as usize * w + x as usize];
                *slot = slot.saturating_add(amplitude as u16);
            }
        }
    }
    skotiq_imaging::ImageData::from_u16(width, height, 1, &pixels)
}

#[test]
fn a_frame_with_stars_publishes_every_measurement_from_one_detection() {
    let image = star_frame(512, 512, 36, 2.0);
    let stats = skotiq_imaging::calculate_stats_u16(&image);
    let stars =
        skotiq_imaging::detect_stars(&image, &skotiq_imaging::StarDetectionConfig::default());
    assert!(!stars.is_empty(), "the synthetic frame must carry stars");

    let published = frame_stats_result(&stats, &stars);

    assert_eq!(published.star_count, stars.len() as u32);
    assert!(
        published.hfr.is_some(),
        "a frame whose stars were detected and counted has a measurable HFR; publishing the \
         count beside a null HFR is the defect this guards"
    );
    assert!(published.fwhm.is_some(), "FWHM comes from the same stars");
    assert_eq!(published.mean, stats.mean);
    assert_eq!(published.median, stats.median);
}

#[test]
fn a_starless_frame_publishes_nothing_rather_than_a_zero() {
    let image = star_frame(128, 128, 0, 2.0);
    let stats = skotiq_imaging::calculate_stats_u16(&image);
    let stars =
        skotiq_imaging::detect_stars(&image, &skotiq_imaging::StarDetectionConfig::default());

    let published = frame_stats_result(&stats, &stars);

    assert_eq!(published.star_count, stars.len() as u32);
    if stars.is_empty() {
        assert!(published.hfr.is_none(), "no stars, no HFR — never a 0.0");
        assert!(published.fwhm.is_none());
        assert!(published.eccentricity.is_none());
    }
}

#[test]
fn a_defocused_frame_publishes_a_larger_hfr_than_a_sharp_one() {
    // The published number tracks the optics rather than being a constant that
    // merely happens to be non-null.
    let sharp = star_frame(512, 512, 36, 1.6);
    let soft = star_frame(512, 512, 36, 3.2);
    let config = skotiq_imaging::StarDetectionConfig::default();

    let sharp_hfr = frame_stats_result(
        &skotiq_imaging::calculate_stats_u16(&sharp),
        &skotiq_imaging::detect_stars(&sharp, &config),
    )
    .hfr
    .expect("the sharp frame is measurable");
    let soft_hfr = frame_stats_result(
        &skotiq_imaging::calculate_stats_u16(&soft),
        &skotiq_imaging::detect_stars(&soft, &config),
    )
    .hfr
    .expect("the defocused frame is measurable");

    assert!(
        soft_hfr > sharp_hfr,
        "HFR must grow with defocus: sharp {sharp_hfr:.2} px vs soft {soft_hfr:.2} px"
    );
}
