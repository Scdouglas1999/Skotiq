//! Live stacking bridge API
//!
//! Exposes the live stacking engine to Dart via flutter_rust_bridge.
//! Uses a global singleton LiveStacker protected by a Mutex.

use skotiq_imaging::stack_master::{write_stack_master, FrameProvenance};
use skotiq_imaging::stacking::{
    debayer_cfa_to_rgb, LiveStackConfig, LiveStacker, SensorMode, StackingStats,
};
use skotiq_imaging::{
    read_image, BayerPattern, DebayerAlgorithm, ImageData, StarDetectionConfig,
};
use std::sync::Mutex;
use std::sync::OnceLock;

/// How CFA frames are converted to RGB for the *current* stacking session.
///
/// The resolved pattern/algorithm are decided once at session start (from the
/// session config plus the reference frame's Bayer geometry) and then reused
/// for every subsequent `from_data` frame so the whole stack is demosaiced
/// consistently. `None` (i.e. the singleton holds no `ColorIngest`) means the
/// session is monochrome and incoming `from_data` frames are fed as a single
/// channel, byte-for-byte as before OSC support existed.
#[derive(Debug, Clone, Copy)]
struct ColorIngest {
    pattern: BayerPattern,
    algorithm: DebayerAlgorithm,
}

/// The live stacker plus the color-ingest decision made when the session
/// started. Bundling them in one cell guarantees the resolved demosaic and the
/// stacker are created, replaced and torn down atomically under a single lock.
struct StackerSession {
    stacker: LiveStacker,
    /// `Some` for OSC sessions, `None` for monochrome.
    color: Option<ColorIngest>,
}

/// Global live stacker instance
static LIVE_STACKER: OnceLock<Mutex<Option<StackerSession>>> = OnceLock::new();

fn get_stacker_lock() -> &'static Mutex<Option<StackerSession>> {
    LIVE_STACKER.get_or_init(|| Mutex::new(None))
}

/// Acquire the stacker mutex with poison recovery.
///
/// # `unwrap_or` policy
///
/// If a previous holder panicked, the mutex becomes poisoned. Rather than
/// making all future stacking calls fail permanently, we recover the inner
/// data (which may be in an inconsistent state) and clear it, logging a
/// warning so the issue is visible.
fn acquire_stacker() -> std::sync::MutexGuard<'static, Option<StackerSession>> {
    get_stacker_lock().lock().unwrap_or_else(|poisoned| {
        tracing::warn!(
            "Live stacker mutex was poisoned (a previous operation panicked); recovering"
        );
        poisoned.into_inner()
    })
}

/// Statistics returned to Dart about the stacking session
#[derive(Debug, Clone)]
pub struct LiveStackingStatsApi {
    pub stacked_frame_count: u32,
    pub total_frames_attempted: u32,
    pub rejected_alignment_failures: u32,
    pub avg_matched_pairs: f64,
    pub avg_alignment_residual: f64,
    pub total_sigma_rejected_pixels: u64,
}

impl From<StackingStats> for LiveStackingStatsApi {
    fn from(s: StackingStats) -> Self {
        Self {
            stacked_frame_count: s.stacked_frame_count,
            total_frames_attempted: s.total_frames_attempted,
            rejected_alignment_failures: s.rejected_alignment_failures,
            avg_matched_pairs: s.avg_matched_pairs,
            avg_alignment_residual: s.avg_alignment_residual,
            total_sigma_rejected_pixels: s.total_sigma_rejected_pixels,
        }
    }
}

/// Configuration parameters exposed to Dart for stacking setup
#[derive(Debug, Clone)]
pub struct LiveStackingConfigApi {
    pub sigma_clip_enabled: bool,
    pub sigma_clip_threshold: f64,
    pub max_match_stars: u32,
    pub match_radius_px: f64,
    pub match_flux_tolerance: f64,
    pub min_matched_pairs: u32,
    /// Sensor acquisition mode: `"mono"`, `"osc"`, or `"auto"` (case-insensitive).
    ///
    /// - `mono` — frames are single-channel luminance; never debayered.
    /// - `osc` — frames are a Bayer CFA mosaic that *must* be debayered to RGB;
    ///   if no pattern can be resolved this is a hard error (no silent
    ///   mono-fallback that would scramble the colour mosaic).
    /// - `auto` — debayer only when the frame actually carries Bayer geometry
    ///   (or `bayer_pattern` is supplied); otherwise treat as mono.
    ///
    /// Defaults to `"mono"`.
    pub sensor_mode: String,
    /// Explicit Bayer pattern override (`"RGGB"`/`"BGGR"`/`"GRBG"`/`"GBRG"`,
    /// case-insensitive). When `None`, OSC/auto sessions fall back to the
    /// pattern the reference frame declares via its FITS `BAYERPAT` geometry.
    /// An unrecognised string is a hard error.
    pub bayer_pattern: Option<String>,
    /// Demosaic quality: `"bilinear"`, `"vng"`, or `"superpixel"`
    /// (case-insensitive). Defaults to `"bilinear"`. An unrecognised value is a
    /// hard error rather than a silent best-guess.
    pub demosaic_quality: String,
}

impl Default for LiveStackingConfigApi {
    fn default() -> Self {
        Self {
            sigma_clip_enabled: true,
            sigma_clip_threshold: 2.5,
            max_match_stars: 100,
            match_radius_px: 50.0,
            match_flux_tolerance: 0.7,
            min_matched_pairs: 5,
            sensor_mode: "mono".to_string(),
            bayer_pattern: None,
            demosaic_quality: "bilinear".to_string(),
        }
    }
}

/// Parse the `demosaic_quality` string into a [`DebayerAlgorithm`].
///
/// Fails loud on an unrecognised value — a typo here would otherwise silently
/// pick a different demosaic than the user asked for.
fn parse_demosaic_quality(quality: &str) -> Result<DebayerAlgorithm, String> {
    match quality.trim().to_ascii_lowercase().as_str() {
        "bilinear" => Ok(DebayerAlgorithm::Bilinear),
        "vng" => Ok(DebayerAlgorithm::VNG),
        // Accept both the spaced and unspaced spelling so the Dart enum
        // (`superPixel`) and a human-typed `"super pixel"` both resolve.
        "superpixel" | "super_pixel" | "super pixel" => Ok(DebayerAlgorithm::SuperPixel),
        other => Err(format!(
            "Unknown demosaic quality '{}' (expected one of: bilinear, vng, superpixel)",
            other
        )),
    }
}

/// Parse an optional Bayer-pattern override string.
///
/// `None`/empty → `Ok(None)` (let the frame's geometry decide). A present but
/// unrecognised string → hard error.
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

/// Parse the `sensor_mode` string into a [`SensorMode`].
///
/// `"auto"` is a *first-class* state distinct from `"osc"`: auto debayers only
/// when a Bayer pattern actually resolves (override or frame geometry) and falls
/// back to mono otherwise, whereas osc *requires* a pattern and hard-errors
/// without one. Collapsing the two would reject every legitimate mono run made
/// under the default `"auto"` mode.
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

impl TryFrom<LiveStackingConfigApi> for LiveStackConfig {
    type Error = String;

    /// Build the native stacking config, surfacing any invalid demosaic /
    /// Bayer-pattern / sensor-mode string to the caller rather than falling back
    /// to a silent best-guess.
    fn try_from(api: LiveStackingConfigApi) -> Result<Self, Self::Error> {
        let demosaic_algorithm = parse_demosaic_quality(&api.demosaic_quality)?;
        let bayer_pattern = parse_bayer_pattern(&api.bayer_pattern)?;
        let sensor_mode = parse_sensor_mode(&api.sensor_mode)?;

        Ok(LiveStackConfig {
            sigma_clip_threshold: api.sigma_clip_threshold,
            sigma_clip_enabled: api.sigma_clip_enabled,
            // Why: live-stacking config values are u32
            // UI-bounded (max_match_stars ≤ 10_000, min_matched_pairs ≤
            // ~100); u32 → usize widening on every supported target.
            max_match_stars: api.max_match_stars as usize,
            match_radius_px: api.match_radius_px,
            match_flux_tolerance: api.match_flux_tolerance,
            min_matched_pairs: api.min_matched_pairs as usize,
            star_detection: StarDetectionConfig {
                detection_sigma: 4.0,
                min_snr: 8.0,
                ..StarDetectionConfig::default()
            },
            // OSC provenance. `bayer_pattern` here is the *config-declared*
            // override; the actual pattern used for ingest is resolved at
            // session start (config override → frame geometry) by the
            // `stacking_start*` functions, which is the value that ends up
            // driving the demosaic. These fields document the session for FITS
            // provenance / diagnostics.
            bayer_pattern,
            sensor_mode,
            demosaic_algorithm,
            // Alignment-residual rejection threshold and any other internal
            // tuning knobs not surfaced in the API keep their tuned defaults.
            ..LiveStackConfig::default()
        })
    }
}

// Public API functions (exposed to Dart via flutter_rust_bridge)

/// Start live stacking by loading a reference image from a file path.
///
/// This initializes the stacker with the given image as the reference frame.
/// All subsequent frames will be aligned to this reference.
pub fn stacking_start(
    reference_image_path: String,
    config: LiveStackingConfigApi,
) -> Result<LiveStackingStatsApi, String> {
    tracing::info!(
        "Starting live stacking with reference: {}",
        reference_image_path
    );

    let path = std::path::Path::new(&reference_image_path);
    let read_result =
        read_image(path).map_err(|e| format!("Failed to read reference image: {}", e))?;

    let native_config: LiveStackConfig = config.try_into()?;

    // Resolve whether this session debayers, and with which pattern/algorithm.
    //
    // The pattern is the config override first, then the reference frame's
    // effective (offset-corrected) FITS BAYERPAT geometry.
    //
    //   * Osc — *must* debayer; an unresolvable pattern is a hard error
    //     (debayering with a guessed mosaic would corrupt colour, and silently
    //     falling back to mono would scramble a CFA frame).
    //   * Auto — debayer when a pattern resolves (explicit override or the
    //     frame carries Bayer geometry); otherwise stack as mono. A missing
    //     pattern is *not* an error.
    //   * Mono — never debayers, regardless of any override.
    let frame_pattern = read_result.bayer.map(|geo| geo.effective);
    let resolved_pattern = native_config.bayer_pattern.or(frame_pattern);

    let color = match native_config.sensor_mode {
        SensorMode::Osc => match resolved_pattern {
            Some(pattern) => Some(ColorIngest {
                pattern,
                algorithm: native_config.demosaic_algorithm,
            }),
            None => {
                return Err(
                    "OSC declared but no Bayer pattern resolvable (set bayer_pattern in the \
                     config or capture with a BAYERPAT FITS header)"
                        .to_string(),
                );
            }
        },
        SensorMode::Auto => resolved_pattern.map(|pattern| ColorIngest {
            pattern,
            algorithm: native_config.demosaic_algorithm,
        }),
        SensorMode::Mono => None,
    };

    // The reference frame's own EXPTIME/DATE-OBS start the master's
    // integration: its pixels are in the stack, so its exposure is too.
    let reference_provenance = FrameProvenance::from_header_map(&read_result.header);

    // Build the reference frame the stacker actually sees: debayered RGB for a
    // colour session, the raw frame for mono.
    let reference_image = match color {
        Some(ingest) => debayer_cfa_to_rgb(&read_result.image, ingest.pattern, ingest.algorithm)
            .map_err(|e| format!("Failed to debayer reference frame: {}", e))?,
        None => read_result.image,
    };

    let stacker =
        LiveStacker::new_with_provenance(&reference_image, native_config, &reference_provenance)
            .map_err(|e| format!("Failed to initialize stacker: {}", e))?;

    let stats = stacker.get_stats();

    let mut guard = acquire_stacker();
    *guard = Some(StackerSession { stacker, color });

    tracing::info!(
        "Live stacking started successfully ({})",
        if color.is_some() { "color/OSC" } else { "mono" }
    );
    Ok(stats.into())
}

/// Start live stacking from raw image data (width, height, u16 pixel data).
///
/// This is used when the reference frame is already in memory (e.g. from a capture).
pub fn stacking_start_from_data(
    width: u32,
    height: u32,
    data: Vec<u16>,
    config: LiveStackingConfigApi,
) -> Result<LiveStackingStatsApi, String> {
    tracing::info!(
        "Starting live stacking from data: {}x{} ({} pixels)",
        width,
        height,
        data.len()
    );

    let native_config: LiveStackConfig = config.try_into()?;

    // In-memory frames are a single CFA (or mono) plane — there is no FITS
    // header to read a Bayer geometry from, so the only pattern source is the
    // config override.
    //
    //   * Osc — requires an explicit override; without one, hard error (the
    //     raw u16 buffer carries no BAYERPAT to auto-detect from).
    //   * Auto — debayer only when an override is supplied; otherwise mono
    //     (there is nothing to auto-detect from a raw u16 buffer).
    //   * Mono — never debayers.
    let color = match native_config.sensor_mode {
        SensorMode::Osc => match native_config.bayer_pattern {
            Some(pattern) => Some(ColorIngest {
                pattern,
                algorithm: native_config.demosaic_algorithm,
            }),
            None => {
                return Err(
                    "OSC declared but no Bayer pattern resolvable (in-memory frames carry no \
                     BAYERPAT header — set bayer_pattern in the config)"
                        .to_string(),
                );
            }
        },
        SensorMode::Auto => native_config.bayer_pattern.map(|pattern| ColorIngest {
            pattern,
            algorithm: native_config.demosaic_algorithm,
        }),
        SensorMode::Mono => None,
    };

    let cfa = ImageData::from_u16(width, height, 1, &data);
    let reference_image = match color {
        Some(ingest) => debayer_cfa_to_rgb(&cfa, ingest.pattern, ingest.algorithm)
            .map_err(|e| format!("Failed to debayer reference frame: {}", e))?,
        None => cfa,
    };

    let stacker = LiveStacker::new(&reference_image, native_config)
        .map_err(|e| format!("Failed to initialize stacker: {}", e))?;

    let stats = stacker.get_stats();

    let mut guard = acquire_stacker();
    *guard = Some(StackerSession { stacker, color });

    tracing::info!(
        "Live stacking started successfully from data ({})",
        if color.is_some() { "color/OSC" } else { "mono" }
    );
    Ok(stats.into())
}

/// Add a frame to the live stack by file path.
///
/// Returns the u16 pixel data of the current stacked result, along with dimensions.
/// The stacked result can be displayed directly as a preview.
pub fn stacking_add_frame(image_path: String) -> Result<LiveStackingAddFrameResult, String> {
    tracing::info!("Adding frame to stack: {}", image_path);

    let path = std::path::Path::new(&image_path);
    let read_result = read_image(path).map_err(|e| format!("Failed to read frame image: {}", e))?;

    let mut guard = acquire_stacker();

    let session = guard
        .as_mut()
        .ok_or_else(|| "Live stacker not initialized. Call stacking_start first.".to_string())?;

    // Feed the same buffer layout the session was started with: debayered RGB
    // for a colour session, the raw frame for mono. Mixing layouts would trip
    // the stacker's channel-count guard, which is exactly the loud failure we
    // want if a frame's geometry disagrees with the session.
    let provenance = FrameProvenance::from_header_map(&read_result.header);
    let frame_image = match session.color {
        Some(ingest) => debayer_cfa_to_rgb(&read_result.image, ingest.pattern, ingest.algorithm)
            .map_err(|e| format!("Failed to debayer frame: {}", e))?,
        None => read_result.image,
    };

    let result_image = session
        .stacker
        .add_frame_with_provenance(&frame_image, &provenance)?;

    let result_u16 = result_image
        .as_u16()
        .ok_or_else(|| "Failed to convert stacked result to u16".to_string())?;

    Ok(LiveStackingAddFrameResult {
        width: result_image.width,
        height: result_image.height,
        channels: result_image.channels,
        data: result_u16,
        stats: session.stacker.get_stats().into(),
    })
}

/// Add a frame to the live stack from raw u16 pixel data.
pub fn stacking_add_frame_from_data(
    width: u32,
    height: u32,
    data: Vec<u16>,
) -> Result<LiveStackingAddFrameResult, String> {
    tracing::debug!("Adding frame from data to stack: {}x{}", width, height);

    let mut guard = acquire_stacker();

    let session = guard
        .as_mut()
        .ok_or_else(|| "Live stacker not initialized. Call stacking_start first.".to_string())?;

    // The incoming buffer is the CFA (or mono) plane. Debayer it with the
    // session's resolved pattern/algorithm so every frame is demosaiced
    // identically to the reference; mono sessions feed it as one channel.
    let frame_image = match session.color {
        Some(ingest) => {
            let cfa = ImageData::from_u16(width, height, 1, &data);
            debayer_cfa_to_rgb(&cfa, ingest.pattern, ingest.algorithm)
                .map_err(|e| format!("Failed to debayer frame: {}", e))?
        }
        None => ImageData::from_u16(width, height, 1, &data),
    };

    let result_image = session.stacker.add_frame(&frame_image)?;

    let result_u16 = result_image
        .as_u16()
        .ok_or_else(|| "Failed to convert stacked result to u16".to_string())?;

    Ok(LiveStackingAddFrameResult {
        width: result_image.width,
        height: result_image.height,
        channels: result_image.channels,
        data: result_u16,
        stats: session.stacker.get_stats().into(),
    })
}

/// Result from adding a frame to the stack
#[derive(Debug, Clone)]
pub struct LiveStackingAddFrameResult {
    pub width: u32,
    pub height: u32,
    /// Channel count of the stacked result: `1` for a monochrome session, `3`
    /// for an OSC/colour session. The Dart side uses this to interpret `data`
    /// as a single luminance plane vs interleaved RGB16.
    pub channels: u32,
    pub data: Vec<u16>,
    pub stats: LiveStackingStatsApi,
}

/// Get the current stacked result without adding a frame.
pub fn stacking_get_result() -> Result<LiveStackingAddFrameResult, String> {
    let guard = acquire_stacker();

    let session = guard
        .as_ref()
        .ok_or_else(|| "Live stacker not initialized".to_string())?;

    let result_image = session.stacker.get_current_stack();

    let result_u16 = result_image
        .as_u16()
        .ok_or_else(|| "Failed to convert stacked result to u16".to_string())?;

    Ok(LiveStackingAddFrameResult {
        width: result_image.width,
        height: result_image.height,
        channels: result_image.channels,
        data: result_u16,
        stats: session.stacker.get_stats().into(),
    })
}

/// What was written when the stacked master was saved.
#[derive(Debug, Clone)]
pub struct LiveStackingMasterApi {
    /// Where the master was written.
    pub file_path: String,
    /// Frames whose pixels are in the master.
    pub stacked_frame_count: u32,
    /// The master's `EXPTIME`: Σ of the exposures the stacked frames reported.
    /// `0.0` means no frame reported one — the header says so in its comment.
    pub total_integration_secs: f64,
    /// The master's `DATE-OBS`, as written.
    pub date_obs: String,
}

/// Save the accumulated stack as a FITS master.
///
/// The master is the session's data product, so it is written as FITS rather
/// than a PNG: `EXPTIME` and `DATE-OBS` are synthesized from the frames the
/// stacker actually folded (see [`skotiq_imaging::stack_master`]), which is
/// the only place that metadata exists for an in-memory stack.
pub fn stacking_save_master_fits(file_path: String) -> Result<LiveStackingMasterApi, String> {
    let guard = acquire_stacker();

    let session = guard
        .as_ref()
        .ok_or_else(|| "Live stacker not initialized".to_string())?;

    let provenance = session.stacker.provenance();
    if provenance.stacked_frames() == 0 {
        return Err("There is no stacked master to save yet".to_string());
    }

    let image = session.stacker.get_current_stack();
    let path = std::path::Path::new(&file_path);
    write_stack_master(path, &image, provenance)
        .map_err(|e| format!("Failed to write stacked master: {:?}", e))?;

    let header = provenance.to_fits_header();
    tracing::info!(
        "Stacked master saved: {} ({} frames, {:.1} s integration)",
        file_path,
        provenance.stacked_frames(),
        provenance.total_integration_secs()
    );

    Ok(LiveStackingMasterApi {
        file_path,
        stacked_frame_count: provenance.stacked_frames(),
        total_integration_secs: provenance.total_integration_secs(),
        // `to_fits_header` always sets DATE-OBS (it synthesizes one when no
        // frame reported it), so a missing card here is an internal
        // invariant break — surface it as the API error instead of quietly
        // returning an empty stamp.
        date_obs: header
            .get_string("DATE-OBS")
            .ok_or_else(|| "internal: stacked master header lacks DATE-OBS".to_string())?
            .to_string(),
    })
}

/// Get the current stacking statistics.
pub fn stacking_get_stats() -> Result<LiveStackingStatsApi, String> {
    let guard = acquire_stacker();

    let session = guard
        .as_ref()
        .ok_or_else(|| "Live stacker not initialized".to_string())?;

    Ok(session.stacker.get_stats().into())
}

/// Reset the live stacker, clearing all accumulated data but keeping the reference frame.
pub fn stacking_reset() -> Result<(), String> {
    let mut guard = acquire_stacker();

    let session = guard
        .as_mut()
        .ok_or_else(|| "Live stacker not initialized".to_string())?;

    session.stacker.reset();
    tracing::info!("Live stacker reset");
    Ok(())
}

/// Stop live stacking and release all resources.
pub fn stacking_stop() -> Result<(), String> {
    let mut guard = acquire_stacker();

    if guard.is_none() {
        return Err("Live stacker not initialized".to_string());
    }

    *guard = None;
    tracing::info!("Live stacker stopped and resources released");
    Ok(())
}

/// Check if live stacking is currently active.
#[flutter_rust_bridge::frb(sync)]
pub fn stacking_is_active() -> bool {
    acquire_stacker().is_some()
}

/// Get the current frame count.
///
/// # `unwrap_or` policy
///
/// No stacker initialised yet → 0 frames. The UI uses this to render the
/// "Stacked: N frames" badge; absent stacker = no badge, matching the
/// "stacking session not started" state.
#[flutter_rust_bridge::frb(sync)]
pub fn stacking_frame_count() -> u32 {
    acquire_stacker()
        .as_ref()
        .map(|s| s.stacker.frame_count())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Serialises every test that touches the process-global `LIVE_STACKER`
    /// singleton so they don't clobber each other's session under `cargo test`'s
    /// parallel harness. Tests that only exercise pure parsing don't need it.
    static SINGLETON_TEST_LOCK: Mutex<()> = Mutex::new(());

    fn singleton_guard() -> std::sync::MutexGuard<'static, ()> {
        SINGLETON_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner())
    }

    const IMG_W: u32 = 512;
    const IMG_H: u32 = 512;

    /// Config for the end-to-end ingest tests.
    ///
    /// `min_matched_pairs: 0` makes [`LiveStacker::new`]/`add_frame` accept a
    /// frame regardless of how many stars its detector finds. This deliberately
    /// decouples these *bridge-wiring* tests (which verify config parsing, the
    /// CFA→RGB debayer-on-ingest path, and channel propagation) from the
    /// imaging crate's star-detection tuning — alignment quality is exercised by
    /// the imaging crate's own stacker tests, not here. It is a legitimate
    /// public-API value (the field is `u32`), not a test-only backdoor.
    fn base_config() -> LiveStackingConfigApi {
        LiveStackingConfigApi {
            min_matched_pairs: 0,
            ..LiveStackingConfigApi::default()
        }
    }

    /// Build a synthetic single-channel U16 frame: a low-noise background with
    /// a few bright, well-separated bright blobs. The blobs make the frame
    /// non-uniform (so a CFA mosaic of it debayers to a non-trivial RGB image)
    /// without depending on the detector accepting them.
    fn make_star_plane(width: u32, height: u32) -> Vec<u16> {
        let w = width as usize;
        let h = height as usize;
        let bg = 1000u16;
        let mut data = vec![bg; w * h];

        // Deterministic low-amplitude background texture.
        for (i, pixel) in data.iter_mut().enumerate() {
            let n = ((i as u64).wrapping_mul(1103515245).wrapping_add(12345) >> 16) & 0xFF;
            let noise = (n as i32 - 128) / 8; // ~[-16, 16] ADU
            *pixel = (bg as i32 + noise).clamp(0, 65535) as u16;
        }

        // A handful of bright Gaussian blobs.
        let blobs = [
            (40.0, 40.0, 40000.0),
            (120.0, 60.0, 35000.0),
            (200.0, 50.0, 38000.0),
            (60.0, 140.0, 30000.0),
            (160.0, 150.0, 36000.0),
        ];
        for &(sx, sy, brightness) in &blobs {
            let radius = 8i32;
            let sigma = 2.5;
            for dy in -radius..=radius {
                for dx in -radius..=radius {
                    let px = sx as i32 + dx;
                    let py = sy as i32 + dy;
                    if px < 0 || px >= width as i32 || py < 0 || py >= height as i32 {
                        continue;
                    }
                    let dist_sq = (dx * dx + dy * dy) as f64;
                    let gauss = (-dist_sq / (2.0 * sigma * sigma)).exp();
                    let idx = py as usize * w + px as usize;
                    data[idx] = (data[idx] as u32 + (brightness * gauss) as u32).min(65535) as u16;
                }
            }
        }

        data
    }

    // Config From-parse

    #[test]
    fn config_parses_valid_demosaic_qualities() {
        for (q, expected) in [
            ("bilinear", DebayerAlgorithm::Bilinear),
            ("VNG", DebayerAlgorithm::VNG),
            ("superpixel", DebayerAlgorithm::SuperPixel),
            ("super pixel", DebayerAlgorithm::SuperPixel),
        ] {
            let cfg = LiveStackingConfigApi {
                demosaic_quality: q.to_string(),
                ..LiveStackingConfigApi::default()
            };
            let native: LiveStackConfig = cfg.try_into().expect("valid quality parses");
            assert_eq!(native.demosaic_algorithm, expected, "quality {q}");
        }
    }

    #[test]
    fn config_parses_sensor_modes_and_patterns() {
        let cfg = LiveStackingConfigApi {
            sensor_mode: "OSC".to_string(),
            bayer_pattern: Some("grbg".to_string()),
            ..LiveStackingConfigApi::default()
        };
        let native: LiveStackConfig = cfg.try_into().expect("valid osc config parses");
        assert_eq!(native.sensor_mode, SensorMode::Osc);
        assert_eq!(native.bayer_pattern, Some(BayerPattern::GRBG));

        // "auto" is its own first-class mode (debayer only when a pattern
        // resolves), distinct from OSC (which requires one).
        let auto = LiveStackingConfigApi {
            sensor_mode: "auto".to_string(),
            ..LiveStackingConfigApi::default()
        };
        let native: LiveStackConfig = auto.try_into().expect("auto parses");
        assert_eq!(native.sensor_mode, SensorMode::Auto);
        assert_eq!(native.bayer_pattern, None);
    }

    #[test]
    fn config_default_is_mono_bilinear_no_pattern() {
        let native: LiveStackConfig = LiveStackingConfigApi::default()
            .try_into()
            .expect("default config parses");
        assert_eq!(native.sensor_mode, SensorMode::Mono);
        assert_eq!(native.demosaic_algorithm, DebayerAlgorithm::Bilinear);
        assert_eq!(native.bayer_pattern, None);
    }

    #[test]
    fn config_invalid_demosaic_quality_is_error() {
        let cfg = LiveStackingConfigApi {
            demosaic_quality: "lanczos".to_string(),
            ..LiveStackingConfigApi::default()
        };
        let err = LiveStackConfig::try_from(cfg).expect_err("invalid quality must error");
        assert!(err.contains("demosaic quality"), "got: {err}");
        assert!(err.contains("lanczos"), "error names the bad value: {err}");
    }

    #[test]
    fn config_invalid_bayer_pattern_is_error() {
        let cfg = LiveStackingConfigApi {
            bayer_pattern: Some("xyzw".to_string()),
            ..LiveStackingConfigApi::default()
        };
        let err = LiveStackConfig::try_from(cfg).expect_err("invalid pattern must error");
        assert!(err.contains("Bayer pattern"), "got: {err}");
    }

    #[test]
    fn config_invalid_sensor_mode_is_error() {
        let cfg = LiveStackingConfigApi {
            sensor_mode: "rgbw".to_string(),
            ..LiveStackingConfigApi::default()
        };
        let err = LiveStackConfig::try_from(cfg).expect_err("invalid sensor mode must error");
        assert!(err.contains("sensor mode"), "got: {err}");
    }

    // OSC-without-pattern (in-memory ingest)

    #[test]
    fn osc_start_from_data_without_pattern_is_error() {
        let _g = singleton_guard();
        let _ = stacking_stop(); // ensure clean slate

        let cfg = LiveStackingConfigApi {
            sensor_mode: "osc".to_string(),
            bayer_pattern: None,
            ..base_config()
        };
        let data = make_star_plane(IMG_W, IMG_H);
        let err = stacking_start_from_data(IMG_W, IMG_H, data, cfg)
            .expect_err("OSC without resolvable pattern must error");
        assert!(
            err.contains("OSC declared but no Bayer pattern resolvable"),
            "got: {err}"
        );
        // Nothing should have been installed.
        assert!(
            !stacking_is_active(),
            "failed start must not leave a session"
        );
    }

    // RGB round-trip

    /// A small, fully-specified RGGB CFA where each colour site holds a distinct
    /// ADU so we can predict the demosaiced RGB at a known pixel exactly.
    /// Layout (RGGB): row0 = R G R G, row1 = G B G B, ...
    /// R sites = 1000, G sites = 500, B sites = 100.
    fn uniform_rggb_cfa(width: usize, height: usize) -> Vec<u16> {
        let mut pixels = vec![0u16; width * height];
        for y in 0..height {
            for x in 0..width {
                pixels[y * width + x] = match BayerPattern::RGGB.color_at(x, y) {
                    skotiq_imaging::BayerColor::Red => 1000,
                    skotiq_imaging::BayerColor::Green => 500,
                    skotiq_imaging::BayerColor::Blue => 100,
                };
            }
        }
        pixels
    }

    #[test]
    fn osc_start_from_data_produces_three_channel_result() {
        let _g = singleton_guard();
        let _ = stacking_stop();

        let cfg = LiveStackingConfigApi {
            sensor_mode: "osc".to_string(),
            bayer_pattern: Some("RGGB".to_string()),
            demosaic_quality: "bilinear".to_string(),
            ..base_config()
        };

        // A CFA star field: the underlying scene is a mono star plane sampled
        // through an RGGB mosaic, which still yields detectable stars in the
        // luminance proxy after debayering.
        let cfa = make_star_plane(IMG_W, IMG_H);
        stacking_start_from_data(IMG_W, IMG_H, cfa.clone(), cfg).expect("osc start succeeds");

        // The current stack is the debayered reference: 3 channels, same dims.
        let result = stacking_get_result().expect("result available");
        assert_eq!(result.channels, 3, "OSC stack must be 3-channel RGB");
        assert_eq!(result.width, IMG_W);
        assert_eq!(result.height, IMG_H);
        assert_eq!(result.data.len(), (IMG_W * IMG_H * 3) as usize);

        // The stack must equal the canonical debayer of the same CFA exactly —
        // the ingest path debayers with no extra processing on the first frame.
        let reference_rgb = debayer_cfa_to_rgb(
            &ImageData::from_u16(IMG_W, IMG_H, 1, &cfa),
            BayerPattern::RGGB,
            DebayerAlgorithm::Bilinear,
        )
        .expect("reference debayer")
        .as_u16()
        .expect("rgb u16");
        assert_eq!(
            result.data, reference_rgb,
            "OSC stack reference must be the canonical debayer of the CFA"
        );

        let _ = stacking_stop();
    }

    /// Known-pixel RGB check: a uniform RGGB CFA (R=1000, G=500, B=100)
    /// debayers to predictable interior values. At an interior *red* site the
    /// red channel keeps 1000, green is the cross-average of four 500s (=500),
    /// and blue is the diagonal-average of four 100s (=100).
    #[test]
    fn rggb_known_pixel_debayers_to_expected_rgb() {
        let cfa = uniform_rggb_cfa(8, 8);
        let rgb = debayer_cfa_to_rgb(
            &ImageData::from_u16(8, 8, 1, &cfa),
            BayerPattern::RGGB,
            DebayerAlgorithm::Bilinear,
        )
        .expect("debayer")
        .as_u16()
        .expect("u16");

        // Interior red site at (x=2, y=2) — fully surrounded, no edge clamping.
        let site = (2 * 8 + 2) * 3;
        assert_eq!(rgb[site], 1000, "R at red site");
        assert_eq!(
            rgb[site + 1],
            500,
            "G interpolated from four green neighbours"
        );
        assert_eq!(
            rgb[site + 2],
            100,
            "B interpolated from four blue neighbours"
        );
    }

    #[test]
    fn osc_add_frame_from_data_keeps_three_channels() {
        let _g = singleton_guard();
        let _ = stacking_stop();

        let cfg = LiveStackingConfigApi {
            sensor_mode: "osc".to_string(),
            bayer_pattern: Some("RGGB".to_string()),
            ..base_config()
        };
        let cfa = make_star_plane(IMG_W, IMG_H);
        stacking_start_from_data(IMG_W, IMG_H, cfa.clone(), cfg).expect("osc start");

        // Feeding the identical CFA plane debayers and accumulates as RGB.
        let added = stacking_add_frame_from_data(IMG_W, IMG_H, cfa).expect("add frame");
        assert_eq!(added.channels, 3, "added OSC frame stays 3-channel");
        assert_eq!(added.data.len(), (IMG_W * IMG_H * 3) as usize);
        assert_eq!(
            added.stats.stacked_frame_count, 2,
            "identical frame aligns and stacks"
        );

        let _ = stacking_stop();
    }

    // Mono path is unchanged

    #[test]
    fn mono_start_from_data_is_single_channel() {
        let _g = singleton_guard();
        let _ = stacking_stop();

        let data = make_star_plane(IMG_W, IMG_H);
        stacking_start_from_data(IMG_W, IMG_H, data.clone(), base_config()).expect("mono start");

        let result = stacking_get_result().expect("result");
        assert_eq!(result.channels, 1, "mono stack stays single-channel");
        assert_eq!(result.width, IMG_W);
        assert_eq!(result.height, IMG_H);
        assert_eq!(result.data.len(), (IMG_W * IMG_H) as usize);
        // The single-frame stack is the reference frame itself, byte-for-byte.
        assert_eq!(result.data, data);

        let _ = stacking_stop();
    }

    // AUTO with no pattern resolves to mono (regression guard)

    #[test]
    fn auto_start_from_data_without_pattern_is_mono() {
        // The default Stack-and-Share config is `sensor_mode = "auto"`. On a
        // monochrome session (a raw u16 buffer carries no BAYERPAT and the
        // config has no override) AUTO must stack as MONO, not error. This is
        // the default mono Stack-and-Share path; collapsing auto into osc
        // bricks it.
        let _g = singleton_guard();
        let _ = stacking_stop();

        let cfg = LiveStackingConfigApi {
            sensor_mode: "auto".to_string(),
            bayer_pattern: None,
            ..base_config()
        };
        let data = make_star_plane(IMG_W, IMG_H);
        stacking_start_from_data(IMG_W, IMG_H, data.clone(), cfg)
            .expect("auto without pattern must stack as mono, not error");

        let result = stacking_get_result().expect("result");
        assert_eq!(result.channels, 1, "auto+no-pattern stacks as mono");
        assert_eq!(result.data.len(), (IMG_W * IMG_H) as usize);
        assert_eq!(result.data, data, "mono reference is byte-for-byte");

        let _ = stacking_stop();
    }

    #[test]
    fn auto_start_from_data_with_pattern_debayers_to_color() {
        // The complement: AUTO *with* an explicit override does debayer.
        let _g = singleton_guard();
        let _ = stacking_stop();

        let cfg = LiveStackingConfigApi {
            sensor_mode: "auto".to_string(),
            bayer_pattern: Some("RGGB".to_string()),
            ..base_config()
        };
        let cfa = make_star_plane(IMG_W, IMG_H);
        stacking_start_from_data(IMG_W, IMG_H, cfa, cfg).expect("auto+pattern start");

        let result = stacking_get_result().expect("result");
        assert_eq!(result.channels, 3, "auto+pattern debayers to RGB");
        assert_eq!(result.data.len(), (IMG_W * IMG_H * 3) as usize);

        let _ = stacking_stop();
    }

    // Every demosaic algorithm ingests end-to-end (geometry guard)

    /// SuperPixel halves resolution; Bilinear/VNG keep it. Each must produce an
    /// integrated result whose declared dimensions and buffer length are
    /// self-consistent — guarding against assuming the input CFA size for an
    /// algorithm that changes geometry.
    #[test]
    fn every_demosaic_quality_ingests_with_consistent_geometry() {
        for quality in ["bilinear", "vng", "superpixel"] {
            let _g = singleton_guard();
            let _ = stacking_stop();

            let cfg = LiveStackingConfigApi {
                sensor_mode: "osc".to_string(),
                bayer_pattern: Some("RGGB".to_string()),
                demosaic_quality: quality.to_string(),
                ..base_config()
            };
            let cfa = make_star_plane(IMG_W, IMG_H);
            stacking_start_from_data(IMG_W, IMG_H, cfa, cfg)
                .unwrap_or_else(|e| panic!("osc start with {quality} failed: {e}"));

            let result = stacking_get_result().expect("result");
            assert_eq!(result.channels, 3, "{quality}: OSC result is 3-channel");

            // The declared dims must match the demosaiced output (half for
            // superpixel, full otherwise) and the buffer must be exactly
            // width*height*3 — never the short buffer that the old
            // input-dims-assumption produced for superpixel.
            let (expect_w, expect_h) = if quality == "superpixel" {
                (IMG_W / 2, IMG_H / 2)
            } else {
                (IMG_W, IMG_H)
            };
            assert_eq!(result.width, expect_w, "{quality}: width");
            assert_eq!(result.height, expect_h, "{quality}: height");
            assert_eq!(
                result.data.len(),
                (result.width * result.height * 3) as usize,
                "{quality}: buffer length matches declared 3-channel dims"
            );

            let _ = stacking_stop();
        }
    }

    // FITS master

    /// Write a single-channel FITS light frame carrying the two keywords the
    /// master's header is built from.
    fn write_light_frame(path: &std::path::Path, exposure_secs: f64, date_obs: &str) {
        let image = ImageData::from_u16(IMG_W, IMG_H, 1, &make_star_plane(IMG_W, IMG_H));
        let mut header = skotiq_imaging::FitsHeader::new();
        header.set_float("EXPTIME", exposure_secs);
        header.set_string("DATE-OBS", date_obs);
        header.set_string("IMAGETYP", "LIGHT");
        skotiq_imaging::write_fits(path, &image, &header).expect("light frame written");
    }

    /// Owner decision 8: the master saves as FITS, and its `EXPTIME` /
    /// `DATE-OBS` come from the frames the stacker really folded — including
    /// the reference frame, which contributes pixels like any other.
    #[test]
    fn saved_master_sums_the_integration_of_the_frames_it_stacked() {
        let _g = singleton_guard();
        let _ = stacking_stop();

        let dir = std::env::temp_dir().join("ns-bridge-stack-master");
        std::fs::create_dir_all(&dir).expect("temp dir");
        let reference = dir.join("reference.fits");
        let second = dir.join("second.fits");
        let master = dir.join("master.fits");
        write_light_frame(&reference, 120.0, "2026-08-14T03:25:00");
        // Earlier than the reference: DATE-OBS must follow the clock, not the
        // order the frames were handed to the stacker.
        write_light_frame(&second, 120.0, "2026-08-14T03:22:30");

        stacking_start(
            reference.to_string_lossy().to_string(),
            base_config().clone(),
        )
        .expect("reference started the stack");
        stacking_add_frame(second.to_string_lossy().to_string()).expect("second frame stacked");

        let saved = stacking_save_master_fits(master.to_string_lossy().to_string())
            .expect("master written");
        assert_eq!(saved.stacked_frame_count, 2);
        assert_eq!(saved.total_integration_secs, 240.0);
        assert_eq!(saved.date_obs, "2026-08-14T03:22:30.000");

        let (image, header) = skotiq_imaging::read_fits(&master).expect("master reads back");
        assert_eq!(image.width, IMG_W);
        assert_eq!(header.get_float("EXPTIME"), Some(240.0));
        assert_eq!(
            header.get_string("DATE-OBS"),
            Some("2026-08-14T03:22:30.000")
        );
        assert_eq!(header.get_int("NFRAMES"), Some(2));

        let _ = stacking_stop();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Saving with no stack running fails loudly rather than writing an empty
    /// file the operator would mistake for their integration.
    #[test]
    fn saving_a_master_without_a_stacker_is_an_error() {
        let _g = singleton_guard();
        let _ = stacking_stop();

        let err = stacking_save_master_fits(
            std::env::temp_dir()
                .join("ns-no-stack-master.fits")
                .to_string_lossy()
                .to_string(),
        )
        .expect_err("no stacker means no master");
        assert!(err.contains("not initialized"), "unexpected error: {err}");
    }
}
