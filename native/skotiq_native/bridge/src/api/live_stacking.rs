//! Live stacking: multi-filter registry fed frame by frame from Dart.
//!
//! Each optical filter (or `"Unfiltered"`) owns an independent [`SlotHandle`]
//! with a microsecond-locked metadata `RwLock` separate from the heavy
//! `LiveStacker` pixel mutex so UI queries, wait-free atomics, Darkroom
//! cache-identity checks, and other filters never stall behind a heavy stack.
//!
//! Preview rendering works directly off un-quantized `f32` running means on
//! background worker threads using native-resolution local sky-noise estimation
//! and progressive EAA MTF stretching so faint structure visibly reveals itself
//! as more frames integrate.

use std::collections::{BTreeMap, VecDeque};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, RwLock, RwLockReadGuard, RwLockWriteGuard};

use rayon::prelude::*;
use skotiq_imaging::recipe::OpImage;
use skotiq_imaging::stack_master::{write_stack_master, FrameProvenance};
use skotiq_imaging::stacking::{
    debayer_cfa_to_rgb, FrameTelemetry, LiveStackConfig, LiveStacker, SensorMode, StackingStats,
};
use skotiq_imaging::{
    read_image, BayerPattern, ColorFilterArray, DebayerAlgorithm, ImageData, StarDetectionConfig,
};

use crate::error::SkotiqError;

/// Default filter slot key when no filter is declared.
pub(crate) const DEFAULT_FILTER_KEY: &str = "Unfiltered";

/// Maximum per-frame diagnostic events retained per filter slot.
const MAX_FRAME_EVENTS: usize = 200;

/// Normalize a user- or header-supplied filter key into a consistent slot key.
pub(crate) fn normalize_filter_key(raw: Option<&str>) -> String {
    match raw.map(str::trim) {
        Some(s) if !s.is_empty() && s != "—" => s.to_string(),
        _ => DEFAULT_FILTER_KEY.to_string(),
    }
}

/// What the stacker is set up with.
#[derive(Debug, Clone)]
pub struct ApiLiveStackingConfig {
    pub sigma_clip_enabled: bool,
    pub sigma_clip_threshold: f64,
    pub max_match_stars: u32,
    pub match_radius_px: f64,
    pub match_flux_tolerance: f64,
    pub min_matched_pairs: u32,
    /// Maximum accepted inlier alignment residual in pixels (default 2.0).
    pub max_alignment_residual_px: f64,
    /// Star detection threshold in sky-noise sigmas (default 4.0).
    pub star_detection_sigma: f64,
    /// Minimum star SNR for alignment detection (default 8.0).
    pub star_detection_min_snr: f64,
    /// Sensor acquisition mode: `"mono"`, `"osc"`, or `"auto"` (case-insensitive).
    pub sensor_mode: String,
    /// Explicit Bayer pattern override (`"RGGB"`/`"BGGR"`/`"GRBG"`/`"GBRG"`,
    /// case-insensitive).
    pub bayer_pattern: Option<String>,
    /// Demosaic quality: `"bilinear"`, `"vng"`, or `"superpixel"`
    /// (case-insensitive).
    pub demosaic_quality: String,
}

/// The stacker's running tally.
#[derive(Debug, Clone)]
pub struct ApiLiveStackingStats {
    pub stacked_frame_count: u32,
    pub total_frames_attempted: u32,
    pub rejected_alignment_failures: u32,
    pub avg_matched_pairs: f64,
    pub avg_alignment_residual: f64,
    pub total_sigma_rejected_pixels: u64,
    pub total_integration_secs: f64,
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
            total_integration_secs: 0.0,
            other_filter_frames: s.other_filter_frames,
            last_other_filter: s.last_other_filter,
            filter: s.filter,
        }
    }
}

/// One per-frame evaluation record surfaced to the UI so live stacking is
/// transparent rather than a black box.
#[derive(Debug, Clone)]
pub struct ApiLiveStackFrameEvent {
    pub sequence_index: u32,
    pub filter_key: String,
    pub source_label: String,
    pub accepted: bool,
    pub rejection_reason: Option<String>,
    pub detected_stars: u32,
    pub matched_pairs: u32,
    pub inlier_pairs: u32,
    pub alignment_residual_px: f64,
    pub shift_x_px: f64,
    pub shift_y_px: f64,
    pub rotation_deg: f64,
    pub sigma_rejected_pixels: u64,
    pub exposure_secs: Option<f64>,
    pub timestamp_ms: i64,
}

/// Summary of one active per-filter stack slot.
#[derive(Debug, Clone)]
pub struct ApiLiveStackFilterSummary {
    pub filter_key: String,
    pub width: u32,
    pub height: u32,
    pub channels: u32,
    pub reference_image_path: Option<String>,
    pub revision: u64,
    pub stats: ApiLiveStackingStats,
}

/// The current stack and the tally behind it.
#[derive(Debug, Clone)]
pub struct ApiLiveStackingResult {
    pub width: u32,
    pub height: u32,
    /// Channel count of the stacked result: `1` for a monochrome session, `3`
    /// for an OSC/color session, whose `data` is interleaved RGB16.
    pub channels: u32,
    pub data: Vec<u16>,
    pub stats: ApiLiveStackingStats,
    pub filter_key: String,
    pub revision: u64,
    pub last_event: Option<ApiLiveStackFrameEvent>,
}

/// Stretched RGBA8 preview returned from off-UI-thread worker pool rendering.
#[derive(Debug, Clone)]
pub struct ApiStretchedPreview {
    pub width: u32,
    pub height: u32,
    pub channels: u32,
    pub rgba: Vec<u8>,
}

/// What was written when the stacked master was saved.
#[derive(Debug, Clone)]
pub struct ApiLiveStackingMaster {
    pub file_path: String,
    pub stacked_frame_count: u32,
    /// The master's `EXPTIME`: Σ of the exposures the stacked frames reported.
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

#[derive(Debug, Clone)]
struct CachedRgbaPreview {
    revision: u64,
    max_dimension: u32,
    width: u32,
    height: u32,
    channels: u32,
    rgba: Vec<u8>,
}

/// Lightweight, microsecond-locked metadata snapshot for one filter slot.
struct SlotMeta {
    filter_key: String,
    width: u32,
    height: u32,
    channels: u32,
    color: Option<ColorIngest>,
    reference_image_path: Option<String>,
    revision: u64,
    stats: ApiLiveStackingStats,
    events: VecDeque<ApiLiveStackFrameEvent>,
}

impl SlotMeta {
    fn push_event(&mut self, event: ApiLiveStackFrameEvent) {
        if self.events.len() >= MAX_FRAME_EVENTS {
            self.events.pop_back();
        }
        self.events.push_front(event);
    }

    fn record_frame_event(
        &mut self,
        telemetry: FrameTelemetry,
        sequence_index: u32,
        source_label: String,
        accepted: bool,
        rejection_reason: Option<String>,
        exposure_secs: Option<f64>,
    ) -> ApiLiveStackFrameEvent {
        let event = ApiLiveStackFrameEvent {
            sequence_index,
            filter_key: self.filter_key.clone(),
            source_label,
            accepted,
            rejection_reason,
            detected_stars: telemetry.detected_stars,
            matched_pairs: telemetry.matched_pairs,
            inlier_pairs: telemetry.inlier_pairs,
            alignment_residual_px: telemetry.alignment_residual_px,
            shift_x_px: telemetry.shift_x_px,
            shift_y_px: telemetry.shift_y_px,
            rotation_deg: telemetry.rotation_deg,
            sigma_rejected_pixels: telemetry.sigma_rejected_pixels,
            exposure_secs,
            timestamp_ms: chrono::Utc::now().timestamp_millis(),
        };
        self.push_event(event.clone());
        event
    }
}

struct SlotHandle {
    meta: RwLock<SlotMeta>,
    stacker: Mutex<LiveStacker>,
    preview_cache: Mutex<Option<CachedRgbaPreview>>,
}

impl SlotHandle {
    fn read_meta(&self) -> RwLockReadGuard<'_, SlotMeta> {
        self.meta
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn write_meta(&self) -> RwLockWriteGuard<'_, SlotMeta> {
        self.meta
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn lock_stacker(&self) -> MutexGuard<'_, LiveStacker> {
        self.stacker
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn lock_preview_cache(&self) -> MutexGuard<'_, Option<CachedRgbaPreview>> {
        self.preview_cache
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

fn stats_api_from_stacker(stacker: &LiveStacker) -> ApiLiveStackingStats {
    let mut stats: ApiLiveStackingStats = stacker.get_stats().into();
    stats.total_integration_secs = stacker.provenance().total_integration_secs();
    stats
}

struct StackerRegistry {
    slots: BTreeMap<String, Arc<SlotHandle>>,
    active_key: Option<String>,
    next_revision: u64,
}

impl StackerRegistry {
    fn new() -> Self {
        Self {
            slots: BTreeMap::new(),
            active_key: None,
            next_revision: 0,
        }
    }

    fn bump_revision(&mut self) -> u64 {
        self.next_revision = self.next_revision.saturating_add(1);
        self.next_revision
    }

    fn resolve_existing_key(&self, raw: &str) -> Option<String> {
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed == "—" {
            return None;
        }
        if self.slots.contains_key(trimmed) {
            return Some(trimmed.to_string());
        }
        let keys: Vec<&String> = self.slots.keys().collect();
        match skotiq_device::match_filter_slot(&keys, trimmed) {
            skotiq_device::FilterSlotMatch::Slot(slot) => Some(keys[slot].clone()),
            _ => None,
        }
    }

    fn resolve_key(&self, filter_key: Option<&str>) -> Option<String> {
        if let Some(raw) = filter_key {
            let trimmed = raw.trim();
            if !trimmed.is_empty() && trimmed != "—" {
                return self.resolve_existing_key(trimmed);
            }
        }
        self.active_key
            .clone()
            .or_else(|| self.slots.keys().next().cloned())
    }

    fn get_handle(&self, filter_key: Option<&str>) -> Option<(String, Arc<SlotHandle>)> {
        let key = self.resolve_key(filter_key)?;
        let handle = self.slots.get(&key).map(Arc::clone)?;
        Some((key, handle))
    }
}

static LIVE_STACKERS: OnceLock<Mutex<StackerRegistry>> = OnceLock::new();
static ACTIVE_SLOT_COUNT: AtomicU32 = AtomicU32::new(0);
static ACTIVE_FRAME_COUNT: AtomicU32 = AtomicU32::new(0);

fn acquire_registry() -> MutexGuard<'static, StackerRegistry> {
    LIVE_STACKERS
        .get_or_init(|| Mutex::new(StackerRegistry::new()))
        .lock()
        .unwrap_or_else(|poisoned| {
            tracing::warn!(
                "Live stacker mutex was poisoned (a previous operation panicked); recovering"
            );
            poisoned.into_inner()
        })
}

fn sync_atomic_counters(registry: &StackerRegistry) {
    ACTIVE_SLOT_COUNT.store(registry.slots.len() as u32, Ordering::Release);
    let active_frames = registry
        .resolve_key(None)
        .and_then(|key| registry.slots.get(&key))
        .map(|slot| slot.read_meta().stats.stacked_frame_count)
        .unwrap_or(0);
    ACTIVE_FRAME_COUNT.store(active_frames, Ordering::Release);
}

fn not_started() -> SkotiqError {
    SkotiqError::ImageError("Live stacker not initialized".to_string())
}

fn source_label_from_path(path: &str) -> String {
    std::path::Path::new(path)
        .file_name()
        .and_then(|n| n.to_str())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| path.to_string())
}

fn parse_demosaic_quality(quality: &str) -> Result<DebayerAlgorithm, String> {
    match quality.trim().to_ascii_lowercase().as_str() {
        "bilinear" => Ok(DebayerAlgorithm::Bilinear),
        "vng" => Ok(DebayerAlgorithm::VNG),
        "superpixel" | "super_pixel" | "super pixel" => Ok(DebayerAlgorithm::SuperPixel),
        other => Err(format!(
            "Unknown demosaic quality '{}' (expected one of: bilinear, vng, superpixel)",
            other
        )),
    }
}

fn parse_bayer_pattern(pattern: &Option<String>) -> Result<Option<BayerPattern>, String> {
    match pattern.as_deref().map(str::trim) {
        None | Some("") => Ok(None),
        Some(s) => skotiq_cfa::ColorFilterArray::parse(s)
            .and_then(|cfa| match cfa {
                skotiq_cfa::ColorFilterArray::Bayer(pattern) => Some(pattern),
                _ => None,
            })
            .map(Some)
            .ok_or_else(|| {
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

fn stacker_config(config: &ApiLiveStackingConfig) -> Result<LiveStackConfig, SkotiqError> {
    let parsed = || -> Result<LiveStackConfig, String> {
        let max_residual = if config.max_alignment_residual_px.is_finite()
            && config.max_alignment_residual_px > 0.0
        {
            config.max_alignment_residual_px
        } else {
            2.0
        };
        let detection_sigma =
            if config.star_detection_sigma.is_finite() && config.star_detection_sigma > 0.0 {
                config.star_detection_sigma
            } else {
                4.0
            };
        let min_snr =
            if config.star_detection_min_snr.is_finite() && config.star_detection_min_snr > 0.0 {
                config.star_detection_min_snr
            } else {
                8.0
            };
        Ok(LiveStackConfig {
            sigma_clip_threshold: config.sigma_clip_threshold,
            sigma_clip_enabled: config.sigma_clip_enabled,
            max_match_stars: config.max_match_stars as usize,
            match_radius_px: config.match_radius_px,
            match_flux_tolerance: config.match_flux_tolerance,
            min_matched_pairs: config.min_matched_pairs as usize,
            max_alignment_residual_px: max_residual,
            star_detection: StarDetectionConfig {
                detection_sigma,
                min_snr,
                ..StarDetectionConfig::default()
            },
            bayer_pattern: parse_bayer_pattern(&config.bayer_pattern)?,
            sensor_mode: parse_sensor_mode(&config.sensor_mode)?,
            demosaic_algorithm: parse_demosaic_quality(&config.demosaic_quality)?,
        })
    };
    parsed().map_err(SkotiqError::ImageError)
}

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

fn ingest(image: ImageData, color: Option<ColorIngest>) -> Result<ImageData, SkotiqError> {
    match color {
        Some(c) => debayer_cfa_to_rgb(&image, c.pattern, c.algorithm)
            .map_err(|e| SkotiqError::ImageError(format!("Failed to debayer frame: {}", e))),
        None => Ok(image),
    }
}

/// Register the live-stack F32 image & cache-identity callbacks into
/// `skotiq_processing::darkroom` once so Darkroom renders live stacks directly
/// from memory with zero disk I/O and zero-copy slider cache hits.
pub(crate) fn ensure_darkroom_live_stack_resolver() {
    skotiq_processing::darkroom::register_live_stack_resolver(
        live_stack_identity,
        live_stack_op_image,
    );
}

fn install_slot(
    resolved_filter: String,
    stacker: LiveStacker,
    color: Option<ColorIngest>,
    width: u32,
    height: u32,
    channels: u32,
    reference_image_path: Option<String>,
    source_label: String,
    exposure_secs: Option<f64>,
) -> ApiLiveStackingStats {
    ensure_darkroom_live_stack_resolver();
    let stats = stats_api_from_stacker(&stacker);
    let telemetry = stacker.last_frame_telemetry().cloned().unwrap_or_default();
    let seq_idx = stats.total_frames_attempted;

    let mut guard = acquire_registry();
    let revision = guard.bump_revision();
    let mut meta = SlotMeta {
        filter_key: resolved_filter.clone(),
        width,
        height,
        channels,
        color,
        reference_image_path,
        revision,
        stats: stats.clone(),
        events: VecDeque::new(),
    };
    meta.record_frame_event(telemetry, seq_idx, source_label, true, None, exposure_secs);
    let slot = Arc::new(SlotHandle {
        meta: RwLock::new(meta),
        stacker: Mutex::new(stacker),
        preview_cache: Mutex::new(None),
    });
    guard.slots.insert(resolved_filter.clone(), slot);
    guard.active_key = Some(resolved_filter.clone());
    sync_atomic_counters(&guard);

    tracing::info!(
        "Live stacking started for '{}' ({})",
        resolved_filter,
        if color.is_some() { "color/OSC" } else { "mono" }
    );
    stats
}

/// Start live stacking for a specific optical filter slot (or auto-resolved
/// from the FITS `FILTER` header / `"Unfiltered"`).
pub fn api_stacking_start_for_filter(
    filter_key: Option<String>,
    reference_image_path: String,
    config: ApiLiveStackingConfig,
) -> Result<ApiLiveStackingStats, SkotiqError> {
    tracing::info!(
        "Starting live stacking with reference: {} (filter={:?})",
        reference_image_path,
        filter_key
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
    let provenance = FrameProvenance::from_header(&read.header);
    let resolved_filter =
        normalize_filter_key(filter_key.as_deref().or(provenance.filter.as_deref()));
    let reference = ingest(read.image, color)?;
    let width = reference.width;
    let height = reference.height;
    let channels = reference.channels;
    let mut stacker = LiveStacker::new_with_provenance(&reference, native, &provenance)
        .map_err(|e| SkotiqError::ImageError(format!("Failed to initialize stacker: {}", e)))?;
    if filter_key.is_some() && resolved_filter != DEFAULT_FILTER_KEY {
        stacker.set_filter(Some(&resolved_filter));
    }
    let source_label = source_label_from_path(&reference_image_path);
    Ok(install_slot(
        resolved_filter,
        stacker,
        color,
        width,
        height,
        channels,
        Some(reference_image_path),
        source_label,
        provenance.exposure_secs,
    ))
}

/// Start live stacking with a reference image file; every later frame is
/// aligned to it.
pub fn api_stacking_start(
    reference_image_path: String,
    config: ApiLiveStackingConfig,
) -> Result<ApiLiveStackingStats, SkotiqError> {
    api_stacking_start_for_filter(None, reference_image_path, config)
}

/// Start live stacking from a single-plane u16 reference frame in memory into a
/// specific optical filter slot.
pub fn api_stacking_start_from_data_for_filter(
    filter_key: Option<String>,
    width: u32,
    height: u32,
    data: Vec<u16>,
    pedestal: f64,
    config: ApiLiveStackingConfig,
) -> Result<ApiLiveStackingStats, SkotiqError> {
    tracing::info!(
        "Starting live stacking from data: {}x{} ({} pixels, filter={:?})",
        width,
        height,
        data.len(),
        filter_key
    );
    let resolved_filter = normalize_filter_key(filter_key.as_deref());
    let native = stacker_config(&config)?;
    let color = color_ingest(
        &native,
        None,
        "OSC declared but no Bayer pattern resolvable (in-memory frames carry no \
         BAYERPAT header — set bayer_pattern in the config)",
    )?;
    let expected_pixels = (width as usize)
        .checked_mul(height as usize)
        .ok_or_else(|| {
            SkotiqError::ImageError(format!("Image dimensions overflow: {}x{}", width, height))
        })?;
    if width == 0 || height == 0 || data.len() != expected_pixels {
        return Err(SkotiqError::ImageError(format!(
            "Invalid image dimensions or pixel buffer length: {}x{} (got {} pixels)",
            width,
            height,
            data.len()
        )));
    }
    let reference = ingest(ImageData::from_u16(width, height, 1, &data), color)?;
    let img_w = reference.width;
    let img_h = reference.height;
    let img_ch = reference.channels;
    let provenance = FrameProvenance {
        pedestal,
        filter: if resolved_filter != DEFAULT_FILTER_KEY {
            Some(resolved_filter.clone())
        } else {
            None
        },
        ..FrameProvenance::unknown()
    };
    let stacker = LiveStacker::new_with_provenance(&reference, native, &provenance)
        .map_err(|e| SkotiqError::ImageError(format!("Failed to initialize stacker: {}", e)))?;
    Ok(install_slot(
        resolved_filter,
        stacker,
        color,
        img_w,
        img_h,
        img_ch,
        None,
        "in-memory".to_string(),
        None,
    ))
}

/// Start live stacking from a single-plane u16 reference frame in memory.
pub fn api_stacking_start_from_data(
    width: u32,
    height: u32,
    data: Vec<u16>,
    pedestal: f64,
    config: ApiLiveStackingConfig,
) -> Result<ApiLiveStackingStats, SkotiqError> {
    api_stacking_start_from_data_for_filter(None, width, height, data, pedestal, config)
}

/// Add a frame file to a specific filter's live stack and return the updated
/// stack. Debayering runs completely unlocked.
pub fn api_stacking_add_frame_for_filter(
    filter_key: Option<String>,
    image_path: String,
) -> Result<ApiLiveStackingResult, SkotiqError> {
    tracing::info!(
        "Adding frame to stack: {} (filter={:?})",
        image_path,
        filter_key
    );
    let read = read_image(std::path::Path::new(&image_path))
        .map_err(|e| SkotiqError::ImageError(format!("Failed to read frame image: {}", e)))?;
    let mut provenance = FrameProvenance::from_header(&read.header);
    let source_label = source_label_from_path(&image_path);

    let (target_key, slot) = {
        let guard = acquire_registry();
        guard.get_handle(filter_key.as_deref()).ok_or_else(|| {
            SkotiqError::ImageError(
                "Live stacker not initialized. Call stacking_start first.".to_string(),
            )
        })?
    };

    // When the caller explicitly routed this frame to a named filter slot,
    // allow headerless frames and canonical aliases (e.g. "H-alpha" -> "Ha")
    // while still rejecting a frame whose header names a different filter.
    if filter_key.is_some() && target_key != DEFAULT_FILTER_KEY {
        let header_compatible = match provenance.filter.as_deref() {
            None => true,
            Some(header_filter) => skotiq_device::same_filter(header_filter, &target_key),
        };
        if header_compatible {
            provenance.filter = Some(target_key.clone());
        }
    }

    let color = slot.read_meta().color;
    let frame = ingest(read.image, color)?;

    // Hold `slot.stacker` across the revision bump and `slot.meta` update so
    // Darkroom/preview readers holding `slot.stacker` always observe pixels
    // and revision atomically in lockstep.
    let outcome = {
        let mut stacker = slot.lock_stacker();
        let res = stacker.add_frame_with_provenance(&frame, &provenance);
        let stats = stats_api_from_stacker(&stacker);
        let telemetry = stacker.last_frame_telemetry().cloned().unwrap_or_default();
        match res {
            Ok(stacked) => {
                let revision = {
                    let mut guard = acquire_registry();
                    let rev = guard.bump_revision();
                    guard.active_key = Some(target_key.clone());
                    rev
                };
                let event = {
                    let mut meta = slot.write_meta();
                    meta.revision = revision;
                    meta.width = stacked.width;
                    meta.height = stacked.height;
                    meta.channels = stacked.channels;
                    meta.stats = stats.clone();
                    meta.record_frame_event(
                        telemetry,
                        stats.total_frames_attempted,
                        source_label,
                        true,
                        None,
                        provenance.exposure_secs,
                    )
                };
                *slot.lock_preview_cache() = None;
                Ok((stacked, stats, revision, event))
            }
            Err(err) => {
                {
                    let mut meta = slot.write_meta();
                    meta.stats = stats.clone();
                    meta.record_frame_event(
                        telemetry,
                        stats.total_frames_attempted,
                        source_label,
                        false,
                        Some(err.clone()),
                        provenance.exposure_secs,
                    );
                }
                Err(SkotiqError::ImageError(err))
            }
        }
    };

    let (stacked, stats, revision, event) = outcome?;
    {
        let guard = acquire_registry();
        sync_atomic_counters(&guard);
    }
    let data = stacked.as_u16().ok_or_else(|| {
        SkotiqError::ImageError("Failed to convert stacked result to u16".to_string())
    })?;
    Ok(ApiLiveStackingResult {
        width: stacked.width,
        height: stacked.height,
        channels: stacked.channels,
        data,
        stats,
        filter_key: target_key,
        revision,
        last_event: Some(event),
    })
}

/// Add a frame file to the active stack and return the stack as it now stands.
pub fn api_stacking_add_frame(image_path: String) -> Result<ApiLiveStackingResult, SkotiqError> {
    api_stacking_add_frame_for_filter(None, image_path)
}

/// Add a single-plane u16 frame in memory to a specific filter's live stack.
pub fn api_stacking_add_frame_from_data_for_filter(
    filter_key: Option<String>,
    width: u32,
    height: u32,
    data: Vec<u16>,
    pedestal: f64,
) -> Result<ApiLiveStackingResult, SkotiqError> {
    tracing::debug!(
        "Adding frame from data to stack: {}x{} (filter={:?})",
        width,
        height,
        filter_key
    );
    let expected = (width as usize)
        .checked_mul(height as usize)
        .ok_or_else(|| {
            SkotiqError::ImageError(format!(
                "Invalid frame dimensions (overflow): {}x{}",
                width, height
            ))
        })?;
    if width == 0 || height == 0 || data.len() != expected {
        return Err(SkotiqError::ImageError(format!(
            "Invalid frame dimensions or buffer length: {}x{} (expected {} samples, got {})",
            width,
            height,
            expected,
            data.len()
        )));
    }
    let (target_key, slot) = {
        let guard = acquire_registry();
        guard.get_handle(filter_key.as_deref()).ok_or_else(|| {
            SkotiqError::ImageError(
                "Live stacker not initialized. Call stacking_start first.".to_string(),
            )
        })?
    };

    let color = slot.read_meta().color;
    let frame = ingest(ImageData::from_u16(width, height, 1, &data), color)?;

    let outcome = {
        let mut stacker = slot.lock_stacker();
        let res = stacker.add_frame(&frame, pedestal);
        let stats = stats_api_from_stacker(&stacker);
        let telemetry = stacker.last_frame_telemetry().cloned().unwrap_or_default();
        match res {
            Ok(stacked) => {
                let revision = {
                    let mut guard = acquire_registry();
                    let rev = guard.bump_revision();
                    guard.active_key = Some(target_key.clone());
                    rev
                };
                let event = {
                    let mut meta = slot.write_meta();
                    meta.revision = revision;
                    meta.width = stacked.width;
                    meta.height = stacked.height;
                    meta.channels = stacked.channels;
                    meta.stats = stats.clone();
                    meta.record_frame_event(
                        telemetry,
                        stats.total_frames_attempted,
                        "in-memory".to_string(),
                        true,
                        None,
                        None,
                    )
                };
                *slot.lock_preview_cache() = None;
                Ok((stacked, stats, revision, event))
            }
            Err(err) => {
                {
                    let mut meta = slot.write_meta();
                    meta.stats = stats.clone();
                    meta.record_frame_event(
                        telemetry,
                        stats.total_frames_attempted,
                        "in-memory".to_string(),
                        false,
                        Some(err.clone()),
                        None,
                    );
                }
                Err(SkotiqError::ImageError(err))
            }
        }
    };

    let (stacked, stats, revision, event) = outcome?;
    {
        let guard = acquire_registry();
        sync_atomic_counters(&guard);
    }
    let out_u16 = stacked.as_u16().ok_or_else(|| {
        SkotiqError::ImageError("Failed to convert stacked result to u16".to_string())
    })?;
    Ok(ApiLiveStackingResult {
        width: stacked.width,
        height: stacked.height,
        channels: stacked.channels,
        data: out_u16,
        stats,
        filter_key: target_key,
        revision,
        last_event: Some(event),
    })
}

/// Add a single-plane u16 frame in memory to the active stack.
pub fn api_stacking_add_frame_from_data(
    width: u32,
    height: u32,
    data: Vec<u16>,
    pedestal: f64,
) -> Result<ApiLiveStackingResult, SkotiqError> {
    api_stacking_add_frame_from_data_for_filter(None, width, height, data, pedestal)
}

/// The current stack for a specific filter slot without adding a frame.
pub fn api_stacking_get_result_for_filter(
    filter_key: Option<String>,
) -> Result<ApiLiveStackingResult, SkotiqError> {
    let (_, slot) = {
        let guard = acquire_registry();
        guard
            .get_handle(filter_key.as_deref())
            .ok_or_else(not_started)?
    };
    let (stacked, stats, resolved_key, revision, last_event) = {
        let stacker = slot.lock_stacker();
        let stacked = stacker.get_current_stack();
        let meta = slot.read_meta();
        (
            stacked,
            meta.stats.clone(),
            meta.filter_key.clone(),
            meta.revision,
            meta.events.front().cloned(),
        )
    };
    let data = stacked.as_u16().ok_or_else(|| {
        SkotiqError::ImageError("Failed to convert stacked result to u16".to_string())
    })?;
    Ok(ApiLiveStackingResult {
        width: stacked.width,
        height: stacked.height,
        channels: stacked.channels,
        data,
        stats,
        filter_key: resolved_key,
        revision,
        last_event,
    })
}

/// The current stack, without adding a frame.
pub fn api_stacking_get_result() -> Result<ApiLiveStackingResult, SkotiqError> {
    api_stacking_get_result_for_filter(None)
}

/// Parallel area-average downscale for f32 mono or interleaved RGB images.
pub(crate) fn downscale_f32_area(
    width: u32,
    height: u32,
    channels: u32,
    data: &[f32],
    max_dimension: u32,
) -> (u32, u32, Vec<f32>) {
    let ch = if channels == 3 { 3usize } else { 1usize };
    let src_w = width as usize;
    let src_h = height as usize;
    let expected = src_w.checked_mul(src_h).and_then(|p| p.checked_mul(ch));
    if src_w == 0 || src_h == 0 || expected.is_none_or(|n| data.len() < n) {
        return (width, height, data.to_vec());
    }
    let max_dim = max_dimension as usize;
    if max_dim == 0 || src_w.max(src_h) <= max_dim {
        return (width, height, data.to_vec());
    }

    let (dst_w, dst_h) = if src_w >= src_h {
        let dw = max_dim.max(1);
        let dh = ((src_h as u64 * dw as u64) / src_w as u64).max(1) as usize;
        (dw, dh)
    } else {
        let dh = max_dim.max(1);
        let dw = ((src_w as u64 * dh as u64) / src_h as u64).max(1) as usize;
        (dw, dh)
    };

    let mut out = vec![0.0_f32; dst_w * dst_h * ch];
    let row_stride_dst = dst_w * ch;
    let row_stride_src = src_w * ch;

    out.par_chunks_exact_mut(row_stride_dst)
        .enumerate()
        .for_each(|(dy, dst_row)| {
            let sy0 = (dy * src_h) / dst_h;
            let sy1 = (((dy + 1) * src_h) / dst_h).max(sy0 + 1).min(src_h);
            for dx in 0..dst_w {
                let sx0 = (dx * src_w) / dst_w;
                let sx1 = (((dx + 1) * src_w) / dst_w).max(sx0 + 1).min(src_w);
                let inv_area = 1.0_f64 / ((sy1 - sy0) * (sx1 - sx0)) as f64;
                let dst_base = dx * ch;
                if ch == 1 {
                    let mut sum = 0.0_f64;
                    for sy in sy0..sy1 {
                        let row_off = sy * row_stride_src;
                        for sx in sx0..sx1 {
                            sum += data[row_off + sx] as f64;
                        }
                    }
                    dst_row[dst_base] = (sum * inv_area) as f32;
                } else {
                    let mut sum_r = 0.0_f64;
                    let mut sum_g = 0.0_f64;
                    let mut sum_b = 0.0_f64;
                    for sy in sy0..sy1 {
                        let row_off = sy * row_stride_src;
                        for sx in sx0..sx1 {
                            let idx = row_off + sx * 3;
                            sum_r += data[idx] as f64;
                            sum_g += data[idx + 1] as f64;
                            sum_b += data[idx + 2] as f64;
                        }
                    }
                    dst_row[dst_base] = (sum_r * inv_area) as f32;
                    dst_row[dst_base + 1] = (sum_g * inv_area) as f32;
                    dst_row[dst_base + 2] = (sum_b * inv_area) as f32;
                }
            }
        });

    (dst_w as u32, dst_h as u32, out)
}

#[derive(Debug, Clone, Copy)]
struct LiveStackChannelStretch {
    black_point: f64,
    inv_range: f64,
    midtone: f64,
}

impl LiveStackChannelStretch {
    #[inline]
    fn apply(self, val: f64) -> u8 {
        if self.inv_range <= 0.0 {
            return 0;
        }
        let x = ((val - self.black_point) * self.inv_range).clamp(0.0, 1.0);
        let y = live_mtf(x, self.midtone);
        (y * 255.0).round().clamp(0.0, 255.0) as u8
    }
}

#[inline]
fn live_mtf(x: f64, m: f64) -> f64 {
    if x <= 0.0 {
        0.0
    } else if x >= 1.0 {
        1.0
    } else if (x - m).abs() < 1e-12 {
        0.5
    } else {
        ((m - 1.0) * x) / ((2.0 * m - 1.0) * x - m)
    }
}

#[inline]
fn live_mtf_midtone(x: f64, target: f64) -> f64 {
    let denom = (2.0 * target - 1.0) * x - target;
    if denom.abs() < f64::EPSILON {
        return target;
    }
    (((target - 1.0) * x) / denom).clamp(1e-6, 0.999999)
}

#[inline]
fn sorted_quantile(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let idx = ((sorted.len() - 1) as f64 * q.clamp(0.0, 1.0)) as usize;
    sorted[idx.min(sorted.len() - 1)]
}

/// Compute progressive EAA live-stack stretch parameters for one channel from
/// native full-resolution floating-point pixels.
fn compute_live_stack_channel_stretch(
    data: &[f32],
    width: usize,
    height: usize,
    channels: usize,
    channel_idx: usize,
    stacked_frame_count: u32,
) -> LiveStackChannelStretch {
    const MAD_TO_SIGMA: f64 = 1.482602218505602;
    const DIFF_TO_SIGMA: f64 = 1.482602218505602 / std::f64::consts::SQRT_2;
    const SAMPLE_BUDGET: usize = 131_072;

    let pixel_count = width * height;
    if pixel_count == 0 {
        return LiveStackChannelStretch {
            black_point: 0.0,
            inv_range: 1.0 / 65535.0,
            midtone: 0.5,
        };
    }

    let stride = (pixel_count / SAMPLE_BUDGET).max(1);
    let mut samples = Vec::with_capacity((pixel_count / stride) + 1);
    let mut p = 0usize;
    while p < pixel_count {
        let v = data[p * channels + channel_idx] as f64;
        if v.is_finite() {
            samples.push(v);
        }
        p += stride;
    }
    if samples.is_empty() {
        return LiveStackChannelStretch {
            black_point: 0.0,
            inv_range: 1.0 / 65535.0,
            midtone: 0.5,
        };
    }

    samples.sort_unstable_by(f64::total_cmp);
    let median = sorted_quantile(&samples, 0.5);
    let p999 = sorted_quantile(&samples, 0.999);
    let max_val = *samples.last().unwrap_or(&65535.0);

    let mut deviations: Vec<f64> = samples.iter().map(|&v| (v - median).abs()).collect();
    deviations.sort_unstable_by(f64::total_cmp);
    let sigma_global = sorted_quantile(&deviations, 0.5) * MAD_TO_SIGMA;

    let pair_dx = if width >= 4 { 2usize } else { 1usize };
    let usable_w = width.saturating_sub(pair_dx);
    let sky_ceiling = median + 3.0 * sigma_global.max(1.0);
    let mut sigma_local = 0.0_f64;
    if usable_w > 0 {
        let row_step = (((height * usable_w) / SAMPLE_BUDGET) as f64).sqrt().floor() as usize;
        let step = row_step.max(1);
        let mut diffs = Vec::with_capacity(SAMPLE_BUDGET.min(pixel_count));
        let mut y = 0usize;
        while y < height {
            let row_base = y * width;
            let mut x = 0usize;
            while x < usable_w {
                let a = data[(row_base + x) * channels + channel_idx] as f64;
                let b = data[(row_base + x + pair_dx) * channels + channel_idx] as f64;
                if a.is_finite() && b.is_finite() && a <= sky_ceiling && b <= sky_ceiling {
                    diffs.push((b - a).abs());
                }
                x += step;
            }
            y += step;
        }
        if diffs.len() >= 64 {
            diffs.sort_unstable_by(f64::total_cmp);
            sigma_local = sorted_quantile(&diffs, 0.5) * DIFF_TO_SIGMA;
        }
    }

    let sigma_eff = if sigma_local > 1e-5 {
        sigma_local
    } else {
        sigma_global
    };

    if sigma_eff <= 1e-6 {
        let min_val = samples[0];
        let range = (max_val - min_val).max(1.0);
        return LiveStackChannelStretch {
            black_point: min_val,
            inv_range: 1.0 / range,
            midtone: 0.5,
        };
    }

    let n_sqrt = (stacked_frame_count.max(1) as f64).sqrt();
    let progress = 1.0 - (1.0 / n_sqrt);
    let shadow_sigma = 2.8 - 0.55 * progress;
    let target_bg = 0.14 + 0.06 * progress;

    let max_bound = max_val.max(65535.0);
    let black_point = (median - shadow_sigma * sigma_eff).clamp(0.0, (max_bound - 1e-4).max(0.0));
    let white_point = p999
        .max(median + 32.0 * sigma_eff)
        .clamp(black_point + 1e-4, max_bound);
    let range = white_point - black_point;
    let x_bg = ((median - black_point) / range).clamp(1e-6, 0.999);
    let midtone = live_mtf_midtone(x_bg, target_bg);

    LiveStackChannelStretch {
        black_point,
        inv_range: 1.0 / range,
        midtone,
    }
}

/// Render a progressive, noise-adaptive RGBA8 preview from un-quantized `f32`
/// running means (measuring native local sky noise *before* downscaling).
pub(crate) fn stretch_live_stack_f32_preview(
    width: u32,
    height: u32,
    channels: u32,
    data: &[f32],
    stacked_frame_count: u32,
    max_dimension: u32,
) -> Result<ApiStretchedPreview, String> {
    let ch = if channels == 3 { 3u32 } else { 1u32 };
    let expected = (width as usize)
        .checked_mul(height as usize)
        .and_then(|p| p.checked_mul(ch as usize))
        .ok_or_else(|| {
            format!(
                "Invalid image dimensions (overflow): {}x{}x{}",
                width, height, ch
            )
        })?;
    if width == 0 || height == 0 || data.len() < expected {
        return Err(format!(
            "Invalid image dimensions or buffer length: {}x{}x{} (got {} samples)",
            width,
            height,
            ch,
            data.len()
        ));
    }

    let native_slice = &data[..expected];
    let w_usize = width as usize;
    let h_usize = height as usize;

    let stretches: Vec<LiveStackChannelStretch> = (0..ch as usize)
        .map(|c| {
            compute_live_stack_channel_stretch(
                native_slice,
                w_usize,
                h_usize,
                ch as usize,
                c,
                stacked_frame_count,
            )
        })
        .collect();

    let (pw, ph, scaled_owned);
    let preview_slice: &[f32] = if max_dimension > 0 && width.max(height) > max_dimension {
        let (dw, dh, buf) = downscale_f32_area(width, height, ch, native_slice, max_dimension);
        pw = dw;
        ph = dh;
        scaled_owned = buf;
        &scaled_owned
    } else {
        pw = width;
        ph = height;
        native_slice
    };

    let rgba_len = (pw as usize)
        .checked_mul(ph as usize)
        .and_then(|p| p.checked_mul(4))
        .ok_or_else(|| format!("Preview dimensions overflow RGBA buffer: {}x{}", pw, ph))?;
    let mut rgba = vec![0u8; rgba_len];
    if ch == 3 {
        let sr = stretches[0];
        let sg = stretches[1];
        let sb = stretches[2];
        rgba.par_chunks_exact_mut(4)
            .zip(preview_slice.par_chunks_exact(3))
            .for_each(|(dst, src)| {
                dst[0] = sr.apply(src[0] as f64);
                dst[1] = sg.apply(src[1] as f64);
                dst[2] = sb.apply(src[2] as f64);
                dst[3] = 255;
            });
    } else {
        let sm = stretches[0];
        rgba.par_chunks_exact_mut(4)
            .zip(preview_slice.par_iter())
            .for_each(|(dst, &v)| {
                let g = sm.apply(v as f64);
                dst[0] = g;
                dst[1] = g;
                dst[2] = g;
                dst[3] = 255;
            });
    }

    Ok(ApiStretchedPreview {
        width: pw,
        height: ph,
        channels: ch,
        rgba,
    })
}

/// Off-UI-thread auto-stretch with optional parallel area downscaling (runs on
/// FRB worker thread pool, never blocking the Flutter UI isolate).
pub fn api_auto_stretch_preview_async(
    width: u32,
    height: u32,
    channels: u32,
    data: Vec<u16>,
    max_dimension: u32,
) -> Result<ApiStretchedPreview, SkotiqError> {
    let ch = if channels == 3 { 3u32 } else { 1u32 };
    let expected = (width as usize)
        .checked_mul(height as usize)
        .and_then(|p| p.checked_mul(ch as usize))
        .ok_or_else(|| {
            SkotiqError::ImageError(format!(
                "Invalid image dimensions (overflow): {}x{}x{}",
                width, height, ch
            ))
        })?;
    if width == 0 || height == 0 || data.len() < expected {
        return Err(SkotiqError::ImageError(format!(
            "Invalid image dimensions or buffer length: {}x{}x{} (got {} samples)",
            width,
            height,
            ch,
            data.len()
        )));
    }
    let as_f32: Vec<f32> = data[..expected].par_iter().map(|&v| v as f32).collect();
    stretch_live_stack_f32_preview(width, height, ch, &as_f32, 1, max_dimension)
        .map_err(SkotiqError::ImageError)
}

/// Render a stretched, downscaled RGBA8 preview directly from an active native
/// live stack slot's un-quantized F32 running means on a background worker
/// thread (cached per `(revision, max_dimension)`).
pub fn api_stacking_render_preview_rgba(
    filter_key: Option<String>,
    max_dimension: u32,
) -> Result<ApiStretchedPreview, SkotiqError> {
    let (_, slot) = {
        let guard = acquire_registry();
        guard
            .get_handle(filter_key.as_deref())
            .ok_or_else(not_started)?
    };

    let cached_revision = slot.read_meta().revision;
    {
        let cache = slot.lock_preview_cache();
        if let Some(cached) = cache.as_ref() {
            if cached.revision == cached_revision && cached.max_dimension == max_dimension {
                return Ok(ApiStretchedPreview {
                    width: cached.width,
                    height: cached.height,
                    channels: cached.channels,
                    rgba: cached.rgba.clone(),
                });
            }
        }
    }

    let (data_f32, width, height, channels, revision, stacked_frames) = {
        let stacker = slot.lock_stacker();
        let (data_f32, width, height, channels) = stacker.get_current_stack_f32();
        let meta = slot.read_meta();
        (
            data_f32,
            width,
            height,
            channels,
            meta.revision,
            meta.stats.stacked_frame_count,
        )
    };
    let rendered = stretch_live_stack_f32_preview(
        width,
        height,
        channels,
        &data_f32,
        stacked_frames,
        max_dimension,
    )
    .map_err(SkotiqError::ImageError)?;

    if slot.read_meta().revision == revision {
        *slot.lock_preview_cache() = Some(CachedRgbaPreview {
            revision,
            max_dimension,
            width: rendered.width,
            height: rendered.height,
            channels: rendered.channels,
            rgba: rendered.rgba.clone(),
        });
    }

    Ok(rendered)
}

/// Wait-free metadata lookup of `(canonical_filter_key, revision_identity)` for
/// Darkroom pyramid cache hits.
pub(crate) fn live_stack_identity(filter_key: &str) -> Result<(String, String), String> {
    let resolved = if filter_key.trim().is_empty() || filter_key == "active" {
        None
    } else {
        Some(filter_key)
    };
    let (_, slot) = {
        let guard = acquire_registry();
        guard
            .get_handle(resolved)
            .ok_or_else(|| format!("No active live stack for filter '{filter_key}'"))?
    };
    let meta = slot.read_meta();
    let canonical_key = meta.filter_key.clone();
    let identity = format!("livestack:{}|rev:{}", meta.filter_key, meta.revision);
    Ok((canonical_key, identity))
}

/// Build an in-memory Darkroom [`OpImage`] + cache identity directly from an
/// active live stack's F32 running means.
pub(crate) fn live_stack_op_image(filter_key: &str) -> Result<(OpImage, String), String> {
    let resolved = if filter_key.trim().is_empty() || filter_key == "active" {
        None
    } else {
        Some(filter_key)
    };
    let (_, slot) = {
        let guard = acquire_registry();
        guard
            .get_handle(resolved)
            .ok_or_else(|| format!("No active live stack for filter '{filter_key}'"))?
    };
    let (data, width, height, channels, header, identity) = {
        let stacker = slot.lock_stacker();
        let (data, width, height, channels) = stacker.get_current_stack_f32();
        let header = stacker.provenance().to_fits_header();
        let meta = slot.read_meta();
        let identity = format!("livestack:{}|rev:{}", meta.filter_key, meta.revision);
        (data, width, height, channels, header, identity)
    };
    let image = OpImage::new(width, height, channels, data, header)
        .map_err(|e| format!("Live stack is not renderable in Darkroom: {e}"))?;
    Ok((image, identity))
}

/// Save a specific filter's accumulated stack as a FITS master off the async
/// runtime and outside all stacker locks during disk I/O.
pub async fn api_stacking_save_master_fits_for_filter(
    filter_key: Option<String>,
    file_path: String,
) -> Result<ApiLiveStackingMaster, SkotiqError> {
    tokio::task::spawn_blocking(move || save_master_fits_for_filter(filter_key, file_path))
        .await
        .map_err(|e| SkotiqError::OperationFailed(format!("Task join error: {}", e)))?
}

/// Save the active stack as a FITS master.
pub async fn api_stacking_save_master_fits(
    file_path: String,
) -> Result<ApiLiveStackingMaster, SkotiqError> {
    api_stacking_save_master_fits_for_filter(None, file_path).await
}

#[cfg(test)]
fn save_master_fits(file_path: String) -> Result<ApiLiveStackingMaster, SkotiqError> {
    save_master_fits_for_filter(None, file_path)
}

fn save_master_fits_for_filter(
    filter_key: Option<String>,
    file_path: String,
) -> Result<ApiLiveStackingMaster, SkotiqError> {
    let (resolved_key, slot) = {
        let guard = acquire_registry();
        guard
            .get_handle(filter_key.as_deref())
            .ok_or_else(not_started)?
    };
    let (image, provenance, pedestal) = {
        let stacker = slot.lock_stacker();
        let provenance = stacker.provenance().clone();
        if provenance.stacked_frames() == 0 {
            return Err(SkotiqError::ImageError(
                "There is no stacked master to save yet".to_string(),
            ));
        }
        let image = stacker.get_current_stack();
        let pedestal = stacker.output_pedestal();
        (image, provenance, pedestal)
    };
    write_stack_master(
        std::path::Path::new(&file_path),
        &image,
        &provenance,
        pedestal,
    )
    .map_err(|e| SkotiqError::ImageError(format!("Failed to write stacked master: {:?}", e)))?;
    tracing::info!(
        "Stacked master saved: {} (filter={}, {} frames, {:.1} s integration)",
        file_path,
        resolved_key,
        provenance.stacked_frames(),
        provenance.total_integration_secs()
    );
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

/// Current tally for a specific filter slot (or active slot).
pub fn api_stacking_get_stats_for_filter(
    filter_key: Option<String>,
) -> Result<ApiLiveStackingStats, SkotiqError> {
    let (_, slot) = {
        let guard = acquire_registry();
        guard
            .get_handle(filter_key.as_deref())
            .ok_or_else(not_started)?
    };
    let stats = slot.read_meta().stats.clone();
    Ok(stats)
}

/// The current tally.
pub fn api_stacking_get_stats() -> Result<ApiLiveStackingStats, SkotiqError> {
    api_stacking_get_stats_for_filter(None)
}

/// List all active per-filter live stacks in O(1) without touching pixel data.
pub fn api_stacking_list_filters() -> Vec<ApiLiveStackFilterSummary> {
    let handles: Vec<Arc<SlotHandle>> = {
        let guard = acquire_registry();
        guard.slots.values().map(Arc::clone).collect()
    };
    handles
        .into_iter()
        .map(|slot| {
            let meta = slot.read_meta();
            ApiLiveStackFilterSummary {
                filter_key: meta.filter_key.clone(),
                width: meta.width,
                height: meta.height,
                channels: meta.channels,
                reference_image_path: meta.reference_image_path.clone(),
                revision: meta.revision,
                stats: meta.stats.clone(),
            }
        })
        .collect()
}

/// Get recent frame evaluation events (newest first) for one filter or across
/// all active filters.
pub fn api_stacking_get_events(filter_key: Option<String>) -> Vec<ApiLiveStackFrameEvent> {
    if let Some(ref key) = filter_key {
        let trimmed = key.trim();
        if !trimmed.is_empty() {
            let slot = {
                let guard = acquire_registry();
                guard
                    .resolve_existing_key(trimmed)
                    .and_then(|resolved| guard.slots.get(&resolved).map(Arc::clone))
            };
            return slot
                .map(|s| s.read_meta().events.iter().cloned().collect())
                .unwrap_or_default();
        }
    }
    let handles: Vec<Arc<SlotHandle>> = {
        let guard = acquire_registry();
        guard.slots.values().map(Arc::clone).collect()
    };
    let mut all: Vec<ApiLiveStackFrameEvent> = handles
        .into_iter()
        .flat_map(|s| {
            let meta = s.read_meta();
            meta.events.iter().cloned().collect::<Vec<_>>()
        })
        .collect();
    all.sort_by_key(|a| std::cmp::Reverse(a.timestamp_ms));
    all.truncate(MAX_FRAME_EVENTS);
    all
}

/// Update runtime-mutable stacking parameters on one filter slot or all active
/// slots without dropping accumulated pixels.
pub fn api_stacking_update_config(
    filter_key: Option<String>,
    config: ApiLiveStackingConfig,
) -> Result<(), SkotiqError> {
    let native_config = stacker_config(&config)?;
    if let Some(ref key) = filter_key {
        let trimmed = key.trim();
        if !trimmed.is_empty() {
            let slot = {
                let guard = acquire_registry();
                guard
                    .resolve_existing_key(trimmed)
                    .and_then(|resolved| guard.slots.get(&resolved).map(Arc::clone))
                    .ok_or_else(|| {
                        SkotiqError::ImageError(format!(
                            "Live stacker not initialized for filter '{trimmed}'"
                        ))
                    })?
            };
            slot.lock_stacker().update_config(native_config);
            return Ok(());
        }
    }
    let handles: Vec<Arc<SlotHandle>> = {
        let guard = acquire_registry();
        guard.slots.values().map(Arc::clone).collect()
    };
    for slot in handles {
        slot.lock_stacker().update_config(native_config.clone());
    }
    Ok(())
}

/// Reset a specific filter's live stacker, clearing accumulated data while
/// keeping its reference stars.
pub fn api_stacking_reset_for_filter(filter_key: Option<String>) -> Result<(), SkotiqError> {
    let (resolved_key, slot) = {
        let guard = acquire_registry();
        guard
            .get_handle(filter_key.as_deref())
            .ok_or_else(not_started)?
    };
    {
        let mut stacker = slot.lock_stacker();
        stacker.reset();
        let stats = stats_api_from_stacker(&stacker);
        let revision = {
            let mut guard = acquire_registry();
            guard.bump_revision()
        };
        {
            let mut meta = slot.write_meta();
            meta.revision = revision;
            meta.stats = stats;
            meta.events.clear();
        }
        *slot.lock_preview_cache() = None;
    }
    {
        let guard = acquire_registry();
        sync_atomic_counters(&guard);
    }
    tracing::info!("Live stacker reset for '{}'", resolved_key);
    Ok(())
}

/// Clear what has been stacked, keeping the reference frame.
pub fn api_stacking_reset() -> Result<(), SkotiqError> {
    api_stacking_reset_for_filter(None)
}

/// Stop and release a single filter slot.
pub fn api_stacking_stop_for_filter(filter_key: String) -> Result<(), SkotiqError> {
    let mut guard = acquire_registry();
    let trimmed = filter_key.trim();
    let resolved = guard.resolve_existing_key(trimmed).ok_or_else(|| {
        SkotiqError::ImageError(format!(
            "Live stacker not initialized for filter '{trimmed}'"
        ))
    })?;
    guard.slots.remove(&resolved);
    if guard.active_key.as_deref() == Some(resolved.as_str()) {
        guard.active_key = guard.slots.keys().next().cloned();
    }
    sync_atomic_counters(&guard);
    tracing::info!("Live stacker stopped for '{}'", resolved);
    Ok(())
}

/// Stop live stacking and release all filter slots.
pub fn api_stacking_stop() -> Result<(), SkotiqError> {
    let mut guard = acquire_registry();
    if guard.slots.is_empty() {
        return Err(not_started());
    }
    guard.slots.clear();
    guard.active_key = None;
    sync_atomic_counters(&guard);
    tracing::info!("Live stacker stopped and resources released");
    Ok(())
}

/// Check if live stacking is currently active (wait-free atomic read).
#[flutter_rust_bridge::frb(sync)]
pub fn api_stacking_is_active() -> bool {
    ACTIVE_SLOT_COUNT.load(Ordering::Acquire) > 0
}

/// Frames in the active stack; 0 when no stack is running (wait-free atomic read).
#[flutter_rust_bridge::frb(sync)]
pub fn api_stacking_frame_count() -> u32 {
    ACTIVE_FRAME_COUNT.load(Ordering::Acquire)
}

#[cfg(test)]
mod tests;
