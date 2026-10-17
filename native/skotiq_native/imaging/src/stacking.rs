//! Live stacking engine for EAA and outreach
//!
//! Provides incremental image stacking with:
//! - Star detection and matching between frames
//! - Affine alignment (translation + rotation) via matched star pairs
//! - Running average accumulation with optional sigma-clipping rejection
//! - Parallel pixel operations via rayon

use crate::integration::{integrate_columns, Combine, IntegrationConfig, IntegrationFrame, Reject};
use crate::stack_master::{FrameProvenance, StackProvenance};
use crate::{
    debayer_u16, detect_stars, BayerPattern, DebayerAlgorithm, DetectedStar, ImageData, PixelType,
    StarDetectionConfig,
};
use rayon::prelude::*;

/// Whether the incoming frames originate from a monochrome sensor or a
/// one-shot-colour (OSC) sensor with a Bayer colour-filter array.
///
/// This is metadata describing the *acquisition*, not the buffer layout the
/// stacker receives. The bridge debayers CFA frames into a 3-channel RGB
/// `ImageData` before handing them to [`LiveStacker`]; the stacker decides how
/// to align/accumulate purely from `ImageData::channels`. `SensorMode` is
/// carried through so the config faithfully records the session's sensor type
/// (useful for diagnostics / FITS provenance) without changing the runtime
/// dispatch, which keys off the actual channel count.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SensorMode {
    /// Monochrome sensor — single-channel luminance frames. Never debayered.
    #[default]
    Mono,
    /// One-shot-colour sensor — frames carry a Bayer CFA that *must* be
    /// debayered to 3-channel RGB upstream of the stacker. A session declared
    /// `Osc` with no resolvable Bayer pattern is a hard error: debayering with a
    /// guessed mosaic would scramble colour, and silently falling back to mono
    /// would mis-render a real CFA frame.
    Osc,
    /// Auto-detect: debayer only when the frame actually carries a Bayer pattern
    /// (resolved from an explicit override or the frame's FITS `BAYERPAT`
    /// geometry); otherwise stack as mono. Unlike [`SensorMode::Osc`], a missing
    /// pattern is *not* an error — it simply means "this frame is mono".
    Auto,
}

/// Configuration for the live stacking engine
#[derive(Debug, Clone)]
pub struct LiveStackConfig {
    /// Sigma threshold for pixel rejection (e.g. 2.5 means reject > 2.5 sigma from running mean)
    pub sigma_clip_threshold: f64,
    /// Whether sigma clipping is enabled
    pub sigma_clip_enabled: bool,
    /// Maximum number of stars to use for matching (brightest N)
    pub max_match_stars: usize,
    /// Maximum distance in pixels for a star match to be valid
    pub match_radius_px: f64,
    /// Maximum flux ratio difference for a star match (0.0 to 1.0; e.g. 0.5 means flux can differ by 50%)
    pub match_flux_tolerance: f64,
    /// Minimum number of matched star pairs required for alignment
    pub min_matched_pairs: usize,
    /// Maximum RMS alignment residual (pixels) accepted before a frame is
    /// folded into the stack. A geometrically-inconsistent fit (mismatched
    /// stars) produces a large residual; folding it in permanently blurs the
    /// stack. Good affine fits are sub-pixel, so the default rejects only
    /// clearly-broken alignments while leaving generous margin for poor
    /// tracking/seeing. Set to `f64::INFINITY` to disable the gate.
    pub max_alignment_residual_px: f64,
    /// Star detection config overrides
    pub star_detection: StarDetectionConfig,
    /// Bayer pattern of the source CFA frames, when the session is OSC.
    ///
    /// This is provenance only — the stacker is handed already-debayered
    /// 3-channel RGB frames (the bridge owns the CFA → RGB step via
    /// [`debayer_cfa_to_rgb`]). It is `None` for monochrome sessions.
    pub bayer_pattern: Option<BayerPattern>,
    /// Whether the acquiring sensor is monochrome or one-shot-colour.
    ///
    /// Defaults to [`SensorMode::Mono`] so every existing caller (which never
    /// set this field) keeps the historic monochrome behaviour byte-for-byte.
    pub sensor_mode: SensorMode,
    /// Demosaic algorithm used by the bridge when converting CFA frames to
    /// RGB before they reach the stacker. Stored here so the whole stacking
    /// session uses one consistent demosaic. Defaults to
    /// [`DebayerAlgorithm::Bilinear`].
    pub demosaic_algorithm: DebayerAlgorithm,
}

impl Default for LiveStackConfig {
    fn default() -> Self {
        Self {
            sigma_clip_threshold: 2.5,
            sigma_clip_enabled: true,
            max_match_stars: 100,
            match_radius_px: 50.0,
            match_flux_tolerance: 0.7,
            min_matched_pairs: 5,
            // Gated on the RMS over the pairs that survive outlier rejection
            // (see `fit_transform_robust`), not over every nearest-neighbour
            // pairing. 10.0 was not a quality gate at all — a 10px misalignment
            // folded into the stack is a visibly smeared image; it only ever
            // measured how badly the matcher mis-paired. 2.0px of *inlier* RMS
            // is already a poorly registered frame.
            max_alignment_residual_px: 2.0,
            star_detection: StarDetectionConfig {
                detection_sigma: 4.0,
                min_snr: 8.0,
                ..StarDetectionConfig::default()
            },
            bayer_pattern: None,
            sensor_mode: SensorMode::Mono,
            demosaic_algorithm: DebayerAlgorithm::Bilinear,
        }
    }
}

/// Debayer a single-channel CFA (Bayer-mosaic) U16 frame into a 3-channel
/// interleaved RGB U16 [`ImageData`].
///
/// This is the ingest helper the bridge calls before handing OSC frames to
/// [`LiveStacker`]: the stacker itself is deliberately CFA-agnostic and only
/// ever sees mono (1-channel) or RGB (3-channel) images. Keeping the demosaic
/// here — rather than inside the stacker — means the stacker has no notion of
/// Bayer patterns or file/path concerns.
///
/// Errors, never silently coerced:
/// - the input is not single-channel (a real CFA frame is one plane);
/// - the input is not [`PixelType::U16`] (CFA data is integer ADU);
/// - the U16 unpacking fails (corrupt/short buffer).
pub fn debayer_cfa_to_rgb(
    cfa: &ImageData,
    pattern: BayerPattern,
    algorithm: DebayerAlgorithm,
) -> Result<ImageData, String> {
    if cfa.channels != 1 {
        return Err(format!(
            "debayer_cfa_to_rgb: expected a single-channel CFA frame, got {} channels",
            cfa.channels
        ));
    }
    if cfa.pixel_type != PixelType::U16 {
        return Err(format!(
            "debayer_cfa_to_rgb: expected U16 CFA data, got {:?}",
            cfa.pixel_type
        ));
    }

    let raw = cfa.as_u16().ok_or_else(|| {
        "debayer_cfa_to_rgb: failed to unpack CFA frame as U16 (corrupt or short buffer)"
            .to_string()
    })?;

    let expected = (cfa.width as usize) * (cfa.height as usize);
    if raw.len() != expected {
        return Err(format!(
            "debayer_cfa_to_rgb: CFA buffer has {} samples but {}x{} requires {}",
            raw.len(),
            cfa.width,
            cfa.height,
            expected
        ));
    }

    // Build the result from the *demosaiced* geometry, not the input CFA size:
    // SuperPixel (2x2 binning) halves resolution, so assuming the input
    // dimensions here would declare a (w x h x 3) image backed by only
    // (w/2)*(h/2)*3 samples — a short buffer that panics or silently corrupts
    // downstream luminance/detection passes.
    let rgb = debayer_u16(&raw, cfa.width, cfa.height, pattern, algorithm);
    Ok(ImageData::from_u16(
        rgb.width,
        rgb.height,
        3,
        &rgb.to_rgb16(),
    ))
}

/// Build a single-channel U16 luminance proxy from a 3-channel interleaved RGB
/// [`ImageData`], using the Rec. 601 luma weights (`0.299 R + 0.587 G +
/// 0.114 B`, rounded to nearest ADU and clamped to the U16 range).
///
/// The proxy exists purely so star detection / matching / transform solving
/// run on a stable, channel-collapsed plane rather than on a single Bayer
/// channel or on interleaved RGB (which `detect_stars` would misread as a
/// scrambled mono buffer). The proxy is never accumulated — only the original
/// RGB channels are stacked.
fn luminance_proxy(rgb: &ImageData) -> ImageData {
    debug_assert_eq!(
        rgb.channels, 3,
        "luminance_proxy requires a 3-channel RGB image"
    );

    let width = rgb.width;
    let height = rgb.height;
    let pixel_count = (width as usize) * (height as usize);

    // Read interleaved RGB triples. `as_u16` returns the full interleaved
    // buffer; we collapse each [r, g, b] triple to one luma sample.
    let interleaved = rgb
        .as_u16()
        .expect("luminance_proxy requires a U16 RGB image");

    let luma: Vec<u16> = (0..pixel_count)
        .into_par_iter()
        .map(|i| {
            let base = i * 3;
            let r = interleaved[base] as f64;
            let g = interleaved[base + 1] as f64;
            let b = interleaved[base + 2] as f64;
            (0.299 * r + 0.587 * g + 0.114 * b)
                .round()
                .clamp(0.0, 65535.0) as u16
        })
        .collect();

    ImageData::from_u16(width, height, 1, &luma)
}

/// Resolve the single-channel image that star detection / matching / transform
/// solving should run on.
///
/// - Mono (1-channel): the frame is borrowed unchanged, so the historic path
///   is byte-for-byte identical (no copy, no luma collapse).
/// - RGB (3-channel): a freshly built luminance proxy (owned) so detection
///   operates on a coherent mono plane.
///
/// The caller (`new` / `add_frame`) has already validated the channel count is
/// 1 or 3, so any other count would be a programmer error; we surface it as a
/// panic rather than silently producing a meaningless plane.
fn detection_plane(frame: &ImageData) -> std::borrow::Cow<'_, ImageData> {
    match frame.channels {
        1 => std::borrow::Cow::Borrowed(frame),
        3 => std::borrow::Cow::Owned(luminance_proxy(frame)),
        other => unreachable!(
            "detection_plane received {} channels; new()/add_frame() must reject anything but 1 or 3",
            other
        ),
    }
}

/// Statistics about the stacking process
#[derive(Debug, Clone, Default)]
pub struct StackingStats {
    /// Total frames added (including rejected)
    pub total_frames_attempted: u32,
    /// Successfully stacked frames
    pub stacked_frame_count: u32,
    /// Frames rejected due to insufficient star matches
    pub rejected_alignment_failures: u32,
    /// Average number of matched star pairs across stacked frames
    pub avg_matched_pairs: f64,
    /// Average alignment residual (RMS of matched star distances after transform)
    pub avg_alignment_residual: f64,
    /// Total pixels rejected by sigma clipping across all frames
    pub total_sigma_rejected_pixels: u64,
}

/// A 2D affine transform: [cos(t)*sx, -sin(t)*sy, tx; sin(t)*sx, cos(t)*sy, ty]
/// Simplified to: translation (tx, ty) + rotation (theta)
/// We don't do scaling because stacking frames from the same scope/camera session
/// should have identical pixel scale.
#[derive(Debug, Clone, Copy)]
struct AffineTransform {
    tx: f64,
    ty: f64,
    cos_theta: f64,
    sin_theta: f64,
}

impl AffineTransform {
    /// Identity transform (no shift, no rotation)
    fn identity() -> Self {
        Self {
            tx: 0.0,
            ty: 0.0,
            cos_theta: 1.0,
            sin_theta: 0.0,
        }
    }

    /// Apply transform to a point
    fn apply(&self, x: f64, y: f64) -> (f64, f64) {
        let rx = self.cos_theta * x - self.sin_theta * y + self.tx;
        let ry = self.sin_theta * x + self.cos_theta * y + self.ty;
        (rx, ry)
    }
}

/// Running statistics per pixel for sigma clipping
/// Stores sum and sum-of-squares to compute mean and variance incrementally.
#[derive(Debug, Clone)]
struct PixelAccumulator {
    /// Running sum of pixel values
    sum: f64,
    /// Running sum of squared pixel values (for variance)
    sum_sq: f64,
    /// Number of accepted values
    count: u32,
}

impl Default for PixelAccumulator {
    fn default() -> Self {
        Self {
            sum: 0.0,
            sum_sq: 0.0,
            count: 0,
        }
    }
}

/// The main live stacking engine
pub struct LiveStacker {
    /// Image dimensions
    width: u32,
    height: u32,
    channels: u32,

    /// Reference frame stars (detected from the first frame)
    reference_stars: Vec<DetectedStar>,

    /// Per-pixel accumulators for sigma-clipping
    /// Length: width * height * channels
    accumulators: Vec<PixelAccumulator>,

    /// Configuration
    config: LiveStackConfig,

    /// Running statistics
    stats: StackingStats,

    /// What the stacked frames' own headers said, folded for the master's FITS
    /// header. See [`crate::stack_master`].
    provenance: StackProvenance,

    /// Centroid of reference stars for transform computation
    ref_centroid: (f64, f64),
}

impl LiveStacker {
    /// Create a new live stacker initialized with the reference frame.
    ///
    /// The reference frame defines the coordinate system that all subsequent
    /// frames will be aligned to. Stars are detected in the reference frame
    /// and stored for matching.
    ///
    /// The reference frame contributes pixels to the master, so it contributes
    /// provenance too — as unknown here. Callers that read the reference from a
    /// file should use [`LiveStacker::new_with_provenance`] so the master's
    /// `EXPTIME` / `DATE-OBS` count it.
    pub fn new(reference_frame: &ImageData, config: LiveStackConfig) -> Result<Self, String> {
        Self::new_with_provenance(reference_frame, config, &FrameProvenance::unknown())
    }

    /// Create a live stacker whose reference frame arrived with a header.
    pub fn new_with_provenance(
        reference_frame: &ImageData,
        config: LiveStackConfig,
        reference_provenance: &FrameProvenance,
    ) -> Result<Self, String> {
        if reference_frame.is_empty() {
            return Err("Reference frame is empty".to_string());
        }

        if reference_frame.pixel_type != PixelType::U16 {
            return Err(format!(
                "Live stacking currently supports U16 images only, got {:?}",
                reference_frame.pixel_type
            ));
        }

        if !matches!(reference_frame.channels, 1 | 3) {
            return Err(format!(
                "Live stacking supports 1-channel (mono) or 3-channel (RGB) images only, got {} channels",
                reference_frame.channels
            ));
        }

        let width = reference_frame.width;
        let height = reference_frame.height;
        let channels = reference_frame.channels;

        // Detect stars on the alignment plane. For mono frames that is the
        // frame itself; for already-debayered RGB frames it is the luminance
        // proxy so star centroids come from a stable, channel-collapsed plane
        // rather than a scrambled interleaved buffer (which `detect_stars`
        // would otherwise misread).
        let detection_image = detection_plane(reference_frame);
        let ref_stars = detect_stars(&detection_image, &config.star_detection);
        if ref_stars.len() < config.min_matched_pairs {
            return Err(format!(
                "Reference frame has only {} stars, need at least {} for alignment",
                ref_stars.len(),
                config.min_matched_pairs
            ));
        }

        tracing::info!(
            "Live stacker initialized: {}x{} reference with {} stars",
            width,
            height,
            ref_stars.len()
        );

        // Compute centroid of reference stars (used for rotation center)
        let n = ref_stars.len().min(config.max_match_stars) as f64;
        let ref_centroid = ref_stars
            .iter()
            .take(config.max_match_stars)
            .fold((0.0, 0.0), |(sx, sy), s| (sx + s.x, sy + s.y));
        let ref_centroid = (ref_centroid.0 / n, ref_centroid.1 / n);

        // Initialize accumulators from reference frame pixel data
        let ref_pixels = extract_u16_as_f64(reference_frame);
        let accumulators: Vec<PixelAccumulator> = ref_pixels
            .par_iter()
            .map(|&val| PixelAccumulator {
                sum: val,
                sum_sq: val * val,
                count: 1,
            })
            .collect();

        let mut stacker = Self {
            width,
            height,
            channels,
            reference_stars: ref_stars,
            accumulators,
            config,
            stats: StackingStats::default(),
            provenance: StackProvenance::default(),
            ref_centroid,
        };

        stacker.stats.total_frames_attempted = 1;
        stacker.stats.stacked_frame_count = 1;
        stacker.provenance.fold(reference_provenance);

        Ok(stacker)
    }

    /// Add a frame to the stack. Returns the current stacked result.
    ///
    /// Steps:
    /// 1. Detect stars in the new frame
    /// 2. Match stars against reference frame using nearest-neighbor with flux constraint
    /// 3. Compute affine transform (translation + rotation) from matched pairs
    /// 4. Apply transform to align frame pixels to reference
    /// 5. Accumulate aligned pixels with optional sigma-clipping rejection
    pub fn add_frame(&mut self, frame: &ImageData) -> Result<ImageData, String> {
        self.add_frame_with_provenance(frame, &FrameProvenance::unknown())
    }

    /// Add a frame that arrived with a header of its own. Only frames that are
    /// actually stacked fold into the master's provenance — a frame rejected
    /// for alignment contributes no pixels, so it must contribute no
    /// integration time either.
    pub fn add_frame_with_provenance(
        &mut self,
        frame: &ImageData,
        provenance: &FrameProvenance,
    ) -> Result<ImageData, String> {
        self.stats.total_frames_attempted += 1;

        // Validate dimensions
        if frame.width != self.width || frame.height != self.height {
            return Err(format!(
                "Frame dimensions {}x{} don't match reference {}x{}",
                frame.width, frame.height, self.width, self.height
            ));
        }
        if frame.channels != self.channels {
            return Err(format!(
                "Frame channel count {} doesn't match reference {}",
                frame.channels, self.channels
            ));
        }
        if frame.pixel_type != PixelType::U16 {
            return Err(format!(
                "Expected U16 pixel type, got {:?}",
                frame.pixel_type
            ));
        }

        // Step 1: Detect stars on the alignment plane (luminance proxy for
        // RGB, the frame itself for mono — see `detection_plane`).
        let detection_image = detection_plane(frame);
        let frame_stars = detect_stars(&detection_image, &self.config.star_detection);
        if frame_stars.len() < self.config.min_matched_pairs {
            self.stats.rejected_alignment_failures += 1;
            tracing::warn!(
                "Frame rejected: only {} stars detected (need {})",
                frame_stars.len(),
                self.config.min_matched_pairs
            );
            return Err(format!(
                "Insufficient stars for alignment: {} detected, {} required",
                frame_stars.len(),
                self.config.min_matched_pairs
            ));
        }

        // Step 2: Match stars
        let matches = match_stars(
            &self.reference_stars,
            &frame_stars,
            self.config.max_match_stars,
            self.config.match_radius_px,
            self.config.match_flux_tolerance,
        );

        if matches.len() < self.config.min_matched_pairs {
            self.stats.rejected_alignment_failures += 1;
            tracing::warn!(
                "Frame rejected: only {} star matches (need {})",
                matches.len(),
                self.config.min_matched_pairs
            );
            return Err(format!(
                "Insufficient star matches for alignment: {} matched, {} required",
                matches.len(),
                self.config.min_matched_pairs
            ));
        }

        // Step 3: Fit the transform robustly. Fitting over every
        // nearest-neighbour pair lets a few mis-pairings from the 50px match
        // radius dominate the least squares — see [`fit_transform_robust`],
        // which first finds the largest set of pairs agreeing on one transform
        // and then clips what remains. `residual` below is therefore the RMS
        // over the surviving pairs, which is what the ceiling is meant to gate
        // on.
        let (transform, residual, inlier_count) =
            fit_transform_robust(&matches, self.ref_centroid, self.config.min_matched_pairs);

        if inlier_count < self.config.min_matched_pairs {
            self.stats.rejected_alignment_failures += 1;
            tracing::warn!(
                "Frame rejected: only {} of {} star matches agree on one transform (need {})",
                inlier_count,
                matches.len(),
                self.config.min_matched_pairs
            );
            return Err(format!(
                "Inconsistent star matches for alignment: {} of {} agree on one transform, \
                 {} required",
                inlier_count,
                matches.len(),
                self.config.min_matched_pairs
            ));
        }

        // Reject a geometrically-inconsistent fit before it is folded in. A
        // large residual means even the surviving pairs do not agree on a
        // single affine transform, and accumulating the resampled frame would
        // permanently blur the stack.
        if residual.is_finite() && residual > self.config.max_alignment_residual_px {
            self.stats.rejected_alignment_failures += 1;
            tracing::warn!(
                "Frame rejected: alignment residual {:.2}px exceeds max {:.2}px \
                 ({} of {} matches used)",
                residual,
                self.config.max_alignment_residual_px,
                inlier_count,
                matches.len()
            );
            return Err(format!(
                "Alignment residual too high: {:.2}px (max {:.2}px)",
                residual, self.config.max_alignment_residual_px
            ));
        }

        tracing::debug!(
            "Frame aligned: {} of {} matches, residual={:.2}px, tx={:.1}, ty={:.1}, rot={:.3}deg",
            inlier_count,
            matches.len(),
            residual,
            transform.tx,
            transform.ty,
            transform.sin_theta.atan2(transform.cos_theta).to_degrees()
        );

        // Step 4: Extract frame pixels and apply transform
        let frame_pixels = extract_u16_as_f64(frame);
        let aligned_pixels = apply_transform_bilinear(
            &frame_pixels,
            self.width as usize,
            self.height as usize,
            self.channels as usize,
            &transform,
        );

        // Step 5: Accumulate with optional sigma clipping
        let sigma_rejected = self.accumulate_pixels(&aligned_pixels);

        // Update stats
        self.stats.stacked_frame_count += 1;
        self.provenance.fold(provenance);
        // Why (audit IMG-): `avg_matched_pairs` and
        // `avg_alignment_residual` are *per-aligned-frame* metrics. The
        // reference frame contributes neither — it is not matched against
        // itself and has zero residual by construction. Dividing by
        // `stacked_frame_count` (which includes the reference) diluted
        // both averages by `(N-1)/N`. We instead average over the count
        // of non-reference frames actually contributing samples.
        //
        // `.saturating_sub(1)` removes the reference's slot;
        // `.max(1)` prevents the impossible-but-cheap divide-by-zero on
        // the very first added frame (where the count just incremented
        // from 1→2, so the contributing count is 1).
        let aligned_count = self.stats.stacked_frame_count.saturating_sub(1).max(1) as f64;
        self.stats.avg_matched_pairs = self.stats.avg_matched_pairs
            * ((aligned_count - 1.0) / aligned_count)
            + matches.len() as f64 / aligned_count;
        self.stats.avg_alignment_residual = self.stats.avg_alignment_residual
            * ((aligned_count - 1.0) / aligned_count)
            + residual / aligned_count;
        self.stats.total_sigma_rejected_pixels += sigma_rejected;

        tracing::info!(
            "Frame {} stacked ({} total, {} rejected, {:.0} sigma-clipped px)",
            self.stats.total_frames_attempted,
            self.stats.stacked_frame_count,
            self.stats.rejected_alignment_failures,
            sigma_rejected,
        );

        // Return current stack
        Ok(self.get_current_stack())
    }

    /// Accumulate aligned pixel values into the running stack.
    /// Returns the number of pixels rejected by sigma clipping.
    ///
    /// Channel independence (load-bearing for OSC): `accumulators` and
    /// `aligned_pixels` are both laid out as `width * height * channels` in
    /// interleaved order (`..., R, G, B, R, G, B, ...` for 3-channel frames).
    /// The `zip` below pairs each accumulator slot with exactly one aligned
    /// sample of the *same* channel, so every interleaved slot owns its own
    /// `sum` / `sum_sq` / `count` and its own sigma-clip decision. No value
    /// from one channel ever contributes to, or is rejected on behalf of,
    /// another channel — colour balance is preserved and a per-channel
    /// outlier (e.g. a hot pixel in only the R plane) is clipped from that
    /// channel alone.
    fn accumulate_pixels(&mut self, aligned_pixels: &[f64]) -> u64 {
        let sigma_enabled = self.config.sigma_clip_enabled;
        let sigma_threshold = self.config.sigma_clip_threshold;

        // Process in parallel chunks for cache efficiency
        // We need mutable access to accumulators, so we use par_iter_mut
        let rejected: u64 = self
            .accumulators
            .par_iter_mut()
            .zip(aligned_pixels.par_iter())
            .map(|(acc, &val)| {
                // Skip NaN values (outside-of-frame pixels from transform)
                if val.is_nan() {
                    return 0u64;
                }

                if sigma_enabled && acc.count >= 3 {
                    // Sigma clipping: reject pixels that deviate too far from running mean
                    let mean = acc.sum / acc.count as f64;
                    let variance = if acc.count > 1 {
                        (acc.sum_sq - (acc.sum * acc.sum) / acc.count as f64)
                            / (acc.count as f64 - 1.0)
                    } else {
                        0.0
                    };
                    let std_dev = variance.max(0.0).sqrt();

                    if std_dev > 0.0 && (val - mean).abs() > sigma_threshold * std_dev {
                        return 1u64; // rejected
                    }
                }

                acc.sum += val;
                acc.sum_sq += val * val;
                acc.count += 1;
                0u64
            })
            .sum();

        rejected
    }

    /// Get the current stacked result as an ImageData.
    /// Returns the mean of all accumulated pixel values.
    pub fn get_current_stack(&self) -> ImageData {
        let pixel_count = (self.width as usize) * (self.height as usize) * (self.channels as usize);
        let mut result_u16 = vec![0u16; pixel_count];

        result_u16
            .par_iter_mut()
            .zip(self.accumulators.par_iter())
            .for_each(|(out, acc)| {
                if acc.count > 0 {
                    let mean = acc.sum / acc.count as f64;
                    *out = mean.round().clamp(0.0, 65535.0) as u16;
                }
            });

        ImageData::from_u16(self.width, self.height, self.channels, &result_u16)
    }

    /// Reset the stacker, clearing all accumulated data.
    /// The reference frame stars are preserved.
    pub fn reset(&mut self) {
        let pixel_count = (self.width as usize) * (self.height as usize) * (self.channels as usize);
        self.accumulators = vec![PixelAccumulator::default(); pixel_count];
        self.stats = StackingStats::default();
        // The reset drops every accumulated pixel, so the integration those
        // frames contributed goes with them: a new stack starts now.
        self.provenance = StackProvenance::default();
        tracing::info!("Live stacker reset");
    }

    /// Get the number of successfully stacked frames.
    pub fn frame_count(&self) -> u32 {
        self.stats.stacked_frame_count
    }

    /// Get stacking statistics.
    pub fn get_stats(&self) -> StackingStats {
        self.stats.clone()
    }

    /// The provenance of the frames actually in the stack, for the FITS master.
    pub fn provenance(&self) -> &StackProvenance {
        &self.provenance
    }
}

// Star matching

/// A matched star pair: reference star index, frame star index, distance
#[derive(Debug, Clone)]
#[allow(dead_code)]
struct StarMatch {
    ref_star: DetectedStar,
    frame_star: DetectedStar,
    distance: f64,
}

/// Match stars between reference and frame by *mutual* nearest neighbour, with
/// a radius and a flux-ratio constraint.
///
/// A pair is kept only when the frame star is the reference star's closest
/// admissible candidate **and** that reference star is in turn the frame star's
/// closest admissible candidate. Both directions are searched over the same
/// candidate set (the brightest `max_stars` reference stars, everything within
/// `match_radius` px whose flux ratio is inside `flux_tolerance`), so the
/// relation is symmetric by construction.
///
/// The mutual test is what stops a *steal chain*. The previous matcher walked
/// the reference stars brightest-first and consumed whichever frame star it
/// picked. A bright reference star the frame detector happened to miss would
/// therefore take a neighbour tens of pixels away but still inside the 50px
/// radius; that neighbour's true owner, now denied, took the next one along;
/// and the displacement propagated across the field in a single direction. A
/// chain of wrong pairs that all point the same way is the worst possible input
/// to a least-squares fit — the errors reinforce instead of cancelling, and no
/// amount of outlier rejection downstream can tell the coherent majority-ish
/// bloc from the truth. Under the mutual test an orphaned reference star simply
/// fails to match: the frame star it wanted is 2px from its real owner and 45px
/// from the orphan, so the frame star's own nearest reference star wins and the
/// chain never starts.
///
/// O(N*M), which is fine for the typical star counts (~50-200).
fn match_stars(
    ref_stars: &[DetectedStar],
    frame_stars: &[DetectedStar],
    max_stars: usize,
    match_radius: f64,
    flux_tolerance: f64,
) -> Vec<StarMatch> {
    let match_radius_sq = match_radius * match_radius;
    let ref_count = ref_stars.len().min(max_stars);
    let min_flux_ratio = 1.0 - flux_tolerance;

    // Closest admissible counterpart in each direction, as (index, dist_sq).
    let mut best_for_ref: Vec<Option<(usize, f64)>> = vec![None; ref_count];
    let mut best_for_frame: Vec<Option<(usize, f64)>> = vec![None; frame_stars.len()];

    // Stars arrive sorted by flux (brightest first) from detect_stars, so a
    // strict `<` on distance resolves an exact tie towards the brighter star in
    // both directions — which keeps the two passes consistent with each other.
    for (ri, ref_star) in ref_stars.iter().take(max_stars).enumerate() {
        for (fi, frame_star) in frame_stars.iter().enumerate() {
            let dx = ref_star.x - frame_star.x;
            let dy = ref_star.y - frame_star.y;
            let dist_sq = dx * dx + dy * dy;

            if dist_sq > match_radius_sq {
                continue;
            }

            // Flux ratio check: the ratio of smaller/larger flux must exceed (1 - tolerance)
            let flux_ratio = if ref_star.flux > frame_star.flux {
                frame_star.flux / ref_star.flux
            } else {
                ref_star.flux / frame_star.flux
            };

            if flux_ratio < min_flux_ratio {
                continue;
            }

            if best_for_ref[ri].is_none_or(|(_, best)| dist_sq < best) {
                best_for_ref[ri] = Some((fi, dist_sq));
            }
            if best_for_frame[fi].is_none_or(|(_, best)| dist_sq < best) {
                best_for_frame[fi] = Some((ri, dist_sq));
            }
        }
    }

    // Emit in reference order (brightest first), as callers have always seen.
    let mut matches = Vec::new();
    for (ri, ref_star) in ref_stars.iter().take(max_stars).enumerate() {
        let Some((fi, dist_sq)) = best_for_ref[ri] else {
            continue;
        };
        if best_for_frame[fi].map(|(best_ri, _)| best_ri) != Some(ri) {
            continue;
        }
        matches.push(StarMatch {
            ref_star: ref_star.clone(),
            frame_star: frame_stars[fi].clone(),
            distance: dist_sq.sqrt(),
        });
    }

    matches
}

// Affine transform computation

/// Compute the best-fit affine transform (translation + rotation) from matched star pairs.
///
/// Uses the Procrustes method:
/// 1. Compute centroids of both point sets
/// 2. Center both sets on their centroids
/// 3. Compute rotation angle via atan2 of cross/dot products
/// 4. Translation = ref_centroid - R * frame_centroid
///
/// This is a rigid body transform (no scaling) which is appropriate for
/// tracking/mount-shift between frames of the same optical system.
fn compute_affine_transform(
    matches: &[StarMatch],
    _ref_centroid_hint: (f64, f64),
) -> AffineTransform {
    if matches.is_empty() {
        return AffineTransform::identity();
    }

    let n = matches.len() as f64;

    // Compute centroids of matched pairs
    let (ref_cx, ref_cy) = matches.iter().fold((0.0, 0.0), |(sx, sy), m| {
        (sx + m.ref_star.x, sy + m.ref_star.y)
    });
    let (ref_cx, ref_cy) = (ref_cx / n, ref_cy / n);

    let (frm_cx, frm_cy) = matches.iter().fold((0.0, 0.0), |(sx, sy), m| {
        (sx + m.frame_star.x, sy + m.frame_star.y)
    });
    let (frm_cx, frm_cy) = (frm_cx / n, frm_cy / n);

    // Center both sets on their centroids
    // Compute rotation using cross-covariance
    // sum of (centered_frame) x (centered_ref) gives sin/cos components
    let mut sum_cross = 0.0; // Sum of x_f * y_r - y_f * x_r (cross product, proportional to sin(theta))
    let mut sum_dot = 0.0; // Sum of x_f * x_r + y_f * y_r (dot product, proportional to cos(theta))

    for m in matches {
        let fx = m.frame_star.x - frm_cx;
        let fy = m.frame_star.y - frm_cy;
        let rx = m.ref_star.x - ref_cx;
        let ry = m.ref_star.y - ref_cy;

        sum_dot += fx * rx + fy * ry;
        sum_cross += fx * ry - fy * rx;
    }

    // Rotation angle: frame -> reference
    let theta = sum_cross.atan2(sum_dot);
    let cos_theta = theta.cos();
    let sin_theta = theta.sin();

    // Translation: ref_centroid = R * frame_centroid + t
    // So: t = ref_centroid - R * frame_centroid
    let tx = ref_cx - (cos_theta * frm_cx - sin_theta * frm_cy);
    let ty = ref_cy - (sin_theta * frm_cx + cos_theta * frm_cy);

    AffineTransform {
        tx,
        ty,
        cos_theta,
        sin_theta,
    }
}

/// Pairs whose post-fit deviation exceeds `CLIP_SIGMA x median deviation` are
/// dropped and the transform refit. Multiplying the *median* (not the RMS)
/// keeps the cutoff from being inflated by the very pairs it must remove.
const CLIP_SIGMA: f64 = 3.0;

/// Floor under the clipping cutoff, in reference pixels. Without it a set of
/// pairs that already agrees to a hundredth of a pixel would clip itself down
/// to the minimum on detector centroid noise alone.
const CLIP_FLOOR_PX: f64 = 1.5;

/// Enough passes to shed the pairs a nearest-neighbour matcher gets wrong;
/// more only chases centroid noise.
const MAX_CLIP_PASSES: usize = 5;

/// How far a pair may sit from a candidate transform and still be counted as
/// agreeing with it, in reference pixels. Star centroids on a well-sampled
/// frame are good to a few tenths of a pixel, so 2px is loose enough to hold
/// every genuinely-corresponding pair and far tighter than the tens of pixels a
/// mis-paired neighbour lands at.
const CONSENSUS_INLIER_PX: f64 = 2.0;

/// Below this RMS the pairs already agree on one transform and the consensus
/// search is skipped: it exists to break a *disagreement*, and running it on
/// clean data could only shrink a healthy pair set.
const CONSENSUS_TRIGGER_PX: f64 = 1.0;

/// Two pairs sitting closer together than this cannot pin down a rotation — the
/// lever arm is too short and centroid noise swamps the angle — so they are not
/// used to seed a candidate transform.
const CONSENSUS_MIN_BASELINE_PX: f64 = 20.0;

/// Ceiling on how many two-pair hypotheses the consensus search will try. All
/// pairs of 100 matches (the `max_match_stars` default) is 4950, so this is
/// only reached with an unusually permissive configuration.
const MAX_CONSENSUS_HYPOTHESES: usize = 8000;

/// The fraction of matched pairs that must agree before the consensus fit is
/// adopted.
///
/// Consensus finds the *largest* agreeing subset, which is the right answer
/// only when the pairs it discards are matcher mistakes. It is the wrong answer
/// when the frame is genuinely not a rigid transform of the reference — a badly
/// distorted or field-rotated sub can split its stars into two blocs that each
/// describe a real but different displacement. Aligning to the bigger bloc
/// there would resample the frame so the other bloc lands pixels away and then
/// fold that smear permanently into the stack, which is precisely what the
/// residual ceiling exists to prevent.
///
/// Requiring a dominant bloc keeps the two cases apart: a scatter of mis-pairs
/// leaves the true correspondences in a clear majority, while a split field has
/// no majority and falls back to the fit over every pair — whose residual is
/// large, so the ceiling rejects the frame exactly as it did before.
const CONSENSUS_MIN_FRACTION: f64 = 0.6;

/// Find the largest subset of `matches` that agrees on a single rigid
/// transform, by seeding a candidate transform from every admissible pair of
/// matches and keeping the seed with the widest agreement.
///
/// This is the part median-based clipping cannot do. Clipping assumes the
/// wrong pairs are a scattered minority, so that the median deviation still
/// describes the good pairs; it drops whatever sits far from the *current* fit
/// and refits. When the wrong pairs are instead displaced coherently — all
/// stolen from the same direction, which is exactly what a steal chain
/// produces — they drag the fit towards themselves, the good pairs end up as
/// far from that fit as the bad ones, the cutoff (3x median) covers everybody,
/// nothing is clipped, and the loop exits on its first pass having changed
/// nothing. Consensus does not care how the errors are distributed: a bloc of
/// coherently-wrong pairs describes a *different* transform, and whichever
/// transform more pairs agree on wins.
///
/// Returns indices into `matches`, or `None` when there is not enough geometry
/// to seed a hypothesis at all.
fn consensus_inliers(matches: &[StarMatch], ref_centroid: (f64, f64)) -> Option<Vec<usize>> {
    let n = matches.len();
    if n < 3 {
        return None;
    }
    let tol_sq = CONSENSUS_INLIER_PX * CONSENSUS_INLIER_PX;
    let baseline_sq = CONSENSUS_MIN_BASELINE_PX * CONSENSUS_MIN_BASELINE_PX;

    let mut best: Vec<usize> = Vec::new();
    let mut hypotheses = 0usize;

    'seeds: for a in 0..n {
        for b in (a + 1)..n {
            // Both sides need a real lever arm: a pair of frame stars that
            // coincide would leave the rotation undetermined.
            let (rdx, rdy) = (
                matches[a].ref_star.x - matches[b].ref_star.x,
                matches[a].ref_star.y - matches[b].ref_star.y,
            );
            let (fdx, fdy) = (
                matches[a].frame_star.x - matches[b].frame_star.x,
                matches[a].frame_star.y - matches[b].frame_star.y,
            );
            if rdx * rdx + rdy * rdy < baseline_sq || fdx * fdx + fdy * fdy < baseline_sq {
                continue;
            }

            hypotheses += 1;
            if hypotheses > MAX_CONSENSUS_HYPOTHESES {
                break 'seeds;
            }

            let seed = [matches[a].clone(), matches[b].clone()];
            let candidate = compute_affine_transform(&seed, ref_centroid);

            let agreeing: Vec<usize> = (0..n)
                .filter(|&i| {
                    let (tx, ty) =
                        candidate.apply(matches[i].frame_star.x, matches[i].frame_star.y);
                    let dx = tx - matches[i].ref_star.x;
                    let dy = ty - matches[i].ref_star.y;
                    dx * dx + dy * dy <= tol_sq
                })
                .collect();

            if agreeing.len() > best.len() {
                best = agreeing;
            }
        }
    }

    if best.is_empty() {
        None
    } else {
        Some(best)
    }
}

/// Fit the frame→reference transform with outlier rejection, and report the
/// fit, the RMS residual **over the surviving pairs**, and how many survived.
///
/// A single least-squares fit over every nearest-neighbour match is not robust.
/// `match_radius_px` defaults to 50 in frames whose mean star separation is
/// under 100px and the flux gate is loose, so the matcher can pair a star with
/// a neighbour tens of pixels away. A handful of such pairs drags the Procrustes
/// fit far enough to inflate the RMS past the rejection ceiling: two frames of
/// the same 40-star field differing by a rigid 2.2px translation measure
/// 10.34px and are refused, when the correct fit is sub-pixel.
///
/// Two stages, in this order, because they fail on opposite inputs:
///
/// 1. [`consensus_inliers`] picks the largest set of pairs that agree on one
///    transform. This survives wrong pairs that are displaced *coherently*,
///    where median clipping provably does not (see that function).
/// 2. The median-clipping loop then polishes that set, shedding pairs that sit
///    just outside the consensus tolerance because of centroid noise rather
///    than mis-pairing. On already-clean data it is a no-op.
///
/// Stage 1 only runs when the plain fit is already inconsistent
/// (`CONSENSUS_TRIGGER_PX`), and its result is adopted only when the agreeing
/// set keeps at least `min_pairs` pairs, holds a dominant share of the matches
/// (`CONSENSUS_MIN_FRACTION`) *and* lowers the residual. So it can never shrink
/// a healthy pair set below the caller's alignment gate, never align to a
/// minority bloc of a genuinely non-rigid frame, and never replace a fit with a
/// worse one — a frame that registers today cannot start failing because of it.
fn fit_transform_robust(
    matches: &[StarMatch],
    ref_centroid: (f64, f64),
    min_pairs: usize,
) -> (AffineTransform, f64, usize) {
    let mut inliers: Vec<StarMatch> = matches.to_vec();
    let mut transform = compute_affine_transform(&inliers, ref_centroid);
    let mut residual = compute_alignment_residual(&inliers, &transform);

    // A rigid fit has 4 degrees of freedom, so never clip below 3 pairs however
    // permissive the caller's `min_matched_pairs` is.
    let floor_pairs = min_pairs.max(3);

    if residual > CONSENSUS_TRIGGER_PX {
        let dominant = (matches.len() as f64 * CONSENSUS_MIN_FRACTION).ceil() as usize;
        if let Some(agreeing) = consensus_inliers(matches, ref_centroid) {
            if agreeing.len() >= floor_pairs && agreeing.len() >= dominant {
                let subset: Vec<StarMatch> = agreeing.iter().map(|&i| matches[i].clone()).collect();
                let subset_transform = compute_affine_transform(&subset, ref_centroid);
                let subset_residual = compute_alignment_residual(&subset, &subset_transform);
                if subset_residual < residual {
                    inliers = subset;
                    transform = subset_transform;
                    residual = subset_residual;
                }
            }
        }
    }

    for _ in 0..MAX_CLIP_PASSES {
        if inliers.len() <= floor_pairs {
            break;
        }

        let mut deviations: Vec<f64> = inliers
            .iter()
            .map(|m| {
                let (tx, ty) = transform.apply(m.frame_star.x, m.frame_star.y);
                let dx = tx - m.ref_star.x;
                let dy = ty - m.ref_star.y;
                (dx * dx + dy * dy).sqrt()
            })
            .collect();

        let mut sorted = deviations.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let median = sorted[sorted.len() / 2];
        let cutoff = (CLIP_SIGMA * median).max(CLIP_FLOOR_PX);

        let kept: Vec<StarMatch> = inliers
            .iter()
            .zip(deviations.drain(..))
            .filter(|(_, dev)| *dev <= cutoff)
            .map(|(m, _)| m.clone())
            .collect();

        // Nothing clipped, or clipping would take us below a fittable set:
        // the current solution is the best this match list supports.
        if kept.len() == inliers.len() || kept.len() < floor_pairs {
            break;
        }

        inliers = kept;
        transform = compute_affine_transform(&inliers, ref_centroid);
        residual = compute_alignment_residual(&inliers, &transform);
    }

    let count = inliers.len();
    (transform, residual, count)
}

/// Compute RMS alignment residual after applying the transform.
/// This measures how well the transform aligns the matched stars.
fn compute_alignment_residual(matches: &[StarMatch], transform: &AffineTransform) -> f64 {
    if matches.is_empty() {
        return 0.0;
    }

    let sum_sq: f64 = matches
        .iter()
        .map(|m| {
            let (tx, ty) = transform.apply(m.frame_star.x, m.frame_star.y);
            let dx = tx - m.ref_star.x;
            let dy = ty - m.ref_star.y;
            dx * dx + dy * dy
        })
        .sum();

    (sum_sq / matches.len() as f64).sqrt()
}

// Frame alignment (pixel resampling)

/// Apply the inverse affine transform to resample frame pixels onto the reference grid.
///
/// For each output pixel (in reference coordinates), we compute where it maps
/// in the frame using the inverse transform, then use bilinear interpolation
/// to sample the frame pixel value.
///
/// Pixels that map outside the frame boundaries are set to NaN (sentinel)
/// so they can be excluded from accumulation.
fn apply_transform_bilinear(
    frame_pixels: &[f64],
    width: usize,
    height: usize,
    channels: usize,
    transform: &AffineTransform,
) -> Vec<f64> {
    let pixel_count = width * height * channels;
    let stride = width * channels;

    // Compute inverse transform: frame_pos = R^-1 * (ref_pos - t)
    // For rotation matrix R(theta), R^-1 = R(-theta)
    let inv_cos = transform.cos_theta; // cos(-theta) = cos(theta)
    let inv_sin = -transform.sin_theta; // sin(-theta) = -sin(theta)
                                        // Process rows in parallel
    let result: Vec<f64> = (0..height)
        .into_par_iter()
        .flat_map(|y| {
            let mut row = vec![f64::NAN; width * channels];

            for x in 0..width {
                // Apply the inverse affine transform explicitly as R^-1(ref - t).
                let rx = x as f64 - transform.tx;
                let ry = y as f64 - transform.ty;
                let fx = inv_cos * rx - inv_sin * ry;
                let fy = inv_sin * rx + inv_cos * ry;

                // Bilinear interpolation
                let fx_floor = fx.floor();
                let fy_floor = fy.floor();
                let ix = fx_floor as i64;
                let iy = fy_floor as i64;

                // Require the base pixel (ix, iy) in range. The +1 neighbours
                // only contribute when the fractional offset is non-zero, so a
                // sample landing exactly on the last row/column (dx==0/dy==0)
                // must not be dropped: an `ix+1 >= width` test would discard
                // the entire last row and column even under the identity
                // transform. Clamp the +1 index to the edge; its weight is 0
                // when the corresponding offset is 0 (exact on-grid), and it
                // edge-extends otherwise.
                if ix < 0 || iy < 0 || ix >= width as i64 || iy >= height as i64 {
                    // Out of bounds: leave as NaN
                    continue;
                }

                let ix = ix as usize;
                let iy = iy as usize;
                let ix1 = (ix + 1).min(width - 1);
                let iy1 = (iy + 1).min(height - 1);
                let dx = fx - fx_floor;
                let dy = fy - fy_floor;

                let w00 = (1.0 - dx) * (1.0 - dy);
                let w10 = dx * (1.0 - dy);
                let w01 = (1.0 - dx) * dy;
                let w11 = dx * dy;

                for c in 0..channels {
                    let p00 = frame_pixels[iy * stride + ix * channels + c];
                    let p10 = frame_pixels[iy * stride + ix1 * channels + c];
                    let p01 = frame_pixels[iy1 * stride + ix * channels + c];
                    let p11 = frame_pixels[iy1 * stride + ix1 * channels + c];

                    row[x * channels + c] = w00 * p00 + w10 * p10 + w01 * p01 + w11 * p11;
                }
            }

            row
        })
        .collect();

    debug_assert_eq!(result.len(), pixel_count);
    result
}

// Utility functions

/// Extract U16 image data as f64 values
fn extract_u16_as_f64(image: &ImageData) -> Vec<f64> {
    image
        .data
        .par_chunks_exact(2)
        .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]) as f64)
        .collect()
}

// Master frame combination (bias / dark / flat)
//
// Why this lives next to LiveStacker: both consume a population of frames and
// produce a single combined frame using rejection statistics. LiveStacker is
// the *online* path (one ref + incoming aligned lights); the routines below
// are the *offline* path (a static stack of calibration frames combined in a
// single pass). Sharing the file keeps the pixel-array math in one place.

/// What kind of master frame we are building.
///
/// The kind controls the post-combine behaviour:
/// - `Bias` and `Dark`: take the combined value as-is (no normalisation).
/// - `Flat`: normalise so the *mean* of the master equals 1.0 for `F32`
///   output or `32768` for `U16` output. Normalising is required because
///   the light/flat division step assumes the flat has unit mean; an
///   un-normalised flat would otherwise rescale the light frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MasterFrameKind {
    Bias,
    Dark,
    Flat,
}

impl MasterFrameKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            MasterFrameKind::Bias => "BIAS",
            MasterFrameKind::Dark => "DARK",
            MasterFrameKind::Flat => "FLAT",
        }
    }
}

/// How to combine the input frames pixel-by-pixel.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum CombineMethod {
    /// Arithmetic mean of all input values. Lowest noise, but a single
    /// transient (cosmic ray, satellite trail, hot pixel pop) propagates
    /// into the master.
    Mean,
    /// Per-pixel median. Robust to single-frame outliers; the default for
    /// bias and dark masters and the recommended fallback for flats when
    /// the user can't afford the cost of sigma clipping.
    Median,
    /// Iterative sigma clipping. For each pixel, compute mean & stddev,
    /// reject samples outside `kappa * sigma`, repeat for `iterations`,
    /// take the final mean. Preferred for >10 frames; rejects single-frame
    /// transients without the full bias of the median.
    SigmaClip { kappa: f64, iterations: u32 },
}

impl CombineMethod {
    pub fn as_str(&self) -> String {
        match self {
            CombineMethod::Mean => "MEAN".to_string(),
            CombineMethod::Median => "MEDIAN".to_string(),
            CombineMethod::SigmaClip { kappa, iterations } => {
                format!("SIGMA_CLIP({:.2}, {})", kappa, iterations)
            }
        }
    }
}

/// Pixel type preference for the produced master frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MasterOutputType {
    /// 16-bit unsigned integer (legacy calibration pipelines). For flats,
    /// mean is rescaled to 32768 ADU (half-scale) so division still uses
    /// the existing u16 divide path.
    U16,
    /// 32-bit float. Preferred for flats (no quantisation loss when
    /// normalised to mean 1.0) and for sigma-clipped masters.
    F32,
}

/// A combined master calibration frame plus the metadata describing how
/// it was built. Stored so downstream calibration knows which combine
/// method was used and how many frames contributed.
#[derive(Debug, Clone)]
pub struct MasterFrame {
    /// The combined pixel data.
    pub image: ImageData,
    /// What kind of master this represents.
    pub kind: MasterFrameKind,
    /// How many input frames contributed to the combine.
    pub frame_count: u32,
    /// Which combine method produced the master.
    pub method: CombineMethod,
    /// The final output pixel type. Mirrors `image.pixel_type` for
    /// quick inspection without unpacking `image`.
    pub output_type: MasterOutputType,
    /// Mean pixel value of the combined master. For flats this is the
    /// pre-normalisation mean; useful for diagnostics and FITS metadata.
    pub input_mean: f64,
    /// Mean pixel value AFTER normalisation (only meaningful for flats;
    /// equals `input_mean` for bias/dark since they are not normalised).
    pub output_mean: f64,
}

/// Peak size of the decoded `f64` working set, across all frames, for one band
/// of rows.
///
/// Why bands: per-column statistics need no more than the rows currently being
/// combined, so frames are decoded a band at a time and peak residency is this
/// constant instead of a multiple of the sensor. Decoding every frame to `f64`
/// up front costs `frames.len() × pixels × 8` bytes — 5.8 GB for 30 darks off a
/// 24 MP sensor, on top of the caller's own `u16` copies.
const BAND_BUDGET_BYTES: usize = 32 * 1024 * 1024;

/// Combine a stack of calibration frames into a single master frame.
///
/// Validation: returns `Err` for an empty input, mismatched dimensions /
/// channel counts, or any unsupported pixel type. We deliberately *do not*
/// fall back silently — a calibration master built from heterogeneous
/// frames would silently corrupt every science frame it touches downstream.
///
/// Output pixel type:
/// - `MasterOutputType::U16`: values are clamped to `[0, 65535]` and rounded.
///   For flats this means the *normalised* master has a target mean of 32768
///   (half-scale) so existing u16 calibration code paths still divide
///   correctly.
/// - `MasterOutputType::F32`: values stored without quantisation. For flats
///   the normalised master has a target mean of 1.0.
pub fn combine_master_frames(
    frames: &[ImageData],
    kind: MasterFrameKind,
    method: CombineMethod,
    output_type: MasterOutputType,
) -> Result<MasterFrame, String> {
    let row_samples = frames
        .first()
        .map(|f| (f.width as usize) * (f.channels as usize))
        .unwrap_or(0);
    let bytes_per_row = row_samples.saturating_mul(frames.len()).saturating_mul(8);
    let band_rows = BAND_BUDGET_BYTES
        .checked_div(bytes_per_row)
        .unwrap_or(1)
        .max(1);
    combine_master_frames_banded(frames, kind, method, output_type, band_rows)
}

/// [`combine_master_frames`] with an explicit band height, so the banding can
/// be exercised at every boundary without synthesising a multi-gigabyte stack.
fn combine_master_frames_banded(
    frames: &[ImageData],
    kind: MasterFrameKind,
    method: CombineMethod,
    output_type: MasterOutputType,
    band_rows: usize,
) -> Result<MasterFrame, String> {
    // Validation
    if frames.is_empty() {
        return Err(format!(
            "combine_master_frames: cannot build {} master from zero frames",
            kind.as_str()
        ));
    }

    let first = &frames[0];
    if first.is_empty() {
        return Err("combine_master_frames: first frame is empty".to_string());
    }

    let width = first.width;
    let height = first.height;
    let channels = first.channels;
    let pixel_type = first.pixel_type;

    if !matches!(pixel_type, PixelType::U16 | PixelType::F32) {
        return Err(format!(
            "combine_master_frames: unsupported input pixel type {:?}; only U16 and F32 are accepted",
            pixel_type
        ));
    }

    for (i, frame) in frames.iter().enumerate() {
        if frame.is_empty() {
            return Err(format!("combine_master_frames: frame {} is empty", i));
        }
        if frame.width != width || frame.height != height {
            return Err(format!(
                "combine_master_frames: frame {} dimensions {}x{} don't match first frame {}x{}",
                i, frame.width, frame.height, width, height
            ));
        }
        if frame.channels != channels {
            return Err(format!(
                "combine_master_frames: frame {} channel count {} doesn't match first frame {}",
                i, frame.channels, channels
            ));
        }
        if frame.pixel_type != pixel_type {
            return Err(format!(
                "combine_master_frames: frame {} pixel type {:?} doesn't match first frame {:?}",
                i, frame.pixel_type, pixel_type
            ));
        }
    }

    if let CombineMethod::SigmaClip { kappa, iterations } = method {
        if !(kappa.is_finite() && kappa > 0.0) {
            return Err(format!(
                "combine_master_frames: invalid sigma-clip kappa {} (must be > 0 and finite)",
                kappa
            ));
        }
        if iterations == 0 {
            return Err("combine_master_frames: sigma-clip iterations must be >= 1".to_string());
        }
    }

    let row_samples = (width as usize) * (channels as usize);
    let pixel_count = row_samples * (height as usize);
    let sample_bytes = pixel_type.byte_size();
    for (i, frame) in frames.iter().enumerate() {
        if frame.data.len() < pixel_count * sample_bytes {
            return Err(format!(
                "combine_master_frames: frame {} holds {} bytes but {}x{}x{} {:?} needs {}",
                i,
                frame.data.len(),
                width,
                height,
                channels,
                pixel_type,
                pixel_count * sample_bytes
            ));
        }
    }

    // Per-pixel combine, one band of rows at a time
    // The statistics themselves live in `integration::integrate_columns`: it is
    // the same population-wide rejector, row-parallel with a reused scratch
    // column instead of a heap allocation per output pixel.
    let (combine, reject, iteration_limit) = match method {
        CombineMethod::Mean => (Combine::Mean, Reject::None, 0),
        CombineMethod::Median => (Combine::Median, Reject::None, 0),
        CombineMethod::SigmaClip { kappa, iterations } => (
            Combine::Mean,
            Reject::SigmaClip {
                low: kappa,
                high: kappa,
            },
            iterations as usize,
        ),
    };
    let config = IntegrationConfig {
        combine,
        reject,
        // `integrate_columns` hands back raw f64; the output type below is
        // applied here, after the flat normalisation.
        output_type: PixelType::F32,
        generate_rejection_map: false,
        generate_weight_map: false,
        min_coverage: 1,
    };

    let band_rows = band_rows.clamp(1, (height as usize).max(1));
    let mut combined: Vec<f64> = Vec::with_capacity(pixel_count);
    let mut band: Vec<Vec<f64>> = vec![Vec::new(); frames.len()];
    let mut row = 0usize;
    while row < height as usize {
        let rows = band_rows.min(height as usize - row);
        let start = row * row_samples;
        let count = rows * row_samples;
        for (buffer, frame) in band.iter_mut().zip(frames) {
            decode_band_f64(frame, start, count, buffer);
        }
        let borrowed: Vec<IntegrationFrame<'_>> = band
            .iter()
            .map(|pixels| IntegrationFrame {
                pixels,
                weight: 1.0,
                coverage: None,
            })
            .collect();
        let columns = integrate_columns(
            &borrowed,
            width,
            rows as u32,
            channels,
            &config,
            iteration_limit,
        )
        .map_err(|e| format!("combine_master_frames: {e}"))?;
        combined.extend_from_slice(&columns.master);
        row += rows;
    }

    // Compute mean BEFORE normalisation
    let input_sum: f64 = combined.par_iter().sum();
    let input_mean = input_sum / combined.len() as f64;

    // Normalise flats only
    let (final_pixels, output_mean) = match kind {
        MasterFrameKind::Flat => {
            if !input_mean.is_finite() || input_mean <= 0.0 {
                return Err(format!(
                    "combine_master_frames: cannot normalise flat — pre-normalisation mean is {} (must be > 0)",
                    input_mean
                ));
            }
            // For F32 output we target a normalised mean of 1.0.
            // For U16 output we target 32768 so the existing u16 divide-by-flat
            // path (which divides by `flat_pixel / flat_mean`) still operates
            // on values that fit in the [0, 65535] range without saturating.
            let target_mean = match output_type {
                MasterOutputType::F32 => 1.0,
                MasterOutputType::U16 => 32768.0,
            };
            let scale = target_mean / input_mean;
            let scaled: Vec<f64> = combined.par_iter().map(|&v| v * scale).collect();
            (scaled, target_mean)
        }
        MasterFrameKind::Bias | MasterFrameKind::Dark => (combined, input_mean),
    };

    // Materialise the output ImageData
    let image = match output_type {
        MasterOutputType::U16 => {
            let u16_data: Vec<u16> = final_pixels
                .par_iter()
                .map(|&v| v.round().clamp(0.0, 65535.0) as u16)
                .collect();
            ImageData::from_u16(width, height, channels, &u16_data)
        }
        MasterOutputType::F32 => {
            let f32_data: Vec<f32> = final_pixels.par_iter().map(|&v| v as f32).collect();
            ImageData::from_f32(width, height, channels, &f32_data)
        }
    };

    Ok(MasterFrame {
        image,
        kind,
        frame_count: frames.len() as u32,
        method,
        output_type,
        input_mean,
        output_mean,
    })
}

/// Decode `count` samples of `image`, starting at sample `start`, into `out`
/// as `f64`. `out` is caller-owned scratch reused across bands.
fn decode_band_f64(image: &ImageData, start: usize, count: usize, out: &mut Vec<f64>) {
    out.clear();
    out.reserve(count);
    match image.pixel_type {
        PixelType::U16 => {
            let bytes = &image.data[start * 2..(start + count) * 2];
            out.extend(
                bytes
                    .as_chunks::<2>()
                    .0
                    .iter()
                    .map(|c| u16::from_le_bytes([c[0], c[1]]) as f64),
            );
        }
        PixelType::F32 => {
            let bytes = &image.data[start * 4..(start + count) * 4];
            out.extend(
                bytes
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]) as f64),
            );
        }
        _ => unreachable!("pixel_type validated by combine_master_frames"),
    }
}

#[cfg(test)]
mod master_parity_tests {
    //! Golden parity for the master-frame combiner.
    //!
    //! [`combine_master_frames`] delegates to
    //! [`crate::integration::integrate_columns`]. `reference_combine` below is
    //! the superseded per-pixel combiner, kept verbatim as the golden: every
    //! case these tests exercise must come out bit-for-bit identical.

    use super::*;

    /// The superseded per-pixel `combine_master_frames`, transcribed
    /// unchanged.
    fn reference_combine(
        frames: &[ImageData],
        kind: MasterFrameKind,
        method: CombineMethod,
        output_type: MasterOutputType,
    ) -> (Vec<u8>, f64, f64) {
        fn median_in_place(samples: &mut [f64]) -> f64 {
            let n = samples.len();
            samples.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
            if n % 2 == 1 {
                samples[n / 2]
            } else {
                (samples[n / 2 - 1] + samples[n / 2]) * 0.5
            }
        }

        fn sigma_clip_in_place(samples: &mut [f64], kappa: f64, iterations: u32) -> f64 {
            if samples.len() <= 2 {
                return samples.iter().sum::<f64>() / samples.len() as f64;
            }
            let mut working: Vec<f64> = samples.to_vec();
            for _ in 0..iterations {
                if working.len() < 3 {
                    break;
                }
                let n = working.len() as f64;
                let mean: f64 = working.iter().sum::<f64>() / n;
                let var: f64 = working
                    .iter()
                    .map(|&v| (v - mean) * (v - mean))
                    .sum::<f64>()
                    / (n - 1.0);
                let sigma = var.max(0.0).sqrt();
                if sigma == 0.0 {
                    break;
                }
                let lo = mean - kappa * sigma;
                let hi = mean + kappa * sigma;
                let before = working.len();
                working.retain(|&v| v >= lo && v <= hi);
                if working.len() == before {
                    break;
                }
                if working.is_empty() {
                    return median_in_place(samples);
                }
            }
            working.iter().sum::<f64>() / working.len() as f64
        }

        let first = &frames[0];
        let (width, height, channels) = (first.width, first.height, first.channels);
        let pixel_count = (width as usize) * (height as usize) * (channels as usize);

        let frame_stacks: Vec<Vec<f64>> = frames
            .iter()
            .map(|f| match f.pixel_type {
                PixelType::U16 => extract_u16_as_f64(f),
                PixelType::F32 => f
                    .data
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]) as f64)
                    .collect(),
                _ => unreachable!(),
            })
            .collect();

        let combined: Vec<f64> = (0..pixel_count)
            .map(|i| {
                let mut samples: Vec<f64> = frame_stacks.iter().map(|s| s[i]).collect();
                match method {
                    CombineMethod::Mean => samples.iter().sum::<f64>() / samples.len() as f64,
                    CombineMethod::Median => median_in_place(&mut samples),
                    CombineMethod::SigmaClip { kappa, iterations } => {
                        sigma_clip_in_place(&mut samples, kappa, iterations)
                    }
                }
            })
            .collect();

        // `par_iter().sum()` (not a sequential sum): rayon's reduction order is
        // an observable part of the result, and the production path uses it.
        let input_mean = combined.par_iter().sum::<f64>() / combined.len() as f64;
        let (final_pixels, output_mean) = match kind {
            MasterFrameKind::Flat => {
                let target_mean = match output_type {
                    MasterOutputType::F32 => 1.0,
                    MasterOutputType::U16 => 32768.0,
                };
                let scale = target_mean / input_mean;
                (
                    combined.iter().map(|&v| v * scale).collect::<Vec<f64>>(),
                    target_mean,
                )
            }
            MasterFrameKind::Bias | MasterFrameKind::Dark => (combined, input_mean),
        };

        let data = match output_type {
            MasterOutputType::U16 => {
                let u16_data: Vec<u16> = final_pixels
                    .iter()
                    .map(|&v| v.round().clamp(0.0, 65535.0) as u16)
                    .collect();
                ImageData::from_u16(width, height, channels, &u16_data).data
            }
            MasterOutputType::F32 => {
                let f32_data: Vec<f32> = final_pixels.iter().map(|&v| v as f32).collect();
                ImageData::from_f32(width, height, channels, &f32_data).data
            }
        };
        (data, input_mean, output_mean)
    }

    /// Deterministic pseudo-random u16 frames with a few injected outliers, so
    /// the sigma-clip and median paths actually have something to reject.
    fn synthetic_u16_frames(
        count: usize,
        width: u32,
        height: u32,
        channels: u32,
    ) -> Vec<ImageData> {
        let n = (width * height * channels) as usize;
        (0..count)
            .map(|f| {
                let pixels: Vec<u16> = (0..n)
                    .map(|i| {
                        let mix = (i as u64)
                            .wrapping_mul(6_364_136_223_846_793_005)
                            .wrapping_add((f as u64).wrapping_mul(1_442_695_040_888_963_407));
                        let base = 1000 + ((mix >> 33) % 200) as u16;
                        // Every 17th pixel of every 3rd frame is a cosmic-ray spike.
                        if f % 3 == 0 && i % 17 == 0 {
                            base.saturating_add(20_000)
                        } else {
                            base
                        }
                    })
                    .collect();
                ImageData::from_u16(width, height, channels, &pixels)
            })
            .collect()
    }

    fn synthetic_f32_frames(
        count: usize,
        width: u32,
        height: u32,
        channels: u32,
    ) -> Vec<ImageData> {
        let n = (width * height * channels) as usize;
        (0..count)
            .map(|f| {
                let pixels: Vec<f32> = (0..n)
                    .map(|i| {
                        let mix = (i as u64)
                            .wrapping_mul(2_862_933_555_777_941_757)
                            .wrapping_add((f as u64).wrapping_mul(3_037_000_493));
                        let base = 0.4 + ((mix >> 40) % 1000) as f32 / 5000.0;
                        if f % 4 == 1 && i % 13 == 0 {
                            base * 9.0
                        } else {
                            base
                        }
                    })
                    .collect();
                ImageData::from_f32(width, height, channels, &pixels)
            })
            .collect()
    }

    fn assert_matches_reference(
        frames: &[ImageData],
        kind: MasterFrameKind,
        method: CombineMethod,
        output_type: MasterOutputType,
        label: &str,
    ) {
        let (expected_data, expected_input_mean, expected_output_mean) =
            reference_combine(frames, kind, method, output_type);
        let got = combine_master_frames(frames, kind, method, output_type).expect(label);

        assert_eq!(
            got.image.data, expected_data,
            "{label}: pixel data diverged"
        );
        assert_eq!(
            got.input_mean, expected_input_mean,
            "{label}: input_mean diverged"
        );
        assert_eq!(
            got.output_mean, expected_output_mean,
            "{label}: output_mean diverged"
        );
        assert_eq!(got.frame_count, frames.len() as u32);
        assert_eq!(got.method, method);
        assert_eq!(got.output_type, output_type);
    }

    #[test]
    fn every_method_and_kind_matches_the_pre_merge_combiner() {
        let methods = [
            CombineMethod::Mean,
            CombineMethod::Median,
            CombineMethod::SigmaClip {
                kappa: 3.0,
                iterations: 5,
            },
            // One iteration must clip exactly once: this is what pins the
            // caller's `iterations` through to the shared rejector, whose own
            // default limit is 8.
            CombineMethod::SigmaClip {
                kappa: 1.5,
                iterations: 1,
            },
            CombineMethod::SigmaClip {
                kappa: 2.0,
                iterations: 20,
            },
        ];
        let kinds = [
            MasterFrameKind::Bias,
            MasterFrameKind::Dark,
            MasterFrameKind::Flat,
        ];
        let outputs = [MasterOutputType::U16, MasterOutputType::F32];

        for &frame_count in &[1usize, 2, 3, 8, 11] {
            for (w, h, c) in [(7u32, 5u32, 1u32), (4, 3, 3)] {
                let u16_frames = synthetic_u16_frames(frame_count, w, h, c);
                let f32_frames = synthetic_f32_frames(frame_count, w, h, c);
                for &method in &methods {
                    for &kind in &kinds {
                        for &output in &outputs {
                            assert_matches_reference(
                                &u16_frames,
                                kind,
                                method,
                                output,
                                &format!("u16 {frame_count}x{w}x{h}x{c} {method:?} {kind:?}"),
                            );
                            assert_matches_reference(
                                &f32_frames,
                                kind,
                                method,
                                output,
                                &format!("f32 {frame_count}x{w}x{h}x{c} {method:?} {kind:?}"),
                            );
                        }
                    }
                }
            }
        }
    }

    /// The combiner now walks the frames in row bands so the decoded `f64`
    /// working set is bounded instead of holding every frame at once. The band
    /// height must not be observable in the output.
    #[test]
    fn band_height_does_not_change_the_result() {
        let frames = synthetic_u16_frames(9, 6, 8, 3);
        let method = CombineMethod::SigmaClip {
            kappa: 2.5,
            iterations: 4,
        };
        let (expected, _, _) = reference_combine(
            &frames,
            MasterFrameKind::Flat,
            method,
            MasterOutputType::F32,
        );

        for band in 1..=9usize {
            let got = combine_master_frames_banded(
                &frames,
                MasterFrameKind::Flat,
                method,
                MasterOutputType::F32,
                band,
            )
            .expect("banded combine");
            assert_eq!(got.image.data, expected, "band height {band} diverged");
        }
    }

    /// A column that sigma clipping rejects entirely falls back to the median
    /// of the untouched column — the pre-merge behaviour, which only a
    /// sub-1σ kappa can reach.
    #[test]
    fn total_rejection_falls_back_to_the_median() {
        // Three at 0 and three at 10 000: mean 5000, sample σ ≈ 5477, so a
        // 0.5σ band excludes every sample.
        let values = [0u16, 0, 0, 10_000, 10_000, 10_000];
        let frames: Vec<ImageData> = values
            .iter()
            .map(|&v| ImageData::from_u16(1, 1, 1, &[v]))
            .collect();
        let method = CombineMethod::SigmaClip {
            kappa: 0.5,
            iterations: 3,
        };

        let (expected, _, _) = reference_combine(
            &frames,
            MasterFrameKind::Dark,
            method,
            MasterOutputType::F32,
        );
        assert_eq!(
            f32::from_le_bytes(expected[..4].try_into().unwrap()),
            5000.0,
            "reference must take the median of the whole column"
        );

        assert_matches_reference(
            &frames,
            MasterFrameKind::Dark,
            method,
            MasterOutputType::F32,
            "total rejection",
        );
    }

    /// The one intentional divergence from the golden: a non-finite sample is
    /// dropped rather than propagated, because one NaN in a flat corrupts that
    /// pixel of the master for every light it divides.
    #[test]
    fn a_nan_in_one_frame_does_not_poison_the_master_pixel() {
        let frames = [
            ImageData::from_f32(1, 1, 1, &[1.0]),
            ImageData::from_f32(1, 1, 1, &[f32::NAN]),
            ImageData::from_f32(1, 1, 1, &[3.0]),
        ];

        let got = combine_master_frames(
            &frames,
            MasterFrameKind::Dark,
            CombineMethod::Mean,
            MasterOutputType::F32,
        )
        .expect("combine");
        assert_eq!(
            f32::from_le_bytes(got.image.data[..4].try_into().unwrap()),
            2.0
        );

        let (reference, _, _) = reference_combine(
            &frames,
            MasterFrameKind::Dark,
            CombineMethod::Mean,
            MasterOutputType::F32,
        );
        assert!(
            f32::from_le_bytes(reference[..4].try_into().unwrap()).is_nan(),
            "the pre-merge combiner propagated the NaN"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Create a simple test image with a known star pattern.
    /// Background is 1000 ADU with Gaussian noise (sigma ~30 ADU).
    /// Stars are Gaussian profiles with sigma=2.5 pixels (realistic HFR ~2-3).
    fn make_test_image(width: u32, height: u32, star_positions: &[(f64, f64, f64)]) -> ImageData {
        let w = width as usize;
        let h = height as usize;
        let bg = 1000u16;
        let mut data = vec![bg; w * h];

        // Add simple deterministic noise for realistic background statistics
        for (i, pixel) in data.iter_mut().enumerate() {
            // Noise with ~30 ADU standard deviation using simple LCG
            let n = ((i as u64).wrapping_mul(1103515245).wrapping_add(12345) >> 16) & 0xFF;
            let noise = (n as i32 - 128) / 4; // range roughly [-32, 32]
            *pixel = (bg as i32 + noise).clamp(0, 65535) as u16;
        }

        for &(sx, sy, brightness) in star_positions {
            // Draw Gaussian star with sigma=2.5 (realistic PSF)
            let radius = 8i32;
            let sigma = 2.5;
            for dy in -radius..=radius {
                for dx in -radius..=radius {
                    let px = sx as i32 + dx;
                    let py = sy as i32 + dy;
                    if px >= 0 && px < width as i32 && py >= 0 && py < height as i32 {
                        let dist_sq = (dx * dx + dy * dy) as f64;
                        let gauss = (-dist_sq / (2.0 * sigma * sigma)).exp();
                        let val = (brightness * gauss) as u32;
                        let idx = py as usize * w + px as usize;
                        data[idx] = (data[idx] as u32 + val).min(65535) as u16;
                    }
                }
            }
        }

        ImageData::from_u16(width, height, 1, &data)
    }

    /// Per-channel scale factors applied to the base star field when building
    /// a 3-channel test image. Distinct factors per channel let tests assert
    /// that channels are kept independent through alignment + accumulation.
    #[derive(Clone, Copy)]
    struct ChannelGains {
        r: f64,
        g: f64,
        b: f64,
    }

    /// Build a 3-channel interleaved RGB star field that is photometrically
    /// consistent with `make_test_image`'s mono field.
    ///
    /// The R, G, B planes are independent copies of the mono field scaled by
    /// `gains.{r,g,b}`. With `gains = (1.0, 1.0, 1.0)` the luminance proxy
    /// (0.299+0.587+0.114 = 1.0) of the result equals the mono field exactly
    /// (modulo rounding), which is what `color_registration_parity` relies on.
    fn make_test_image_rgb(
        width: u32,
        height: u32,
        star_positions: &[(f64, f64, f64)],
        gains: ChannelGains,
    ) -> ImageData {
        let mono = make_test_image(width, height, star_positions);
        let mono_px = mono.as_u16().expect("mono test image is u16");
        let pixel_count = mono_px.len();

        let mut interleaved = vec![0u16; pixel_count * 3];
        for (i, &m) in mono_px.iter().enumerate() {
            let v = m as f64;
            interleaved[i * 3] = (v * gains.r).round().clamp(0.0, 65535.0) as u16;
            interleaved[i * 3 + 1] = (v * gains.g).round().clamp(0.0, 65535.0) as u16;
            interleaved[i * 3 + 2] = (v * gains.b).round().clamp(0.0, 65535.0) as u16;
        }

        ImageData::from_u16(width, height, 3, &interleaved)
    }

    /// The bright, well-separated star field shared by the OSC tests.
    fn osc_test_field() -> Vec<(f64, f64, f64)> {
        vec![
            (100.0, 100.0, 40000.0),
            (200.0, 150.0, 35000.0),
            (300.0, 200.0, 38000.0),
            (150.0, 300.0, 30000.0),
            (250.0, 250.0, 36000.0),
            (350.0, 100.0, 32000.0),
            (50.0, 350.0, 28000.0),
        ]
    }

    /// Lenient detection config used by the OSC tests (mirrors
    /// `test_stacker_creation`).
    fn osc_test_config() -> LiveStackConfig {
        LiveStackConfig {
            min_matched_pairs: 3,
            star_detection: StarDetectionConfig {
                detection_sigma: 3.0,
                min_snr: 3.0,
                min_hfr: 0.5,
                max_sharpness: 1.0,
                ..StarDetectionConfig::default()
            },
            ..LiveStackConfig::default()
        }
    }

    #[test]
    fn test_stacker_creation() {
        // Bright stars with peak intensities well above background
        let stars = vec![
            (100.0, 100.0, 40000.0),
            (200.0, 150.0, 35000.0),
            (300.0, 200.0, 38000.0),
            (150.0, 300.0, 30000.0),
            (250.0, 250.0, 36000.0),
            (350.0, 100.0, 32000.0),
            (50.0, 350.0, 28000.0),
        ];
        let img = make_test_image(512, 512, &stars);
        let config = LiveStackConfig {
            min_matched_pairs: 3,
            star_detection: StarDetectionConfig {
                detection_sigma: 3.0,
                min_snr: 3.0,
                min_hfr: 0.5,
                max_sharpness: 1.0,
                ..StarDetectionConfig::default()
            },
            ..LiveStackConfig::default()
        };

        let stacker = LiveStacker::new(&img, config);
        assert!(
            stacker.is_ok(),
            "Stacker creation failed: {:?}",
            stacker.err()
        );
        let stacker = stacker.unwrap();
        assert_eq!(stacker.frame_count(), 1);
    }

    #[test]
    fn test_affine_translation_only() {
        // Create matches with a known translation
        let matches = vec![
            StarMatch {
                ref_star: DetectedStar {
                    x: 100.0,
                    y: 100.0,
                    flux: 1000.0,
                    hfr: 2.0,
                    fwhm: 4.7,
                    peak: 5000.0,
                    background: 500.0,
                    snr: 50.0,
                    eccentricity: 0.1,
                    sharpness: 0.3,
                },
                frame_star: DetectedStar {
                    x: 105.0,
                    y: 103.0,
                    flux: 1000.0,
                    hfr: 2.0,
                    fwhm: 4.7,
                    peak: 5000.0,
                    background: 500.0,
                    snr: 50.0,
                    eccentricity: 0.1,
                    sharpness: 0.3,
                },
                distance: 5.83,
            },
            StarMatch {
                ref_star: DetectedStar {
                    x: 200.0,
                    y: 200.0,
                    flux: 800.0,
                    hfr: 2.0,
                    fwhm: 4.7,
                    peak: 4000.0,
                    background: 500.0,
                    snr: 40.0,
                    eccentricity: 0.1,
                    sharpness: 0.3,
                },
                frame_star: DetectedStar {
                    x: 205.0,
                    y: 203.0,
                    flux: 800.0,
                    hfr: 2.0,
                    fwhm: 4.7,
                    peak: 4000.0,
                    background: 500.0,
                    snr: 40.0,
                    eccentricity: 0.1,
                    sharpness: 0.3,
                },
                distance: 5.83,
            },
        ];

        let transform = compute_affine_transform(&matches, (150.0, 150.0));

        // With pure translation of (5,3), the transform should have tx ~ -5, ty ~ -3
        // and zero rotation
        assert!(
            (transform.cos_theta - 1.0).abs() < 0.01,
            "cos_theta should be ~1.0"
        );
        assert!(transform.sin_theta.abs() < 0.01, "sin_theta should be ~0.0");
        assert!(
            (transform.tx - (-5.0)).abs() < 0.1,
            "tx should be ~-5.0, got {}",
            transform.tx
        );
        assert!(
            (transform.ty - (-3.0)).abs() < 0.1,
            "ty should be ~-3.0, got {}",
            transform.ty
        );
    }

    #[test]
    fn test_apply_transform_bilinear_rotation_and_translation() {
        let width = 5usize;
        let height = 5usize;
        let channels = 1usize;
        let mut frame_pixels = vec![0.0; width * height * channels];
        frame_pixels[2 * width + 1] = 42.0;

        let transform = AffineTransform {
            tx: 2.0,
            ty: 1.0,
            cos_theta: 0.0,
            sin_theta: 1.0,
        };

        let aligned = apply_transform_bilinear(&frame_pixels, width, height, channels, &transform);

        assert_eq!(
            aligned[2 * width],
            42.0,
            "inverse affine mapping should land the rotated pixel at its transformed coordinates"
        );
    }

    #[test]
    fn test_star_matching() {
        let ref_stars = vec![
            DetectedStar {
                x: 100.0,
                y: 100.0,
                flux: 10000.0,
                hfr: 2.0,
                fwhm: 4.7,
                peak: 5000.0,
                background: 500.0,
                snr: 50.0,
                eccentricity: 0.1,
                sharpness: 0.3,
            },
            DetectedStar {
                x: 200.0,
                y: 200.0,
                flux: 8000.0,
                hfr: 2.0,
                fwhm: 4.7,
                peak: 4000.0,
                background: 500.0,
                snr: 40.0,
                eccentricity: 0.1,
                sharpness: 0.3,
            },
        ];

        // Frame stars shifted by (3, 2)
        let frame_stars = vec![
            DetectedStar {
                x: 103.0,
                y: 102.0,
                flux: 9500.0,
                hfr: 2.0,
                fwhm: 4.7,
                peak: 5000.0,
                background: 500.0,
                snr: 50.0,
                eccentricity: 0.1,
                sharpness: 0.3,
            },
            DetectedStar {
                x: 203.0,
                y: 202.0,
                flux: 7800.0,
                hfr: 2.0,
                fwhm: 4.7,
                peak: 4000.0,
                background: 500.0,
                snr: 40.0,
                eccentricity: 0.1,
                sharpness: 0.3,
            },
        ];

        let matches = match_stars(&ref_stars, &frame_stars, 50, 20.0, 0.5);
        assert_eq!(matches.len(), 2, "Should match both stars");
    }

    #[test]
    fn sigma_clipping_uses_sample_variance_for_small_stacks() {
        let count = 3.0;
        let sum = 1000.0 + 1002.0 + 998.0;
        let sum_sq = 1000.0f64.powi(2) + 1002.0f64.powi(2) + 998.0f64.powi(2);
        let mean = sum / count;
        let sample_variance = (sum_sq - (sum * sum) / count) / (count - 1.0);
        let population_variance = (sum_sq / count) - mean * mean;
        let sample_std_dev = sample_variance.sqrt();
        let population_std_dev = population_variance.sqrt();
        let outlier_delta = (1004.0 - mean).abs();

        assert!(
            outlier_delta <= 2.0 * sample_std_dev,
            "sample variance should keep the moderate deviation"
        );
        assert!(
            outlier_delta > 2.0 * population_std_dev,
            "population variance would incorrectly reject the same deviation"
        );
    }

    // Master frame combination tests

    /// Build a synthetic U16 image filled with a constant value (single channel).
    fn constant_u16_image(width: u32, height: u32, value: u16) -> ImageData {
        let data = vec![value; (width as usize) * (height as usize)];
        ImageData::from_u16(width, height, 1, &data)
    }

    #[test]
    fn master_bias_constant_value_yields_that_constant() {
        // 5 identical bias frames at 1234 ADU. Median (and mean) should
        // produce exactly 1234 — bias is the simplest case and any drift
        // would indicate the combine path is silently corrupting data.
        let frames: Vec<ImageData> = (0..5).map(|_| constant_u16_image(4, 4, 1234)).collect();
        let master = combine_master_frames(
            &frames,
            MasterFrameKind::Bias,
            CombineMethod::Median,
            MasterOutputType::U16,
        )
        .expect("master bias build should succeed");

        assert_eq!(master.kind, MasterFrameKind::Bias);
        assert_eq!(master.frame_count, 5);
        assert_eq!(master.output_type, MasterOutputType::U16);

        let pixels = master.image.as_u16().expect("u16 master should return u16");
        assert_eq!(pixels.len(), 16);
        for &p in &pixels {
            assert_eq!(
                p, 1234,
                "every pixel of the bias master should be the constant input value"
            );
        }
        assert!((master.input_mean - 1234.0).abs() < 1e-9);
        assert!((master.output_mean - 1234.0).abs() < 1e-9);
    }

    #[test]
    fn master_dark_median_rejects_single_cosmic_ray_hit() {
        // 3 dark frames, all at ADU=500 except one frame has a cosmic-ray
        // hit at pixel (1,1) saturating to 65535. Median should reject the
        // outlier and return 500 at that pixel; the mean would return ~21845.
        let w = 4;
        let h = 4;
        let mut f1 = vec![500u16; (w * h) as usize];
        let mut f2 = vec![500u16; (w * h) as usize];
        let f3 = vec![500u16; (w * h) as usize];
        // Cosmic ray on f1 at (1,1); also a different hit on f2 at (2,2)
        // to confirm median rejects each independently per-pixel.
        let cr_idx_1 = (w + 1) as usize;
        let cr_idx_2 = (2 * w + 2) as usize;
        f1[cr_idx_1] = 65535;
        f2[cr_idx_2] = 65535;

        let frames = vec![
            ImageData::from_u16(w, h, 1, &f1),
            ImageData::from_u16(w, h, 1, &f2),
            ImageData::from_u16(w, h, 1, &f3),
        ];

        let master = combine_master_frames(
            &frames,
            MasterFrameKind::Dark,
            CombineMethod::Median,
            MasterOutputType::U16,
        )
        .expect("master dark build should succeed");

        let pixels = master.image.as_u16().expect("u16 master");
        for (i, &p) in pixels.iter().enumerate() {
            assert_eq!(
                p, 500,
                "pixel {} should be 500 after median rejection of cosmic ray",
                i
            );
        }
    }

    #[test]
    fn master_flat_is_normalised_to_unit_mean_f32() {
        // 5 flat frames with mean ~10000 ADU. After normalisation to F32,
        // the master mean must be 1.0 (within floating-point tolerance).
        // Use a gradient so the normalised values are visibly non-uniform
        // — this catches the bug where normalisation accidentally maps
        // everything to a single constant.
        let w: u32 = 8;
        let h: u32 = 8;
        let pixel_count = (w * h) as usize;

        // Build a frame whose mean is 10000 ADU but with per-pixel variation
        // (linear ramp 5000..15000). The mean of this ramp is 10000.
        let mut ramp_pixels = Vec::with_capacity(pixel_count);
        for i in 0..pixel_count {
            // Linear from 5000 to 15000 across the image.
            let v = 5000.0 + 10000.0 * (i as f64) / ((pixel_count - 1) as f64);
            ramp_pixels.push(v.round() as u16);
        }
        // Sanity: confirm the test fixture mean really is 10000.
        let raw_mean =
            ramp_pixels.iter().map(|&p| p as f64).sum::<f64>() / ramp_pixels.len() as f64;
        assert!(
            (raw_mean - 10000.0).abs() < 1.0,
            "test fixture ramp mean should be ~10000, got {}",
            raw_mean
        );

        let frames: Vec<ImageData> = (0..5)
            .map(|_| ImageData::from_u16(w, h, 1, &ramp_pixels))
            .collect();

        let master = combine_master_frames(
            &frames,
            MasterFrameKind::Flat,
            CombineMethod::Median,
            MasterOutputType::F32,
        )
        .expect("master flat build should succeed");

        assert_eq!(master.kind, MasterFrameKind::Flat);
        assert_eq!(master.output_type, MasterOutputType::F32);

        let pixels = master.image.as_f32().expect("f32 master should return f32");
        assert_eq!(pixels.len(), pixel_count);
        let out_mean: f64 = pixels.iter().map(|&v| v as f64).sum::<f64>() / pixels.len() as f64;
        assert!(
            (out_mean - 1.0).abs() < 1e-4,
            "normalised flat mean should be 1.0, got {}",
            out_mean
        );
        // Confirm we preserved relative variation — the smallest normalised
        // pixel should be roughly 0.5 (since 5000/10000=0.5).
        let min_pixel = pixels.iter().cloned().fold(f32::INFINITY, f32::min);
        assert!(
            (min_pixel - 0.5).abs() < 0.01,
            "min normalised pixel should be ~0.5, got {}",
            min_pixel
        );
    }

    #[test]
    fn master_flat_u16_normalised_to_half_scale_32768() {
        // Same as the f32 case but request U16 output. The flat's normalised
        // mean should land on 32768 (half-scale) so the legacy u16
        // calibration code can still divide without saturation.
        let w: u32 = 4;
        let h: u32 = 4;
        let frames: Vec<ImageData> = (0..5).map(|_| constant_u16_image(w, h, 10000)).collect();

        let master = combine_master_frames(
            &frames,
            MasterFrameKind::Flat,
            CombineMethod::Median,
            MasterOutputType::U16,
        )
        .expect("u16 master flat build should succeed");

        let pixels = master.image.as_u16().expect("u16 master");
        for &p in &pixels {
            assert_eq!(
                p, 32768,
                "constant flat normalised to U16 should be exactly 32768"
            );
        }
        assert!((master.output_mean - 32768.0).abs() < 1e-9);
        assert!((master.input_mean - 10000.0).abs() < 1e-9);
    }

    #[test]
    fn empty_input_returns_err() {
        let frames: Vec<ImageData> = Vec::new();
        let result = combine_master_frames(
            &frames,
            MasterFrameKind::Bias,
            CombineMethod::Median,
            MasterOutputType::U16,
        );
        assert!(
            result.is_err(),
            "empty input must return Err, not silently produce a master"
        );
        let err = result.unwrap_err();
        assert!(
            err.contains("zero frames") || err.contains("empty"),
            "error should mention empty/zero frames, got: {}",
            err
        );
    }

    #[test]
    fn mixed_dimensions_returns_err() {
        let f1 = constant_u16_image(4, 4, 1000);
        let f2 = constant_u16_image(8, 4, 1000); // different width
        let result = combine_master_frames(
            &[f1, f2],
            MasterFrameKind::Dark,
            CombineMethod::Median,
            MasterOutputType::U16,
        );
        assert!(result.is_err(), "mixed dimensions must return Err");
        assert!(
            result.unwrap_err().contains("dimensions"),
            "error should mention dimensions"
        );
    }

    #[test]
    fn mixed_pixel_types_returns_err() {
        let f1 = constant_u16_image(4, 4, 1000);
        let f2 = ImageData::from_f32(4, 4, 1, &[1000.0f32; 16]);
        let result = combine_master_frames(
            &[f1, f2],
            MasterFrameKind::Dark,
            CombineMethod::Median,
            MasterOutputType::U16,
        );
        assert!(result.is_err(), "mixed pixel types must return Err");
    }

    #[test]
    fn sigma_clip_rejects_outliers_in_dark_master() {
        // 11 dark frames: 10 at 500 ADU and one outlier at 65000.
        // Sigma clipping at k=2 should reject the outlier; the resulting
        // mean should be ~500, not the mean-with-outlier (~6363).
        let w: u32 = 2;
        let h: u32 = 2;
        let mut frames: Vec<ImageData> = (0..10).map(|_| constant_u16_image(w, h, 500)).collect();
        frames.push(constant_u16_image(w, h, 65000));

        let master = combine_master_frames(
            &frames,
            MasterFrameKind::Dark,
            CombineMethod::SigmaClip {
                kappa: 2.0,
                iterations: 3,
            },
            MasterOutputType::U16,
        )
        .expect("sigma-clip master should succeed");

        let pixels = master.image.as_u16().unwrap();
        for &p in &pixels {
            assert!(
                (p as i32 - 500).abs() < 5,
                "sigma-clipped dark pixel should be ~500, got {}",
                p
            );
        }
    }

    #[test]
    fn invalid_sigma_clip_params_return_err() {
        let frames: Vec<ImageData> = (0..5).map(|_| constant_u16_image(2, 2, 1000)).collect();
        // Zero iterations
        let r1 = combine_master_frames(
            &frames,
            MasterFrameKind::Dark,
            CombineMethod::SigmaClip {
                kappa: 2.0,
                iterations: 0,
            },
            MasterOutputType::U16,
        );
        assert!(r1.is_err(), "sigma-clip iterations=0 must fail");
        // Negative kappa
        let r2 = combine_master_frames(
            &frames,
            MasterFrameKind::Dark,
            CombineMethod::SigmaClip {
                kappa: -1.0,
                iterations: 3,
            },
            MasterOutputType::U16,
        );
        assert!(r2.is_err(), "sigma-clip kappa<=0 must fail");
    }

    // avg_matched_pairs / avg_alignment_residual divisor
    //
    // The per-aligned-frame averages divide by the count of *non-reference*
    // frames, not the full stacked_frame_count. The reference frame contributes
    // 0 to both metrics by construction, so a divisor that includes it scales
    // the averages by (N-1)/N.

    /// Update stats using the same arithmetic the accumulator path uses, so
    /// the test exercises the divisor formula without spinning up a full
    /// LiveStacker (which requires successful star detection on each frame).
    fn step_stats(stats: &mut StackingStats, matches_len: usize, residual: f64) {
        stats.stacked_frame_count += 1;
        let aligned_count = stats.stacked_frame_count.saturating_sub(1).max(1) as f64;
        stats.avg_matched_pairs = stats.avg_matched_pairs * ((aligned_count - 1.0) / aligned_count)
            + matches_len as f64 / aligned_count;
        stats.avg_alignment_residual = stats.avg_alignment_residual
            * ((aligned_count - 1.0) / aligned_count)
            + residual / aligned_count;
    }

    #[test]
    fn avg_metrics_exclude_reference_frame_contribution() {
        // Simulate 5 stacked frames: 1 reference (no metrics), 4 aligned each
        // with matched_pairs=10 and residual=0.5. The average must be exactly
        // 10.0 and 0.5; counting the reference in the divisor dilutes it to 8.0
        // and 0.4.
        // reference frame initialised but not measured
        let mut stats = StackingStats {
            stacked_frame_count: 1,
            ..Default::default()
        };

        for _ in 0..4 {
            step_stats(&mut stats, 10, 0.5);
        }

        assert_eq!(stats.stacked_frame_count, 5);
        assert!(
            (stats.avg_matched_pairs - 10.0).abs() < 1e-9,
            "avg_matched_pairs should be 10.0 (not diluted by reference), got {}",
            stats.avg_matched_pairs
        );
        assert!(
            (stats.avg_alignment_residual - 0.5).abs() < 1e-9,
            "avg_alignment_residual should be 0.5 (not diluted by reference), got {}",
            stats.avg_alignment_residual
        );
    }

    #[test]
    fn divisor_including_the_reference_would_yield_8_and_0_4() {
        // Re-derive the rejected formula on the same inputs: a divisor of
        // `stacked_frame_count` (which includes the reference) multiplies the
        // average by (N-1)/N. For 5 frames that is 4/5 = 0.8, so 10 * 0.8 = 8.0
        // and 0.5 * 0.8 = 0.4.
        let mut buggy_count: u32 = 1;
        let mut buggy_avg_matches = 0.0_f64;
        let mut buggy_avg_residual = 0.0_f64;
        for _ in 0..4 {
            buggy_count += 1;
            let n = buggy_count as f64;
            buggy_avg_matches = buggy_avg_matches * ((n - 1.0) / n) + 10.0 / n;
            buggy_avg_residual = buggy_avg_residual * ((n - 1.0) / n) + 0.5 / n;
        }
        assert!((buggy_avg_matches - 8.0).abs() < 1e-9);
        assert!((buggy_avg_residual - 0.4).abs() < 1e-9);
    }

    #[test]
    fn first_aligned_frame_yields_exact_metrics() {
        // After exactly one aligned frame (so stacked_frame_count=2), the
        // average must equal that frame's metrics — not half of them.
        let mut stats = StackingStats {
            stacked_frame_count: 1,
            ..Default::default()
        };
        step_stats(&mut stats, 17, 0.83);
        assert_eq!(stats.stacked_frame_count, 2);
        assert!(
            (stats.avg_matched_pairs - 17.0).abs() < 1e-9,
            "single aligned frame must report its own match count, got {}",
            stats.avg_matched_pairs
        );
        assert!(
            (stats.avg_alignment_residual - 0.83).abs() < 1e-9,
            "single aligned frame must report its own residual, got {}",
            stats.avg_alignment_residual
        );
    }

    // OSC / colour stacking

    /// Translate a star field by a (whole-pixel) offset so the mono and RGB
    /// "second frame" share an identical geometric shift.
    fn shift_field(field: &[(f64, f64, f64)], dx: f64, dy: f64) -> Vec<(f64, f64, f64)> {
        field.iter().map(|&(x, y, b)| (x + dx, y + dy, b)).collect()
    }

    /// A geometrically-inconsistent fit must be rejected on
    /// its RMS residual rather than silently folded into the stack.
    #[test]
    fn add_frame_rejects_high_alignment_residual() {
        let field = osc_test_field();
        let reference = make_test_image(512, 512, &field);
        // Inconsistent per-star shifts: no single affine transform fits them
        // all, so the least-squares fit carries a multi-pixel residual while the
        // stars still match their reference counterparts (shifts « match radius).
        let inconsistent: Vec<(f64, f64, f64)> = field
            .iter()
            .enumerate()
            .map(|(i, &(x, y, b))| {
                if i % 2 == 0 {
                    (x + 3.0, y + 2.0, b)
                } else {
                    (x + 9.0, y + 8.0, b)
                }
            })
            .collect();
        let frame = make_test_image(512, 512, &inconsistent);

        // Gate disabled -> the poor fit is still accepted (historic behaviour).
        let mut permissive = LiveStacker::new(
            &reference,
            LiveStackConfig {
                max_alignment_residual_px: f64::INFINITY,
                ..osc_test_config()
            },
        )
        .expect("reference accepted");
        assert!(
            permissive.add_frame(&frame).is_ok(),
            "with the gate disabled the frame should still stack"
        );

        // Tight gate -> the same frame is rejected and not counted.
        let mut strict = LiveStacker::new(
            &reference,
            LiveStackConfig {
                max_alignment_residual_px: 0.5,
                ..osc_test_config()
            },
        )
        .expect("reference accepted");
        let err = strict
            .add_frame(&frame)
            .expect_err("high-residual frame must be rejected");
        assert!(err.contains("residual"), "unexpected error: {err}");
        assert_eq!(
            strict.frame_count(),
            1,
            "a rejected frame must not be counted into the stack"
        );
        assert_eq!(
            strict.provenance().stacked_frames(),
            1,
            "a rejected frame must not be counted into the master's provenance"
        );
    }

    /// The master's integration counts the frames whose pixels are in it — the
    /// reference included, a rejected frame excluded.
    #[test]
    fn provenance_sums_the_exposures_of_the_frames_actually_stacked() {
        let field = osc_test_field();
        let reference = make_test_image(512, 512, &field);
        let shifted = make_test_image(512, 512, &shift_field(&field, 3.0, 2.0));
        let starless = make_test_image(512, 512, &[]);

        let mut stacker = LiveStacker::new_with_provenance(
            &reference,
            osc_test_config(),
            &FrameProvenance {
                exposure_secs: Some(90.0),
                date_obs: Some("2026-08-14T03:22:30".to_string()),
            },
        )
        .expect("reference accepted");

        stacker
            .add_frame_with_provenance(
                &shifted,
                &FrameProvenance {
                    exposure_secs: Some(90.0),
                    date_obs: Some("2026-08-14T03:21:00".to_string()),
                },
            )
            .expect("shifted frame stacked");
        stacker
            .add_frame_with_provenance(
                &starless,
                &FrameProvenance {
                    exposure_secs: Some(90.0),
                    date_obs: Some("2026-08-14T03:19:30".to_string()),
                },
            )
            .expect_err("a starless frame cannot align");

        assert_eq!(stacker.provenance().stacked_frames(), 2);
        assert_eq!(stacker.provenance().total_integration_secs(), 180.0);
        let header = stacker.provenance().to_fits_header();
        assert_eq!(
            header.get_string("DATE-OBS"),
            Some("2026-08-14T03:21:00.000"),
            "DATE-OBS must come from the earliest STACKED frame, not the rejected one"
        );
    }

    /// The mono two-frame stack is pinned byte-for-byte.
    ///
    /// We build a reference + a frame shifted by a known integer offset, stack
    /// them, and assert the result matches a captured golden vector taken at a
    /// fixed set of probe pixels. Any drift in alignment, accumulation, or the
    /// `detection_plane` borrow-through trips this. The golden values are the
    /// engine's own output recorded once and frozen here.
    #[test]
    fn mono_stacking_unchanged_regression() {
        let field = osc_test_field();
        let reference = make_test_image(512, 512, &field);
        // Integer shift keeps bilinear resampling exact at the probe pixels.
        let shifted = make_test_image(512, 512, &shift_field(&field, 3.0, 2.0));

        let mut stacker =
            LiveStacker::new(&reference, osc_test_config()).expect("mono reference accepted");
        let result = stacker.add_frame(&shifted).expect("mono frame stacked");

        assert_eq!(result.channels, 1, "mono stack must stay single-channel");
        assert_eq!(result.pixel_type, PixelType::U16);
        assert_eq!(stacker.frame_count(), 2);

        let px = result.as_u16().expect("u16 result");
        // Probe pixels: the centres of the first three stars (in reference
        // coords) plus a background sample. These are the captured golden
        // values for the 3,2-shift two-frame mean stack.
        // Captured golden vector for the integer-(3,2)-shift two-frame mean
        // stack. The shifted frame is registered back onto the reference, so
        // both frames contribute the star peak at the reference centroids;
        // the background sample at (10,10) is the two-frame mean of the
        // deterministic-noise background.
        let probes: [(usize, usize, u16); 4] = [
            (100, 100, 40999),
            (200, 150, 36006),
            (300, 200, 39012),
            (10, 10, 1009),
        ];
        for (x, y, expected) in probes {
            let got = px[y * 512 + x];
            assert_eq!(
                got, expected,
                "mono golden mismatch at ({x},{y}): expected {expected}, got {got}"
            );
        }
    }

    /// (2) Parity: an RGB field shifted by a known sub-pixel offset must solve
    /// to the *same* affine transform (within 0.05 px) as the equivalent mono
    /// luminance field shifted identically.
    ///
    /// Because `make_test_image_rgb` with unit gains has a luminance proxy
    /// equal to the mono field, both pipelines feed `detect_stars` the same
    /// pixels — so the recovered transform must agree to floating-point noise.
    #[test]
    fn color_registration_parity() {
        let field = osc_test_field();
        let dx = 4.3;
        let dy = -2.7;
        let shifted_field = shift_field(&field, dx, dy);

        let config = osc_test_config();

        // Mono pipeline transform
        let mono_ref = make_test_image(512, 512, &field);
        let mono_frame = make_test_image(512, 512, &shifted_field);
        let mono_ref_stars = detect_stars(&mono_ref, &config.star_detection);
        let mono_frame_stars = detect_stars(&mono_frame, &config.star_detection);
        let mono_matches = match_stars(
            &mono_ref_stars,
            &mono_frame_stars,
            config.max_match_stars,
            config.match_radius_px,
            config.match_flux_tolerance,
        );
        assert!(
            mono_matches.len() >= config.min_matched_pairs,
            "mono field should match enough stars, got {}",
            mono_matches.len()
        );
        let mono_tf = compute_affine_transform(&mono_matches, (0.0, 0.0));

        // Color pipeline transform (via luminance proxy)
        let gains = ChannelGains {
            r: 1.0,
            g: 1.0,
            b: 1.0,
        };
        let rgb_ref = make_test_image_rgb(512, 512, &field, gains);
        let rgb_frame = make_test_image_rgb(512, 512, &shifted_field, gains);
        let rgb_ref_plane = detection_plane(&rgb_ref);
        let rgb_frame_plane = detection_plane(&rgb_frame);
        assert_eq!(rgb_ref_plane.channels, 1, "proxy must be single-channel");
        let rgb_ref_stars = detect_stars(&rgb_ref_plane, &config.star_detection);
        let rgb_frame_stars = detect_stars(&rgb_frame_plane, &config.star_detection);
        let rgb_matches = match_stars(
            &rgb_ref_stars,
            &rgb_frame_stars,
            config.max_match_stars,
            config.match_radius_px,
            config.match_flux_tolerance,
        );
        assert!(
            rgb_matches.len() >= config.min_matched_pairs,
            "rgb proxy field should match enough stars, got {}",
            rgb_matches.len()
        );
        let rgb_tf = compute_affine_transform(&rgb_matches, (0.0, 0.0));

        // Transforms must agree to well under 0.05 px in translation and be
        // rotation-free in both cases.
        assert!(
            (mono_tf.tx - rgb_tf.tx).abs() < 0.05,
            "tx parity: mono {} vs rgb {}",
            mono_tf.tx,
            rgb_tf.tx
        );
        assert!(
            (mono_tf.ty - rgb_tf.ty).abs() < 0.05,
            "ty parity: mono {} vs rgb {}",
            mono_tf.ty,
            rgb_tf.ty
        );
        // Sanity: the recovered shift inverts the applied star shift. The test
        // field renders star peaks at integer-rounded centres
        // (`make_test_image` uses `sx as i32`), so the geometric offset both
        // pipelines actually see is the rounded shift; the centroid solve then
        // recovers it to sub-pixel precision. We therefore compare against the
        // rounded offset. The load-bearing assertion is the <0.05px mono/RGB
        // parity above — this only confirms we measured a real, non-trivial
        // displacement.
        let expected_tx = -dx.round();
        let expected_ty = -dy.round();
        assert!(
            (rgb_tf.tx - expected_tx).abs() < 0.1 && (rgb_tf.ty - expected_ty).abs() < 0.1,
            "recovered transform should invert the applied (rounded) shift: tx={} ty={}",
            rgb_tf.tx,
            rgb_tf.ty
        );
    }

    /// (3) Per-channel rejection isolation: inject a sigma-clip outlier into
    /// the R channel of one accumulated sample only. The R accumulator's count
    /// must drop by one (the outlier rejected) while G and B keep every
    /// sample. This directly exercises the interleaved-slot independence
    /// documented on `accumulate_pixels`.
    #[test]
    fn per_channel_rejection_isolation() {
        // Two pixels, three channels, interleaved: [R G B | R G B].
        let width = 2u32;
        let height = 1u32;
        let channels = 3usize;
        let slots = (width as usize) * (height as usize) * channels;

        // Seed accumulators with a tight cluster so the sigma threshold is
        // small and a single outlier is clearly rejected. count >= 3 is
        // required before sigma clipping engages.
        let mut stacker = LiveStacker {
            width,
            height,
            channels: channels as u32,
            reference_stars: Vec::new(),
            accumulators: vec![PixelAccumulator::default(); slots],
            config: LiveStackConfig {
                sigma_clip_enabled: true,
                sigma_clip_threshold: 2.5,
                ..LiveStackConfig::default()
            },
            stats: StackingStats::default(),
            provenance: StackProvenance::default(),
            ref_centroid: (0.0, 0.0),
        };

        // Three clean frames (counts → 3 per slot) of value 1000 with tiny
        // jitter so std_dev is small but non-zero.
        let clean: [[f64; 6]; 3] = [
            [1000.0, 1000.0, 1000.0, 1000.0, 1000.0, 1000.0],
            [1002.0, 1002.0, 1002.0, 1002.0, 1002.0, 1002.0],
            [998.0, 998.0, 998.0, 998.0, 998.0, 998.0],
        ];
        for frame in &clean {
            let rejected = stacker.accumulate_pixels(frame);
            assert_eq!(rejected, 0, "clean frames should not be rejected");
        }
        for acc in &stacker.accumulators {
            assert_eq!(acc.count, 3, "all slots should have 3 clean samples");
        }

        // Fourth frame: a large outlier in the R slot of pixel 0 only
        // (index 0). Everything else is in-family.
        let mut outlier = [1000.0; 6];
        outlier[0] = 60000.0; // pixel 0, R channel
        let rejected = stacker.accumulate_pixels(&outlier);
        assert_eq!(
            rejected, 1,
            "exactly one pixel (R of px0) should be rejected"
        );

        // R slot of pixel 0 (index 0) stayed at count 3 (outlier clipped);
        // every other slot advanced to count 4.
        assert_eq!(
            stacker.accumulators[0].count, 3,
            "R channel of px0 must reject the outlier (count stays 3)"
        );
        assert_eq!(
            stacker.accumulators[1].count, 4,
            "G channel of px0 must be untouched (count 4)"
        );
        assert_eq!(
            stacker.accumulators[2].count, 4,
            "B channel of px0 must be untouched (count 4)"
        );
        // The other pixel's channels are all clean too.
        for slot in 3..slots {
            assert_eq!(
                stacker.accumulators[slot].count, 4,
                "slot {slot} must accept all four samples"
            );
        }
    }

    /// (4) Luminance proxy weights: a single known RGB pixel must collapse to
    /// exactly `round(0.299 R + 0.587 G + 0.114 B)`.
    #[test]
    fn luminance_proxy_weights() {
        // One pixel, RGB = (10000, 20000, 30000).
        let rgb = ImageData::from_u16(1, 1, 3, &[10000, 20000, 30000]);
        let proxy = luminance_proxy(&rgb);

        assert_eq!(proxy.channels, 1);
        assert_eq!(proxy.width, 1);
        assert_eq!(proxy.height, 1);

        let px = proxy.as_u16().expect("proxy is u16");
        assert_eq!(px.len(), 1);

        let expected = (0.299 * 10000.0 + 0.587 * 20000.0 + 0.114 * 30000.0_f64).round() as u16;
        // 2990 + 11740 + 3420 = 18150
        assert_eq!(expected, 18150, "hand-computed luma weight");
        assert_eq!(
            px[0], expected,
            "luminance proxy must apply exact Rec.601 weights"
        );

        // A second pixel to confirm per-pixel independence and rounding.
        let rgb2 = ImageData::from_u16(2, 1, 3, &[255, 255, 255, 0, 100, 0]);
        let proxy2 = luminance_proxy(&rgb2);
        let px2 = proxy2.as_u16().unwrap();
        assert_eq!(
            px2[0], 255,
            "equal RGB collapses to that value (weights sum to 1)"
        );
        let expected2 = (0.587 * 100.0_f64).round() as u16; // 59
        assert_eq!(px2[1], expected2, "pure-green pixel uses the green weight");
    }

    /// `debayer_cfa_to_rgb` must fail loud on the wrong channel count and the
    /// wrong pixel type, and must produce a 3-channel U16 image of the same
    /// dimensions on the happy path.
    #[test]
    fn debayer_cfa_to_rgb_validates_and_expands() {
        // Wrong channel count.
        let rgb_in = ImageData::from_u16(2, 2, 3, &[0u16; 12]);
        assert!(
            debayer_cfa_to_rgb(&rgb_in, BayerPattern::RGGB, DebayerAlgorithm::Bilinear).is_err()
        );

        // Wrong pixel type.
        let f32_in = ImageData::from_f32(2, 2, 1, &[0.0f32; 4]);
        assert!(
            debayer_cfa_to_rgb(&f32_in, BayerPattern::RGGB, DebayerAlgorithm::Bilinear).is_err()
        );

        // Happy path: a 4x4 CFA expands to 4x4x3 under full-resolution Bilinear.
        let cfa = ImageData::from_u16(4, 4, 1, &[1234u16; 16]);
        let rgb = debayer_cfa_to_rgb(&cfa, BayerPattern::RGGB, DebayerAlgorithm::Bilinear)
            .expect("valid CFA debayers");
        assert_eq!(rgb.channels, 3);
        assert_eq!(rgb.width, 4);
        assert_eq!(rgb.height, 4);
        assert_eq!(rgb.pixel_type, PixelType::U16);
        assert_eq!(rgb.as_u16().unwrap().len(), 4 * 4 * 3);

        // SuperPixel halves resolution (2x2 binning): the result must declare
        // the HALVED geometry and back it with a matching buffer. The output
        // dimensions are derived from the demosaiced RgbImage, not assumed from
        // the input CFA size — otherwise the declared (4x4x3) image would be
        // backed by only (2x2x3) samples and panic/corrupt downstream.
        let sp = debayer_cfa_to_rgb(&cfa, BayerPattern::RGGB, DebayerAlgorithm::SuperPixel)
            .expect("valid CFA superpixel-debayers");
        assert_eq!(sp.channels, 3);
        assert_eq!(sp.width, 2, "superpixel halves width");
        assert_eq!(sp.height, 2, "superpixel halves height");
        assert_eq!(
            sp.as_u16().unwrap().len(),
            2 * 2 * 3,
            "buffer length matches the halved, declared dimensions"
        );
    }

    /// An OSC end-to-end stack: a 3-channel reference + a shifted 3-channel
    /// frame must register and produce a 3-channel result, with each channel
    /// independently accumulated. This is the integration counterpart to the
    /// transform-parity test.
    #[test]
    fn color_two_frame_stack_produces_rgb_result() {
        let field = osc_test_field();
        // Distinct per-channel gains so a channel mix-up would be visible.
        let gains = ChannelGains {
            r: 0.8,
            g: 1.0,
            b: 0.6,
        };
        let reference = make_test_image_rgb(512, 512, &field, gains);
        let shifted = make_test_image_rgb(512, 512, &shift_field(&field, 3.0, 2.0), gains);

        let mut stacker =
            LiveStacker::new(&reference, osc_test_config()).expect("rgb reference accepted");
        let result = stacker.add_frame(&shifted).expect("rgb frame stacked");

        assert_eq!(result.channels, 3, "color stack must stay 3-channel");
        assert_eq!(result.pixel_type, PixelType::U16);
        assert_eq!(stacker.frame_count(), 2);

        // At a star centre, R should be brighter than B given the gains
        // (0.8 vs 0.6), confirming channels were not transposed.
        let px = result.as_u16().expect("u16 rgb result");
        let base = (100 * 512 + 100) * 3;
        let r = px[base];
        let b = px[base + 2];
        assert!(
            r > b,
            "R ({r}) should exceed B ({b}) under gains r=0.8 b=0.6 — channels preserved"
        );
    }

    /// A synthetic matched pair with a nominal flux, for transform-fit tests.
    fn pair(rx: f64, ry: f64, fx: f64, fy: f64) -> StarMatch {
        let mk = |x: f64, y: f64| DetectedStar {
            x,
            y,
            flux: 1000.0,
            hfr: 2.0,
            fwhm: 3.0,
            peak: 5000.0,
            background: 1000.0,
            snr: 50.0,
            eccentricity: 0.0,
            sharpness: 0.2,
        };
        StarMatch {
            ref_star: mk(rx, ry),
            frame_star: mk(fx, fy),
            distance: ((rx - fx).powi(2) + (ry - fy).powi(2)).sqrt(),
        }
    }

    /// Two views of the same star field differing by a rigid translation,
    /// where the 50px match radius lets the greedy matcher pair a few stars
    /// with the wrong neighbour.
    ///
    /// A plain least-squares fit over every pair is dragged far enough by those
    /// few to report a residual metres away from the truth — that is how a pure
    /// 2.2px translation of a 40-star field measures 10.34px and is refused by
    /// a 10.00px ceiling. Fitting with outlier rejection must recover the true
    /// sub-pixel transform.
    #[test]
    fn mis_paired_stars_do_not_wreck_the_transform_fit() {
        // 24 correct pairs on a rigid (dx = -1, dy = +2) translation ...
        let (dx, dy) = (-1.0, 2.0);
        let mut matches: Vec<StarMatch> = Vec::new();
        for i in 0..24 {
            let rx = 40.0 + (i % 6) as f64 * 80.0;
            let ry = 40.0 + (i / 6) as f64 * 110.0;
            matches.push(pair(rx, ry, rx - dx, ry - dy));
        }
        // ... plus 4 pairs the matcher got wrong: the frame star is a genuine
        // star, but a DIFFERENT one, tens of pixels away yet inside the 50px
        // radius.
        matches.push(pair(120.0, 150.0, 158.0, 186.0));
        matches.push(pair(280.0, 260.0, 245.0, 302.0));
        matches.push(pair(360.0, 370.0, 402.0, 331.0));
        matches.push(pair(200.0, 480.0, 165.0, 442.0));

        let centroid = (256.0, 256.0);

        // The naive fit is what shipped: it reports a residual far past a
        // meaningful ceiling for a field that is a rigid translation.
        let naive = compute_affine_transform(&matches, centroid);
        let naive_residual = compute_alignment_residual(&matches, &naive);
        assert!(
            naive_residual > 5.0,
            "the unclipped fit should be badly wrong here (got {naive_residual:.2}px) — \
             otherwise this test is not exercising the defect"
        );

        // The robust fit recovers the true translation and a sub-pixel residual
        // over the pairs that agree.
        let (transform, residual, inliers) = fit_transform_robust(&matches, centroid, 5);
        assert!(
            residual < 0.5,
            "robust fit residual should be sub-pixel, got {residual:.3}px"
        );
        assert_eq!(inliers, 24, "exactly the 24 correct pairs should survive");
        assert!(
            (transform.tx - dx).abs() < 0.1 && (transform.ty - dy).abs() < 0.1,
            "recovered translation ({:.3}, {:.3}) should match the true ({dx}, {dy})",
            transform.tx,
            transform.ty
        );
    }

    /// Clean data must not be clipped down to a hand-picked subset: a field
    /// whose pairs already agree keeps every pair.
    #[test]
    fn a_clean_match_set_keeps_every_pair() {
        let mut matches: Vec<StarMatch> = Vec::new();
        for i in 0..20 {
            let rx = 50.0 + (i % 5) as f64 * 90.0;
            let ry = 50.0 + (i / 5) as f64 * 110.0;
            // Sub-pixel centroid jitter, the realistic case.
            let jitter = ((i % 3) as f64 - 1.0) * 0.15;
            matches.push(pair(rx, ry, rx + 3.0 + jitter, ry - 4.0 - jitter));
        }
        let (transform, residual, inliers) = fit_transform_robust(&matches, (256.0, 256.0), 5);
        assert_eq!(inliers, 20, "no pair should be clipped from a clean set");
        assert!(residual < 0.5, "clean residual {residual:.3}px");
        assert!((transform.tx + 3.0).abs() < 0.3 && (transform.ty - 4.0).abs() < 0.3);
    }

    /// End-to-end through `add_frame`: a frame that is a small rigid shift of
    /// the reference must register even when the greedy matcher produces a
    /// handful of wrong pairs.
    ///
    /// The mis-pairing mechanism is the real one. `match_stars` walks the
    /// reference stars brightest-first and *consumes* the frame star it picks.
    /// A bright reference star the frame detector missed therefore steals a
    /// neighbour inside the 50px radius, that neighbour's true owner is denied
    /// and steals another, and the cascade seeds several ~45px pairs. Fitting
    /// over all of them puts the residual far past any meaningful ceiling — the
    /// reported 10.34px on a 2.2px translation. The fit has to survive that.
    #[test]
    fn add_frame_survives_a_matcher_cascade_from_missing_stars() {
        // 8x8 grid at 45px pitch: mean separation is inside the 50px match
        // radius, which is what lets an orphaned reference star steal.
        let mut reference_field: Vec<(f64, f64, f64)> = Vec::new();
        for row in 0..8 {
            for col in 0..8 {
                let x = 50.0 + col as f64 * 45.0;
                let y = 50.0 + row as f64 * 45.0;
                // The three corner stars are the brightest, so the matcher
                // processes them first.
                let bright = (row, col) == (0, 0) || (row, col) == (0, 7) || (row, col) == (7, 0);
                reference_field.push((x, y, if bright { 45000.0 } else { 22000.0 }));
            }
        }
        // The frame is the same field shifted by a rigid (+2, +1) — with the
        // three brightest stars absent, as a thin cloud or a detection-
        // threshold flicker would leave them.
        let frame_field: Vec<(f64, f64, f64)> = reference_field
            .iter()
            .filter(|(_, _, flux)| *flux < 40000.0)
            .map(|(x, y, flux)| (x + 2.0, y + 1.0, *flux))
            .collect();

        let config = LiveStackConfig {
            min_matched_pairs: 5,
            star_detection: StarDetectionConfig {
                detection_sigma: 3.0,
                min_snr: 3.0,
                min_hfr: 0.5,
                max_sharpness: 1.0,
                ..StarDetectionConfig::default()
            },
            ..LiveStackConfig::default()
        };

        let reference = make_test_image(512, 512, &reference_field);
        let frame = make_test_image(512, 512, &frame_field);

        let mut stacker =
            LiveStacker::new(&reference, config).expect("reference field is detectable");
        let outcome = stacker.add_frame(&frame);
        assert!(
            outcome.is_ok(),
            "a rigid 2px shift must register despite mis-paired stars, got {:?}",
            outcome.err()
        );
        assert_eq!(stacker.frame_count(), 2);
        assert_eq!(
            stacker.get_stats().rejected_alignment_failures,
            0,
            "the frame must not be counted as an alignment rejection"
        );
    }

    /// A bare detected star at a position and flux, for matcher tests.
    fn star(x: f64, y: f64, flux: f64) -> DetectedStar {
        DetectedStar {
            x,
            y,
            flux,
            hfr: 2.0,
            fwhm: 3.0,
            peak: flux / 10.0,
            background: 1000.0,
            snr: 50.0,
            eccentricity: 0.0,
            sharpness: 0.2,
        }
    }

    /// The matcher must not let a reference star with no counterpart in the
    /// frame take a frame star that plainly belongs to someone else.
    ///
    /// This is the seed of the steal chain. `A` is the brightest reference
    /// star and the frame detector missed it; the nearest frame star inside the
    /// 50px radius is `B'`, 47px away — but `B'` is 2.2px from its own owner
    /// `B`. Consuming `B'` for `A` would then push `B` onto `C'`, and the whole
    /// row would end up displaced by one star spacing in the same direction.
    /// Coherent errors like that are the ones a least-squares fit cannot shrug
    /// off, so the matcher has to refuse the first steal.
    #[test]
    fn match_stars_refuses_to_let_an_orphan_steal_a_claimed_star() {
        let ref_stars = vec![
            star(60.0, 60.0, 40000.0),  // A — absent from the frame
            star(105.0, 60.0, 30000.0), // B
            star(150.0, 60.0, 20000.0), // C
        ];
        let frame_stars = vec![
            star(107.0, 61.0, 30000.0), // B'
            star(152.0, 61.0, 20000.0), // C'
        ];

        let matches = match_stars(&ref_stars, &frame_stars, 100, 50.0, 0.7);

        assert_eq!(
            matches.len(),
            2,
            "both frame stars should pair, and only with their own owners"
        );
        for m in &matches {
            assert!(
                m.distance < 3.0,
                "pair ({}, {}) -> ({}, {}) is {:.2}px apart — a steal, not a match",
                m.ref_star.x,
                m.ref_star.y,
                m.frame_star.x,
                m.frame_star.y,
                m.distance
            );
        }
        assert!(
            !matches.iter().any(|m| m.ref_star.x == 60.0),
            "the orphaned reference star must go unmatched rather than take a neighbour"
        );
    }

    /// Wrong pairs that are all displaced the SAME way defeat median clipping,
    /// and only a consensus search recovers from them.
    ///
    /// Clipping compares each pair against the current fit and drops whatever
    /// sits past 3x the median deviation. That works when the wrong pairs point
    /// in scattered directions, because they stay a minority of the deviation
    /// distribution. A steal chain does not scatter: every stolen pair is off by
    /// one star spacing in one direction, so the fit is dragged bodily towards
    /// them until the honest pairs are just as far from it as the stolen ones,
    /// the 3x-median cutoff covers the whole set, and the loop exits having
    /// clipped nothing at all.
    #[test]
    fn a_coherent_steal_chain_is_broken_by_consensus_not_clipping() {
        let (dx, dy) = (-1.0, 2.0);
        let mut matches: Vec<StarMatch> = Vec::new();
        // 20 honest pairs on a rigid (dx = -1, dy = +2) translation ...
        for i in 0..20 {
            let rx = 40.0 + (i % 5) as f64 * 90.0;
            let ry = 40.0 + (i / 5) as f64 * 110.0;
            matches.push(pair(rx, ry, rx - dx, ry - dy));
        }
        // ... and 8 stolen ones, each taking the neighbour 45px to its right.
        for i in 0..8 {
            let rx = 60.0 + (i % 4) as f64 * 100.0;
            let ry = 300.0 + (i / 4) as f64 * 100.0;
            matches.push(pair(rx, ry, rx + 45.0, ry));
        }
        let centroid = (256.0, 256.0);

        // Median clipping on its own is inert here: the cutoff never falls
        // below the worst pair, so the very first pass keeps everything and
        // stops. Confirm that directly, so this test keeps its meaning if the
        // clipping constants are ever retuned.
        let naive = compute_affine_transform(&matches, centroid);
        let deviations: Vec<f64> = matches
            .iter()
            .map(|m| {
                let (tx, ty) = naive.apply(m.frame_star.x, m.frame_star.y);
                ((tx - m.ref_star.x).powi(2) + (ty - m.ref_star.y).powi(2)).sqrt()
            })
            .collect();
        let mut sorted = deviations.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let median = sorted[sorted.len() / 2];
        let worst = sorted[sorted.len() - 1];
        assert!(
            (CLIP_SIGMA * median).max(CLIP_FLOOR_PX) > worst,
            "clipping should be unable to remove anything here (cutoff {:.2} vs worst {worst:.2})",
            (CLIP_SIGMA * median).max(CLIP_FLOOR_PX)
        );

        let (transform, residual, inliers) = fit_transform_robust(&matches, centroid, 5);
        assert_eq!(inliers, 20, "exactly the 20 honest pairs should survive");
        assert!(
            residual < 0.5,
            "residual should be sub-pixel once the stolen bloc is dropped, got {residual:.3}px"
        );
        assert!(
            (transform.tx - dx).abs() < 0.1 && (transform.ty - dy).abs() < 0.1,
            "recovered translation ({:.3}, {:.3}) should match the true ({dx}, {dy})",
            transform.tx,
            transform.ty
        );
    }

    /// End-to-end through `add_frame`: a rigid 2px shift of a field dense enough
    /// for neighbours to be inside the match radius must register, even when
    /// several of the brightest reference stars are missing from the frame.
    ///
    /// Rows are spaced wider than the 50px match radius and columns closer than
    /// it, so any mis-pairing has to run along a row — a chain, not a scatter.
    /// Four rows are missing their leading star, which under a consuming
    /// brightest-first matcher seeds four chains and leaves under 60% of the
    /// pairs honest. That is deliberately past the point where picking the
    /// larger agreeing bloc is safe (a genuinely distorted frame looks the same
    /// from there and must still be refused), so nothing downstream can rescue
    /// this: the matcher itself has to not create the chain.
    #[test]
    fn add_frame_registers_a_dense_field_a_consuming_matcher_would_chain() {
        const COLS: usize = 8;
        const ROWS: usize = 8;
        const CHAINED_ROWS: usize = 4;

        let mut reference_field: Vec<(f64, f64, f64)> = Vec::new();
        for row in 0..ROWS {
            for col in 0..COLS {
                // Columns at 45px (inside the 50px radius), rows at 60px
                // (outside it), so a steal can only run along a row.
                let x = 60.0 + col as f64 * 45.0;
                let y = 60.0 + row as f64 * 60.0;
                // Brightness falls left to right so a brightest-first matcher
                // walks each row from its leading star outwards.
                reference_field.push((x, y, 40000.0 - col as f64 * 2000.0));
            }
        }

        // The frame is the same field shifted by a rigid (+2, +1), with the
        // leading star of the first four rows absent — a thin cloud or a
        // detection-threshold flicker leaves exactly this.
        let frame_field: Vec<(f64, f64, f64)> = reference_field
            .iter()
            .enumerate()
            .filter(|(i, _)| !(i % COLS == 0 && i / COLS < CHAINED_ROWS))
            .map(|(_, &(x, y, flux))| (x + 2.0, y + 1.0, flux))
            .collect();

        let config = LiveStackConfig {
            min_matched_pairs: 5,
            star_detection: StarDetectionConfig {
                detection_sigma: 3.0,
                min_snr: 3.0,
                min_hfr: 0.5,
                max_sharpness: 1.0,
                ..StarDetectionConfig::default()
            },
            ..LiveStackConfig::default()
        };

        let reference = make_test_image(512, 512, &reference_field);
        let frame = make_test_image(512, 512, &frame_field);

        let mut stacker =
            LiveStacker::new(&reference, config).expect("reference field is detectable");
        let outcome = stacker.add_frame(&frame);
        assert!(
            outcome.is_ok(),
            "a rigid 2px shift of a dense field must register, got {:?}",
            outcome.err()
        );
        assert_eq!(stacker.frame_count(), 2);
        assert_eq!(
            stacker.get_stats().rejected_alignment_failures,
            0,
            "the frame must not be counted as an alignment rejection"
        );
    }
}
