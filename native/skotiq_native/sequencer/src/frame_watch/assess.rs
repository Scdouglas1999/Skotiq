//! Measuring a saved light frame: read it back, take its sky background and
//! plate solve it.

use super::classify::SolveOutcome;
use crate::device_ops::{ImageData, SharedDeviceOps};
use std::time::{Duration, Instant};

/// What a saved frame measured.
#[derive(Debug, Clone, PartialEq)]
pub struct MeasuredFrame {
    pub width: u32,
    pub height: u32,
    pub background_adu: Option<f64>,
    pub solve: SolveOutcome,
    /// The frame's shorter side on the sky, from the solved pixel scale.
    pub field_short_side_arcmin: Option<f64>,
}

/// Samples the background median is taken from: enough for a stable median,
/// few enough that a 16-megapixel frame costs a few milliseconds.
const BACKGROUND_SAMPLES: usize = 200_000;

/// Read `path` back and measure it. The solve is hinted with the target's
/// position (degrees); a solve that errors or finds nothing is
/// [`SolveOutcome::Failed`].
pub async fn measure_saved_frame(
    device_ops: &SharedDeviceOps,
    path: &str,
    hint_ra_deg: Option<f64>,
    hint_dec_deg: Option<f64>,
) -> Result<MeasuredFrame, String> {
    let owned = path.to_string();
    let image = tokio::task::spawn_blocking(move || load_frame(&owned))
        .await
        .map_err(|e| format!("reading the frame back failed: {e}"))??;
    let background_adu = sky_background(&image.data);
    let solve = match device_ops
        .plate_solve(&image, hint_ra_deg, hint_dec_deg, None)
        .await
    {
        Ok(result)
            if result.success && result.pixel_scale.is_finite() && result.pixel_scale > 0.0 =>
        {
            SolveOutcome::Solved {
                ra_deg: result.ra_degrees,
                dec_deg: result.dec_degrees,
                pixel_scale_arcsec: result.pixel_scale,
                rotation_deg: result.rotation,
            }
        }
        Ok(_) => SolveOutcome::Failed,
        Err(e) => {
            tracing::info!("[FRAME_WATCH] Plate solve of {} failed: {}", path, e);
            SolveOutcome::Failed
        }
    };
    let field_short_side_arcmin = match solve {
        SolveOutcome::Solved {
            pixel_scale_arcsec, ..
        } => Some(f64::from(image.width.min(image.height)) * pixel_scale_arcsec / 60.0),
        _ => None,
    };
    Ok(MeasuredFrame {
        width: image.width,
        height: image.height,
        background_adu,
        solve,
        field_short_side_arcmin,
    })
}

fn load_frame(path: &str) -> Result<ImageData, String> {
    let (image, header) = skotiq_imaging::read_fits(std::path::Path::new(path))
        .map_err(|e| format!("could not read {path}: {e}"))?;
    let data = image
        .as_u16()
        .ok_or_else(|| format!("{path} is not a 16-bit frame"))?;
    Ok(ImageData {
        width: image.width,
        height: image.height,
        data,
        bits_per_pixel: 16,
        exposure_secs: header.get_float("EXPTIME").unwrap_or(0.0),
        gain: None,
        offset: None,
        temperature: None,
        filter: header.get_string("FILTER").map(|s| s.to_string()),
        timestamp: 0,
        sensor_type: None,
        bayer_offset: None,
    })
}

/// Median of an even sample of the pixels: the sky level, since stars cover a
/// tiny fraction of a deep-sky frame.
pub fn sky_background(data: &[u16]) -> Option<f64> {
    if data.is_empty() {
        return None;
    }
    let step = (data.len() / BACKGROUND_SAMPLES).max(1);
    let mut sample: Vec<u16> = data.iter().step_by(step).copied().collect();
    let mid = sample.len() / 2;
    let (_, median, _) = sample.select_nth_unstable(mid);
    Some(f64::from(*median))
}

/// The guide RMS over the last `window`: the root mean square of the guider's
/// total-RMS samples in it, and how many there were.
pub fn guide_rms_over(history: &[(Instant, f64)], window: Duration) -> (Option<f64>, u32) {
    let samples: Vec<f64> = history
        .iter()
        .filter(|(at, rms)| at.elapsed() <= window && rms.is_finite())
        .map(|(_, rms)| *rms)
        .collect();
    if samples.is_empty() {
        return (None, 0);
    }
    let mean_square = samples.iter().map(|r| r * r).sum::<f64>() / samples.len() as f64;
    (Some(mean_square.sqrt()), samples.len() as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_background_is_the_sky_level_not_the_stars() {
        let mut data = vec![1000u16; 1_000_000];
        for px in data.iter_mut().step_by(50) {
            *px = 60_000;
        }
        assert_eq!(sky_background(&data), Some(1000.0));
        assert_eq!(sky_background(&[]), None);
    }

    #[test]
    fn guide_rms_covers_only_the_window() {
        let now = Instant::now();
        let old = now - Duration::from_secs(400);
        let history = vec![(old, 9.0), (now, 0.6), (now, 0.8)];
        let (rms, n) = guide_rms_over(&history, Duration::from_secs(130));
        assert_eq!(n, 2);
        assert!((rms.unwrap() - 0.5f64.sqrt()).abs() < 1e-9);
        assert_eq!(guide_rms_over(&[], Duration::from_secs(10)), (None, 0));
    }

    #[tokio::test]
    async fn a_saved_frame_is_read_back_measured_and_solved() {
        let dir = std::env::temp_dir().join(format!("frame-watch-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("frame.fits");
        let image = skotiq_imaging::ImageData::from_u16(400, 300, 1, &vec![1200u16; 400 * 300]);
        let mut header = skotiq_imaging::FitsHeader::new();
        header.set_float("EXPTIME", 120.0);
        skotiq_imaging::write_fits(&path, &image, &header).unwrap();

        let ops: SharedDeviceOps = std::sync::Arc::new(crate::device_ops::NullDeviceOps);
        let measured = measure_saved_frame(&ops, path.to_str().unwrap(), Some(35.6), Some(42.3))
            .await
            .unwrap();
        assert_eq!((measured.width, measured.height), (400, 300));
        assert_eq!(measured.background_adu, Some(1200.0));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
