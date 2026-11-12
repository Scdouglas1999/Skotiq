//! The last frame each camera delivered, measured once for the screens.
//!
//! Every exposure reaches the store through [`store`], whether the Imaging
//! screen or a sequence took it and whether a simulator or a camera made it:
//! its statistics, star measurements, display buffer and histogram are
//! computed here and nowhere else, so one frame reports the same numbers
//! whoever asks for it.

use crate::api::imaging::{CapturedImageResult, ImageStatsResult};
use crate::error::SkotiqError;
use skotiq_device::BayerPattern;
use std::sync::OnceLock;
use tokio::sync::Mutex;

/// A frame as the camera delivered it.
#[derive(Debug, Clone)]
pub(crate) struct RawFrame {
    pub width: u32,
    pub height: u32,
    pub data: Vec<u16>,
    /// `None` for a monochrome sensor.
    pub bayer_pattern: Option<BayerPattern>,
}

/// One camera's last frame: what the screens draw, and the samples it was
/// drawn from (for FITS saves, star crops and quality maps).
#[derive(Debug, Clone)]
pub(crate) struct StoredFrame {
    pub display: CapturedImageResult,
    pub raw: RawFrame,
}

/// How many cameras' frames are kept.
///
/// The store is keyed by device id, so each connected camera holds one slot.
/// 50 covers any rig (1-5 cameras) with room for transient reconnections that
/// rotate the id (USB re-enumeration appending a serial suffix). At ~24 MB per
/// 16-bit frame (4144x2822) the worst case is ~1.2 GB, which keeps a 16 GB
/// laptop safe over a long session.
pub(crate) const STORE_CAPACITY: usize = 50;

type Store = Mutex<lru::LruCache<String, StoredFrame>>;

fn frames() -> &'static Store {
    static STORE: OnceLock<Store> = OnceLock::new();
    STORE.get_or_init(|| {
        let capacity =
            std::num::NonZeroUsize::new(STORE_CAPACITY).expect("STORE_CAPACITY is non-zero");
        Mutex::new(lru::LruCache::new(capacity))
    })
}

/// Measure `raw` and make it `camera_id`'s last frame.
///
/// The measurement is seconds of CPU on a large sensor, so it runs on a
/// blocking thread: on the async runtime it would starve the event bridge,
/// the device heartbeats and the headless HTTP handlers.
pub(crate) async fn store(
    camera_id: &str,
    raw: RawFrame,
    exposure_secs: f64,
) -> Result<(), SkotiqError> {
    let frame = tokio::task::spawn_blocking(move || StoredFrame {
        display: measure(&raw, exposure_secs),
        raw,
    })
    .await
    .map_err(|e| SkotiqError::OperationFailed(format!("Image analysis task failed: {}", e)))?;
    put(camera_id, frame).await;
    Ok(())
}

/// What the screens show for one frame.
pub(crate) fn measure(raw: &RawFrame, exposure_secs: f64) -> CapturedImageResult {
    let image = skotiq_imaging::ImageData::from_u16(raw.width, raw.height, 1, &raw.data);
    let display = match raw.bayer_pattern {
        Some(pattern) => crate::frame_display::color(
            &raw.data,
            raw.width,
            raw.height,
            crate::frame_display::device_filter(pattern),
        ),
        None => crate::frame_display::mono(&image),
    };
    // Measured on the sensor's own samples, mosaic included, as the FITS on
    // disk holds them.
    let stats = skotiq_imaging::calculate_stats_u16(&image);
    let stars =
        skotiq_imaging::detect_stars(&image, &skotiq_imaging::StarDetectionConfig::default());
    let stats = frame_stats_result(&stats, &stars);
    tracing::info!(
        "Captured {}x{}: {} stars, median HFR {:?}, median eccentricity {:?}",
        raw.width,
        raw.height,
        stats.star_count,
        stats.hfr,
        stats.eccentricity
    );
    CapturedImageResult {
        width: raw.width,
        height: raw.height,
        display_data: display.rgba,
        histogram: display.histogram,
        stats,
        exposure_time: exposure_secs,
        timestamp: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        is_color: raw.bayer_pattern.is_some(),
    }
}

async fn put(camera_id: &str, frame: StoredFrame) {
    let mut frames = frames().lock().await;
    if let Some((evicted, _)) = frames.push(camera_id.to_string(), frame) {
        if evicted != camera_id {
            tracing::debug!(
                "Last-frame store full ({STORE_CAPACITY}): dropped the frame of {evicted}"
            );
        }
    }
}

/// The display result of `camera_id`'s last frame.
pub(crate) async fn display(camera_id: &str) -> Option<CapturedImageResult> {
    frames()
        .lock()
        .await
        .get(camera_id)
        .map(|f| f.display.clone())
}

/// A copy of `camera_id`'s last frame as the camera delivered it.
pub(crate) async fn raw(camera_id: &str) -> Option<RawFrame> {
    frames().lock().await.get(camera_id).map(|f| f.raw.clone())
}

pub(crate) async fn clear(camera_id: &str) {
    frames().lock().await.pop(camera_id);
}

/// Stars sampled for the per-frame medians: the brightest half of the
/// detections, never more than this many. Detection returns stars brightest
/// first, so the sample is the same set on every run over the same frame.
const FRAME_METRIC_SAMPLE_CAP: usize = 50;

/// Largest HFR or FWHM, in pixels, that a detection can contribute to a frame
/// median. A value at or past it is a smear or a detection artefact, not a star
/// this frame can be measured by.
const FRAME_METRIC_MAX_PIXELS: f64 = 20.0;

/// Median of the sampled stars' `value`, or `None` when none of them carries a
/// usable one.
fn frame_metric_median(
    stars: &[skotiq_imaging::DetectedStar],
    value: impl Fn(&skotiq_imaging::DetectedStar) -> f64,
) -> Option<f64> {
    let sample = (stars.len() / 2).clamp(1, FRAME_METRIC_SAMPLE_CAP);
    let mut values: Vec<f64> = stars
        .iter()
        .take(sample)
        .map(&value)
        .filter(|v| *v > 0.0 && *v < FRAME_METRIC_MAX_PIXELS)
        .collect();
    if values.is_empty() {
        return None;
    }
    values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    Some(values[values.len() / 2])
}

/// The stats block a stored frame publishes, read out of that frame's own
/// statistics and the stars already detected in it: HFR, FWHM, eccentricity
/// and the star count all come from one detection.
///
/// `None` for HFR, FWHM or eccentricity means too few usable stars to measure
/// this frame — never a fabricated 0.
pub(crate) fn frame_stats_result(
    stats: &skotiq_imaging::ImageStats,
    stars: &[skotiq_imaging::DetectedStar],
) -> ImageStatsResult {
    ImageStatsResult {
        min: stats.min,
        max: stats.max,
        mean: stats.mean,
        median: stats.median,
        std_dev: stats.std_dev,
        hfr: frame_metric_median(stars, |s| s.hfr),
        eccentricity: skotiq_imaging::frame_eccentricity(stars),
        fwhm: frame_metric_median(stars, |s| s.fwhm),
        star_count: stars.len() as u32,
    }
}

#[cfg(test)]
mod stats_tests;
#[cfg(test)]
mod store_tests;
