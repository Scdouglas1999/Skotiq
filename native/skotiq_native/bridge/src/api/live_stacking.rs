//! Live stacking: one process-wide stacker fed frame by frame from Dart.
//!
//! The types here are the only shape of the stacker's settings and results
//! on either side of the bridge; the session converts them once, into the
//! imaging crate's [`LiveStackConfig`].

use crate::error::SkotiqError;
use skotiq_imaging::stack_master::{write_stack_master, FrameProvenance};
use skotiq_imaging::stacking::{
    debayer_cfa_to_rgb, LiveStackConfig, LiveStacker, SensorMode, StackingStats,
};
use skotiq_imaging::{
    read_image, BayerPattern, ColorFilterArray, DebayerAlgorithm, ImageData, StarDetectionConfig,
};
use std::sync::Mutex;
use std::sync::OnceLock;

/// What the stacker is set up with.
pub struct ApiLiveStackingConfig {
    pub sigma_clip_enabled: bool,
    pub sigma_clip_threshold: f64,
    pub max_match_stars: u32,
    pub match_radius_px: f64,
    pub match_flux_tolerance: f64,
    pub min_matched_pairs: u32,
    /// Sensor acquisition mode: `"mono"`, `"osc"`, or `"auto"` (case-insensitive).
    ///
    /// - `mono` — frames are single-channel luminance; never debayered.
    /// - `osc` — frames are a Bayer CFA mosaic that must be debayered to RGB;
    ///   a pattern that cannot be resolved is an error, never a mono fallback
    ///   that would scramble the color mosaic.
    /// - `auto` — debayer only when the frame carries Bayer geometry (or
    ///   `bayer_pattern` is given); otherwise treat as mono.
    pub sensor_mode: String,
    /// Explicit Bayer pattern override (`"RGGB"`/`"BGGR"`/`"GRBG"`/`"GBRG"`,
    /// case-insensitive). When `None`, OSC/auto sessions use the pattern the
    /// reference frame declares in its FITS `BAYERPAT` geometry. An
    /// unrecognized string is an error.
    pub bayer_pattern: Option<String>,
    /// Demosaic quality: `"bilinear"`, `"vng"`, or `"superpixel"`
    /// (case-insensitive). An unrecognized value is an error.
    pub demosaic_quality: String,
}

/// The stacker's running tally.
#[derive(Debug)]
pub struct ApiLiveStackingStats {
    pub stacked_frame_count: u32,
    pub total_frames_attempted: u32,
    pub rejected_alignment_failures: u32,
    pub avg_matched_pairs: f64,
    pub avg_alignment_residual: f64,
    pub total_sigma_rejected_pixels: u64,
    /// Frames left out for being taken through another filter than the stack's.
    pub other_filter_frames: u32,
    /// The filter of the most recent such frame.
    pub last_other_filter: Option<String>,
    /// The filter the stack is of; `None` when its reference named none.
    pub filter: Option<String>,
}

impl From<StackingStats> for ApiLiveStackingStats {
    fn from(s: StackingStats) -> Self {
        Self {
            stacked_frame_count: s.stacked_frame_count,
            total_frames_attempted: s.total_frames_attempted,
            rejected_alignment_failures: s.rejected_alignment_failures,
            avg_matched_pairs: s.avg_matched_pairs,
            avg_alignment_residual: s.avg_alignment_residual,
            total_sigma_rejected_pixels: s.total_sigma_rejected_pixels,
            other_filter_frames: s.other_filter_frames,
            last_other_filter: s.last_other_filter,
            filter: s.filter,
        }
    }
}

/// The current stack and the tally behind it.
#[derive(Debug)]
pub struct ApiLiveStackingResult {
    pub width: u32,
    pub height: u32,
    /// Channel count of the stacked result: `1` for a monochrome session, `3`
    /// for an OSC/color session, whose `data` is interleaved RGB16.
    pub channels: u32,
    pub data: Vec<u16>,
    pub stats: ApiLiveStackingStats,
}

/// What was written when the stacked master was saved.
#[derive(Debug)]
pub struct ApiLiveStackingMaster {
    pub file_path: String,
    pub stacked_frame_count: u32,
    /// The master's `EXPTIME`: Σ of the exposures the stacked frames reported.
    /// `0.0` means no frame reported one (an in-memory stack has no headers to
    /// read); the FITS card comment says so.
    pub total_integration_secs: f64,
    /// The master's `DATE-OBS`: the earliest stacked frame's stamp, or the
    /// moment the stack started when no frame carried one.
    pub date_obs: String,
}

/// How CFA frames become RGB for the current session: decided once at start
/// (from the settings and the reference frame's Bayer geometry) and used for
/// every later frame, so the whole stack is demosaiced the same way.
#[derive(Debug, Clone, Copy)]
struct ColorIngest {
    pattern: ColorFilterArray,
    algorithm: DebayerAlgorithm,
}

/// The stacker and its color decision, created, replaced and dropped
/// together under one lock.
struct StackerSession {
    stacker: LiveStacker,
    /// `Some` for OSC sessions, `None` for monochrome.
    color: Option<ColorIngest>,
}

impl StackerSession {
    fn result(&self, image: &ImageData) -> Result<ApiLiveStackingResult, SkotiqError> {
        let data = image.as_u16().ok_or_else(|| {
            SkotiqError::ImageError("Failed to convert stacked result to u16".to_string())
        })?;
        Ok(ApiLiveStackingResult {
            width: image.width,
            height: image.height,
            channels: image.channels,
            data,
            stats: self.stacker.get_stats().into(),
        })
    }
}

static LIVE_STACKER: OnceLock<Mutex<Option<StackerSession>>> = OnceLock::new();

/// The stacker lock. A holder that panicked leaves the session as it was;
/// the next call goes on with it rather than failing every call after.
fn acquire_stacker() -> std::sync::MutexGuard<'static, Option<StackerSession>> {
    LIVE_STACKER
        .get_or_init(|| Mutex::new(None))
        .lock()
        .unwrap_or_else(|poisoned| {
            tracing::warn!(
                "Live stacker mutex was poisoned (a previous operation panicked); recovering"
            );
            poisoned.into_inner()
        })
}

fn not_started() -> SkotiqError {
    SkotiqError::ImageError("Live stacker not initialized".to_string())
}

fn parse_demosaic_quality(quality: &str) -> Result<DebayerAlgorithm, String> {
    match quality.trim().to_ascii_lowercase().as_str() {
        "bilinear" => Ok(DebayerAlgorithm::Bilinear),
        "vng" => Ok(DebayerAlgorithm::VNG),
        "superpixel" => Ok(DebayerAlgorithm::SuperPixel),
        other => Err(format!(
            "Unknown demosaic quality '{}' (expected one of: bilinear, vng, superpixel)",
            other
        )),
    }
}

/// `None` or empty lets the frame's geometry decide.
fn parse_bayer_pattern(pattern: &Option<String>) -> Result<Option<BayerPattern>, String> {
    match pattern.as_deref().map(str::trim) {
        None | Some("") => Ok(None),
        Some(s) => BayerPattern::from_str(s).map(Some).ok_or_else(|| {
            format!(
                "Unknown Bayer pattern '{}' (expected one of: RGGB, BGGR, GRBG, GBRG)",
                s
            )
        }),
    }
}

fn parse_sensor_mode(mode: &str) -> Result<SensorMode, String> {
    match mode.trim().to_ascii_lowercase().as_str() {
        "mono" => Ok(SensorMode::Mono),
        "osc" => Ok(SensorMode::Osc),
        "auto" => Ok(SensorMode::Auto),
        other => Err(format!(
            "Unknown sensor mode '{}' (expected one of: mono, osc, auto)",
            other
        )),
    }
}

/// The imaging crate's stacker settings for `config`. Tuning not offered to
/// the user (the alignment-residual limit and the like) keeps its defaults.
fn stacker_config(config: &ApiLiveStackingConfig) -> Result<LiveStackConfig, SkotiqError> {
    let parsed = || -> Result<LiveStackConfig, String> {
        Ok(LiveStackConfig {
            sigma_clip_threshold: config.sigma_clip_threshold,
            sigma_clip_enabled: config.sigma_clip_enabled,
            // Why: u32 → usize widens on every supported target.
            max_match_stars: config.max_match_stars as usize,
            match_radius_px: config.match_radius_px,
            match_flux_tolerance: config.match_flux_tolerance,
            min_matched_pairs: config.min_matched_pairs as usize,
            star_detection: StarDetectionConfig {
                detection_sigma: 4.0,
                min_snr: 8.0,
                ..StarDetectionConfig::default()
            },
            // The override the settings name; the pattern a session ingests
            // with is resolved at start from this or the frame's geometry.
            bayer_pattern: parse_bayer_pattern(&config.bayer_pattern)?,
            sensor_mode: parse_sensor_mode(&config.sensor_mode)?,
            demosaic_algorithm: parse_demosaic_quality(&config.demosaic_quality)?,
            ..LiveStackConfig::default()
        })
    };
    parsed().map_err(SkotiqError::ImageError)
}

/// The color decision for a session whose reference may declare a color
/// filter (`frame_cfa`, `None` for an in-memory frame, which has no header).
///
/// OSC must debayer, so a pattern that resolves from neither the settings nor
/// the frame is an error. Auto debayers only when one resolves. Mono never
/// debayers.
fn color_ingest(
    native: &LiveStackConfig,
    frame_cfa: Option<ColorFilterArray>,
    missing_pattern: &str,
) -> Result<Option<ColorIngest>, SkotiqError> {
    let pattern = native
        .bayer_pattern
        .map(ColorFilterArray::Bayer)
        .or(frame_cfa);
    let ingest = |pattern| ColorIngest {
        pattern,
        algorithm: native.demosaic_algorithm,
    };
    match native.sensor_mode {
        SensorMode::Osc => pattern
            .map(ingest)
            .map(Some)
            .ok_or_else(|| SkotiqError::ImageError(missing_pattern.to_string())),
        SensorMode::Auto => Ok(pattern.map(ingest)),
        SensorMode::Mono => Ok(None),
    }
}

/// `image` in the layout the session stacks: debayered RGB for a color
/// session, as it is for mono.
fn ingest(image: ImageData, color: Option<ColorIngest>) -> Result<ImageData, SkotiqError> {
    match color {
        Some(c) => debayer_cfa_to_rgb(&image, c.pattern, c.algorithm)
            .map_err(|e| SkotiqError::ImageError(format!("Failed to debayer frame: {}", e))),
        None => Ok(image),
    }
}

fn install(stacker: LiveStacker, color: Option<ColorIngest>) -> ApiLiveStackingStats {
    let stats = stacker.get_stats();
    *acquire_stacker() = Some(StackerSession { stacker, color });
    tracing::info!(
        "Live stacking started ({})",
        if color.is_some() { "color/OSC" } else { "mono" }
    );
    stats.into()
}

/// Start live stacking with a reference image file; every later frame is
/// aligned to it.
pub fn api_stacking_start(
    reference_image_path: String,
    config: ApiLiveStackingConfig,
) -> Result<ApiLiveStackingStats, SkotiqError> {
    tracing::info!(
        "Starting live stacking with reference: {}",
        reference_image_path
    );
    let read = read_image(std::path::Path::new(&reference_image_path))
        .map_err(|e| SkotiqError::ImageError(format!("Failed to read reference image: {}", e)))?;
    let native = stacker_config(&config)?;
    let color = color_ingest(
        &native,
        read.cfa,
        "OSC declared but no Bayer pattern resolvable (set bayer_pattern in the \
         config or capture with a BAYERPAT FITS header)",
    )?;
    // The reference's pixels are in the stack, so its EXPTIME and DATE-OBS
    // start the master's integration.
    let provenance = FrameProvenance::from_header(&read.header);
    let reference = ingest(read.image, color)?;
    let stacker = LiveStacker::new_with_provenance(&reference, native, &provenance)
        .map_err(|e| SkotiqError::ImageError(format!("Failed to initialize stacker: {}", e)))?;
    Ok(install(stacker, color))
}

/// Start live stacking from a single-plane u16 reference frame in memory.
/// Such a frame has no header, so a color session needs `bayer_pattern`.
pub fn api_stacking_start_from_data(
    width: u32,
    height: u32,
    data: Vec<u16>,
    config: ApiLiveStackingConfig,
) -> Result<ApiLiveStackingStats, SkotiqError> {
    tracing::info!(
        "Starting live stacking from data: {}x{} ({} pixels)",
        width,
        height,
        data.len()
    );
    let native = stacker_config(&config)?;
    let color = color_ingest(
        &native,
        None,
        "OSC declared but no Bayer pattern resolvable (in-memory frames carry no \
         BAYERPAT header — set bayer_pattern in the config)",
    )?;
    let reference = ingest(ImageData::from_u16(width, height, 1, &data), color)?;
    let stacker = LiveStacker::new(&reference, native)
        .map_err(|e| SkotiqError::ImageError(format!("Failed to initialize stacker: {}", e)))?;
    Ok(install(stacker, color))
}

/// Add a frame file to the stack and return the stack as it now stands.
pub fn api_stacking_add_frame(image_path: String) -> Result<ApiLiveStackingResult, SkotiqError> {
    tracing::info!("Adding frame to stack: {}", image_path);
    let read = read_image(std::path::Path::new(&image_path))
        .map_err(|e| SkotiqError::ImageError(format!("Failed to read frame image: {}", e)))?;
    let mut guard = acquire_stacker();
    let session = guard.as_mut().ok_or_else(|| {
        SkotiqError::ImageError(
            "Live stacker not initialized. Call stacking_start first.".to_string(),
        )
    })?;
    let provenance = FrameProvenance::from_header(&read.header);
    let frame = ingest(read.image, session.color)?;
    let stacked = session
        .stacker
        .add_frame_with_provenance(&frame, &provenance)
        .map_err(SkotiqError::ImageError)?;
    session.result(&stacked)
}

/// Add a single-plane u16 frame in memory to the stack.
pub fn api_stacking_add_frame_from_data(
    width: u32,
    height: u32,
    data: Vec<u16>,
) -> Result<ApiLiveStackingResult, SkotiqError> {
    tracing::debug!("Adding frame from data to stack: {}x{}", width, height);
    let mut guard = acquire_stacker();
    let session = guard.as_mut().ok_or_else(|| {
        SkotiqError::ImageError(
            "Live stacker not initialized. Call stacking_start first.".to_string(),
        )
    })?;
    let frame = ingest(ImageData::from_u16(width, height, 1, &data), session.color)?;
    let stacked = session
        .stacker
        .add_frame(&frame)
        .map_err(SkotiqError::ImageError)?;
    session.result(&stacked)
}

/// The current stack, without adding a frame.
pub fn api_stacking_get_result() -> Result<ApiLiveStackingResult, SkotiqError> {
    let guard = acquire_stacker();
    let session = guard.as_ref().ok_or_else(not_started)?;
    session.result(&session.stacker.get_current_stack())
}

/// Save the stack as a FITS master. It is the session's data product, so
/// it carries the `EXPTIME` and `DATE-OBS` of the frames actually folded in
/// ([`skotiq_imaging::stack_master`]), the only record of them a stack in
/// memory has.
pub async fn api_stacking_save_master_fits(
    file_path: String,
) -> Result<ApiLiveStackingMaster, SkotiqError> {
    // A full-frame master is tens of megabytes; write it off the async runtime.
    tokio::task::spawn_blocking(move || save_master_fits(file_path))
        .await
        .map_err(|e| SkotiqError::OperationFailed(format!("Task join error: {}", e)))?
}

fn save_master_fits(file_path: String) -> Result<ApiLiveStackingMaster, SkotiqError> {
    let guard = acquire_stacker();
    let session = guard.as_ref().ok_or_else(not_started)?;
    let provenance = session.stacker.provenance();
    if provenance.stacked_frames() == 0 {
        return Err(SkotiqError::ImageError(
            "There is no stacked master to save yet".to_string(),
        ));
    }
    let image = session.stacker.get_current_stack();
    write_stack_master(std::path::Path::new(&file_path), &image, provenance)
        .map_err(|e| SkotiqError::ImageError(format!("Failed to write stacked master: {:?}", e)))?;
    tracing::info!(
        "Stacked master saved: {} ({} frames, {:.1} s integration)",
        file_path,
        provenance.stacked_frames(),
        provenance.total_integration_secs()
    );
    // `to_fits_header` always writes DATE-OBS, synthesizing one when no frame
    // reported it.
    let date_obs = provenance
        .to_fits_header()
        .get_string("DATE-OBS")
        .ok_or_else(|| {
            SkotiqError::ImageError("internal: stacked master header lacks DATE-OBS".to_string())
        })?
        .to_string();
    Ok(ApiLiveStackingMaster {
        file_path,
        stacked_frame_count: provenance.stacked_frames(),
        total_integration_secs: provenance.total_integration_secs(),
        date_obs,
    })
}

/// The current tally.
pub fn api_stacking_get_stats() -> Result<ApiLiveStackingStats, SkotiqError> {
    let guard = acquire_stacker();
    let session = guard.as_ref().ok_or_else(not_started)?;
    Ok(session.stacker.get_stats().into())
}

/// Clear what has been stacked, keeping the reference frame.
pub fn api_stacking_reset() -> Result<(), SkotiqError> {
    let mut guard = acquire_stacker();
    let session = guard.as_mut().ok_or_else(not_started)?;
    session.stacker.reset();
    tracing::info!("Live stacker reset");
    Ok(())
}

/// Stop live stacking and release the stack.
pub fn api_stacking_stop() -> Result<(), SkotiqError> {
    let mut guard = acquire_stacker();
    if guard.take().is_none() {
        return Err(not_started());
    }
    tracing::info!("Live stacker stopped and resources released");
    Ok(())
}

#[flutter_rust_bridge::frb(sync)]
pub fn api_stacking_is_active() -> bool {
    acquire_stacker().is_some()
}

/// Frames in the stack; 0 when no stack is running.
#[flutter_rust_bridge::frb(sync)]
pub fn api_stacking_frame_count() -> u32 {
    acquire_stacker()
        .as_ref()
        .map_or(0, |s| s.stacker.frame_count())
}

#[cfg(test)]
mod tests;
