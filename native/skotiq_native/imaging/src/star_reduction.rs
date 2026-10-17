//! Star-size reduction preview (Algo track).
//!
//! Bright stars dominate a deep-sky image visually: once nebulosity and faint
//! structure are stretched up, oversized stellar cores and their bloated halos
//! compete with the subject for attention. "Star reduction" is the standard
//! post-processing answer — PixInsight's *MorphologicalTransformation* (an
//! erosion confined to a star mask) and Russell Croman's *StarXTerminator* /
//! the classic *screen-and-residual* recipe are the two families practitioners
//! reach for. This module implements a **non-destructive, mask-confined**
//! preview of both: only pixels that fall inside a detected-star mask are
//! touched, and every pixel **outside** the mask is byte-identical to the
//! input. That invariant is what makes this safe to run as a live "preview"
//! over a calibrated linear or stretched frame without corrupting the
//! background, faint galaxies, or nebulosity the user actually came for.
//!
//! ## Algorithm
//!
//! 1. **Detect stars** with the crate's [`crate::detect_stars`] (the same
//!    detector the autofocus / grading paths use), giving a list of
//!    sub-pixel centres each with a measured HFR.
//! 2. **Build a soft star mask.** Each star contributes a feathered disk: a
//!    flat core out to a radius proportional to its HFR, then a smooth cosine
//!    feather out to `core + dilate + feather`. Disks are combined with a
//!    `max` (union) so overlapping stars merge cleanly. The result is a
//!    per-pixel weight in `[0, 1]`: `1` deep inside a star, `0` on clean
//!    background, fractional in the feather ring. This is the direct analogue
//!    of a *star mask* in PixInsight, dilated by `mask_dilate` so the halo
//!    just outside the photometric core is also reduced.
//! 3. **Compute a reduced plane** under one of two methods:
//!    * [`StarReduceMethod::MorphologicalErosion`] — a grayscale **erosion**
//!      (local minimum over a small structuring disk). Eroding a bright blob
//!      shrinks it from the edges inward, which is exactly the geometric
//!      operation that makes a star smaller. This is the operation
//!      PixInsight's *MorphologicalTransformation → Erosion* performs inside a
//!      star mask.
//!    * [`StarReduceMethod::ScreenedResidual`] — estimate a **star-free
//!      background** under each star with a local minimum/median filter,
//!      compute `residual = image − background` (the star's own light above
//!      the local floor), scale that residual *down* by `strength`, and
//!      recombine `background + residual·(1 − strength)`. Shrinking a star's
//!      excess-over-background lowers its peak and pulls its wings toward the
//!      floor, which both dims and tightens it. This is the "screen the stars,
//!      keep the residual, attenuate it" recipe.
//! 4. **Composite** the reduced plane back over the input using the mask weight
//!    *attenuated by `strength`*: `out = input·(1 − w·s) + reduced·(w·s)`. A
//!    pixel with mask weight `0` (clean background) keeps its **exact input
//!    bytes** — no float round-trip, no off-by-one — so the background is
//!    provably untouched. `strength = 0` is the identity transform.
//!
//! ## Limitations
//!
//! The geometric constants here — the core-radius multiple of HFR
//! ([`HFR_CORE_MULTIPLE`]), the feather width ([`DEFAULT_FEATHER_PX`]), the
//! erosion structuring radius ([`EROSION_RADIUS_PX`]), and the background
//! estimator window — are **defensible defaults in the spirit of the standard
//! tools, not values tuned against a corpus** of real images. They are sized
//! relative to the measured per-star HFR so they adapt to focal length /
//! seeing, but a power user would still want a UI knob for each. The detection
//! pass uses [`StarDetectionConfig::default`] with the star-mask-friendly
//! relaxations documented in [`reduce_stars`]; it is deliberately
//! conservative (it reduces what it is confident is a star and leaves
//! ambiguous compact structure alone). Detection runs on a per-pixel **max
//! across channels** so a star bright in only one channel (a blue or Hα-bright
//! star faint in red) still enters the mask — detecting on a single channel
//! could drop it and leave it at full size everywhere. The *reduction* methods
//! operate per channel independently, which is correct for mono and acceptable
//! for RGB previews but is *not* a colour-preserving star reduction — a
//! production path would reduce on luminance and re-apply the ratio to
//! chrominance. That is out of scope for this preview and noted here rather than
//! silently assumed.

use crate::{detect_stars, DetectedStar, ImageData, PixelType, StarDetectionConfig};
use rayon::prelude::*;

/// Core radius of a star's mask disk as a multiple of its measured HFR.
///
/// HFR is the half-flux radius (≈ 1.177σ for a Gaussian PSF); the visible
/// stellar disk after stretching extends to roughly 2–2.5×HFR (≈ 95% encircled
/// energy at ~2.08×HFR). `2.0` places the flat core of the mask just inside
/// that 95% radius so the bright body is fully covered while the faint wings
/// are handled by the feather. Defensible default, not corpus-tuned.
const HFR_CORE_MULTIPLE: f64 = 2.0;

/// Default cosine-feather width (px) added outside the dilated core.
///
/// A feathered (not hard-edged) mask is essential: a hard mask edge inside a
/// star's wings produces a visible ring artifact where the reduction stops.
/// Three pixels is the smallest feather that reliably hides the seam at typical
/// sampling; a defensible default, exposed implicitly through `mask_dilate`
/// which extends the core before the feather begins.
const DEFAULT_FEATHER_PX: f64 = 3.0;

/// Lower bound on a star's mask core radius (px) regardless of HFR.
///
/// Very tight stars (HFR ≈ 1) would otherwise get a sub-pixel core that the
/// erosion / residual operators cannot act on. One pixel guarantees the
/// operators have a neighbourhood to work with.
const MIN_CORE_RADIUS_PX: f64 = 1.0;

/// Structuring-element radius (px) for the grayscale erosion / local-min
/// background estimate.
///
/// The erosion local-minimum is taken over a disk of this radius. Two pixels
/// shrinks a star by a couple of pixels per pass without obliterating compact
/// structure; it matches the small structuring element a practitioner would
/// pick in *MorphologicalTransformation* for a gentle reduction. It is a
/// default, not a corpus-tuned value.
const EROSION_RADIUS_PX: i32 = 2;

/// Radius (px) of the local-minimum window used to estimate the star-free
/// background floor in [`StarReduceMethod::ScreenedResidual`].
///
/// This must be large enough to reach *past* the star's wings to genuinely
/// star-free pixels, so it is sized as a multiple of the mask core at call
/// time; this constant is the floor when a star is very small. Defensible
/// default.
const MIN_BACKGROUND_RADIUS_PX: i32 = 3;

/// How the per-star light is attenuated inside the star mask.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StarReduceMethod {
    /// Grayscale **morphological erosion**: replace each masked pixel by the
    /// local minimum over a small structuring disk, then blend toward that
    /// minimum by `strength`. Eroding a bright blob shrinks it from the edge
    /// inward — the geometric definition of making a star smaller. This is the
    /// *MorphologicalTransformation → Erosion* operation confined to a star
    /// mask.
    MorphologicalErosion,
    /// **Screened residual**: estimate a star-free background floor under each
    /// star (local minimum / median), take `residual = image − background`,
    /// scale the residual down by `strength`, and recombine
    /// `background + residual·(1 − strength)`. Attenuating a star's
    /// excess-over-background lowers its peak and tightens its wings.
    ScreenedResidual,
}

/// Configuration for [`reduce_stars`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StarReductionConfig {
    /// Reduction strength in `[0, 1]`. `0` is the identity transform (output is
    /// byte-identical to input); `1` applies the method at full intensity
    /// inside the mask. Intermediate values blend linearly. Values outside
    /// `[0, 1]` are a caller mistake and yield [`StarReduceError::BadStrength`].
    pub strength: f64,
    /// Which attenuation method to apply inside the mask.
    pub method: StarReduceMethod,
    /// Extra dilation (px) applied to each star's mask core before feathering,
    /// so the halo just outside the photometric core is reduced too. `2` is a
    /// gentle default; `0` confines the reduction to the measured core.
    pub mask_dilate: usize,
}

impl Default for StarReductionConfig {
    fn default() -> Self {
        Self {
            strength: 0.5,
            method: StarReduceMethod::ScreenedResidual,
            mask_dilate: 2,
        }
    }
}

/// Errors from [`reduce_stars`]. Every variant is a *caller* mistake the module
/// refuses to paper over (an empty frame, an out-of-range strength) — never a
/// silent best-effort reduction on bad input.
#[derive(Debug, thiserror::Error, PartialEq)]
pub enum StarReduceError {
    /// The image has zero width/height or no pixel data.
    #[error("image is empty (zero-sized or no pixel data)")]
    EmptyImage,
    /// `strength` was not a finite value in `[0, 1]`.
    #[error("strength must be a finite value in [0, 1]")]
    BadStrength,
}

/// Reduce the apparent size and brightness of detected stars, confined to a
/// soft star mask, leaving the background byte-identical to the input.
///
/// Supports `U16` and `F32` `ImageData` (mono or multi-channel; each channel is
/// processed independently — see the module-level "Limitations" note on
/// colour). Returns a new [`ImageData`] of the same dimensions and pixel type;
/// the input is never mutated.
///
/// ## Guarantees
///
/// * **Background untouched.** Any pixel whose star-mask weight is exactly `0`
///   is copied verbatim (byte-for-byte) from the input. There is no float
///   round-trip on background pixels, so background regions are provably
///   identical.
/// * **`strength = 0` is the identity.** The output equals the input exactly.
/// * **Bounded.** Reduced values are clamped to the channel's valid range
///   (`[0, 65535]` for `U16`; left in `f32` range for `F32`).
///
/// ## Errors
///
/// * [`StarReduceError::EmptyImage`] if the image is zero-sized / empty.
/// * [`StarReduceError::BadStrength`] if `strength` is not finite or lies
///   outside `[0, 1]`.
///
/// The star detector is run with [`StarDetectionConfig::default`] but with the
/// hot-pixel/area gates relaxed for mask building: we want a generous,
/// inclusive star mask (it is feathered and attenuated, so a marginal
/// inclusion is gentle), not the strict reliable-photometry set the grading
/// path wants.
pub fn reduce_stars(
    image: &ImageData,
    cfg: &StarReductionConfig,
) -> Result<ImageData, StarReduceError> {
    if image.is_empty() {
        return Err(StarReduceError::EmptyImage);
    }
    if !cfg.strength.is_finite() || !(0.0..=1.0).contains(&cfg.strength) {
        return Err(StarReduceError::BadStrength);
    }

    let width = image.width as usize;
    let height = image.height as usize;
    let channels = image.channels.max(1) as usize;
    let n = width.checked_mul(height).unwrap_or(0);
    if n == 0 {
        return Err(StarReduceError::EmptyImage);
    }

    // strength == 0 is the identity transform: return an exact clone. This also
    // short-circuits all the work below.
    if cfg.strength == 0.0 {
        return Ok(image.clone());
    }

    // Detection runs on a single luminance-like plane shared across channels
    // (stars are at the same *place* in every channel). For mono that is the image
    // itself; for multi-channel we synthesise a per-pixel **max across channels**
    // rather than using channel 0. Detecting on channel 0 (R for interleaved RGB)
    // would miss a star that is bright in green/blue but faint in red — it would
    // fall below the detector's SNR/area gate and never enter the mask, leaving it
    // at FULL size in every channel — the worst-case visible failure this
    // module otherwise works hard to avoid. The max keeps a star that is
    // bright in any single channel, which is the detectability-preserving choice.
    let detect_plane = luminance_plane_for_detection(image).ok_or(StarReduceError::EmptyImage)?;

    // Run detection on a U16 view of the luminance plane (the detector consumes
    // U16). We build that view directly from the plane so the detector sees the
    // same geometry regardless of the source pixel type.
    let detect_image = plane_to_u16_image(&detect_plane, image.width, image.height);
    let det_cfg = mask_detection_config();
    let stars = detect_stars(&detect_image, &det_cfg);

    // Build the soft star mask once (shared across channels).
    let mask = build_star_mask(&stars, width, height, cfg.mask_dilate);

    // Process each channel into its own f64 plane, then re-interleave.
    let mut out_planes: Vec<Vec<f64>> = Vec::with_capacity(channels);
    for c in 0..channels {
        let plane = extract_plane_f64(image, c).ok_or(StarReduceError::EmptyImage)?;
        let reduced = match cfg.method {
            StarReduceMethod::MorphologicalErosion => {
                erode_plane(&plane, width, height, EROSION_RADIUS_PX)
            }
            StarReduceMethod::ScreenedResidual => {
                screened_residual_plane(&plane, &stars, width, height, cfg.strength)
            }
        };
        // Composite: out = input·(1 − w·s) + reduced·(w·s). For erosion the
        // `reduced` plane is the eroded image and `strength` scales the blend
        // here. For screened-residual the strength is already folded into
        // `reduced`, so we blend by the mask weight alone (s = 1 in the blend)
        // to avoid double-applying it.
        let blend_strength = match cfg.method {
            StarReduceMethod::MorphologicalErosion => cfg.strength,
            StarReduceMethod::ScreenedResidual => 1.0,
        };
        let composited = composite_plane(&plane, &reduced, &mask, blend_strength);
        out_planes.push(composited);
    }

    Ok(write_planes(image, &out_planes, &mask, channels))
}

/// Star-detection config tuned for *mask building* (inclusive), not grading.
///
/// We relax the hot-pixel / sharpness / area gates so a generous set of stars
/// is collected: the mask is feathered and the reduction attenuated, so an
/// over-inclusive mask is gentle, whereas a star missed entirely is left at
/// full size (the visible failure mode). We keep the SNR / HFR floors modest so
/// genuine compact noise spikes are still excluded.
fn mask_detection_config() -> StarDetectionConfig {
    StarDetectionConfig {
        // Compact synthetic / well-focused stars concentrate flux; the default
        // 0.95 sharpness gate rejects them, which would empty the mask. Relax
        // it for mask building.
        max_sharpness: 1.0,
        // A modest minimum area keeps single hot pixels out while admitting
        // small real stars.
        min_area: 5,
        // Allow elongated stars into the mask — a trailed star still needs
        // reducing, and the mask is the place to be inclusive.
        max_eccentricity: 1.0,
        ..StarDetectionConfig::default()
    }
}

/// Build the single-plane luminance proxy the star detector runs on.
///
/// For a mono frame this is just the one channel. For a multi-channel frame it is
/// the **per-pixel maximum over channels**, not channel 0: a star can be bright in
/// one channel (a blue or Hα-bright star) yet faint in another, and detecting on a
/// single channel would drop it below the detector's gate and leave it at full
/// size everywhere. The max keeps any star that is bright in *any*
/// channel, which is exactly the detectability the mask needs (star *positions*
/// coincide across channels, so a max-plane detection masks them in all channels).
/// Returns `None` only if even channel 0 cannot be extracted (empty/unsupported).
fn luminance_plane_for_detection(image: &ImageData) -> Option<Vec<f64>> {
    let channels = image.channels.max(1) as usize;
    let mut lum = extract_plane_f64(image, 0)?;
    for c in 1..channels {
        let Some(plane) = extract_plane_f64(image, c) else {
            // A channel we cannot read is skipped rather than failing the whole
            // detection: the channels we do have still give a valid max proxy.
            continue;
        };
        for (l, &v) in lum.iter_mut().zip(plane.iter()) {
            if v > *l {
                *l = v;
            }
        }
    }
    Some(lum)
}

/// Extract channel `c` of `image` as an `f64` plane (`width × height`),
/// row-major. Returns `None` if the buffer is too small or the pixel type is
/// unsupported for reduction.
fn extract_plane_f64(image: &ImageData, c: usize) -> Option<Vec<f64>> {
    let width = image.width as usize;
    let height = image.height as usize;
    let channels = image.channels.max(1) as usize;
    let n = width.checked_mul(height)?;
    if c >= channels {
        return None;
    }
    match image.pixel_type {
        PixelType::U16 => {
            let bpp = 2;
            let stride = channels * bpp;
            if image.data.len() < n * stride {
                return None;
            }
            let mut plane = vec![0.0f64; n];
            plane.par_iter_mut().enumerate().for_each(|(i, out)| {
                let base = i * stride + c * bpp;
                *out = u16::from_le_bytes([image.data[base], image.data[base + 1]]) as f64;
            });
            Some(plane)
        }
        PixelType::F32 => {
            let bpp = 4;
            let stride = channels * bpp;
            if image.data.len() < n * stride {
                return None;
            }
            let mut plane = vec![0.0f64; n];
            plane.par_iter_mut().enumerate().for_each(|(i, out)| {
                let base = i * stride + c * bpp;
                *out = f32::from_le_bytes([
                    image.data[base],
                    image.data[base + 1],
                    image.data[base + 2],
                    image.data[base + 3],
                ]) as f64;
            });
            Some(plane)
        }
        _ => None,
    }
}

/// Build a `U16` mono [`ImageData`] from an `f64` plane (for the detector,
/// which consumes `U16`).
///
/// Integer/U16-scale planes (the common case, and what the U16 detector
/// thresholds are calibrated for) are passed through with a plain clamp so the
/// detector sees the native ADU values unchanged — zero behaviour change from
/// the original passthrough.
///
/// A **low-amplitude** plane (peak `< 256`), which is what a normalized F32
/// frame looks like — star structure lives in values like `[0.02, 0.82]` — is
/// instead **rescaled by its own [min, max]** to span the 16-bit range before
/// quantizing. Without this, the bare clamp would crush those values to 0/1 and
/// hide every star from the detector, so no stars would ever be reduced in an
/// F32 frame. Rescaling preserves the relative star/background contrast the
/// detector keys on regardless of the source's absolute scale (the same
/// luminance-synthesis idiom used by [`crate::background_extraction`]). The
/// `256` cutoff cleanly separates normalized-float frames (peak ≤ ~1) from any
/// real integer-ADU frame (whose stars are in the thousands), so genuine U16
/// data never takes the rescale path. A flat plane (`max == min`) maps to
/// all-zero, which correctly yields no detections.
fn plane_to_u16_image(plane: &[f64], width: u32, height: u32) -> ImageData {
    let (mut lo, mut hi) = (f64::INFINITY, f64::NEG_INFINITY);
    for &v in plane {
        if v.is_finite() {
            lo = lo.min(v);
            hi = hi.max(v);
        }
    }
    // U16-scale (or unknown but already wide-range) data: native passthrough.
    if !hi.is_finite() || hi >= 256.0 {
        let data: Vec<u16> = plane
            .par_iter()
            .map(|&v| v.clamp(0.0, 65535.0).round() as u16)
            .collect();
        return ImageData::from_u16(width, height, 1, &data);
    }
    // Degenerate / flat low-amplitude plane: nothing to detect.
    if !lo.is_finite() || hi <= lo {
        return ImageData::from_u16(width, height, 1, &vec![0u16; plane.len()]);
    }
    // Normalized-float plane: rescale [min, max] → [0, 60000]. The 60000 ceiling
    // (not 65535) keeps the brightest pixel at or below the detector's default
    // `saturation_limit` (60000), so a bright star core is NOT discarded as
    // saturated — matching the rescale target used by
    // [`crate::background_extraction`]'s luminance synthesis for the same reason.
    let inv_range = 1.0 / (hi - lo);
    let data: Vec<u16> = plane
        .par_iter()
        .map(|&v| {
            (((v - lo) * inv_range) * 60000.0)
                .clamp(0.0, 65535.0)
                .round() as u16
        })
        .collect();
    ImageData::from_u16(width, height, 1, &data)
}

/// Build a soft, feathered star mask in `[0, 1]` from detected stars.
///
/// Each star contributes a disk: weight `1` out to `core` (= HFR·multiple +
/// dilate, floored), then a raised-cosine feather from `1 → 0` across
/// `DEFAULT_FEATHER_PX`. Disks combine with `max` (union) so overlaps merge
/// without summing past `1`. The mask is built per-row in parallel.
fn build_star_mask(
    stars: &[DetectedStar],
    width: usize,
    height: usize,
    mask_dilate: usize,
) -> Vec<f32> {
    let mut mask = vec![0.0f32; width * height];
    if stars.is_empty() {
        return mask;
    }

    // Precompute per-star geometry: centre, core radius, outer (feather) radius.
    struct Disk {
        cx: f64,
        cy: f64,
        core: f64,
        outer: f64,
    }
    let dilate = mask_dilate as f64;
    let disks: Vec<Disk> = stars
        .iter()
        .map(|s| {
            let core = (s.hfr * HFR_CORE_MULTIPLE + dilate).max(MIN_CORE_RADIUS_PX);
            Disk {
                cx: s.x,
                cy: s.y,
                core,
                outer: core + DEFAULT_FEATHER_PX,
            }
        })
        .collect();

    // For each row, accumulate the max contribution of every disk that reaches
    // it. We only iterate disks whose vertical extent covers the row.
    mask.par_chunks_mut(width).enumerate().for_each(|(y, row)| {
        let yf = y as f64;
        for d in &disks {
            let dy = yf - d.cy;
            if dy.abs() > d.outer {
                continue;
            }
            // Horizontal half-extent of the outer disk at this row.
            let half = (d.outer * d.outer - dy * dy).max(0.0).sqrt();
            let x0 = ((d.cx - half).floor().max(0.0)) as usize;
            let x1 = ((d.cx + half).ceil().min((width - 1) as f64)) as usize;
            for (x, cell) in row.iter_mut().enumerate().take(x1 + 1).skip(x0) {
                let dx = x as f64 - d.cx;
                let r = (dx * dx + dy * dy).sqrt();
                let w = disk_weight(r, d.core, d.outer);
                if w > *cell {
                    *cell = w;
                }
            }
        }
    });

    mask
}

/// Raised-cosine feather weight for radius `r` given a flat `core` and an
/// `outer` (zero-crossing) radius. `1` for `r ≤ core`, `0` for `r ≥ outer`,
/// smooth cosine ramp in between.
#[inline]
fn disk_weight(r: f64, core: f64, outer: f64) -> f32 {
    if r <= core {
        1.0
    } else if r >= outer || outer <= core {
        0.0
    } else {
        let t = (r - core) / (outer - core); // 0 → 1 across the feather
                                             // Raised cosine: 1 at t=0, 0 at t=1, zero slope at both ends.
        (0.5 * (1.0 + (std::f64::consts::PI * t).cos())) as f32
    }
}

/// Grayscale morphological **erosion**: each output pixel is the minimum over a
/// disk of `radius` px centred on it (clamped at the borders). Eroding shrinks
/// bright blobs from the edge inward. Computed per-row in parallel.
fn erode_plane(plane: &[f64], width: usize, height: usize, radius: i32) -> Vec<f64> {
    let r = radius.max(1);
    let r_sq = (r * r) as f64;
    let mut out = vec![0.0f64; width * height];
    out.par_chunks_mut(width).enumerate().for_each(|(y, row)| {
        for (x, cell) in row.iter_mut().enumerate() {
            let mut min_v = f64::INFINITY;
            for dy in -r..=r {
                let yy = y as i32 + dy;
                if yy < 0 || yy >= height as i32 {
                    continue;
                }
                let dy_sq = (dy * dy) as f64;
                if dy_sq > r_sq {
                    continue;
                }
                let dx_max = (r_sq - dy_sq).sqrt().floor() as i32;
                let base = yy as usize * width;
                for dx in -dx_max..=dx_max {
                    let xx = x as i32 + dx;
                    if xx < 0 || xx >= width as i32 {
                        continue;
                    }
                    let v = plane[base + xx as usize];
                    if v < min_v {
                        min_v = v;
                    }
                }
            }
            *cell = if min_v.is_finite() {
                min_v
            } else {
                plane[y * width + x]
            };
        }
    });
    out
}

/// Screened-residual reduction plane.
///
/// For each star, estimate a star-free background floor via a local minimum
/// over a window sized to reach past the star's wings, then attenuate the
/// star's excess-over-floor by `strength`:
///
/// ```text
///     residual = image − background_floor
///     reduced  = background_floor + residual · (1 − strength)
/// ```
///
/// Pixels outside every star's influence keep the input value (the floor there
/// equals the image, residual ≈ 0, so `reduced ≈ image`). The composite step
/// then masks this so only star pixels are affected.
fn screened_residual_plane(
    plane: &[f64],
    stars: &[DetectedStar],
    width: usize,
    height: usize,
    strength: f64,
) -> Vec<f64> {
    // Background floor via a local-minimum erosion. The window must reach past
    // the typical star wing; size it from the median star core, floored.
    let radius = background_radius(stars);
    let floor = erode_plane(plane, width, height, radius);

    let keep = 1.0 - strength;
    let mut out = vec![0.0f64; width * height];
    out.par_iter_mut().enumerate().for_each(|(i, o)| {
        let bg = floor[i];
        let residual = plane[i] - bg;
        // Only attenuate positive excess (star light *above* the floor); a
        // negative residual (noise dip) is left alone so we never brighten.
        *o = if residual > 0.0 {
            bg + residual * keep
        } else {
            plane[i]
        };
    });
    out
}

/// Local-minimum window radius (px) for the background floor, derived from the
/// detected stars' HFR so it reaches past their wings.
fn background_radius(stars: &[DetectedStar]) -> i32 {
    if stars.is_empty() {
        return MIN_BACKGROUND_RADIUS_PX;
    }
    // Use a high HFR percentile so the window clears even the larger stars.
    let mut hfrs: Vec<f64> = stars
        .iter()
        .map(|s| s.hfr)
        .filter(|h| h.is_finite())
        .collect();
    if hfrs.is_empty() {
        return MIN_BACKGROUND_RADIUS_PX;
    }
    hfrs.sort_by(f64::total_cmp);
    let p = hfrs[(hfrs.len() * 9 / 10).min(hfrs.len() - 1)];
    // Reach to ~2.5×HFR (just past the 95% encircled-energy radius) plus a
    // pixel of margin.
    ((p * 2.5).ceil() as i32 + 1).max(MIN_BACKGROUND_RADIUS_PX)
}

/// Composite a `reduced` plane over the original `plane` using the star `mask`
/// attenuated by `strength`:
///
/// ```text
///     w   = mask · strength            (effective blend weight)
///     out = plane · (1 − w) + reduced · w
/// ```
///
/// When `w == 0` the original value is returned **exactly** (no arithmetic), so
/// background pixels are bit-preserved through the f64 stage.
fn composite_plane(plane: &[f64], reduced: &[f64], mask: &[f32], strength: f64) -> Vec<f64> {
    let mut out = vec![0.0f64; plane.len()];
    out.par_iter_mut().enumerate().for_each(|(i, o)| {
        let w = mask[i] as f64 * strength;
        if w <= 0.0 {
            *o = plane[i];
        } else {
            *o = plane[i] * (1.0 - w) + reduced[i] * w;
        }
    });
    out
}

/// Re-interleave processed `f64` planes into an [`ImageData`] of the same
/// dimensions and pixel type as `template`.
///
/// For background pixels (mask weight `0`) the **original input bytes** are
/// copied verbatim rather than re-encoding the plane value, guaranteeing the
/// background is byte-identical to the input regardless of float rounding.
fn write_planes(
    template: &ImageData,
    planes: &[Vec<f64>],
    mask: &[f32],
    channels: usize,
) -> ImageData {
    let mut out = template.clone();
    let n = (template.width as usize) * (template.height as usize);
    match template.pixel_type {
        PixelType::U16 => {
            let bpp = 2;
            let stride = channels * bpp;
            for i in 0..n {
                if mask[i] <= 0.0 {
                    // Background: leave the cloned input bytes untouched.
                    continue;
                }
                for (c, plane) in planes.iter().enumerate().take(channels) {
                    let v = plane[i].clamp(0.0, 65535.0).round() as u16;
                    let base = i * stride + c * bpp;
                    out.data[base..base + 2].copy_from_slice(&v.to_le_bytes());
                }
            }
        }
        PixelType::F32 => {
            let bpp = 4;
            let stride = channels * bpp;
            for i in 0..n {
                if mask[i] <= 0.0 {
                    continue;
                }
                for (c, plane) in planes.iter().enumerate().take(channels) {
                    let v = plane[i] as f32;
                    let base = i * stride + c * bpp;
                    out.data[base..base + 4].copy_from_slice(&v.to_le_bytes());
                }
            }
        }
        _ => {}
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Render a synthetic mono `U16` frame: a flat background plus round
    /// Gaussian stars of a known peak and σ on a coarse grid. Deterministic
    /// (no rng); the background is exactly `background` everywhere a star does
    /// not reach.
    fn synth_starfield(
        width: u32,
        height: u32,
        background: u16,
        star_peak: f64,
        star_sigma: f64,
        step: usize,
    ) -> ImageData {
        let w = width as usize;
        let h = height as usize;
        let mut data = vec![background; w * h];
        let two_sig_sq = 2.0 * star_sigma * star_sigma;
        // Truncate the Gaussian at 4σ so the background outside is exactly flat.
        let r = (4.0 * star_sigma).ceil() as i32;
        let mut sy = step;
        while sy + step < h {
            let mut sx = step;
            while sx + step < w {
                for dy in -r..=r {
                    for dx in -r..=r {
                        let x = sx as i32 + dx;
                        let y = sy as i32 + dy;
                        if x < 0 || y < 0 || x >= w as i32 || y >= h as i32 {
                            continue;
                        }
                        let rr = (dx * dx + dy * dy) as f64;
                        if rr > (r * r) as f64 {
                            continue;
                        }
                        let add = star_peak * (-rr / two_sig_sq).exp();
                        let idx = y as usize * w + x as usize;
                        data[idx] = (data[idx] as f64 + add).clamp(0.0, 65535.0) as u16;
                    }
                }
                sx += step;
            }
            sy += step;
        }
        ImageData::from_u16(width, height, 1, &data)
    }

    /// Read a single u16 pixel from a mono `ImageData`.
    fn px(image: &ImageData, x: usize, y: usize) -> u16 {
        let w = image.width as usize;
        let base = (y * w + x) * 2;
        u16::from_le_bytes([image.data[base], image.data[base + 1]])
    }

    /// Locate the brightest pixel (a star centre) in a mono u16 frame.
    fn brightest_pixel(image: &ImageData) -> (usize, usize, u16) {
        let w = image.width as usize;
        let h = image.height as usize;
        let mut best = (0usize, 0usize, 0u16);
        for y in 0..h {
            for x in 0..w {
                let v = px(image, x, y);
                if v > best.2 {
                    best = (x, y, v);
                }
            }
        }
        best
    }

    /// Encircled-energy "size" proxy: count of pixels above a fixed threshold
    /// over background within a window around a centre. A smaller star covers
    /// fewer above-threshold pixels.
    fn star_footprint(
        image: &ImageData,
        cx: usize,
        cy: usize,
        background: u16,
        win: usize,
    ) -> usize {
        let w = image.width as usize;
        let h = image.height as usize;
        let thresh = background as u32 + 200; // well above flat background
        let mut count = 0usize;
        let x0 = cx.saturating_sub(win);
        let y0 = cy.saturating_sub(win);
        let x1 = (cx + win).min(w - 1);
        let y1 = (cy + win).min(h - 1);
        for y in y0..=y1 {
            for x in x0..=x1 {
                if px(image, x, y) as u32 > thresh {
                    count += 1;
                }
            }
        }
        count
    }

    #[test]
    fn screened_residual_reduces_peak_and_size_while_background_is_exact() {
        let background = 1000u16;
        let input = synth_starfield(160, 160, background, 25000.0, 3.0, 40);
        let cfg = StarReductionConfig {
            strength: 0.7,
            method: StarReduceMethod::ScreenedResidual,
            mask_dilate: 2,
        };
        let out = reduce_stars(&input, &cfg).expect("reduction should succeed");

        // Find a star in the input and compare peak + footprint.
        let (cx, cy, peak_in) = brightest_pixel(&input);
        let peak_out = px(&out, cx, cy);
        assert!(
            (peak_out as f64) < (peak_in as f64),
            "star peak must drop: in={peak_in} out={peak_out}"
        );
        // The peak excess above background should shrink roughly in proportion
        // to (1 − strength). With strength 0.7 the residual is scaled to 0.3 of
        // its value, so the output excess must be well below the input excess.
        let excess_in = peak_in as f64 - background as f64;
        let excess_out = peak_out as f64 - background as f64;
        let ratio = excess_out / excess_in;
        assert!(
            ratio < 0.6,
            "peak excess should fall toward (1−strength)=0.3; got ratio {ratio:.3}"
        );

        // The star's footprint (above-threshold area) must shrink.
        let foot_in = star_footprint(&input, cx, cy, background, 12);
        let foot_out = star_footprint(&out, cx, cy, background, 12);
        assert!(
            foot_out < foot_in,
            "star footprint must shrink: in={foot_in} out={foot_out}"
        );

        // Background sample points far from any star must be byte-identical.
        // The grid step is 40 with stars at (40,40),(40,80)... so (5,5),(20,20)
        // and a few interior gaps are clean background.
        for &(bx, by) in &[(5usize, 5usize), (20, 20), (5, 100), (100, 5)] {
            assert_eq!(
                px(&out, bx, by),
                px(&input, bx, by),
                "background pixel ({bx},{by}) must be unchanged"
            );
        }
        // Stronger guarantee: every pixel the mask did not touch is identical.
        // We re-derive the mask the same way reduce_stars does and check.
        assert_background_bitwise_identical(&input, &out, &cfg);
    }

    #[test]
    fn erosion_method_reduces_star_size_and_leaves_background_exact() {
        let background = 800u16;
        let star_sigma = 3.0_f64;
        let strength = 0.8_f64;
        let input = synth_starfield(160, 160, background, 22000.0, star_sigma, 40);
        let cfg = StarReductionConfig {
            strength,
            method: StarReduceMethod::MorphologicalErosion,
            mask_dilate: 1,
        };
        let out = reduce_stars(&input, &cfg).expect("reduction should succeed");

        let (cx, cy, peak_in) = brightest_pixel(&input);
        let peak_out = px(&out, cx, cy);
        assert!(
            peak_out < peak_in,
            "erosion must lower the star peak: in={peak_in} out={peak_out}"
        );
        let foot_in = star_footprint(&input, cx, cy, background, 12);
        let foot_out = star_footprint(&out, cx, cy, background, 12);
        assert!(
            foot_out < foot_in,
            "erosion must shrink the star footprint: in={foot_in} out={foot_out}"
        );

        // QUANTITATIVE bound: the bare `peak_out < peak_in` /
        // `foot_out < foot_in` checks pass for ANY non-zero reduction, so a
        // regression that all-but-disabled erosion (radius collapsed to 0, strength
        // mis-wired) would still pass. Pin the center-min reduction analytically.
        //
        // At the star centre the grayscale erosion replaces the peak with the local
        // minimum over a disk of EROSION_RADIUS_PX, which for a Gaussian is the
        // value at that radius: excess·exp(−R²/2σ²). The composite at the (fully
        // masked, w≈1) centre is excess·(1 − s) + eroded_excess·s, so
        //   excess_out / excess_in ≈ 1 − s·(1 − exp(−R²/2σ²)).
        let r = EROSION_RADIUS_PX as f64;
        let erosion_floor = (-(r * r) / (2.0 * star_sigma * star_sigma)).exp();
        let expected_ratio = 1.0 - strength * (1.0 - erosion_floor);
        let excess_in = peak_in as f64 - background as f64;
        let excess_out = peak_out as f64 - background as f64;
        let ratio = excess_out / excess_in;
        assert!(
            (ratio - expected_ratio).abs() < 0.06,
            "erosion centre reduction {ratio:.3} must match the analytic bound \
             {expected_ratio:.3} (1 − s·(1 − e^(−R²/2σ²))); a near-no-op erosion \
             would land near 1.0 and fail this"
        );

        assert_background_bitwise_identical(&input, &out, &cfg);
    }

    #[test]
    fn erosion_strength_meaningfully_changes_the_result() {
        // Lock in that `strength` actually drives the erosion outcome
        // (it scales the blend toward the eroded plane), not merely that it is
        // accepted. A gentle (0.3) and an aggressive (0.9) erosion must produce
        // measurably different centre excess AND footprints; if strength were
        // mis-wired to a constant blend, these would coincide.
        let background = 800u16;
        let input = synth_starfield(160, 160, background, 22000.0, 3.0, 40);
        let (cx, cy, peak_in) = brightest_pixel(&input);

        let mk = |s: f64| StarReductionConfig {
            strength: s,
            method: StarReduceMethod::MorphologicalErosion,
            mask_dilate: 1,
        };
        let gentle = reduce_stars(&input, &mk(0.3)).expect("gentle erosion");
        let aggressive = reduce_stars(&input, &mk(0.9)).expect("aggressive erosion");

        let excess = |img: &ImageData| px(img, cx, cy) as f64 - background as f64;
        let e_gentle = excess(&gentle);
        let e_aggr = excess(&aggressive);
        assert!(
            e_aggr < e_gentle && e_gentle < (peak_in as f64 - background as f64),
            "stronger erosion must reduce the centre more: gentle={e_gentle} aggressive={e_aggr}"
        );
        // The difference must be substantial, not a rounding tie — the analytic gap
        // between s=0.3 and s=0.9 at the centre is (0.9−0.3)·(1−e^(−4/18))·excess ≈
        // 0.6·0.199·excess ≈ 0.12·excess, far above u16 quantization.
        let gap = (e_gentle - e_aggr) / (peak_in as f64 - background as f64);
        assert!(
            gap > 0.05,
            "erosion strength must visibly change the centre excess; gap fraction {gap:.3}"
        );

        // Footprints must also differ in the strength-driven direction.
        let foot = |img: &ImageData| star_footprint(img, cx, cy, background, 12);
        assert!(
            foot(&aggressive) <= foot(&gentle),
            "aggressive erosion footprint {} must be <= gentle {}",
            foot(&aggressive),
            foot(&gentle)
        );
        assert!(
            foot(&aggressive) < foot(&gentle) || e_aggr < e_gentle,
            "strength must change at least one of footprint/centre measurably"
        );
    }

    #[test]
    fn stronger_strength_reduces_more() {
        let background = 1000u16;
        let input = synth_starfield(160, 160, background, 25000.0, 3.0, 40);
        let (cx, cy, peak_in) = brightest_pixel(&input);

        let mk = |s: f64| StarReductionConfig {
            strength: s,
            method: StarReduceMethod::ScreenedResidual,
            mask_dilate: 2,
        };
        let weak = reduce_stars(&input, &mk(0.3)).unwrap();
        let strong = reduce_stars(&input, &mk(0.9)).unwrap();

        let excess = |img: &ImageData| px(img, cx, cy) as f64 - background as f64;
        let e_weak = excess(&weak);
        let e_strong = excess(&strong);
        assert!(
            e_strong < e_weak && e_weak < (peak_in as f64 - background as f64),
            "more strength must reduce the peak more: weak={e_weak} strong={e_strong}"
        );
    }

    #[test]
    fn strength_zero_is_identity() {
        let input = synth_starfield(96, 96, 1200, 20000.0, 2.5, 32);
        let cfg = StarReductionConfig {
            strength: 0.0,
            method: StarReduceMethod::ScreenedResidual,
            mask_dilate: 2,
        };
        let out = reduce_stars(&input, &cfg).expect("strength 0 must succeed");
        assert_eq!(
            out.data, input.data,
            "strength=0 must produce a byte-identical output"
        );

        // Same for the erosion method.
        let cfg_e = StarReductionConfig {
            method: StarReduceMethod::MorphologicalErosion,
            ..cfg
        };
        let out_e = reduce_stars(&input, &cfg_e).unwrap();
        assert_eq!(
            out_e.data, input.data,
            "strength=0 erosion must be identity"
        );
    }

    #[test]
    fn empty_image_is_an_error() {
        let empty = ImageData::new(0, 0, 1, PixelType::U16);
        assert_eq!(
            reduce_stars(&empty, &StarReductionConfig::default()).unwrap_err(),
            StarReduceError::EmptyImage
        );

        // A non-zero declared size but empty buffer is also empty.
        let empty2 = ImageData {
            width: 4,
            height: 4,
            channels: 1,
            pixel_type: PixelType::U16,
            data: vec![],
        };
        assert_eq!(
            reduce_stars(&empty2, &StarReductionConfig::default()).unwrap_err(),
            StarReduceError::EmptyImage
        );
    }

    #[test]
    fn out_of_range_strength_is_an_error() {
        let input = synth_starfield(48, 48, 1000, 15000.0, 2.0, 24);
        for bad in [-0.1, 1.1, f64::NAN, f64::INFINITY] {
            let cfg = StarReductionConfig {
                strength: bad,
                ..StarReductionConfig::default()
            };
            assert_eq!(
                reduce_stars(&input, &cfg).unwrap_err(),
                StarReduceError::BadStrength,
                "strength {bad} must be rejected"
            );
        }
    }

    #[test]
    fn f32_image_is_supported_and_background_preserved() {
        // Build an F32 frame: flat background + one Gaussian star.
        let w = 96usize;
        let h = 96usize;
        let bg = 0.02f32;
        let mut data = vec![bg; w * h];
        let (scx, scy) = (48.0f64, 48.0f64);
        let sigma = 3.0f64;
        let two_sig_sq = 2.0 * sigma * sigma;
        for y in 0..h {
            for x in 0..w {
                let dx = x as f64 - scx;
                let dy = y as f64 - scy;
                let rr = dx * dx + dy * dy;
                if rr <= (4.0 * sigma) * (4.0 * sigma) {
                    let add = 0.8 * (-rr / two_sig_sq).exp();
                    data[y * w + x] = (data[y * w + x] as f64 + add) as f32;
                }
            }
        }
        let input = ImageData::from_f32(w as u32, h as u32, 1, &data);
        let cfg = StarReductionConfig {
            strength: 0.6,
            method: StarReduceMethod::ScreenedResidual,
            mask_dilate: 2,
        };
        let out = reduce_stars(&input, &cfg).expect("f32 reduction should succeed");
        assert_eq!(out.pixel_type, PixelType::F32);

        let read_f32 = |img: &ImageData, x: usize, y: usize| -> f32 {
            let base = (y * w + x) * 4;
            f32::from_le_bytes([
                img.data[base],
                img.data[base + 1],
                img.data[base + 2],
                img.data[base + 3],
            ])
        };

        // Star centre must be reduced.
        assert!(
            read_f32(&out, 48, 48) < read_f32(&input, 48, 48),
            "f32 star peak must drop"
        );
        // A far-corner background pixel must be byte-identical.
        let corner_in = &input.data[0..4];
        let corner_out = &out.data[0..4];
        assert_eq!(
            corner_in, corner_out,
            "f32 background must be byte-identical"
        );
    }

    /// Assert that every pixel the (re-derived) star mask did not touch is
    /// byte-for-byte identical between `input` and `out`. This is the core
    /// non-destructive guarantee.
    fn assert_background_bitwise_identical(
        input: &ImageData,
        out: &ImageData,
        cfg: &StarReductionConfig,
    ) {
        let width = input.width as usize;
        let height = input.height as usize;
        // Re-derive the mask exactly as reduce_stars does.
        let plane = luminance_plane_for_detection(input).unwrap();
        let det_img = plane_to_u16_image(&plane, input.width, input.height);
        let stars = detect_stars(&det_img, &mask_detection_config());
        let mask = build_star_mask(&stars, width, height, cfg.mask_dilate);

        let bpp = input.pixel_type.byte_size();
        for (i, &m) in mask.iter().enumerate().take(width * height) {
            if m <= 0.0 {
                let a = &input.data[i * bpp..i * bpp + bpp];
                let b = &out.data[i * bpp..i * bpp + bpp];
                assert_eq!(
                    a, b,
                    "masked-out pixel index {i} must be byte-identical (mask weight 0)"
                );
            }
        }
        // Sanity: the mask must actually have selected *some* pixels, otherwise
        // the test is vacuous.
        assert!(
            mask.iter().any(|&m| m > 0.0),
            "test precondition: at least one star must be masked"
        );
    }

    #[test]
    fn star_bright_only_in_a_non_red_channel_is_still_reduced() {
        // An RGB star that is bright in GREEN/BLUE but FAINT in red
        // (channel 0) must still be detected and reduced. Detecting on channel 0
        // alone would miss it — it would stay at full size in every channel, the
        // worst-case visible failure. The max-across-channels detection plane keeps
        // it. We build a 96×96 RGB frame: flat background, one star whose red
        // amplitude is tiny (below the detector gate) but whose green/blue
        // amplitude is large.
        let w = 96usize;
        let h = 96usize;
        let bg = 1000.0_f64;
        let (scx, scy) = (48.0f64, 48.0f64);
        let sigma = 3.0f64;
        let two_sig_sq = 2.0 * sigma * sigma;
        // Per-pixel deterministic Gaussian noise (σ ≈ 30 ADU) so the detector's
        // SNR gate is meaningful: a faint red bump sits inside the noise and is
        // rejected, while the strong green/blue star clears it easily. Tiny LCG +
        // sum-of-12-uniforms Gaussian, dependency-free and reproducible.
        let mut state: u64 = 0x5EED_1234_ABCD_0001;
        let mut gauss = || -> f64 {
            let mut s = 0.0;
            for _ in 0..12 {
                state = state
                    .wrapping_mul(6364136223846793005)
                    .wrapping_add(1442695040888963407);
                s += ((state >> 40) as f64) / ((1u64 << 24) as f64);
            }
            s - 6.0
        };
        let mut data = vec![0u16; w * h * 3];
        for y in 0..h {
            for x in 0..w {
                let dx = x as f64 - scx;
                let dy = y as f64 - scy;
                let rr = dx * dx + dy * dy;
                let g = if rr <= (4.0 * sigma) * (4.0 * sigma) {
                    (-rr / two_sig_sq).exp()
                } else {
                    0.0
                };
                let base = (y * w + x) * 3;
                // Red barely rises (≈ +25 ADU peak — buried in the 30-ADU noise, so
                // detection on red alone fails the SNR gate); green & blue rise
                // strongly (well above the noise).
                data[base] = (bg + 25.0 * g + 30.0 * gauss()).clamp(0.0, 65535.0) as u16;
                data[base + 1] = (bg + 24000.0 * g + 30.0 * gauss()).clamp(0.0, 65535.0) as u16;
                data[base + 2] = (bg + 20000.0 * g + 30.0 * gauss()).clamp(0.0, 65535.0) as u16;
            }
        }
        let input = ImageData::from_u16(w as u32, h as u32, 3, &data);

        // Sanity: detecting on channel 0 (red) alone finds NO star here (the red
        // amplitude is below the gate), which is precisely the bug. Detecting on the
        // max-across-channels plane DOES find it.
        let red_only = extract_plane_f64(&input, 0).unwrap();
        let red_stars = detect_stars(
            &plane_to_u16_image(&red_only, w as u32, h as u32),
            &mask_detection_config(),
        );
        let lum = luminance_plane_for_detection(&input).unwrap();
        let lum_stars = detect_stars(
            &plane_to_u16_image(&lum, w as u32, h as u32),
            &mask_detection_config(),
        );
        assert!(
            red_stars.is_empty(),
            "precondition: the star must be invisible in red alone (got {} red detections)",
            red_stars.len()
        );
        assert!(
            !lum_stars.is_empty(),
            "the max-across-channels plane must detect the green/blue-bright star"
        );

        // The reduction must actually shrink the star in the bright channels.
        let cfg = StarReductionConfig {
            strength: 0.7,
            method: StarReduceMethod::ScreenedResidual,
            mask_dilate: 2,
        };
        let out = reduce_stars(&input, &cfg).expect("reduction should succeed");
        let read = |img: &ImageData, x: usize, y: usize, c: usize| -> u16 {
            let base = ((y * w + x) * 3 + c) * 2;
            u16::from_le_bytes([img.data[base], img.data[base + 1]])
        };
        let cx = scx as usize;
        let cy = scy as usize;
        assert!(
            read(&out, cx, cy, 1) < read(&input, cx, cy, 1),
            "green peak must be reduced: in={} out={}",
            read(&input, cx, cy, 1),
            read(&out, cx, cy, 1)
        );
        assert!(
            read(&out, cx, cy, 2) < read(&input, cx, cy, 2),
            "blue peak must be reduced: in={} out={}",
            read(&input, cx, cy, 2),
            read(&out, cx, cy, 2)
        );
    }

    #[test]
    fn disk_weight_is_a_valid_feather() {
        // Inside the core → 1.
        assert_eq!(disk_weight(0.0, 3.0, 6.0), 1.0);
        assert_eq!(disk_weight(3.0, 3.0, 6.0), 1.0);
        // Outside the outer radius → 0.
        assert_eq!(disk_weight(6.0, 3.0, 6.0), 0.0);
        assert_eq!(disk_weight(10.0, 3.0, 6.0), 0.0);
        // Midpoint of the feather → 0.5 (raised cosine at t=0.5).
        let mid = disk_weight(4.5, 3.0, 6.0);
        assert!(
            (mid - 0.5).abs() < 1e-6,
            "feather midpoint should be 0.5, got {mid}"
        );
        // Monotonically decreasing across the feather.
        let a = disk_weight(3.5, 3.0, 6.0);
        let b = disk_weight(5.5, 3.0, 6.0);
        assert!(a > b && b > 0.0, "feather must decrease: a={a} b={b}");
    }

    #[test]
    fn erosion_shrinks_a_bright_blob() {
        // A 5×5 bright square on a dark plane; erosion by radius 1 must shrink
        // the bright region (border pixels take the dark neighbour's value).
        let w = 11usize;
        let h = 11usize;
        let mut plane = vec![100.0f64; w * h];
        for y in 3..=7 {
            for x in 3..=7 {
                plane[y * w + x] = 5000.0;
            }
        }
        let eroded = erode_plane(&plane, w, h, 1);
        // A border pixel of the square (3,5) has a dark neighbour → eroded to 100.
        assert_eq!(eroded[5 * w + 3], 100.0, "border must erode to background");
        // The very centre (5,5) is surrounded by bright pixels within radius 1
        // → stays bright.
        assert_eq!(eroded[5 * w + 5], 5000.0, "interior must stay bright");
    }
}
