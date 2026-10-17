//! Image statistics and star detection
//!
//! ## `as`-cast policy
//!
//! This module's numeric casts are dominated by pixel-arithmetic patterns that
//! are safe by construction:
//! - `u16 as f64`, `u32 as f64`: pixel values / sensor dimensions widening into
//!   the f64 53-bit mantissa. Lossless for any real-world camera.
//! - `usize as f64`: pixel-count math; image pixel counts fit in 53 bits for any
//!   sensor under ~9 PB which is far beyond physical reality.
//! - `i32 as usize` (image coordinates): bounds-checked above the cast, so the
//!   cast is from a non-negative value within image extent.
//! - `f64 as i32` / `f64 as u16`: saturating per Rust 1.45 spec, used for star
//!   coordinates and ADU values that are inherently in-range.
//!
//! Sites with a specific invariant comment override the module-level reasoning.

use crate::ImageData;
use rayon::prelude::*;

/// Statistics for an image
#[derive(Debug, Clone, Default)]
pub struct ImageStats {
    pub min: f64,
    pub max: f64,
    pub mean: f64,
    pub median: f64,
    pub std_dev: f64,
    pub mad: f64, // Median Absolute Deviation
}

/// Calculate statistics for a 16-bit image
pub fn calculate_stats_u16(image: &ImageData) -> ImageStats {
    if image.data.is_empty() {
        return ImageStats::default();
    }

    // Parallel conversion to u16
    let mut pixels: Vec<u16> = image
        .data
        .par_chunks_exact(2)
        .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
        .collect();

    if pixels.is_empty() {
        return ImageStats::default();
    }

    // Parallel calculation of min, max, sum
    let (min, max, sum) = pixels
        .par_iter()
        .fold(
            || (u16::MAX, u16::MIN, 0.0f64),
            |(min, max, sum), &val| (min.min(val), max.max(val), sum + val as f64),
        )
        .reduce(
            || (u16::MAX, u16::MIN, 0.0f64),
            |(min1, max1, sum1), (min2, max2, sum2)| (min1.min(min2), max1.max(max2), sum1 + sum2),
        );

    let count = pixels.len() as f64;
    let mean = sum / count;

    // Parallel variance calculation
    let variance: f64 = pixels
        .par_iter()
        .map(|&p| {
            let diff = p as f64 - mean;
            diff * diff
        })
        .sum::<f64>()
        / count;
    let std_dev = variance.sqrt();

    // Parallel sort for median
    pixels.par_sort_unstable();
    let median = if pixels.len().is_multiple_of(2) {
        let mid = pixels.len() / 2;
        (pixels[mid - 1] as f64 + pixels[mid] as f64) / 2.0
    } else {
        pixels[pixels.len() / 2] as f64
    };

    // Parallel MAD calculation
    let mut deviations: Vec<f64> = pixels
        .par_iter()
        .map(|&p| (p as f64 - median).abs())
        .collect();

    deviations.par_sort_unstable_by(|a, b| a.total_cmp(b));

    let mad = if deviations.len().is_multiple_of(2) {
        let mid = deviations.len() / 2;
        (deviations[mid - 1] + deviations[mid]) / 2.0
    } else {
        deviations[deviations.len() / 2]
    };

    ImageStats {
        min: min as f64,
        max: max as f64,
        mean,
        median,
        std_dev,
        mad,
    }
}

/// Star detection result
#[derive(Debug, Clone)]
pub struct DetectedStar {
    pub x: f64,
    pub y: f64,
    pub flux: f64,
    pub hfr: f64,
    pub fwhm: f64,
    pub peak: f64,
    pub background: f64,
    pub snr: f64,
    /// Eccentricity: 0 = perfect circle, 1 = line (elongated)
    pub eccentricity: f64,
    /// Sharpness: ratio of peak to spread - hot pixels have high sharpness, real stars lower
    /// Typical real stars: 0.1-0.5, hot pixels: > 0.8
    pub sharpness: f64,
}

/// Camera-domain inputs for the standard CCD-equation SNR.
///
/// Why: SNR must be computed in the electron domain using
/// `SNR = signal / sqrt(signal + n_pix * (sky + read_noise² + dark))`. That
/// formula needs the conversion from ADU to electrons (`gain_e_per_adu`),
/// the per-pixel read noise (`read_noise_e`), and the per-pixel dark
/// accumulated over the exposure (`dark_e_per_sec * exposure_s`). When the
/// caller cannot supply this metadata, `StarDetectionConfig::noise_model`
/// is left `None` and we fall back to the ADU-domain CCD-equation
/// approximation (see `compute_snr` for the explicit formula and
/// documented approximation), which is the same equation evaluated against
/// the empirically-measured per-pixel background variance.
#[derive(Debug, Clone, Copy)]
pub struct CameraNoiseModel {
    /// Gain in electrons per ADU (e.g. ZWO ASI2600MM at unity gain ≈ 1.0).
    pub gain_e_per_adu: f64,
    /// Read noise in electrons RMS per pixel.
    pub read_noise_e: f64,
    /// Dark current in electrons per pixel per second.
    pub dark_e_per_sec: f64,
    /// Exposure duration in seconds (used to compute total dark per pixel).
    pub exposure_s: f64,
}

/// Detection-time eccentricity ceiling used by [`StarDetectionConfig::default`].
///
/// This filter's job is to cull sources that are *not stars* — cosmic-ray
/// hits and satellite trails, which are effectively one-dimensional (axis
/// ratio worse than ~1:3, so e > 0.94). It is deliberately NOT the
/// image-grading eccentricity threshold, which operators set around 0.6-0.8.
///
/// Why the two must not be the same number: a wind-trailed star at a 2:1 axis
/// ratio measures e = 0.87 and is still a star. A detector ceiling of 0.7
/// discards exactly those, so a trailed frame comes back with no measurable
/// stars, [`frame_eccentricity`] returns `None`, and the grading gate reads
/// that as "unknown — do not reject": clipping the measurement at the decision
/// threshold makes the decision un-fireable. The detector must measure well
/// past anything a grader would reject. [`SELECTION_MAX_ECCENTRICITY`] is the
/// tight answer, for callers that need one.
pub const DETECTION_MAX_ECCENTRICITY: f64 = 0.95;

/// Working-star eccentricity ceiling: how round a source must be before we
/// will *centroid on it, focus by it, or solve with it*.
///
/// [`DETECTION_MAX_ECCENTRICITY`] answers a different question — "is this
/// source a star at all?" — and must stay permissive so a trailed frame is
/// still measurable. One number cannot answer both: a guide star at e = 0.9 is
/// a smear whose centroid wanders along its major axis, and a trailed star's
/// HFR reads as defocus, so a focuser chases a shape error.
///
/// 0.7 (a ~1.4:1 axis ratio) is what guide-star picking, autofocus HFR and
/// star masking are tuned against. Use [`detect_stars_for_selection`] — or
/// [`detect_stars_with_stats`], which applies this to the stars it returns —
/// to get the tight answer; [`detect_stars`] deliberately returns everything
/// the detector measured so per-frame shape statistics stay honest.
pub const SELECTION_MAX_ECCENTRICITY: f64 = 0.7;

/// Star detection configuration
#[derive(Debug, Clone)]
pub struct StarDetectionConfig {
    /// Detection threshold in sigma above background
    pub detection_sigma: f64,
    /// Minimum star area in pixels
    pub min_area: u32,
    /// Maximum star area in pixels
    pub max_area: u32,
    /// Maximum eccentricity for a source to count as a star at all
    /// (0 = circle, 1 = line). See [`DETECTION_MAX_ECCENTRICITY`] for why this
    /// ceiling must stay well above any image-grading eccentricity threshold.
    ///
    /// This is **not** the "is this star good enough to use" filter — that is
    /// [`SELECTION_MAX_ECCENTRICITY`], applied by
    /// [`detect_stars_for_selection`] and [`detect_stars_with_stats`].
    pub max_eccentricity: f64,
    /// Saturation threshold (0-65535)
    pub saturation_limit: u16,
    /// Search radius for HFR calculation
    pub hfr_radius: u32,
    /// Minimum HFR to be considered a real star (filters hot pixels)
    /// Hot pixels typically have HFR < 1.0, real stars > 1.2
    pub min_hfr: f64,
    /// Minimum SNR to be considered a valid detection
    pub min_snr: f64,
    /// Maximum sharpness (filters hot pixels which have very high sharpness)
    pub max_sharpness: f64,
    /// Camera noise model for the electron-domain CCD-equation SNR.
    ///
    /// When present, SNR is computed in electrons from gain, read noise, dark
    /// current and exposure. When `None`, SNR uses the ADU-domain
    /// approximation against the measured per-pixel background variance —
    /// still the standard CCD equation, just evaluated empirically. Populate
    /// it wherever camera metadata is available so reported SNR is comparable
    /// across cameras.
    pub noise_model: Option<CameraNoiseModel>,
}

impl Default for StarDetectionConfig {
    fn default() -> Self {
        Self {
            detection_sigma: 5.0, // Increased from 3.0 - more conservative
            min_area: 9,          // Increased from 5 - hot pixels rarely exceed this
            max_area: 10000,
            // Culls streaks (cosmic rays, satellites), NOT trailed stars —
            // see DETECTION_MAX_ECCENTRICITY.
            max_eccentricity: DETECTION_MAX_ECCENTRICITY,
            saturation_limit: 60000,
            hfr_radius: 20,
            min_hfr: 1.0,        // Real stars have HFR > ~1.0; hot pixels < 0.8
            min_snr: 5.0,        // Modest SNR threshold - real stars in short subs can be faint
            max_sharpness: 0.95, // Only reject extreme hot pixels (sharpness ~1.0); real stars spread flux
            // Why: callers without camera metadata fall back to the ADU-domain
            // CCD-equation approximation (documented in `compute_snr`). Callers
            // with profile metadata should set this explicitly.
            noise_model: None,
        }
    }
}

/// Detect stars in a 16-bit image.
///
/// This is the **measurement** entry point: it returns every source that
/// survives `config`'s detection filters, including trailed stars up to
/// [`DETECTION_MAX_ECCENTRICITY`]. Per-frame shape statistics
/// ([`frame_eccentricity`]) must be computed from this population, because a
/// population pre-filtered at the grader's own threshold can never report a
/// value above it.
///
/// Callers that need stars to *work with* rather than to *count* — guide-star
/// picking, autofocus HFR, plate-solve centroids, star masking — want
/// [`detect_stars_for_selection`] instead.
pub fn detect_stars(image: &ImageData, config: &StarDetectionConfig) -> Vec<DetectedStar> {
    let width = image.width as usize;
    let height = image.height as usize;

    if width == 0 || height == 0 || image.data.len() < width * height * 2 {
        return Vec::new();
    }

    // Parallel convert to f64 array
    let pixels: Vec<f64> = image
        .data
        .par_chunks_exact(2)
        .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]) as f64)
        .collect();

    // Estimate background using sigma-clipped median (partially parallelized)
    let (background, noise) = estimate_background(&pixels, width, height);

    // Detection threshold
    let threshold = background + config.detection_sigma * noise;

    // Find candidate pixels above threshold
    // Note: Full star detection is hard to parallelize due to 'visited' state
    // We keep the main loop sequential for correctness but use the parallelized setup
    let mut visited = vec![false; pixels.len()];
    let mut stars = Vec::new();

    for y in 2..height - 2 {
        for x in 2..width - 2 {
            let idx = y * width + x;

            if visited[idx] || pixels[idx] < threshold {
                continue;
            }

            // Check if this is a local maximum (8-connected)
            let val = pixels[idx];
            let is_max = val >= pixels[idx - 1]
                && val >= pixels[idx + 1]
                && val >= pixels[idx - width]
                && val >= pixels[idx + width]
                && val >= pixels[idx - width - 1]
                && val >= pixels[idx - width + 1]
                && val >= pixels[idx + width - 1]
                && val >= pixels[idx + width + 1];

            if !is_max {
                continue;
            }

            // Skip saturated stars
            if val > config.saturation_limit as f64 {
                continue;
            }

            // Extract star region and measure
            let mut ctx = StarMeasurementContext {
                pixels: &pixels,
                width,
                height,
                background,
                noise,
                config,
                visited: &mut visited,
            };
            if let Some(star) = measure_star(&mut ctx, x, y) {
                // Comprehensive star validation to filter hot pixels and noise
                // Track rejection reasons for diagnostics (only log first few)
                static LOGGED_REJECTIONS: std::sync::atomic::AtomicU32 =
                    std::sync::atomic::AtomicU32::new(0);
                let should_log = LOGGED_REJECTIONS.load(std::sync::atomic::Ordering::Relaxed) < 5;

                // 1. HFR check - hot pixels have very small HFR
                if star.hfr < config.min_hfr {
                    if should_log {
                        tracing::debug!(
                            "Star rejected: HFR {:.2} < min {:.2} (pos: {:.1},{:.1})",
                            star.hfr,
                            config.min_hfr,
                            star.x,
                            star.y
                        );
                        LOGGED_REJECTIONS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    }
                    continue;
                }

                // 2. SNR check - require good signal-to-noise
                if star.snr < config.min_snr {
                    if should_log {
                        tracing::debug!(
                            "Star rejected: SNR {:.2} < min {:.2} (pos: {:.1},{:.1}, HFR: {:.2})",
                            star.snr,
                            config.min_snr,
                            star.x,
                            star.y,
                            star.hfr
                        );
                        LOGGED_REJECTIONS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    }
                    continue;
                }

                // 3. Eccentricity check - reject elongated objects (cosmic rays, tracking errors)
                if star.eccentricity > config.max_eccentricity {
                    if should_log {
                        tracing::debug!(
                            "Star rejected: eccentricity {:.2} > max {:.2} (pos: {:.1},{:.1})",
                            star.eccentricity,
                            config.max_eccentricity,
                            star.x,
                            star.y
                        );
                        LOGGED_REJECTIONS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    }
                    continue;
                }

                // 4. Sharpness check - hot pixels have very high sharpness
                if star.sharpness > config.max_sharpness {
                    if should_log {
                        tracing::debug!(
                            "Star rejected: sharpness {:.2} > max {:.2} (pos: {:.1},{:.1})",
                            star.sharpness,
                            config.max_sharpness,
                            star.x,
                            star.y
                        );
                        LOGGED_REJECTIONS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    }
                    continue;
                }

                // 5. Area check (approximate from flux distribution)
                let area = star.flux / (star.peak - background).max(1.0);
                if area < config.min_area as f64 || area > config.max_area as f64 {
                    if should_log {
                        tracing::debug!(
                            "Star rejected: area {:.1} outside range [{}, {}] (pos: {:.1},{:.1})",
                            area,
                            config.min_area,
                            config.max_area,
                            star.x,
                            star.y
                        );
                        LOGGED_REJECTIONS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    }
                    continue;
                }

                stars.push(star);
            }
        }
    }

    // Sort by flux (brightest first)
    stars.sort_by(|a, b| b.flux.total_cmp(&a.flux));

    stars
}

/// The eccentricity a star must beat to be *usable* under `config`.
///
/// Takes the tighter of the caller's own ceiling and
/// [`SELECTION_MAX_ECCENTRICITY`], so a config that deliberately asks for
/// rounder-than-usual stars (e.g. the PSF-estimation configs) keeps its
/// choice, while a config left at the permissive detection default gets the
/// working-star answer rather than the "is it a star at all" answer.
///
/// The asymmetry is why [`StarDetectionResult::sources`] exists: a caller
/// asking for something *looser* than the working-star ceiling is measuring
/// the field, not picking guide stars, and this function cannot tell that
/// apart from the crate default (both are 0.95). `stars` therefore keeps the
/// safe answer and `sources` carries the caller's verbatim population.
fn selection_eccentricity_ceiling(config: &StarDetectionConfig) -> f64 {
    config.max_eccentricity.min(SELECTION_MAX_ECCENTRICITY)
}

/// The ceiling the *measurement* pass of [`detect_stars_with_stats`] runs at:
/// the caller's own ceiling widened to at least [`DETECTION_MAX_ECCENTRICITY`].
///
/// Deliberately ignores a caller that asks for something tighter, because a
/// shape statistic computed from a population pre-filtered at the caller's own
/// threshold can never exceed that threshold. `api_detect_stars_in_file` ships
/// a config with `max_eccentricity: 0.7`, so without this widening the FITS
/// star-analysis screen reports every trailed frame as `e <= 0.70` no matter
/// how badly it is smeared.
///
/// Widening is safe because eccentricity is the *only* filter relaxed: area,
/// HFR, SNR and sharpness limits still apply, and a cosmic ray or satellite
/// streak sits above 0.95 and is still culled. What the widening admits is
/// trailed stars, which is exactly what the statistic needs to see.
///
/// The caller's ceiling is still honoured for everything it hands back —
/// [`StarDetectionResult::stars`] is narrowed by
/// [`selection_eccentricity_ceiling`], which reads the *original* config.
fn measurement_eccentricity_ceiling(config: &StarDetectionConfig) -> f64 {
    config.max_eccentricity.max(DETECTION_MAX_ECCENTRICITY)
}

/// Detect stars and keep only the ones round enough to work with.
///
/// Use this wherever a star's *shape* is load-bearing for the operation:
/// guide-star selection (a smear's centroid slides along its major axis),
/// autofocus HFR (a trail reads as defocus), plate-solve centroids, and PSF
/// fitting. See [`SELECTION_MAX_ECCENTRICITY`].
///
/// [`detect_stars`] remains the measurement entry point and is what per-frame
/// eccentricity must be computed from.
pub fn detect_stars_for_selection(
    image: &ImageData,
    config: &StarDetectionConfig,
) -> Vec<DetectedStar> {
    let ceiling = selection_eccentricity_ceiling(config);
    let mut stars = detect_stars(image, config);
    stars.retain(|s| s.eccentricity <= ceiling);
    stars
}

/// Estimate background level and noise using sigma clipping
fn estimate_background(pixels: &[f64], _width: usize, _height: usize) -> (f64, f64) {
    // Sample every 4th pixel for speed
    // Parallelize sampling
    let mut samples: Vec<f64> = pixels.par_iter().step_by(4).copied().collect();

    if samples.is_empty() {
        return (0.0, 1.0);
    }

    // Sigma clipping iterations
    for _ in 0..3 {
        samples.par_sort_unstable_by(|a, b| a.total_cmp(b));
        let median = samples[samples.len() / 2];

        // Parallel MAD calculation
        let mad: f64 =
            samples.par_iter().map(|&v| (v - median).abs()).sum::<f64>() / samples.len() as f64;
        let sigma = mad * 1.4826;

        let lower = median - 3.0 * sigma;
        let upper = median + 3.0 * sigma;

        // Parallel retain is not available directly on Vec, but we can filter and collect
        // However, retain is in-place and might be faster than allocating new vec
        // Keep sequential retain as it iterates an already reduced set.
        samples.retain(|&v| v >= lower && v <= upper);

        if samples.is_empty() {
            return (median, sigma);
        }
    }

    samples.par_sort_unstable_by(|a, b| a.total_cmp(b));
    let background = samples[samples.len() / 2];

    // Estimate noise from remaining samples
    let variance: f64 = samples
        .par_iter()
        .map(|&v| (v - background).powi(2))
        .sum::<f64>()
        / samples.len() as f64;
    let noise = variance.sqrt();

    (background, noise.max(1.0))
}

/// Context for star measurement to reduce parameter count
struct StarMeasurementContext<'a> {
    pixels: &'a [f64],
    width: usize,
    height: usize,
    background: f64,
    noise: f64,
    config: &'a StarDetectionConfig,
    visited: &'a mut [bool],
}

/// Measure a star's properties including eccentricity and sharpness
fn measure_star(ctx: &mut StarMeasurementContext, cx: usize, cy: usize) -> Option<DetectedStar> {
    // Why: hfr_radius is u32 (UI-bounded, typically <=50). TryFrom surfaces a
    // pathological value as i32::MAX instead of wrapping negative; the bounds
    // checks below then cap the loop range to in-image pixels.
    let radius = i32::try_from(ctx.config.hfr_radius).unwrap_or(i32::MAX);

    // First pass: Calculate centroid using intensity-weighted center.
    //
    // Why visited is not marked here: stamping the whole
    // `(2·hfr_radius+1)²` search window is a 41×41 forbidden zone after each
    // detection at the default `hfr_radius=20`, so in dense fields (M13, M11
    // cores, Pleiades) the second of two stars ~40 px apart is masked out
    // before its centroid is ever computed. Marking is deferred until HFR is
    // known and then stamps only the star aperture, an HFR-derived disk. See
    // the stamp at the bottom of this function.
    let mut sum_x = 0.0;
    let mut sum_y = 0.0;
    let mut sum_flux = 0.0;
    let mut peak = 0.0_f64;
    let mut pixel_count = 0u32;

    for dy in -radius..=radius {
        for dx in -radius..=radius {
            let x = cx as i32 + dx;
            let y = cy as i32 + dy;

            if x < 0 || y < 0 || x >= ctx.width as i32 || y >= ctx.height as i32 {
                continue;
            }

            let idx = y as usize * ctx.width + x as usize;
            let val = ctx.pixels[idx] - ctx.background;

            if val > 0.0 {
                sum_x += x as f64 * val;
                sum_y += y as f64 * val;
                sum_flux += val;
                peak = peak.max(ctx.pixels[idx]);
                pixel_count += 1;
            }
        }
    }

    if sum_flux <= 0.0 || pixel_count == 0 {
        // Centroid failed (no positive pixels in the search window). Stamp
        // a tiny disk around the seed so the outer loop doesn't re-trigger
        // on the same local maximum. Keep this disk small enough that real
        // neighbouring stars are not excluded.
        stamp_visited_disk(ctx, cx as f64, cy as f64, fallback_visited_radius(radius));
        return None;
    }

    let centroid_x = sum_x / sum_flux;
    let centroid_y = sum_y / sum_flux;

    // Second pass: Calculate second moments for eccentricity
    // Mxx = Σ(x - cx)² * I / Σ I
    // Myy = Σ(y - cy)² * I / Σ I
    // Mxy = Σ(x - cx)(y - cy) * I / Σ I
    let mut mxx = 0.0;
    let mut myy = 0.0;
    let mut mxy = 0.0;

    for dy in -radius..=radius {
        for dx in -radius..=radius {
            let x = cx as i32 + dx;
            let y = cy as i32 + dy;

            if x < 0 || y < 0 || x >= ctx.width as i32 || y >= ctx.height as i32 {
                continue;
            }

            let idx = y as usize * ctx.width + x as usize;
            let val = ctx.pixels[idx] - ctx.background;

            if val > 0.0 {
                let dx_c = x as f64 - centroid_x;
                let dy_c = y as f64 - centroid_y;
                mxx += dx_c * dx_c * val;
                myy += dy_c * dy_c * val;
                mxy += dx_c * dy_c * val;
            }
        }
    }

    mxx /= sum_flux;
    myy /= sum_flux;
    mxy /= sum_flux;

    // Calculate eccentricity from second moments
    // Using eigenvalues of the covariance matrix
    let trace = mxx + myy;
    let det = mxx * myy - mxy * mxy;
    let discriminant = (trace * trace - 4.0 * det).max(0.0).sqrt();

    let lambda1 = (trace + discriminant) / 2.0;
    let lambda2 = (trace - discriminant) / 2.0;

    // Eccentricity: 0 = circle, 1 = line
    let eccentricity = if lambda1 > 1e-10 && lambda2 >= 0.0 {
        (1.0 - lambda2 / lambda1).max(0.0).sqrt()
    } else {
        0.0
    };

    // Calculate HFR (true encircled-energy 50% radius).
    let hfr = calculate_hfr_at_point(
        ctx.pixels,
        ctx.width,
        ctx.height,
        centroid_x,
        centroid_y,
        ctx.background,
        radius,
    );

    // Why: with the encircled-energy 50% HFR (matching NINA / SGP / PixInsight),
    // FWHM = 2.0 × HFR for a Gaussian PSF (HFR_true = σ·√(2 ln 2),
    // FWHM = 2σ·√(2 ln 2)). The previous 2.3548 constant assumed HFR ≈ σ,
    // which is wrong: HFR_true ≈ 1.177σ.
    const FWHM_TO_HFR_RATIO: f64 = 2.0;
    let fwhm = hfr * FWHM_TO_HFR_RATIO;

    // SNR via the standard CCD equation. `pixel_count` is the
    // actual aperture pixel count `n_pix` derived from the detection mask.
    let snr = compute_snr(
        sum_flux,
        pixel_count as f64,
        ctx.noise,
        ctx.config.noise_model.as_ref(),
    );

    let peak_above_bg = peak - ctx.background;

    // Sharpness: the FRACTION of the source's flux sitting in its brightest
    // pixel. A hot pixel puts nearly all of it there (→ ~1.0); a real star
    // spreads it over its PSF (→ 0.1-0.5, as the field's docs state).
    //
    // This divided by the MEAN flux per pixel instead of the TOTAL, which
    // inverts the discriminator: peak/mean exceeds 1 for ANY peaked source, so
    // `.min(1.0)` pinned every real star at exactly 1.0 — above the 0.95
    // default — while a single hot pixel (peak == mean over a 1-pixel footprint)
    // scored 1.0 too. With `StarDetectionConfig::default()` the filter therefore
    // rejected EVERYTHING: autofocus reported "Insufficient stars detected. Only
    // 0 stars found (minimum: 10)", HFR-based grading and the HFR /
    // focus-drift triggers had nothing to measure, and every frame logged "no
    // stars detected for HFR calculation". Found while making the simulator emit
    // a detectable star field: a clean 45-star Gaussian frame scored 0 stars
    // under the default config and 40 under `max_sharpness: 1.1`.
    //
    // Dividing by total flux is bounded to (0, 1] by construction, so the clamp
    // is now only a guard against floating-point overshoot.
    let sharpness = if sum_flux > 0.0 {
        (peak_above_bg / sum_flux).clamp(0.0, 1.0)
    } else {
        1.0 // Default to high sharpness (reject) if it cannot be calculated
    };

    // Stamp the visited mask as the actual star aperture (audit IMG-).
    //
    // Why `2·HFR`: for a Gaussian PSF the encircled-energy radius at 95%
    // of total flux is r_95 ≈ 2.45σ ≈ 2.08·HFR (HFR = σ·√(2 ln 2) ≈
    // 1.177σ). Using `2·HFR` therefore covers ~94–95% of the star's
    // flux — comfortably past the radius at which one star's wings
    // overlap a neighbour's centroid contribution while staying well
    // inside the search window for tightly packed fields.
    //
    // Why the `hfr_radius` cap: a saturated or blooming core can produce
    // a pathologically large encircled-energy radius (the wings carry as
    // much area as the core). Capping the visited disk at `hfr_radius`
    // (the same bound the search window already uses) prevents one
    // saturated detection from blanking an entire region.
    //
    // The disk uses the sub-pixel centroid so the mask is centred on the
    // true star, not the (possibly off-centre) seed local maximum.
    let radius_f = radius as f64;
    let visited_radius = (2.0 * hfr).min(radius_f).max(1.0);
    stamp_visited_disk(ctx, centroid_x, centroid_y, visited_radius);

    Some(DetectedStar {
        x: centroid_x,
        y: centroid_y,
        flux: sum_flux,
        hfr,
        fwhm,
        peak,
        background: ctx.background,
        snr,
        eccentricity,
        sharpness,
    })
}

/// Fallback visited radius when centroid computation fails.
///
/// Why `hfr_radius / 4` (min 1): we only need to prevent the outer
/// detection loop from re-triggering on the same seed pixel and its
/// immediate hot-pixel neighbourhood. A radius smaller than this risks
/// duplicate detections from the 8-connected local-max test; larger
/// would excuse the visited-mask bug we're fixing.
fn fallback_visited_radius(hfr_radius: i32) -> f64 {
    ((hfr_radius / 4).max(1)) as f64
}

/// Mark a disk of pixels as visited.
///
/// Why a disk and not a square: stars are circular (or near-circular)
/// in well-tracked frames, so a disk mask matches the actual star
/// aperture. The check `dx² + dy² ≤ r²` is the same `O(r²)` cost as
/// the previous full-square stamp — the inner loop body is cheaper
/// (one fused-multiply-add comparison vs an unconditional store) so
/// total work is the same order or less.
fn stamp_visited_disk(ctx: &mut StarMeasurementContext, cx: f64, cy: f64, radius: f64) {
    if radius <= 0.0 {
        return;
    }
    let r_ceil = radius.ceil() as i32;
    let r_sq = radius * radius;
    let cx_round = cx.round() as i32;
    let cy_round = cy.round() as i32;

    for dy in -r_ceil..=r_ceil {
        let y = cy_round + dy;
        if y < 0 || y >= ctx.height as i32 {
            continue;
        }
        let y_us = y as usize;
        // Tight x-bound per row from the disk equation: |dx| ≤ √(r² − dy²).
        let dy_sq = (dy * dy) as f64;
        if dy_sq > r_sq {
            continue;
        }
        let dx_max = (r_sq - dy_sq).sqrt().floor() as i32;
        let x_start = (cx_round - dx_max).max(0);
        let x_end = (cx_round + dx_max).min(ctx.width as i32 - 1);
        if x_start > x_end {
            continue;
        }
        let row = y_us * ctx.width;
        for x in x_start..=x_end {
            ctx.visited[row + x as usize] = true;
        }
    }
}

/// Compute the true encircled-energy 50% half-flux radius (HFR).
///
/// Why: we sort the aperture pixels by distance from the
/// centroid, integrate background-subtracted flux in increasing-radius
/// order, and return the radius at which cumulative flux first crosses
/// 50% of the total. Sub-pixel accuracy is achieved by linearly
/// interpolating the radius between the two pixels that bracket the
/// 50% point.
///
/// This matches the NINA / SGP / PixInsight HFR convention. The
/// flux-weighted *mean* radius ⟨r⟩ is a different quantity — it
/// over-states FWHM by ~25% for a Gaussian PSF.
fn calculate_hfr_at_point(
    pixels: &[f64],
    width: usize,
    height: usize,
    cx: f64,
    cy: f64,
    background: f64,
    radius: i32,
) -> f64 {
    // Use the sub-pixel centroid as the reference for radial distances so
    // that the returned HFR has sub-pixel accuracy.
    let mut samples: Vec<(f64, f64)> =
        Vec::with_capacity(((2 * radius + 1) * (2 * radius + 1)) as usize);

    for dy in -radius..=radius {
        for dx in -radius..=radius {
            let xi = cx.round() as i32 + dx;
            let yi = cy.round() as i32 + dy;
            if xi < 0 || yi < 0 || xi >= width as i32 || yi >= height as i32 {
                continue;
            }
            let val = (pixels[yi as usize * width + xi as usize] - background).max(0.0);
            if val <= 0.0 {
                continue;
            }
            let dxr = xi as f64 - cx;
            let dyr = yi as f64 - cy;
            let dist = (dxr * dxr + dyr * dyr).sqrt();
            samples.push((dist, val));
        }
    }

    if samples.is_empty() {
        return 0.0;
    }

    // Sort by radial distance ascending.
    samples.sort_by(|a, b| a.0.total_cmp(&b.0));

    let total_flux: f64 = samples.iter().map(|s| s.1).sum();
    if total_flux <= 0.0 {
        return 0.0;
    }
    let half_flux = 0.5 * total_flux;

    let mut cum = 0.0;
    let mut prev_r = 0.0;
    let mut prev_cum = 0.0;
    for &(r, v) in &samples {
        let next_cum = cum + v;
        if next_cum >= half_flux {
            // Linearly interpolate between the previous (r, cum) and (r, next_cum).
            // Why: cumulative flux is piecewise-linear in r if we treat each
            // pixel contribution as an instantaneous step at its radius; using
            // a linear interpolation between the bracketing samples gives the
            // best sub-pixel estimate available without re-sampling the PSF.
            let denom = next_cum - prev_cum;
            if denom <= 0.0 {
                return r;
            }
            let frac = (half_flux - prev_cum) / denom;
            return prev_r + frac * (r - prev_r);
        }
        prev_cum = next_cum;
        prev_r = r;
        cum = next_cum;
    }

    // Fallback: should not happen because cum reaches total_flux >= half_flux
    // at the last sample, but keep the outermost radius if it does.
    prev_r
}

/// Compute SNR via the standard CCD equation.
///
/// Why: the previous formula
/// `sum_flux / (noise * sqrt(sum_flux / peak_above_bg))` is non-standard
/// and omits read noise + dark current entirely. The correct model is
///
/// ```text
///     SNR = signal / sqrt(signal + n_pix * (sky + read_noise² + dark))
/// ```
///
/// Inputs:
/// * `signal_adu` — integrated background-subtracted flux in the aperture (ADU).
/// * `n_pix` — actual aperture pixel count from the detection mask.
/// * `bg_noise_adu` — empirical per-pixel background sigma in ADU
///   (output of `estimate_background`). This already aggregates sky shot
///   noise, read noise, and dark current as they appear in this frame.
/// * `model` — optional electron-domain camera metadata.
///
/// When `model` is supplied, the calculation is performed in electrons
/// using `gain_e_per_adu`, `read_noise_e`, `dark_e_per_sec * exposure_s`,
/// and the empirical sky variance converted to electrons. When `model`
/// is `None`, we evaluate the same CCD equation in the ADU domain
/// against `bg_noise_adu²`; this is mathematically the standard CCD
/// equation with the sum (sky + read_noise² + dark) replaced by the
/// empirically-measured per-pixel background variance. The ADU-domain
/// branch under-counts only the source-shot-noise term that depends on
/// gain (it is treated as if gain = 1 e/ADU); this is documented and
/// callers that have profile metadata should populate `noise_model`.
fn compute_snr(
    signal_adu: f64,
    n_pix: f64,
    bg_noise_adu: f64,
    model: Option<&CameraNoiseModel>,
) -> f64 {
    if signal_adu <= 0.0 || n_pix <= 0.0 {
        return 0.0;
    }

    match model {
        Some(m) if m.gain_e_per_adu > 0.0 => {
            // Convert ADU → electrons for the source signal and the
            // empirical sky variance. The empirical per-pixel variance in
            // ADU² maps to electron² via gain² (since e = ADU * gain).
            let signal_e = signal_adu * m.gain_e_per_adu;
            let sky_var_e2 = (bg_noise_adu * bg_noise_adu) * m.gain_e_per_adu * m.gain_e_per_adu;
            let read_var_e2 = m.read_noise_e * m.read_noise_e;
            let dark_e = (m.dark_e_per_sec * m.exposure_s).max(0.0);

            // Per-pixel background variance term (electrons²). We add
            // read_noise² and dark explicitly. If the empirical sky
            // variance already includes them (typical for a well-sampled
            // background), this slightly over-counts; that is the safe
            // direction (pessimistic SNR) and is documented.
            let per_pixel_var_e2 = sky_var_e2 + read_var_e2 + dark_e;
            let denom = signal_e + n_pix * per_pixel_var_e2;
            if denom <= 0.0 {
                return 0.0;
            }
            signal_e / denom.sqrt()
        }
        _ => {
            // ADU-domain CCD equation against the measured background
            // variance. Treats ADU as electrons (gain = 1 e/ADU) for the
            // source-shot-noise term — documented approximation.
            let var_per_pixel = bg_noise_adu * bg_noise_adu;
            let denom = signal_adu + n_pix * var_per_pixel;
            if denom <= 0.0 {
                return 0.0;
            }
            signal_adu / denom.sqrt()
        }
    }
}

/// Calculate median HFR for detected stars
pub fn calculate_median_hfr(image: &ImageData) -> Option<f64> {
    let config = StarDetectionConfig::default();
    // Round stars only: HFR is a FOCUS metric, and a trailed star's half-flux
    // radius is inflated by the trail, not by defocus. Measuring it over the
    // permissive detection population makes a windy night look like a focus
    // drift — and the sequencer answers focus drift by running an autofocus,
    // which cannot fix trailing and costs the exposures it burns.
    let stars = detect_stars_for_selection(image, &config);

    if stars.is_empty() {
        return None;
    }

    // Use top 50% brightest stars for HFR
    let count = (stars.len() / 2).clamp(1, 50);
    let mut hfrs: Vec<f64> = stars
        .iter()
        .take(count)
        .map(|s| s.hfr)
        .filter(|&h| h > 0.0 && h < 20.0) // Filter outliers
        .collect();

    if hfrs.is_empty() {
        return None;
    }

    hfrs.sort_by(|a, b| a.total_cmp(b));
    Some(hfrs[hfrs.len() / 2])
}

/// Calculate histogram for a 16-bit image
pub fn calculate_histogram(image: &ImageData, bins: usize) -> Vec<u32> {
    if bins == 0 {
        return Vec::new();
    }

    let bin_size = 65536 / bins;

    // Parallel histogram calculation
    // Each thread calculates a local histogram, then they are reduced
    image
        .data
        .par_chunks_exact(2)
        .fold(
            || vec![0u32; bins],
            |mut hist, chunk| {
                let val = u16::from_le_bytes([chunk[0], chunk[1]]) as usize;
                let bin = (val / bin_size).min(bins - 1);
                hist[bin] += 1;
                hist
            },
        )
        .reduce(
            || vec![0u32; bins],
            |mut hist1, hist2| {
                for (h1, h2) in hist1.iter_mut().zip(hist2.iter()) {
                    *h1 += h2;
                }
                hist1
            },
        )
}

/// Calculate histogram for display (256 bins, logarithmic scale option)
pub fn calculate_display_histogram(image: &ImageData, logarithmic: bool) -> Vec<f32> {
    let histogram = calculate_histogram(image, 256);

    // Parallel processing for display conversion
    if logarithmic {
        histogram
            .par_iter()
            .map(|&count| if count > 0 { (count as f32).ln() } else { 0.0 })
            .collect()
    } else {
        // Why: `calculate_histogram` always returns 256
        // entries (we just asked for `bins=256`), so `.iter().max()` is
        // `None` ONLY in the never-reached "0 bins requested" branch.
        // Substituting `&1` is the documented "empty/all-zero histogram"
        // divisor that yields a flat 0.0 display (no division by zero)
        // rather than a NaN-filled output that the GPU shader would
        // render as black. We also clamp the actual max to 1 for the same
        // reason: an all-zero image (e.g. just-opened darks) would otherwise
        // divide 0/0 into NaN bars.
        let max_raw = *histogram.iter().max().unwrap_or(&1);
        let max_val = max_raw.max(1) as f32;
        histogram
            .par_iter()
            .map(|&count| count as f32 / max_val)
            .collect()
    }
}

/// Star detection summary.
///
/// Three different populations come out of one detection pass, because three
/// different questions are being asked of the same frame. Reading the wrong
/// one is what this type exists to prevent:
///
/// | field | eccentricity ceiling | the question it answers |
/// |---|---|---|
/// | [`Self::stars`] | `min(config, `[`SELECTION_MAX_ECCENTRICITY`]`)` | "which stars can I centroid on / focus by?" |
/// | [`Self::sources`] | `config.max_eccentricity` | "what did I ask the detector for?" |
/// | [`Self::detected_star_count`] / [`Self::median_eccentricity`] | `max(config, `[`DETECTION_MAX_ECCENTRICITY`]`)` | "what is actually in this frame?" |
#[derive(Debug, Clone)]
pub struct StarDetectionResult {
    /// Stars round enough to work with — filtered at
    /// [`SELECTION_MAX_ECCENTRICITY`]. This is what a guider centroids on and
    /// what the HFR/FWHM/SNR medians below are computed from.
    ///
    /// **This list is narrowed past what the caller asked for.** A caller that
    /// deliberately passes a *looser* `max_eccentricity` because it is
    /// measuring the field rather than working in it — PSF/tilt maps,
    /// photometry, astrometric residuals — must read [`Self::sources`], or it
    /// silently gets the 0.7 answer to a question it asked at 0.95.
    pub stars: Vec<DetectedStar>,
    /// `stars.len()`, i.e. the count of *usable* stars.
    pub star_count: u32,
    /// Every source that passed the caller's **own** `config`, unnarrowed by
    /// the working-star ceiling.
    ///
    /// Why this exists: the working-star ceiling is a *policy* about what is
    /// safe to guide or focus on, and applying it to `stars` fixed the guider.
    /// But it is not a fact about the frame, and silently imposing it on a
    /// caller who asked for a wider population re-creates the original defect
    /// one level up — a shape measurement clipped at a threshold can never
    /// report a value above that threshold. `sources` is the honest answer to
    /// "run the config I gave you", which is the contract every
    /// caller-supplied-config entry point has.
    pub sources: Vec<DetectedStar>,
    /// Sources the detector measured before the selection filter, i.e. every
    /// star up to at least [`DETECTION_MAX_ECCENTRICITY`] (see
    /// `measurement_eccentricity_ceiling`) — which is why this can exceed
    /// `star_count`, and `sources.len()`, even for a caller whose own ceiling
    /// is tighter.
    ///
    /// Why it is reported separately: "0 usable stars" and "0 stars at all"
    /// are different nights. A frame full of 2:1 trails yields
    /// `star_count == 0` with `detected_star_count == 40`, and calling that
    /// "no stars detected" would send the operator hunting for clouds or a
    /// dust cap instead of for the mount.
    pub detected_star_count: u32,
    pub median_hfr: f64,
    pub median_fwhm: f64,
    pub median_snr: f64,
    /// Per-frame median eccentricity across the brightest, most reliable
    /// detected stars (0.0 = perfectly round, →1.0 = trailed/elongated).
    ///
    /// Measured over [`Self::detected_star_count`] — the population *before*
    /// the selection filter, and at a ceiling of at least
    /// [`DETECTION_MAX_ECCENTRICITY`] even when the caller's config asks for
    /// something tighter — so it can and routinely does exceed
    /// [`SELECTION_MAX_ECCENTRICITY`] or the caller's own threshold. Measuring
    /// it over `stars`, or at the caller's ceiling, would clip it at that
    /// ceiling and report a trailed frame as round.
    ///
    /// `None` (not `0.0`) when the metric cannot be honestly measured —
    /// either no stars were detected or too few survived the reliability
    /// filter to form a stable median. The grading gate treats `None` as
    /// "unknown, do not reject"; fabricating `0.0` would silently let
    /// trailed frames pass a configured eccentricity gate, so we never do.
    pub median_eccentricity: Option<f64>,
    pub background: f64,
    pub noise: f64,
}

/// Minimum number of reliable stars required to report a stable per-frame
/// eccentricity. Below this the median is too noisy to gate on, so we
/// report `None` (honest absence) rather than a fabricated value.
const MIN_STARS_FOR_FRAME_ECCENTRICITY: usize = 5;

/// Aggregate a per-frame eccentricity from individually-measured stars.
///
/// Selection rationale (mirrors the HFR aggregation): we rank stars by flux
/// (brightest first — these have the best-sampled shape moments), keep the
/// reliable ones (positive flux, finite eccentricity, plausible HFR so hot
/// pixels and cosmic rays are excluded), cap at the brightest 50 to bound
/// cost, then take the median. The median is robust to a handful of
/// blended/saturated outliers that would skew a mean.
///
/// Returns `None` (fail-closed) when fewer than
/// [`MIN_STARS_FOR_FRAME_ECCENTRICITY`] reliable stars are available — a
/// single round star must not be reported as "the frame is round".
pub fn frame_eccentricity(stars: &[DetectedStar]) -> Option<f64> {
    let mut reliable: Vec<&DetectedStar> = stars
        .iter()
        .filter(|s| {
            s.flux > 0.0
                && s.eccentricity.is_finite()
                && (0.0..=1.0).contains(&s.eccentricity)
                // Reject hot pixels / cosmic rays whose "shape" is meaningless:
                // a real star has measurable spread (HFR > 0.5 px).
                && s.hfr > 0.5
        })
        .collect();

    if reliable.len() < MIN_STARS_FOR_FRAME_ECCENTRICITY {
        return None;
    }

    // Brightest first — best-sampled moments dominate the estimate.
    reliable.sort_by(|a, b| b.flux.total_cmp(&a.flux));
    let take = reliable.len().min(50);

    let mut eccs: Vec<f64> = reliable.iter().take(take).map(|s| s.eccentricity).collect();
    eccs.sort_by(f64::total_cmp);
    Some(eccs[eccs.len() / 2])
}

/// Run full star detection with summary statistics
pub fn detect_stars_with_stats(
    image: &ImageData,
    config: &StarDetectionConfig,
) -> StarDetectionResult {
    let width = image.width as usize;
    let height = image.height as usize;

    // Estimate background first
    // Parallel conversion
    let pixels: Vec<f64> = image
        .data
        .par_chunks_exact(2)
        .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]) as f64)
        .collect();

    let (background, noise) = if !pixels.is_empty() {
        estimate_background(&pixels, width, height)
    } else {
        (0.0, 1.0)
    };

    // Log detection parameters for diagnostics
    let threshold = background + config.detection_sigma * noise;
    let pixel_stats: (f64, f64, f64) = if !pixels.is_empty() {
        let min = pixels.iter().copied().fold(f64::INFINITY, f64::min);
        let max = pixels.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        let sum: f64 = pixels.iter().sum();
        let avg = sum / pixels.len() as f64;
        (min, max, avg)
    } else {
        (0.0, 0.0, 0.0)
    };
    tracing::info!(
        "[STAR_DETECT] Image {}x{}, pixel range: {:.0}-{:.0}, avg: {:.1}",
        width,
        height,
        pixel_stats.0,
        pixel_stats.1,
        pixel_stats.2
    );
    tracing::info!(
        "[STAR_DETECT] Background: {:.1}, Noise: {:.1}, Threshold: {:.1} (sigma={})",
        background,
        noise,
        threshold,
        config.detection_sigma
    );

    // Three populations, three questions, one detection pass. `detected`
    // answers "what is in this frame" and is what the shape statistics must be
    // measured from. `stars` answers "what can I work with" and is what the
    // guider, autofocus and frame weighting consume. `sources` answers "what
    // did the caller ask for" — it is the caller's own ceiling, honoured
    // verbatim, because narrowing a caller who deliberately widened the ceiling
    // to measure the field is the same self-blinding bug as clipping the
    // eccentricity median at the grading threshold, just moved one level up.
    let measurement_config = StarDetectionConfig {
        max_eccentricity: measurement_eccentricity_ceiling(config),
        ..config.clone()
    };
    let detected = detect_stars(image, &measurement_config);
    let detected_star_count = detected.len() as u32;

    let median_eccentricity = frame_eccentricity(&detected);

    let mut sources = detected;
    sources.retain(|s| s.eccentricity <= config.max_eccentricity);

    let selection_ceiling = selection_eccentricity_ceiling(config);
    let mut stars = sources.clone();
    stars.retain(|s| s.eccentricity <= selection_ceiling);
    let star_count = stars.len() as u32;
    tracing::info!(
        "[STAR_DETECT] Measured {} sources (eccentricity <= {:.2}), {} at the requested ceiling (<= {:.2}), {} usable (<= {:.2})",
        detected_star_count,
        measurement_config.max_eccentricity,
        sources.len(),
        config.max_eccentricity,
        star_count,
        selection_ceiling
    );

    // Calculate median statistics
    let (median_hfr, median_fwhm, median_snr) = if !stars.is_empty() {
        let count = (stars.len() / 2).clamp(1, 50);

        let mut hfrs: Vec<f64> = stars.iter().take(count).map(|s| s.hfr).collect();
        let mut fwhms: Vec<f64> = stars.iter().take(count).map(|s| s.fwhm).collect();
        let mut snrs: Vec<f64> = stars.iter().take(count).map(|s| s.snr).collect();

        hfrs.sort_by(|a, b| a.total_cmp(b));
        fwhms.sort_by(|a, b| a.total_cmp(b));
        snrs.sort_by(|a, b| a.total_cmp(b));

        (
            hfrs[hfrs.len() / 2],
            fwhms[fwhms.len() / 2],
            snrs[snrs.len() / 2],
        )
    } else {
        (0.0, 0.0, 0.0)
    };

    StarDetectionResult {
        stars,
        star_count,
        sources,
        detected_star_count,
        median_hfr,
        median_fwhm,
        median_snr,
        median_eccentricity,
        background,
        noise,
    }
}

/// Data for a cropped star image ready for UI display
#[derive(Debug, Clone)]
pub struct StarCropData {
    /// Cropped image pixels as 8-bit grayscale (normalized/stretched)
    pub pixels: Vec<u8>,
    /// Width of the crop
    pub width: u32,
    /// Height of the crop
    pub height: u32,
    /// Star X position in original image
    pub star_x: f64,
    /// Star Y position in original image
    pub star_y: f64,
    /// Star's HFR value
    pub hfr: f64,
    /// Star's SNR value
    pub snr: f64,
}

/// Extract a cropped region around a star, normalized for display
///
/// Returns an 80x80 (or smaller near edges) crop centered on the star,
/// with pixel values auto-stretched to 0-255 range for display.
pub fn extract_star_crop(image: &ImageData, star: &DetectedStar, crop_size: u32) -> StarCropData {
    let width = image.width as i32;
    let height = image.height as i32;
    let half_size = crop_size as i32 / 2;

    // Calculate crop bounds, clamping to image edges
    let star_x = star.x.round() as i32;
    let star_y = star.y.round() as i32;

    let x_start = (star_x - half_size).max(0);
    let y_start = (star_y - half_size).max(0);
    let x_end = (star_x + half_size).min(width);
    let y_end = (star_y + half_size).min(height);

    let crop_width = (x_end - x_start) as u32;
    let crop_height = (y_end - y_start) as u32;

    // Extract pixels from the raw byte array (2 bytes per pixel, little-endian u16)
    let mut crop_pixels: Vec<u16> = Vec::with_capacity((crop_width * crop_height) as usize);
    let mut min_val = u16::MAX;
    let mut max_val = u16::MIN;

    for y in y_start..y_end {
        for x in x_start..x_end {
            let idx = ((y * width + x) * 2) as usize; // 2 bytes per pixel
            if idx + 1 < image.data.len() {
                let val = u16::from_le_bytes([image.data[idx], image.data[idx + 1]]);
                crop_pixels.push(val);
                min_val = min_val.min(val);
                max_val = max_val.max(val);
            }
        }
    }

    // Normalize to 0-255 with auto-stretch
    let range = (max_val - min_val).max(1) as f64;
    let normalized: Vec<u8> = crop_pixels
        .iter()
        .map(|&val| ((val - min_val) as f64 / range * 255.0) as u8)
        .collect();

    StarCropData {
        pixels: normalized,
        width: crop_width,
        height: crop_height,
        star_x: star.x,
        star_y: star.y,
        hfr: star.hfr,
        snr: star.snr,
    }
}

/// Extract crops for the top N brightest stars, sorted by SNR
///
/// Returns up to `max_crops` star crops, sorted by brightness (SNR descending).
/// Useful for the autofocus UI to let users cycle through different stars.
pub fn extract_top_star_crops(
    image: &ImageData,
    stars: &[DetectedStar],
    max_crops: usize,
    crop_size: u32,
) -> Vec<StarCropData> {
    // Sort stars by SNR (brightness) descending
    // Why: `partial_cmp` returns `None` only when comparing
    // against NaN. SNR is computed in `detect_stars` as a ratio of finite
    // sums divided by a positive standard deviation, so NaN here would
    // indicate a star-detection bug (zero pixel variance with non-zero flux,
    // impossible by construction). Treating any NaN as `Equal` keeps the
    // sort stable for those edge stars rather than panicking; if the bug
    // ever materialises the NaN-SNR stars cluster together at their original
    // positions, which is easy to spot in the UI/log.
    let mut sorted_stars: Vec<&DetectedStar> = stars.iter().collect();
    sorted_stars.sort_by(|a, b| {
        b.snr
            .partial_cmp(&a.snr)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    // Extract crops for top N
    sorted_stars
        .into_iter()
        .take(max_crops)
        .map(|star| extract_star_crop(image, star, crop_size))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn calculate_stats_reports_expected_mad_for_even_sample() {
        let image = ImageData::from_u16(4, 1, 1, &[10, 10, 14, 22]);
        let stats = calculate_stats_u16(&image);
        assert_eq!(stats.median, 12.0);
        assert_eq!(stats.mad, 2.0);
    }

    #[test]
    fn calculate_stats_ignores_trailing_odd_byte() {
        let image = ImageData {
            width: 1,
            height: 1,
            channels: 1,
            pixel_type: crate::PixelType::U16,
            data: vec![0x34, 0x12, 0xFF],
        };
        let stats = calculate_stats_u16(&image);
        assert_eq!(stats.min, 0x1234 as f64);
        assert_eq!(stats.max, 0x1234 as f64);
        assert_eq!(stats.mad, 0.0);
    }

    #[test]
    fn calculate_histogram_returns_empty_for_zero_bins() {
        let image = ImageData::from_u16(2, 1, 1, &[10, 20]);
        assert!(calculate_histogram(&image, 0).is_empty());
    }

    /// Render a synthetic 2-D Gaussian PSF on a u16 grid.
    ///
    /// Why: the load-bearing test builds a known-σ Gaussian, runs the
    /// detector, and asserts the reported HFR (≈ 1.177 σ) and FWHM
    /// (≈ 2.355 σ) within 5%.
    fn render_gaussian_u16(width: u32, height: u32, cx: f64, cy: f64, sigma: f64) -> ImageData {
        const BACKGROUND: f64 = 1000.0;
        const PEAK: f64 = 30000.0;
        let mut data = vec![BACKGROUND as u16; (width * height) as usize];
        let two_sigma_sq = 2.0 * sigma * sigma;
        for y in 0..height {
            for x in 0..width {
                let dx = x as f64 - cx;
                let dy = y as f64 - cy;
                let r2 = dx * dx + dy * dy;
                let v = BACKGROUND + PEAK * (-r2 / two_sigma_sq).exp();
                let v = v.clamp(0.0, 65535.0) as u16;
                data[(y * width + x) as usize] = v;
            }
        }
        ImageData::from_u16(width, height, 1, &data)
    }

    /// Render a synthetic Moffat-β profile.
    ///
    /// Why: the Moffat-2 cross-check confirms the metric behaves under
    /// non-Gaussian PSFs. Moffat β=2 has heavier wings
    /// than a Gaussian; its encircled-energy HFR is therefore larger than
    /// the half-maximum radius for the same analytic FWHM.
    fn render_moffat_u16(
        width: u32,
        height: u32,
        cx: f64,
        cy: f64,
        alpha: f64,
        beta: f64,
    ) -> ImageData {
        const BACKGROUND: f64 = 1000.0;
        const PEAK: f64 = 30000.0;
        let mut data = vec![BACKGROUND as u16; (width * height) as usize];
        let alpha_sq = alpha * alpha;
        for y in 0..height {
            for x in 0..width {
                let dx = x as f64 - cx;
                let dy = y as f64 - cy;
                let r2 = dx * dx + dy * dy;
                let v = BACKGROUND + PEAK * (1.0 + r2 / alpha_sq).powf(-beta);
                let v = v.clamp(0.0, 65535.0) as u16;
                data[(y * width + x) as usize] = v;
            }
        }
        ImageData::from_u16(width, height, 1, &data)
    }

    #[test]
    fn hfr_and_fwhm_match_gaussian_definition_within_five_percent() {
        let sigma = 2.5_f64;
        let image = render_gaussian_u16(64, 64, 32.0, 32.0, sigma);

        // Reduce min_area: the synthetic Gaussian on a 64×64 grid still has
        // many pixels above background but we want the HFR computation to
        // dominate the assertion, not detection thresholds.
        let config = StarDetectionConfig {
            min_area: 5,
            min_hfr: 0.5,
            min_snr: 1.0,
            max_sharpness: 1.0,
            hfr_radius: 16,
            ..Default::default()
        };

        let stars = detect_stars(&image, &config);
        assert!(
            !stars.is_empty(),
            "expected at least one detected star for synthetic Gaussian"
        );
        // Pick the brightest detection — that is the synthetic peak.
        let star = &stars[0];

        let expected_hfr = sigma * (2.0_f64 * 2.0_f64.ln()).sqrt();
        let expected_fwhm = 2.0 * sigma * (2.0_f64 * 2.0_f64.ln()).sqrt();

        let hfr_err = (star.hfr - expected_hfr).abs() / expected_hfr;
        let fwhm_err = (star.fwhm - expected_fwhm).abs() / expected_fwhm;
        assert!(
            hfr_err < 0.05,
            "HFR {:.4} vs expected {:.4} (err {:.2}%)",
            star.hfr,
            expected_hfr,
            hfr_err * 100.0
        );
        assert!(
            fwhm_err < 0.05,
            "FWHM {:.4} vs expected {:.4} (err {:.2}%)",
            star.fwhm,
            expected_fwhm,
            fwhm_err * 100.0
        );
    }

    #[test]
    fn hfr_and_fwhm_track_moffat_beta_two_profile() {
        // For Moffat-β, analytic FWHM = 2·α·√(2^(1/β) − 1). Pick α so
        // that half-maximum width matches an easy reference (5 px), then
        // verify the encircled-energy HFR independently.
        let beta = 2.0_f64;
        let target_fwhm = 5.0_f64;
        let alpha = (target_fwhm / 2.0) / (2.0_f64.powf(1.0 / beta) - 1.0).sqrt();
        let image = render_moffat_u16(64, 64, 32.0, 32.0, alpha, beta);

        let config = StarDetectionConfig {
            min_area: 5,
            min_hfr: 0.5,
            min_snr: 1.0,
            max_sharpness: 1.0,
            hfr_radius: 24,
            ..Default::default()
        };

        let stars = detect_stars(&image, &config);
        assert!(!stars.is_empty(), "expected detection on Moffat-2 PSF");
        let star = &stars[0];

        // Encircled-energy 50% HFR for a normalized Moffat-β PSF:
        // r_50 = α·√(2^(1/(β−1)) − 1), beta > 1.
        let expected_hfr = alpha * (2.0_f64.powf(1.0 / (beta - 1.0)) - 1.0).sqrt();
        let expected_fwhm = 2.0 * expected_hfr;

        // 10% tolerance: Moffat has heavier wings than a Gaussian, the
        // discrete aperture truncation introduces more error than for the
        // Gaussian case.
        let hfr_err = (star.hfr - expected_hfr).abs() / expected_hfr;
        let fwhm_err = (star.fwhm - expected_fwhm).abs() / expected_fwhm;
        assert!(
            hfr_err < 0.10,
            "Moffat-2 HFR {:.4} vs expected {:.4} (err {:.2}%)",
            star.hfr,
            expected_hfr,
            hfr_err * 100.0
        );
        assert!(
            fwhm_err < 0.10,
            "Moffat-2 FWHM {:.4} vs expected {:.4} (err {:.2}%)",
            star.fwhm,
            expected_fwhm,
            fwhm_err * 100.0
        );
    }

    /// Render an elliptical 2-D Gaussian with independent σx, σy.
    ///
    /// A round star uses σx == σy → eccentricity ≈ 0. An axis-aligned
    /// elongated/trailed star uses σx ≫ σy → high eccentricity. The
    /// analytic eccentricity of a Gaussian with semi-axes proportional to
    /// (σ_major, σ_minor) is sqrt(1 − (σ_minor/σ_major)²) because the
    /// second central moments are σ² along each axis, so the moment-matrix
    /// eigenvalues are σx² and σy² and ecc = sqrt(1 − λ_min/λ_max).
    fn render_elliptical_gaussian_u16(
        width: u32,
        height: u32,
        cx: f64,
        cy: f64,
        sigma_x: f64,
        sigma_y: f64,
    ) -> ImageData {
        const BACKGROUND: f64 = 1000.0;
        const PEAK: f64 = 30000.0;
        let mut data = vec![BACKGROUND as u16; (width * height) as usize];
        let two_sx_sq = 2.0 * sigma_x * sigma_x;
        let two_sy_sq = 2.0 * sigma_y * sigma_y;
        for y in 0..height {
            for x in 0..width {
                let dx = x as f64 - cx;
                let dy = y as f64 - cy;
                let v = BACKGROUND + PEAK * (-(dx * dx) / two_sx_sq - (dy * dy) / two_sy_sq).exp();
                data[(y * width + x) as usize] = v.clamp(0.0, 65535.0) as u16;
            }
        }
        ImageData::from_u16(width, height, 1, &data)
    }

    fn detect_for_shape(image: &ImageData) -> Vec<DetectedStar> {
        let config = StarDetectionConfig {
            min_area: 5,
            min_hfr: 0.5,
            min_snr: 1.0,
            max_sharpness: 1.0,
            // Don't let the detector's own ecc filter cull the trailed star
            // we are trying to measure — we assert the measured value here.
            max_eccentricity: 1.0,
            hfr_radius: 20,
            ..Default::default()
        };
        detect_stars(image, &config)
    }

    #[test]
    fn round_star_has_near_zero_eccentricity() {
        let image = render_elliptical_gaussian_u16(64, 64, 32.0, 32.0, 2.5, 2.5);
        let stars = detect_for_shape(&image);
        assert!(!stars.is_empty(), "expected detection on round Gaussian");
        let star = &stars[0];
        assert!(
            star.eccentricity < 0.20,
            "round star eccentricity should be ~0, got {:.4}",
            star.eccentricity
        );
    }

    #[test]
    fn elongated_star_has_high_eccentricity_matching_axis_ratio() {
        // σx = 5, σy = 2 → analytic ecc = sqrt(1 − (2/5)²) = sqrt(0.84) ≈ 0.917.
        let sigma_major = 5.0_f64;
        let sigma_minor = 2.0_f64;
        let image = render_elliptical_gaussian_u16(80, 80, 40.0, 40.0, sigma_major, sigma_minor);
        let stars = detect_for_shape(&image);
        assert!(
            !stars.is_empty(),
            "expected detection on elongated Gaussian"
        );
        let star = &stars[0];

        let expected = (1.0 - (sigma_minor / sigma_major).powi(2)).sqrt();
        let err = (star.eccentricity - expected).abs();
        assert!(
            star.eccentricity > 0.7,
            "trailed star must read as highly eccentric, got {:.4}",
            star.eccentricity
        );
        // The discrete aperture + background subtraction bias the measured
        // moments slightly low; 0.08 absolute tolerance against the analytic
        // axis-ratio eccentricity confirms the eigenvalue derivation.
        assert!(
            err < 0.08,
            "measured ecc {:.4} should match analytic {:.4} (err {:.4})",
            star.eccentricity,
            expected,
            err
        );
    }

    #[test]
    fn frame_eccentricity_is_none_below_min_reliable_stars() {
        // Four reliable stars is below MIN_STARS_FOR_FRAME_ECCENTRICITY (5):
        // an honest "unknown", never a fabricated 0.0.
        let stars: Vec<DetectedStar> = (0..4)
            .map(|i| DetectedStar {
                x: i as f64,
                y: 0.0,
                flux: 1000.0,
                hfr: 2.0,
                fwhm: 4.0,
                peak: 5000.0,
                background: 100.0,
                snr: 50.0,
                eccentricity: 0.1,
                sharpness: 0.3,
            })
            .collect();
        assert_eq!(frame_eccentricity(&stars), None);
        assert_eq!(frame_eccentricity(&[]), None);
    }

    #[test]
    fn frame_eccentricity_takes_median_of_reliable_stars() {
        // Five round stars (ecc 0.1) plus one trailed outlier (ecc 0.9):
        // the median is robust → 0.1, not pulled toward the outlier.
        let mut stars: Vec<DetectedStar> = (0..5)
            .map(|i| DetectedStar {
                x: i as f64,
                y: 0.0,
                flux: 1000.0 + i as f64,
                hfr: 2.0,
                fwhm: 4.0,
                peak: 5000.0,
                background: 100.0,
                snr: 50.0,
                eccentricity: 0.1,
                sharpness: 0.3,
            })
            .collect();
        stars.push(DetectedStar {
            x: 99.0,
            y: 0.0,
            flux: 2000.0,
            hfr: 2.0,
            fwhm: 4.0,
            peak: 9000.0,
            background: 100.0,
            snr: 80.0,
            eccentricity: 0.9,
            sharpness: 0.3,
        });
        let ecc = frame_eccentricity(&stars).expect("six reliable stars → Some");
        assert!(
            (ecc - 0.1).abs() < 1e-9,
            "median should reject the single trailed outlier, got {}",
            ecc
        );
    }

    #[test]
    fn frame_eccentricity_rejects_hot_pixels_by_hfr_floor() {
        // Five "hot pixels": positive flux but sub-0.5px HFR. They must not
        // count toward the reliable-star floor, so the result is None.
        let stars: Vec<DetectedStar> = (0..5)
            .map(|i| DetectedStar {
                x: i as f64,
                y: 0.0,
                flux: 1000.0,
                hfr: 0.3,
                fwhm: 0.6,
                peak: 5000.0,
                background: 100.0,
                snr: 50.0,
                eccentricity: 0.05,
                sharpness: 0.99,
            })
            .collect();
        assert_eq!(frame_eccentricity(&stars), None);
    }

    /// Render a whole field of identically-trailed elliptical Gaussians.
    ///
    /// Wind shake or a dropped guide correction smears *every* star in the
    /// frame along the same axis — a single elongated blob among round stars
    /// is a cosmic ray, which is a different (and correctly filtered) thing.
    fn render_trailed_field_u16(
        width: u32,
        height: u32,
        centers: &[(f64, f64)],
        sigma_major: f64,
        sigma_minor: f64,
    ) -> ImageData {
        const BACKGROUND: f64 = 1000.0;
        const PEAK: f64 = 30000.0;
        let mut data = vec![BACKGROUND as u16; (width * height) as usize];
        let two_sx_sq = 2.0 * sigma_major * sigma_major;
        let two_sy_sq = 2.0 * sigma_minor * sigma_minor;
        for y in 0..height {
            for x in 0..width {
                let mut v = BACKGROUND;
                for &(cx, cy) in centers {
                    let dx = x as f64 - cx;
                    let dy = y as f64 - cy;
                    v += PEAK * (-(dx * dx) / two_sx_sq - (dy * dy) / two_sy_sq).exp();
                }
                data[(y * width + x) as usize] = v.clamp(0.0, 65535.0) as u16;
            }
        }
        ImageData::from_u16(width, height, 1, &data)
    }

    fn trailed_field_centers() -> Vec<(f64, f64)> {
        (0..8)
            .map(|i| (40.0 + (i % 4) as f64 * 60.0, 40.0 + (i / 4) as f64 * 60.0))
            .collect()
    }

    #[test]
    fn trailed_field_stays_measurable_under_the_production_default_config() {
        // 2.5:1 smear — analytic e = √(1 − (2.4/6.0)²) = 0.917. That is a bad
        // gust or a dropped guide correction, not a satellite streak, and it
        // is the frame the grading gate exists to cull.
        //
        // The config here is deliberately `default()`, not a loosened test
        // config: it is verbatim what `real_device_ops` /
        // `unified_device_ops` hand to `detect_stars` before calling
        // `frame_eccentricity`. A 0.7 detection ceiling discards every one of
        // these stars, the frame reports zero stars, and the median
        // eccentricity comes back `None` = "unknown, don't reject".
        let (sigma_major, sigma_minor) = (6.0_f64, 2.4_f64);
        let image =
            render_trailed_field_u16(280, 160, &trailed_field_centers(), sigma_major, sigma_minor);
        let stars = detect_stars(&image, &StarDetectionConfig::default());

        assert!(
            stars.len() >= MIN_STARS_FOR_FRAME_ECCENTRICITY,
            "a trailed star field must still be detectable, got {} stars",
            stars.len()
        );
        let ecc = frame_eccentricity(&stars)
            .expect("a trailed field must yield a measurable eccentricity, not None");
        assert!(
            ecc > 0.8,
            "a 2.5:1 trail must measure above every plausible grading threshold, got {:.3}",
            ecc
        );
        // And it must be the *physical* value, not merely "some number above
        // 0.8" — a measurement pinned near the ceiling would be just as
        // uninformative as one pinned below it.
        let analytic = (1.0 - (sigma_minor / sigma_major).powi(2)).sqrt();
        assert!(
            (ecc - analytic).abs() < 0.05,
            "measured {:.3} should track the analytic axis-ratio eccentricity {:.3}",
            ecc,
            analytic
        );
    }

    #[test]
    fn satellite_streak_is_still_culled_by_the_detection_ceiling() {
        // The detection ceiling still has to do its original job. A 10:1
        // source (analytic e = 0.995) is a cosmic ray or a satellite trail,
        // never a star, and must not be admitted as one — otherwise raising
        // the ceiling would just trade a false pass for a false reject.
        let image = render_elliptical_gaussian_u16(160, 64, 80.0, 32.0, 20.0, 2.0);
        let stars = detect_stars(&image, &StarDetectionConfig::default());
        assert!(
            stars.is_empty(),
            "a 10:1 streak must not be admitted as a star, got {} (ecc {:?})",
            stars.len(),
            stars.first().map(|s| s.eccentricity)
        );
    }

    /// One elliptical Gaussian source: (cx, cy, σ_major, σ_minor, peak).
    ///
    /// Unlike [`render_trailed_field_u16`] every source carries its own shape
    /// and brightness, which is what a real frame looks like when the mount is
    /// misbehaving on only some sources (a passing satellite, a blended
    /// double) or when everything trails but the operator still has round
    /// stars from an earlier part of the field.
    type Source = (f64, f64, f64, f64, f64);

    fn render_sources_u16(width: u32, height: u32, sources: &[Source]) -> ImageData {
        const BACKGROUND: f64 = 1000.0;
        let mut data = vec![BACKGROUND as u16; (width * height) as usize];
        for y in 0..height {
            for x in 0..width {
                let mut v = BACKGROUND;
                for &(cx, cy, sx, sy, peak) in sources {
                    let dx = x as f64 - cx;
                    let dy = y as f64 - cy;
                    v += peak * (-(dx * dx) / (2.0 * sx * sx) - (dy * dy) / (2.0 * sy * sy)).exp();
                }
                data[(y * width + x) as usize] = v.clamp(0.0, 65535.0) as u16;
            }
        }
        ImageData::from_u16(width, height, 1, &data)
    }

    /// A grid of round stars, optionally with the same grid of trailed
    /// sources offset below it. Trailed sources are given the HIGHER peak so
    /// they sort to the front by flux — if the selection filter is not doing
    /// its job they, not the round stars, are what a consumer picks up.
    fn mixed_round_and_trailed_field(include_trailed: bool) -> ImageData {
        let mut sources: Vec<Source> = (0..8)
            .map(|i| {
                (
                    40.0 + (i % 4) as f64 * 60.0,
                    40.0 + (i / 4) as f64 * 60.0,
                    2.5,
                    2.5,
                    20000.0,
                )
            })
            .collect();
        if include_trailed {
            sources.extend((0..8).map(|i| {
                (
                    40.0 + (i % 4) as f64 * 60.0,
                    180.0 + (i / 4) as f64 * 60.0,
                    6.0,
                    2.4,
                    30000.0,
                )
            }));
        }
        render_sources_u16(280, 300, &sources)
    }

    #[test]
    fn guide_star_selection_skips_the_brightest_smear() {
        // Verbatim the guide-frame path: `builtin_guider::capture_guide_frame`
        // calls `detect_stars_with_stats(&image, &StarDetectionConfig::default())`
        // and then takes the brightest entry of `summary.stars` as the guide
        // star. Widening the *detection* ceiling to 0.95 so grading could
        // measure trailing also let a 2.5:1 smear — brighter than every round
        // star in the frame — become the thing the mount chases. A smear's
        // centroid slides along its major axis, so guiding on it injects the
        // very error it is supposed to correct.
        let image = mixed_round_and_trailed_field(true);
        let summary = detect_stars_with_stats(&image, &StarDetectionConfig::default());

        let mut stars = summary.stars.clone();
        stars.sort_by(|a, b| b.flux.total_cmp(&a.flux));
        let guide_star = stars
            .first()
            .expect("round stars are present, so a guide star must be selectable");

        assert!(
            guide_star.eccentricity <= SELECTION_MAX_ECCENTRICITY,
            "the guider must not lock onto a smear: picked ecc {:.3} (> {:.2}) from {} usable stars",
            guide_star.eccentricity,
            SELECTION_MAX_ECCENTRICITY,
            summary.star_count
        );

        // The smear was still *seen* — it is excluded from selection, not
        // erased from the frame. Reporting it as absent would be the same
        // class of lie in the other direction.
        assert!(
            summary.detected_star_count > summary.star_count,
            "the trailed sources must be measured and then excluded, not undetected \
             (detected {}, usable {})",
            summary.detected_star_count,
            summary.star_count
        );
    }

    #[test]
    fn trailed_field_is_measurable_but_yields_no_usable_stars() {
        // The two answers, from one call, on the frame that forced the
        // detection ceiling open in the first place. Grading needs the shape
        // (`median_eccentricity` above every plausible threshold); selection
        // needs to say "nothing here is round enough to work with" without
        // claiming the frame is empty.
        let image = render_trailed_field_u16(280, 160, &trailed_field_centers(), 6.0_f64, 2.4_f64);
        let summary = detect_stars_with_stats(&image, &StarDetectionConfig::default());

        let ecc = summary
            .median_eccentricity
            .expect("a trailed field must still yield a measurable eccentricity");
        assert!(
            ecc > 0.8,
            "shape measurement must survive the selection filter, got {:.3}",
            ecc
        );
        assert!(
            summary
                .stars
                .iter()
                .all(|s| s.eccentricity <= SELECTION_MAX_ECCENTRICITY),
            "no smear may be handed out as a usable star"
        );
        assert!(
            summary.detected_star_count >= MIN_STARS_FOR_FRAME_ECCENTRICITY as u32,
            "the sources were detected, got {}",
            summary.detected_star_count
        );
    }

    #[test]
    fn median_hfr_is_not_inflated_by_trailed_sources() {
        // HFR is the focus metric the sequencer compares against its baseline
        // and its autofocus trigger. A trail's half-flux radius is inflated by
        // the trail, so measuring HFR over the permissive detection population
        // makes a windy night read as focus drift — and the sequencer answers
        // focus drift by burning exposures on an autofocus run that cannot fix
        // trailing. The trailed sources here are the BRIGHTEST in the frame,
        // so they dominate the brightest-50% window `calculate_median_hfr`
        // uses unless they are filtered out.
        let round_only = calculate_median_hfr(&mixed_round_and_trailed_field(false))
            .expect("round field must yield an HFR");
        let with_trails = calculate_median_hfr(&mixed_round_and_trailed_field(true))
            .expect("adding trailed sources must not make the frame unmeasurable");

        let drift = (with_trails - round_only).abs() / round_only;
        assert!(
            drift < 0.15,
            "HFR must track focus, not trailing: {:.3} px with trails vs {:.3} px without \
             ({:.0}% drift)",
            with_trails,
            round_only,
            drift * 100.0
        );
    }

    /// Field-for-field what `api_detect_stars_in_file` builds from
    /// `StarDetectionConfigApi::default()` before calling
    /// `detect_stars_with_stats` — the manual FITS star-analysis screen's
    /// production config. Its `max_eccentricity` is still 0.7 (that struct
    /// lives in the bridge crate and carries its own default), which is the
    /// whole point of the test below.
    fn fits_analysis_screen_default_config() -> StarDetectionConfig {
        StarDetectionConfig {
            detection_sigma: 5.0,
            min_area: 9,
            max_area: 10000,
            max_eccentricity: 0.7,
            saturation_limit: 60000,
            hfr_radius: 20,
            min_hfr: 1.0,
            min_snr: 5.0,
            max_sharpness: 0.95,
            noise_model: None,
        }
    }

    #[test]
    fn shape_stays_measurable_for_a_caller_whose_own_ceiling_is_the_threshold() {
        // The self-blinding bug, one level up: a caller may hand in its own
        // eccentricity ceiling, and if the shape statistic is measured from a
        // population already filtered at that ceiling it can never report a
        // value above it. Widening only the DETECTION default fixed the
        // sequencer's grading path and left this one exactly as broken —
        // `StarDetectionConfigApi::default()` still says 0.7, so the FITS
        // analysis screen reported a 2.5:1 smear as e <= 0.70 (or, once every
        // star was culled, as no stars at all).
        let config = fits_analysis_screen_default_config();
        let image = render_trailed_field_u16(280, 160, &trailed_field_centers(), 6.0_f64, 2.4_f64);
        let summary = detect_stars_with_stats(&image, &config);

        let ecc = summary.median_eccentricity.expect(
            "a caller-supplied ceiling must not blind the shape statistic to a trailed frame",
        );
        let analytic = (1.0_f64 - (2.4_f64 / 6.0_f64).powi(2)).sqrt();
        assert!(
            (ecc - analytic).abs() < 0.05,
            "measured {:.3} must track the physical eccentricity {:.3}, not the caller's \
             {:.2} ceiling",
            ecc,
            analytic,
            config.max_eccentricity
        );

        // The caller's ceiling is still honoured for what it gets handed back:
        // widening the measurement pass must not smuggle smears into the star
        // list a consumer works from.
        assert!(
            summary
                .stars
                .iter()
                .all(|s| s.eccentricity <= config.max_eccentricity),
            "the caller asked for stars rounder than {:.2} and must get exactly that",
            config.max_eccentricity
        );
        assert!(
            summary.detected_star_count >= MIN_STARS_FOR_FRAME_ECCENTRICITY as u32,
            "the trailed sources must be measured, got {}",
            summary.detected_star_count
        );
    }

    /// Field-for-field what `api_detect_stars_in_file` builds from the
    /// `StarDetectionConfigApi` that `DefaultScienceBackend.measureStars`
    /// sends (default_science_backend.dart:107-117 with the default
    /// `PhotometryOptions`: `apertureRadiusPixels: 6`, `minSnr: 4.0`).
    ///
    /// This is the science pipeline's own detector config, and it asks for
    /// `max_eccentricity: 0.95` **on purpose** — everything downstream of it
    /// (the PSF field map and its `medianEccentricity` / `roundness` tiles,
    /// photometry, astrometric residuals, transient search) is measuring the
    /// shape of the field, not picking stars to work with.
    fn science_pipeline_config() -> StarDetectionConfig {
        StarDetectionConfig {
            detection_sigma: 4.0,
            min_area: 4,
            max_area: 1024,
            max_eccentricity: 0.95,
            saturation_limit: 60000,
            hfr_radius: 6,
            min_hfr: 0.6,
            min_snr: 4.0,
            max_sharpness: 100.0,
            noise_model: None,
        }
    }

    #[test]
    fn a_caller_that_widened_the_ceiling_to_measure_the_field_still_gets_its_stars() {
        // Applying the working-star ceiling to `stars` is what restored the
        // guider — but `stars` was also the only list this function handed
        // back, so it silently narrowed a caller who had deliberately asked
        // for 0.95 down to 0.7. That is the original defect relocated: a
        // shape measurement clipped at a threshold cannot report a value
        // above that threshold. The casualty was the whole science pipeline
        // (`DefaultScienceBackend.measureStars`), including the PSF-tile
        // eccentricity that `FrameAutoGrader` grades frames on — so a
        // `maxEccentricity` rule above 0.7 became un-fireable again, on the
        // persisted grading path this time.
        let config = science_pipeline_config();
        let image = mixed_round_and_trailed_field(true);
        let summary = detect_stars_with_stats(&image, &config);

        assert!(
            summary
                .sources
                .iter()
                .any(|s| s.eccentricity > SELECTION_MAX_ECCENTRICITY),
            "a caller asking for e <= {:.2} must get the trailed sources back; \
             got {} sources, max ecc {:?}",
            config.max_eccentricity,
            summary.sources.len(),
            summary
                .sources
                .iter()
                .map(|s| s.eccentricity)
                .fold(f64::NEG_INFINITY, f64::max)
        );

        // ...and no further than it asked. `sources` is the caller's ceiling
        // verbatim, not the widened measurement pass leaking through.
        assert!(
            summary
                .sources
                .iter()
                .all(|s| s.eccentricity <= config.max_eccentricity),
            "sources must honour the caller's ceiling exactly, not exceed it"
        );

        // The guider fix is untouched: `stars` is still the round-only list.
        assert!(
            summary
                .stars
                .iter()
                .all(|s| s.eccentricity <= SELECTION_MAX_ECCENTRICITY),
            "widening `sources` must not put smears back into the working set"
        );
        assert!(
            summary.sources.len() > summary.stars.len(),
            "the two populations must actually differ on this frame \
             (sources {}, stars {})",
            summary.sources.len(),
            summary.stars.len()
        );
    }

    #[test]
    fn sources_honours_a_caller_that_asked_for_a_tight_ceiling() {
        // The other direction: `sources` is "what you asked for", so the FITS
        // analysis screen's 0.7 config must NOT receive the widened
        // measurement population. Only `median_eccentricity` is allowed to
        // see past the caller's ceiling, because that is a statement about the
        // frame rather than a list of stars the caller will work with.
        let config = fits_analysis_screen_default_config();
        let image = mixed_round_and_trailed_field(true);
        let summary = detect_stars_with_stats(&image, &config);

        assert!(
            summary
                .sources
                .iter()
                .all(|s| s.eccentricity <= config.max_eccentricity),
            "a caller that asked for e <= {:.2} must not be handed smears",
            config.max_eccentricity
        );
        assert!(
            summary.detected_star_count as usize > summary.sources.len(),
            "the smears must still have been measured for the shape statistic \
             (detected {}, sources {})",
            summary.detected_star_count,
            summary.sources.len()
        );
    }

    #[test]
    fn selection_respects_a_caller_that_asks_for_rounder_stars() {
        // The selection ceiling is a floor on strictness, not an override: a
        // config that deliberately asks for rounder stars than 0.7 (the PSF
        // and mask configs do) must keep its own, tighter answer.
        let image = mixed_round_and_trailed_field(true);
        let strict = StarDetectionConfig {
            max_eccentricity: 0.05,
            ..StarDetectionConfig::default()
        };
        assert!(
            detect_stars_for_selection(&image, &strict)
                .iter()
                .all(|s| s.eccentricity <= 0.05),
            "a caller-supplied ceiling tighter than SELECTION_MAX_ECCENTRICITY must win"
        );
    }

    #[test]
    fn snr_uses_ccd_equation_in_adu_domain_when_no_camera_model() {
        // signal=1000 ADU, n_pix=10, bg_noise=2 ADU.
        // Standard CCD eq in ADU domain: signal / sqrt(signal + n_pix·noise²).
        // = 1000 / sqrt(1000 + 10·4) = 1000 / sqrt(1040).
        let snr = compute_snr(1000.0, 10.0, 2.0, None);
        let expected = 1000.0 / (1040.0_f64).sqrt();
        assert!((snr - expected).abs() < 1e-9);
    }

    #[test]
    fn snr_uses_full_ccd_equation_with_camera_model() {
        // signal=1000 ADU, n_pix=10, bg_noise=2 ADU, gain=1 e/ADU,
        // read=3 e, dark=0.5 e/s, exposure=10s ⇒ dark=5 e.
        // electrons: signal_e=1000, sky_var_e²=4, read²=9, dark=5
        // SNR = 1000 / sqrt(1000 + 10·(4+9+5)) = 1000 / sqrt(1180).
        let model = CameraNoiseModel {
            gain_e_per_adu: 1.0,
            read_noise_e: 3.0,
            dark_e_per_sec: 0.5,
            exposure_s: 10.0,
        };
        let snr = compute_snr(1000.0, 10.0, 2.0, Some(&model));
        let expected = 1000.0 / (1180.0_f64).sqrt();
        assert!(
            (snr - expected).abs() < 1e-9,
            "got {} expected {}",
            snr,
            expected
        );
    }

    #[test]
    fn snr_returns_zero_for_invalid_inputs() {
        assert_eq!(compute_snr(0.0, 10.0, 2.0, None), 0.0);
        assert_eq!(compute_snr(100.0, 0.0, 2.0, None), 0.0);
    }

    // Visited mask is the star aperture, not the search window.

    /// Render `n` Gaussian PSFs at the supplied (cx, cy) coordinates.
    fn render_multi_gaussian_u16(
        width: u32,
        height: u32,
        centers: &[(f64, f64)],
        sigma: f64,
    ) -> ImageData {
        const BACKGROUND: f64 = 1000.0;
        const PEAK: f64 = 30000.0;
        let mut data = vec![BACKGROUND as u16; (width * height) as usize];
        let two_sigma_sq = 2.0 * sigma * sigma;
        for y in 0..height {
            for x in 0..width {
                let mut v = BACKGROUND;
                for &(cx, cy) in centers {
                    let dx = x as f64 - cx;
                    let dy = y as f64 - cy;
                    let r2 = dx * dx + dy * dy;
                    v += PEAK * (-r2 / two_sigma_sq).exp();
                }
                data[(y * width + x) as usize] = v.clamp(0.0, 65535.0) as u16;
            }
        }
        ImageData::from_u16(width, height, 1, &data)
    }

    /// `sigma = FWHM / (2·√(2 ln 2))` — the standard Gaussian conversion.
    fn sigma_for_fwhm(fwhm: f64) -> f64 {
        fwhm / (2.0 * (2.0_f64 * 2.0_f64.ln()).sqrt())
    }

    fn detection_config_for_aperture_tests() -> StarDetectionConfig {
        StarDetectionConfig {
            // Lower min_area: small (FWHM=4) Gaussians can have ~10–20
            // pixels above background; we want both stars detected.
            min_area: 5,
            min_hfr: 0.5,
            min_snr: 1.0,
            max_sharpness: 1.0,
            // Default hfr_radius=20: a square visited-stamp would be a 41×41
            // forbidden zone after each detection, hiding stars 25 px apart.
            hfr_radius: 20,
            ..Default::default()
        }
    }

    /// Two stars 25 px apart with FWHM=4 must both be detected: visited is
    /// stamped only over the HFR-derived disk (≈ 5 px radius), where a full
    /// 41×41 search-window stamp hides the second star.
    #[test]
    fn two_neighbouring_stars_are_both_detected() {
        let fwhm = 4.0;
        let sigma = sigma_for_fwhm(fwhm);
        let centers = [(30.0, 32.0), (55.0, 32.0)]; // 25 px apart
        let image = render_multi_gaussian_u16(96, 64, &centers, sigma);

        let config = detection_config_for_aperture_tests();
        let stars = detect_stars(&image, &config);

        assert!(
            stars.len() >= 2,
            "expected ≥2 stars for two PSFs 25 px apart, got {} ({:?})",
            stars.len(),
            stars.iter().map(|s| (s.x, s.y)).collect::<Vec<_>>()
        );

        // Each expected centre should have a detection within ~2 px.
        for &(cx, cy) in &centers {
            let matched = stars.iter().any(|s| (s.x - cx).hypot(s.y - cy) < 2.0);
            assert!(
                matched,
                "no detection within 2 px of expected centre ({cx}, {cy}); detections = {:?}",
                stars.iter().map(|s| (s.x, s.y)).collect::<Vec<_>>()
            );
        }
    }

    /// Three stars in a row 30 px apart must all be detected.
    #[test]
    fn three_neighbouring_stars_are_all_detected_after_aperture_visited_fix() {
        let fwhm = 4.0;
        let sigma = sigma_for_fwhm(fwhm);
        let centers = [(20.0, 32.0), (50.0, 32.0), (80.0, 32.0)]; // 30 px spacing
        let image = render_multi_gaussian_u16(120, 64, &centers, sigma);

        let config = detection_config_for_aperture_tests();
        let stars = detect_stars(&image, &config);

        assert!(
            stars.len() >= 3,
            "expected ≥3 stars for three PSFs 30 px apart, got {} ({:?})",
            stars.len(),
            stars.iter().map(|s| (s.x, s.y)).collect::<Vec<_>>()
        );

        for &(cx, cy) in &centers {
            let matched = stars.iter().any(|s| (s.x - cx).hypot(s.y - cy) < 2.0);
            assert!(
                matched,
                "no detection within 2 px of expected centre ({cx}, {cy})"
            );
        }
    }

    /// A single PSF must be detected exactly once — the visited disk
    /// (even at minimum radius) must cover the star itself so the outer
    /// loop does not re-trigger on neighbouring pixels of the same
    /// detection.
    #[test]
    fn single_star_is_not_self_redetected() {
        let sigma = sigma_for_fwhm(4.0);
        let image = render_multi_gaussian_u16(64, 64, &[(32.0, 32.0)], sigma);

        let config = detection_config_for_aperture_tests();
        let stars = detect_stars(&image, &config);

        assert_eq!(
            stars.len(),
            1,
            "single PSF should produce exactly one detection, got {} ({:?})",
            stars.len(),
            stars.iter().map(|s| (s.x, s.y)).collect::<Vec<_>>()
        );
    }

    /// A saturated PSF whose encircled-energy HFR exceeds the search
    /// window must NOT mask the entire frame: the visited disk is
    /// capped at `hfr_radius`, so a faint star just outside that cap
    /// remains detectable.
    ///
    /// We directly exercise `stamp_visited_disk` plus the cap formula
    /// rather than running `detect_stars` end-to-end. End-to-end is
    /// the wrong test surface here: a saturated PSF wide enough to
    /// report `HFR > hfr_radius` also dominates global background
    /// estimation, which interferes with detection thresholds and
    /// muddies the unit-test signal. The post-HFR cap behaviour is
    /// what matters — and it is a pure function of the formula.
    #[test]
    fn saturated_psf_visited_disk_is_capped_at_hfr_radius() {
        let width = 200usize;
        let height = 100usize;
        let mut visited = vec![false; width * height];
        let pixels = vec![0.0; width * height];
        let config = StarDetectionConfig {
            hfr_radius: 20,
            ..StarDetectionConfig::default()
        };
        let mut ctx = StarMeasurementContext {
            pixels: &pixels,
            width,
            height,
            background: 0.0,
            noise: 1.0,
            config: &config,
            visited: &mut visited,
        };

        // Simulate a saturated/extended detection: HFR = 100 px (way
        // larger than hfr_radius = 20). The cap formula is
        // `min(2·HFR, hfr_radius).max(1)` = `min(200, 20)` = 20.
        let hfr: f64 = 100.0;
        let radius_f = config.hfr_radius as f64;
        let visited_radius = (2.0 * hfr).min(radius_f).max(1.0);
        assert_eq!(
            visited_radius, 20.0,
            "cap formula must yield hfr_radius, not 2·HFR, when HFR is huge"
        );

        let centre = (50.0, 50.0);
        stamp_visited_disk(&mut ctx, centre.0, centre.1, visited_radius);

        // Inside the cap (≤ 20 px from centre): marked.
        assert!(visited[50 * width + 50], "centre must be marked");
        assert!(visited[50 * width + 70], "(70, 50) at r=20 must be marked");

        // Just outside the cap (> 20 px from centre): NOT marked. This
        // is the property under test: a saturated detection with
        // unbounded HFR still leaves the rest of the frame available
        // for further star detection.
        let far_point_idx = 50 * width + 75; // (75, 50): 25 px from centre
        assert!(
            !visited[far_point_idx],
            "(75, 50) at r=25 (>cap) must NOT be marked — the cap protects far-field stars"
        );
        // A pixel at the opposite end of the wide image: well outside.
        assert!(!visited[50 * width + 180]);
        // And a corner-ish pixel.
        assert!(!visited[10 * width + 100]);
    }

    /// `stamp_visited_disk` marks pixels inside the disk and leaves
    /// pixels outside untouched.
    #[test]
    fn stamp_visited_disk_marks_disk_pixels_only() {
        let width = 21usize;
        let height = 21usize;
        let mut visited = vec![false; width * height];
        let pixels = vec![0.0; width * height];
        let config = StarDetectionConfig::default();
        let mut ctx = StarMeasurementContext {
            pixels: &pixels,
            width,
            height,
            background: 0.0,
            noise: 1.0,
            config: &config,
            visited: &mut visited,
        };

        let cx = 10.0_f64;
        let cy = 10.0_f64;
        let r = 4.0_f64;
        stamp_visited_disk(&mut ctx, cx, cy, r);

        // Inside-the-disk pixel: (10, 10) — the centre.
        assert!(visited[10 * width + 10]);
        // Inside-the-disk pixel at r=4 exactly (10+4, 10).
        assert!(visited[10 * width + 14]);
        // Outside-the-disk pixel: (10+5, 10) — distance 5 > 4.
        assert!(!visited[10 * width + 15]);
        // Outside-the-disk corner: (10+4, 10+4) — distance √32 ≈ 5.66 > 4.
        assert!(!visited[14 * width + 14]);
        // Inside on the diagonal: (10+2, 10+2) — distance √8 ≈ 2.83 < 4.
        assert!(visited[12 * width + 12]);
    }

    /// The sharpness filter must discriminate stars from hot pixels, not
    /// reject everything.
    ///
    /// A `sharpness` of `peak / mean_flux_per_pixel` exceeds 1 for any peaked
    /// source and clamps to exactly 1.0 — above the 0.95 default — so
    /// `detect_stars_with_stats` returns ZERO stars for real star fields.
    /// Downstream that reads as "Insufficient stars detected. Only 0 stars
    /// found (minimum: 10)" from autofocus, no HFR for grading, and nothing
    /// for the HFR / focus-drift triggers to measure.
    #[test]
    fn sharpness_passes_a_star_and_rejects_a_hot_pixel() {
        const W: usize = 120;
        const H: usize = 120;
        const BG: u16 = 300;

        // A Gaussian star: flux spread over its PSF.
        let mut star = vec![BG; W * H];
        let (cx, cy, sigma, amp) = (60.0f64, 60.0f64, 2.0f64, 20_000.0f64);
        for y in 0..H {
            for x in 0..W {
                let r_sq = (x as f64 - cx).powi(2) + (y as f64 - cy).powi(2);
                let v = amp * (-r_sq / (2.0 * sigma * sigma)).exp();
                if v >= 1.0 {
                    star[y * W + x] = star[y * W + x].saturating_add(v as u16);
                }
            }
        }
        let image = ImageData::from_u16(W as u32, H as u32, 1, &star);
        let found = detect_stars_with_stats(&image, &StarDetectionConfig::default());
        assert_eq!(
            found.stars.len(),
            1,
            "a clean Gaussian star must be detected under the DEFAULT config"
        );
        let sharpness = found.stars[0].sharpness;
        assert!(
            sharpness > 0.0 && sharpness < 0.6,
            "a star spreads its flux, so sharpness {sharpness} should be well              below the 0.95 hot-pixel bar"
        );

        // A single hot pixel: all of its flux in one pixel. It must NOT be
        // reported as a star — here via the area floor, and its sharpness must
        // sit at the top of the range rather than in star territory.
        let mut hot = vec![BG; W * H];
        hot[60 * W + 60] = 40_000;
        let hot_image = ImageData::from_u16(W as u32, H as u32, 1, &hot);
        let hot_found = detect_stars_with_stats(&hot_image, &StarDetectionConfig::default());
        assert!(
            hot_found.stars.is_empty(),
            "a lone hot pixel must not be reported as a star"
        );
    }
}
