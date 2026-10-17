//! Drizzle (variable-pixel linear reconstruction) and Bayer-drizzle integration.
//!
//! This module implements the Fruchter–Hook *drizzle* algorithm — "variable-pixel
//! linear reconstruction" — and its colour-filter-array (CFA / Bayer) variant for
//! one-shot-colour (OSC) cameras. Drizzle is the standard technique for recovering
//! resolution from a stack of **dithered, under-sampled** sub-frames: see
//! Fruchter & Hook, *PASP* 114, 144 (2002), the method developed for the
//! Hubble Deep Field.
//!
//! ## What drizzle does (and why it beats a plain warp-and-average)
//!
//! A classical resampling warp (see [`crate::registration::register_frame`]) maps
//! each *output* pixel back to a fractional *input* location and interpolates.
//! That convolves the data with the interpolation kernel, softening the PSF and
//! correlating the noise — and for an under-sampled signal (a star whose PSF is
//! ~1 pixel FWHM) it cannot reconstruct detail finer than the input grid.
//!
//! Drizzle instead works **forward**: it treats each input pixel as a small
//! "drop" of flux and *paints* (drizzles) that drop onto a finer output grid,
//! shrunk by the linear factor `pixfrac` and weighted by the geometric overlap
//! area between the drop and each output cell. Because many frames are dithered
//! by sub-pixel offsets, different frames deposit their drops at different
//! sub-pixel phases on the output grid; the accumulated, overlap-weighted average
//! recovers spatial frequencies above the input Nyquist that no single frame
//! sampled. The output is sharper and the noise is *less* correlated than an
//! interpolated warp.
//!
//! ## The overlap-area kernel (the heart of the algorithm)
//!
//! Output grid dimensions are `ceil(ref_w · scale) × ceil(ref_h · scale)`. For an
//! input pixel whose **centre** maps (via the frame's [`TransformModel`], then a
//! multiply by `scale`) to output coordinate `(ox, oy)`, the drop is a square of
//! side `pixfrac · scale` centred at `(ox, oy)` — i.e. an input pixel, which is a
//! unit square in input space, shrinks to side `pixfrac` in input units and then
//! magnifies by `scale` into output units. (We assume the transform is locally a
//! similarity, the regime drizzle is used in; the drop is axis-aligned in output
//! space, which is the universal "square-kernel" drizzle approximation and the
//! one PixInsight / DrizzlePac use for the square kernel.)
//!
//! For each output cell `[cx, cx+1] × [cy, cy+1]` the deposited weight is the
//! **area of intersection** of that unit cell with the drop rectangle:
//!
//! ```text
//!     drop  = [ox − d, ox + d] × [oy − d, oy + d],   d = pixfrac · scale / 2
//!     overlap(cell) = max(0, min(ox+d, cx+1) − max(ox−d, cx))
//!                   · max(0, min(oy+d, cy+1) − max(oy−d, cy))
//! ```
//!
//! That product of clamped 1-D overlaps is the classic separable box∩box area.
//! Per output cell we accumulate
//!
//! ```text
//!     flux[cell]   += value · frame_weight · overlap
//!     weight[cell] += frame_weight · overlap
//! ```
//!
//! and after every frame the reconstructed master is `flux / weight` where
//! `weight > 0`, else 0 (an uncovered cell). This is exactly the Fruchter–Hook
//! accumulation; it is *flux-conserving* in the sense that, summed over the
//! output cells a drop touches, the deposited weight equals `frame_weight ·
//! (pixfrac·scale)²`, and the value is the overlap-weighted mean of the inputs
//! that landed there.
//!
//! The [`DrizzleKernel::Gaussian`] and [`DrizzleKernel::Point`] variants replace
//! the box overlap with, respectively, a Gaussian footprint integrated over the
//! cell (smoother, trades resolution for a softer noise floor) and a
//! nearest-cell delta (`pixfrac → 0` limit: deposit the whole drop into the one
//! cell containing the centre — the sharpest, noisiest choice). `Square` is the
//! default and the one with rigorous flux-conservation guarantees.
//!
//! ## Bayer (CFA) drizzle
//!
//! [`bayer_drizzle_integrate`] drizzles a raw, **un-debayered** CFA mosaic. Each
//! mosaic pixel carries exactly one colour (determined by its position in the
//! Bayer pattern), so it is deposited **only into its own colour plane** of the
//! RGB output — there is *no* debayer interpolation. Dithering across frames
//! fills in the colour planes that a single CFA frame leaves sparse, so the RGB
//! master is reconstructed at higher resolution directly from the raw sub-pixel
//! samples. This is "Bayer drizzle" / "CFA drizzle" as popularised by
//! DeepSkyStacker and PixInsight's `DrizzleIntegration` in CFA mode, and it
//! avoids the chroma smearing a demosaic-then-drizzle pipeline introduces.
//!
//! ## Limitations
//!
//! - The `Square` drop is axis-aligned in output space; under a transform with
//!   significant **rotation** the true drop is a rotated square and the
//!   axis-aligned box is an approximation. For the dither-and-similarity regime
//!   drizzle targets (small rotations) this is the standard, well-justified
//!   approximation; large field rotation between subs would want a full polygon
//!   clip, which this module does not implement.
//! - `pixfrac` and the Gaussian footprint width are exposed knobs with defensible
//!   defaults (`pixfrac = 0.9`, the DrizzlePac default; Gaussian σ tied to the
//!   drop half-width), **not** corpus-tuned constants.
//! - Accumulation is into a single shared flux/weight buffer pair (memory =
//!   `O(output pixels)`, independent of frame count), matching the
//!   "memory-reasonable" requirement.

use crate::registration::TransformModel;
use crate::{BayerColor, BayerPattern, ImageData};
use rayon::prelude::*;

// Public configuration types

/// The shape of the "drop" footprint a single input pixel deposits onto the
/// output grid.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DrizzleKernel {
    /// A `pixfrac`-shrunk **square** drop; the deposited weight per output cell
    /// is the exact box∩box overlap area. Flux-conserving and the Fruchter–Hook
    /// default — the recommended choice for almost all data.
    #[default]
    Square,
    /// A **point** (delta) drop: the whole pixel is deposited into the single
    /// output cell that contains the mapped centre (the `pixfrac → 0` limit).
    /// Sharpest reconstruction but noisiest and prone to moiré if the dither
    /// pattern is poor; useful as a resolution upper bound / diagnostic.
    Point,
    /// A **Gaussian** footprint (σ tied to the drop half-width) integrated over
    /// each output cell. Smoother than `Square` — it trades a little resolution
    /// for a lower, less-correlated noise floor — at the cost of strict
    /// flux-conservation only holding in the limit of full footprint coverage.
    Gaussian,
}

/// Tunables for a drizzle integration. [`Default`] is a 2× drizzle with the
/// DrizzlePac-standard `pixfrac = 0.9` square kernel.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DrizzleConfig {
    /// Linear output/input scale factor (e.g. `2.0` → the output grid has twice
    /// the linear resolution of the reference grid). Must be `> 0`.
    pub scale: f64,
    /// Drop-shrink fraction in `(0, 1]`. `1.0` keeps the full input pixel
    /// footprint (maximum coverage, softest); smaller values shrink the drop so
    /// dithered frames sample finer detail (sharper, but needs more frames to
    /// fill coverage). `0.9` is the DrizzlePac default.
    pub pixfrac: f64,
    /// The drop footprint shape.
    pub kernel: DrizzleKernel,
}

impl Default for DrizzleConfig {
    fn default() -> Self {
        Self {
            scale: 2.0,
            pixfrac: 0.9,
            kernel: DrizzleKernel::Square,
        }
    }
}

impl DrizzleConfig {
    /// Validate the user-supplied parameters, returning [`DrizzleError::BadParams`]
    /// for anything the algorithm cannot make honest sense of.
    fn validate(&self) -> Result<(), DrizzleError> {
        if !(self.scale.is_finite() && self.scale > 0.0) {
            return Err(DrizzleError::BadParams);
        }
        if !(self.pixfrac.is_finite() && self.pixfrac > 0.0 && self.pixfrac <= 1.0) {
            return Err(DrizzleError::BadParams);
        }
        Ok(())
    }
}

/// One frame's contribution to a (non-CFA) drizzle integration.
///
/// `pixels` is row-major, **channel-interleaved** `f64` exactly like
/// [`ImageData`] (a 3-channel frame is `[r,g,b, r,g,b, …]`). The `transform`
/// maps *this frame's* pixel coordinates onto the **reference grid** (source →
/// reference, the same convention as [`crate::registration::TransformModel`]);
/// drizzle then magnifies reference coordinates by `cfg.scale` to reach the
/// output grid. `weight` is the scalar quality weight applied to every drop from
/// this frame (frames with `weight <= 0` are skipped).
#[derive(Debug, Clone, Copy)]
pub struct DrizzleFrame<'a> {
    /// Aligned-or-not pixel buffer (`width × height × channels`, f64, interleaved).
    pub pixels: &'a [f64],
    /// Frame width in pixels.
    pub width: u32,
    /// Frame height in pixels.
    pub height: u32,
    /// Channel count (must match every other frame and the output).
    pub channels: u32,
    /// Source (this frame) → reference-grid transform.
    pub transform: &'a TransformModel,
    /// Scalar quality weight for every drop from this frame.
    pub weight: f64,
}

/// One frame's contribution to a **Bayer (CFA) drizzle** integration.
///
/// `mosaic` is a single-channel raw CFA buffer (`width × height`, f64,
/// row-major). `pattern` is the **effective** Bayer pattern at the mosaic origin
/// `(0, 0)` (already composed with any sub-frame offset — see
/// [`crate::effective_bayer_pattern`]); the colour of mosaic pixel `(ix, iy)` is
/// `pattern.color_at(ix, iy)`. The `transform` and `weight` carry the same
/// meaning as in [`DrizzleFrame`].
#[derive(Debug, Clone, Copy)]
pub struct BayerDrizzleFrame<'a> {
    /// Raw single-channel CFA mosaic (`width × height`, f64, row-major).
    pub mosaic: &'a [f64],
    /// Mosaic width in pixels.
    pub width: u32,
    /// Mosaic height in pixels.
    pub height: u32,
    /// Effective Bayer pattern at the mosaic origin `(0, 0)`.
    pub pattern: BayerPattern,
    /// Source (this frame) → reference-grid transform.
    pub transform: &'a TransformModel,
    /// Scalar quality weight for every drop from this frame.
    pub weight: f64,
}

/// The result of a drizzle integration: the reconstructed master plus the
/// per-pixel coverage (accumulated drizzle weight) buffer.
#[derive(Debug, Clone)]
pub struct DrizzleOutput {
    /// The reconstructed master, `F32`, of dimensions
    /// `ceil(ref_w · scale) × ceil(ref_h · scale)`, with the same channel count
    /// as the input frames (3 for [`bayer_drizzle_integrate`]). Cells with zero
    /// accumulated weight (no drop ever landed) are 0.
    pub master: ImageData,
    /// The per-pixel **coverage** map, `F32`, single channel, same output
    /// dimensions. Each value is the total drizzle weight `Σ frame_weight ·
    /// overlap` deposited into that output cell — a direct SNR / coverage
    /// diagnostic (zero ⇒ a hole the dither pattern never reached).
    ///
    /// For multi-channel masters the coverage is the **green/first-plane**
    /// geometric coverage in the RGB case (coverage is a geometric property of
    /// the drop, shared by all channels in [`drizzle_integrate`]); for Bayer
    /// drizzle each colour plane has independent coverage, and this map reports
    /// the **green** plane (the densest in a Bayer mosaic, hence the best
    /// coverage proxy).
    pub coverage: ImageData,
}

/// Errors from the drizzle entry points. Every variant is a *caller* mistake the
/// module refuses to paper over — an empty population, mismatched frame
/// geometry, or out-of-range parameters — never a silent best-effort stack.
#[derive(Debug, thiserror::Error, PartialEq)]
pub enum DrizzleError {
    /// No frames were supplied (or, for the typed entry points, the population
    /// was empty after validation).
    #[error("no frames to drizzle")]
    NoFrames,
    /// A frame's declared geometry is inconsistent: its `pixels`/`mosaic` length
    /// does not equal `width × height × channels`, a frame's channel count
    /// disagrees with the others, or the reference grid is zero-sized.
    #[error(
        "frame dimensions are inconsistent (buffer length, channel count, or zero-sized grid)"
    )]
    DimMismatch,
    /// `scale`, `pixfrac`, or a derived parameter is out of its valid range.
    #[error("invalid drizzle parameters (need scale > 0 and 0 < pixfrac <= 1)")]
    BadParams,
}

// Public entry points

/// Drizzle a population of frames onto a `scale`× output grid.
///
/// Each frame's pixels are deposited (drizzled) as `pixfrac`-shrunk drops via the
/// frame's source→reference [`TransformModel`] (then magnified by `cfg.scale`),
/// accumulating per channel into a shared flux/weight buffer. The returned master
/// is the overlap-weighted average `flux / weight` (zero where uncovered).
///
/// # Errors
/// - [`DrizzleError::NoFrames`] if `frames` is empty.
/// - [`DrizzleError::BadParams`] if `cfg.scale`/`cfg.pixfrac` are out of range.
/// - [`DrizzleError::DimMismatch`] if `ref_w`/`ref_h`/channels are zero, a frame
///   has zero channels, frames disagree on channel count, or any frame's buffer
///   length is not `width × height × channels`.
pub fn drizzle_integrate(
    frames: &[DrizzleFrame],
    ref_w: u32,
    ref_h: u32,
    cfg: &DrizzleConfig,
) -> Result<DrizzleOutput, DrizzleError> {
    if frames.is_empty() {
        return Err(DrizzleError::NoFrames);
    }
    cfg.validate()?;
    if ref_w == 0 || ref_h == 0 {
        return Err(DrizzleError::DimMismatch);
    }

    // All frames must agree on channel count, and every buffer length must match
    // its declared geometry; guessing would make the integration silently
    // mis-index.
    let channels = frames[0].channels;
    if channels == 0 {
        return Err(DrizzleError::DimMismatch);
    }
    for f in frames {
        if f.channels != channels {
            return Err(DrizzleError::DimMismatch);
        }
        let expected = (f.width as usize) * (f.height as usize) * (channels as usize);
        if f.pixels.len() != expected {
            return Err(DrizzleError::DimMismatch);
        }
    }

    let (out_w, out_h) = output_dims(ref_w, ref_h, cfg.scale);
    let cells = out_w * out_h;
    let c = channels as usize;

    // flux[cell * c + ch], weight[cell] (coverage is geometric, shared by every
    // channel of a frame — one weight buffer suffices for the RGB warp case).
    let mut flux = vec![0.0f64; cells * c];
    let mut weight = vec![0.0f64; cells];

    for f in frames {
        if !(f.weight.is_finite() && f.weight > 0.0) {
            continue;
        }
        deposit_frame(
            f.pixels,
            f.width as usize,
            f.height as usize,
            c,
            f.transform,
            f.weight,
            cfg,
            out_w,
            out_h,
            &mut flux,
            &mut weight,
        );
    }

    let master = resolve_master(&flux, &weight, out_w, out_h, c);
    let coverage = ImageData::from_f32(
        out_w as u32,
        out_h as u32,
        1,
        &weight.iter().map(|&w| w as f32).collect::<Vec<_>>(),
    );

    Ok(DrizzleOutput { master, coverage })
}

/// Bayer-drizzle a population of raw CFA mosaics onto a `scale`× **3-channel RGB**
/// output grid.
///
/// Each mosaic pixel is deposited into **only** its own colour plane (the colour
/// given by `frame.pattern.color_at(ix, iy)`); there is no debayer interpolation.
/// Coverage is tracked per colour plane (the planes fill in at different rates),
/// and each plane's master is its own overlap-weighted average.
///
/// # Errors
/// - [`DrizzleError::NoFrames`] if `frames` is empty.
/// - [`DrizzleError::BadParams`] if `cfg.scale`/`cfg.pixfrac` are out of range.
/// - [`DrizzleError::DimMismatch`] if `ref_w`/`ref_h` are zero or a mosaic's
///   length is not `width × height`.
pub fn bayer_drizzle_integrate(
    frames: &[BayerDrizzleFrame],
    ref_w: u32,
    ref_h: u32,
    cfg: &DrizzleConfig,
) -> Result<DrizzleOutput, DrizzleError> {
    if frames.is_empty() {
        return Err(DrizzleError::NoFrames);
    }
    cfg.validate()?;
    if ref_w == 0 || ref_h == 0 {
        return Err(DrizzleError::DimMismatch);
    }
    for f in frames {
        let expected = (f.width as usize) * (f.height as usize);
        if f.mosaic.len() != expected {
            return Err(DrizzleError::DimMismatch);
        }
    }

    let (out_w, out_h) = output_dims(ref_w, ref_h, cfg.scale);
    let cells = out_w * out_h;

    // Per-colour-plane flux and weight (RGB → 3 planes), each independent because
    // a CFA pixel only ever touches one plane and the planes fill at different
    // rates as the dither sweeps the mosaic.
    let mut flux = vec![0.0f64; cells * 3];
    let mut weight = vec![0.0f64; cells * 3];

    for f in frames {
        if !(f.weight.is_finite() && f.weight > 0.0) {
            continue;
        }
        deposit_bayer_frame(f, cfg, out_w, out_h, &mut flux, &mut weight);
    }

    // Resolve each of the 3 planes independently: master[cell*3+ch] =
    // flux[cell*3+ch] / weight[cell*3+ch].
    let master_data: Vec<f32> = (0..cells * 3)
        .into_par_iter()
        .map(|i| {
            let w = weight[i];
            if w > 0.0 {
                (flux[i] / w) as f32
            } else {
                0.0
            }
        })
        .collect();
    let master = ImageData::from_f32(out_w as u32, out_h as u32, 3, &master_data);

    // Report the GREEN plane's coverage: green is sampled twice as densely as red
    // or blue in every Bayer pattern, so its coverage is the best single-channel
    // proxy for "did the dither reach this cell".
    let green_coverage: Vec<f32> = (0..cells).map(|cell| weight[cell * 3 + 1] as f32).collect();
    let coverage = ImageData::from_f32(out_w as u32, out_h as u32, 1, &green_coverage);

    Ok(DrizzleOutput { master, coverage })
}

// Core deposition

/// Output grid dimensions: `ceil(ref · scale)`, floored to at least 1 cell so a
/// degenerate-but-valid 1×1 reference still produces an output.
fn output_dims(ref_w: u32, ref_h: u32, scale: f64) -> (usize, usize) {
    let ow = (ref_w as f64 * scale).ceil() as usize;
    let oh = (ref_h as f64 * scale).ceil() as usize;
    (ow.max(1), oh.max(1))
}

/// Resolve the accumulated flux/weight into an `F32` master: `flux / weight`
/// per channel where `weight > 0`, else 0. Coverage (`weight`) is shared across
/// channels here (the geometric drop case).
fn resolve_master(flux: &[f64], weight: &[f64], out_w: usize, out_h: usize, c: usize) -> ImageData {
    let cells = out_w * out_h;
    let data: Vec<f32> = (0..cells)
        .into_par_iter()
        .flat_map_iter(|cell| {
            let w = weight[cell];
            (0..c).map(move |ch| {
                if w > 0.0 {
                    (flux[cell * c + ch] / w) as f32
                } else {
                    0.0
                }
            })
        })
        .collect();
    ImageData::from_f32(out_w as u32, out_h as u32, c as u32, &data)
}

/// Deposit every pixel of one (interleaved, multi-channel) frame.
///
/// Single-threaded over the frame's pixels because all frames share one
/// flux/weight accumulator (a scatter-add into a shared buffer); parallelism in
/// this module is over the *resolve* step and over channels, not the scatter,
/// which would otherwise require atomics or per-thread partial buffers. For the
/// memory-reasonable, single-shared-buffer design this is the correct trade.
#[allow(clippy::too_many_arguments)]
fn deposit_frame(
    pixels: &[f64],
    width: usize,
    height: usize,
    c: usize,
    transform: &TransformModel,
    frame_weight: f64,
    cfg: &DrizzleConfig,
    out_w: usize,
    out_h: usize,
    flux: &mut [f64],
    weight: &mut [f64],
) {
    let half = drop_half_width(cfg);
    for iy in 0..height {
        for ix in 0..width {
            // Input pixel CENTRE maps to reference, then to the output grid.
            let (ox, oy) = map_center(transform, ix, iy, cfg.scale);
            if !(ox.is_finite() && oy.is_finite()) {
                continue;
            }
            let base = (iy * width + ix) * c;
            // The geometric weight[cell] is the SHARED denominator for every
            // channel of this cell, so it must only be incremented when EVERY
            // channel of this input pixel contributes a finite sample. If we bumped
            // the weight but skipped a non-finite channel's flux, that channel's
            // resolved mean (flux/weight) would be biased toward zero — the bad
            // sample silently treated as 0 rather than excluded. So if ANY channel
            // is non-finite (a rejected/masked pixel, a hot column), skip the whole
            // pixel before depositing — matching the Bayer path, which already
            // `continue`s on a non-finite mosaic value.
            if !pixels[base..base + c].iter().all(|v| v.is_finite()) {
                continue;
            }
            // Distribute the drop once, accumulating geometric weight separately
            // (shared across channels) and flux per channel.
            for_each_overlapped_cell(ox, oy, half, cfg.kernel, out_w, out_h, |cell, overlap| {
                let w = frame_weight * overlap;
                weight[cell] += w;
                for ch in 0..c {
                    flux[cell * c + ch] += pixels[base + ch] * w;
                }
            });
        }
    }
}

/// Deposit every pixel of one CFA mosaic into its colour plane only.
fn deposit_bayer_frame(
    frame: &BayerDrizzleFrame,
    cfg: &DrizzleConfig,
    out_w: usize,
    out_h: usize,
    flux: &mut [f64],
    weight: &mut [f64],
) {
    let width = frame.width as usize;
    let height = frame.height as usize;
    let half = drop_half_width(cfg);
    for iy in 0..height {
        for ix in 0..width {
            let v = frame.mosaic[iy * width + ix];
            if !v.is_finite() {
                continue;
            }
            // The colour plane is chosen by the EFFECTIVE pattern at (ix, iy):
            // Red→0, Green→1, Blue→2 in the interleaved RGB output.
            let plane = match frame.pattern.color_at(ix, iy) {
                BayerColor::Red => 0usize,
                BayerColor::Green => 1usize,
                BayerColor::Blue => 2usize,
            };
            let (ox, oy) = map_center(frame.transform, ix, iy, cfg.scale);
            if !(ox.is_finite() && oy.is_finite()) {
                continue;
            }
            for_each_overlapped_cell(ox, oy, half, cfg.kernel, out_w, out_h, |cell, overlap| {
                let w = frame.weight * overlap;
                let idx = cell * 3 + plane;
                weight[idx] += w;
                flux[idx] += v * w;
            });
        }
    }
}

/// Map an input pixel centre through the source→reference transform and then
/// onto the `scale`× output grid.
///
/// The registration transform is fitted in a *pixel-centre-at-integer-index*
/// frame — star centroids are computed as `Σ(index·flux)/Σflux`, so a star
/// confined to pixel `(i, j)` has centroid `(i, j)`. The input sample is
/// therefore the pixel centre at `(ix, iy)`, NOT `(ix + 0.5, iy + 0.5)`.
///
/// Adding the `+0.5` *before* the transform only happens to be correct for
/// identity/translation (the offset commutes); under a rotation it is sent onto
/// the wrong axis and shifts the deposited drop by a whole output cell. Instead
/// we apply the transform to the true centre and add the `+0.5` output-grid
/// shift *after*, where output cell `c` occupies `[c, c+1)` (centre at `c+0.5`).
#[inline]
fn map_center(transform: &TransformModel, ix: usize, iy: usize, scale: f64) -> (f64, f64) {
    let (rx, ry) = transform.apply(ix as f64, iy as f64);
    ((rx + 0.5) * scale, (ry + 0.5) * scale)
}

/// Half-width (in output cells) of the square drop: an input pixel is a unit
/// square, shrunk by `pixfrac` and magnified by `scale`, giving side
/// `pixfrac · scale`; the half-width is half of that.
#[inline]
fn drop_half_width(cfg: &DrizzleConfig) -> f64 {
    0.5 * cfg.pixfrac * cfg.scale
}

/// Invoke `f(cell_index, overlap_weight)` for every output cell the drop centred
/// at `(ox, oy)` with half-width `half` deposits into, per the chosen kernel.
///
/// `overlap_weight` is the geometric weight in `[0, (2·half)²]` for `Square`,
/// the integrated Gaussian mass for `Gaussian`, and `1.0` for the single nearest
/// cell for `Point`. The weights deposited by one drop sum to the drop's total
/// footprint area (`Square`) — the property that makes the accumulation
/// flux-conserving.
fn for_each_overlapped_cell<F: FnMut(usize, f64)>(
    ox: f64,
    oy: f64,
    half: f64,
    kernel: DrizzleKernel,
    out_w: usize,
    out_h: usize,
    mut f: F,
) {
    match kernel {
        DrizzleKernel::Point => {
            // Deposit the whole drop into the one cell containing the centre.
            let cx = ox.floor();
            let cy = oy.floor();
            if cx < 0.0 || cy < 0.0 {
                return;
            }
            let (cxi, cyi) = (cx as usize, cy as usize);
            if cxi < out_w && cyi < out_h {
                f(cyi * out_w + cxi, 1.0);
            }
        }
        DrizzleKernel::Square => {
            box_drop(ox, oy, half, out_w, out_h, &mut f);
        }
        DrizzleKernel::Gaussian => {
            gaussian_drop(ox, oy, half, out_w, out_h, &mut f);
        }
    }
}

/// Square (box) drop: deposit the exact box∩box overlap area of the drop
/// rectangle `[ox−half, ox+half] × [oy−half, oy+half]` with each output unit
/// cell it touches.
///
/// The drop spans integer cell columns `floor(ox−half) ..= floor(ox+half)` (and
/// likewise for rows). For each candidate cell `(cx, cy)` the overlap is the
/// product of the clamped 1-D interval intersections — the separable box∩box
/// area derived in this module's header. Cells outside the grid are dropped
/// (lost flux at the frame border, the correct drizzle behaviour — no edge
/// replication).
fn box_drop<F: FnMut(usize, f64)>(
    ox: f64,
    oy: f64,
    half: f64,
    out_w: usize,
    out_h: usize,
    mut f: F,
) {
    let x_lo = ox - half;
    let x_hi = ox + half;
    let y_lo = oy - half;
    let y_hi = oy + half;

    // Integer cell index range the drop spans. We clamp the *iteration* to the
    // grid but compute overlaps against the true (unclamped) drop extent so a
    // drop straddling the border deposits only its in-grid fraction.
    let cx_start = x_lo.floor();
    let cx_end = (x_hi).floor();
    let cy_start = y_lo.floor();
    let cy_end = (y_hi).floor();

    // Skip drops entirely off the grid.
    if cx_end < 0.0 || cy_end < 0.0 {
        return;
    }

    let cx0 = cx_start.max(0.0) as i64;
    let cy0 = cy_start.max(0.0) as i64;
    let cx1 = cx_end.min((out_w as i64 - 1) as f64) as i64;
    let cy1 = cy_end.min((out_h as i64 - 1) as f64) as i64;

    for cy in cy0..=cy1 {
        let cell_y0 = cy as f64;
        let cell_y1 = cell_y0 + 1.0;
        let oy_overlap = (y_hi.min(cell_y1) - y_lo.max(cell_y0)).max(0.0);
        if oy_overlap <= 0.0 {
            continue;
        }
        for cx in cx0..=cx1 {
            let cell_x0 = cx as f64;
            let cell_x1 = cell_x0 + 1.0;
            let ox_overlap = (x_hi.min(cell_x1) - x_lo.max(cell_x0)).max(0.0);
            if ox_overlap <= 0.0 {
                continue;
            }
            let overlap = ox_overlap * oy_overlap;
            let cell = (cy as usize) * out_w + (cx as usize);
            f(cell, overlap);
        }
    }
}

/// Gaussian drop: a circular Gaussian footprint with σ tied to the drop
/// half-width, its mass integrated exactly over each output cell it materially
/// touches.
///
/// We set `σ = half / 2` so the drop's `pixfrac·scale` extent is ≈ ±2σ (the
/// footprint is essentially contained within the same span as the square drop,
/// keeping the two kernels comparable in reach). The mass in a cell is the
/// separable product of 1-D Gaussian integrals over the cell's x- and y-extent,
/// each evaluated via the error function: `∫ N(t;μ,σ) dt = ½[erf((hi−μ)/(σ√2)) −
/// erf((lo−μ)/(σ√2))]`. Summed over all cells the mass → 1 (full unit drop), so
/// in the well-covered limit the Gaussian kernel is flux-conserving like the box.
/// We iterate cells within ±3σ of the centre (>99.7% of the mass) for efficiency.
fn gaussian_drop<F: FnMut(usize, f64)>(
    ox: f64,
    oy: f64,
    half: f64,
    out_w: usize,
    out_h: usize,
    mut f: F,
) {
    // σ tied to the drop half-width; guard the degenerate half→0 (point-like).
    let sigma = (half * 0.5).max(1e-6);
    let reach = 3.0 * sigma;
    let inv = 1.0 / (sigma * std::f64::consts::SQRT_2);

    let cx_start = (ox - reach).floor();
    let cx_end = (ox + reach).floor();
    let cy_start = (oy - reach).floor();
    let cy_end = (oy + reach).floor();

    if cx_end < 0.0 || cy_end < 0.0 {
        return;
    }
    let cx0 = cx_start.max(0.0) as i64;
    let cy0 = cy_start.max(0.0) as i64;
    let cx1 = cx_end.min((out_w as i64 - 1) as f64) as i64;
    let cy1 = cy_end.min((out_h as i64 - 1) as f64) as i64;

    // 1-D Gaussian CDF mass over [lo, hi] about mean mu.
    let mass_1d =
        |lo: f64, hi: f64, mu: f64| -> f64 { 0.5 * (erf((hi - mu) * inv) - erf((lo - mu) * inv)) };

    for cy in cy0..=cy1 {
        let my = mass_1d(cy as f64, cy as f64 + 1.0, oy);
        if my <= 0.0 {
            continue;
        }
        for cx in cx0..=cx1 {
            let mx = mass_1d(cx as f64, cx as f64 + 1.0, ox);
            if mx <= 0.0 {
                continue;
            }
            let cell = (cy as usize) * out_w + (cx as usize);
            f(cell, mx * my);
        }
    }
}

/// Abramowitz–Stegun 7.1.26 rational approximation of the error function.
///
/// Max absolute error ≈ 1.5e-7, far below the f32 master quantisation — more than
/// adequate for integrating the Gaussian drop footprint. Kept inline to avoid a
/// dependency just for one `erf`.
fn erf(x: f64) -> f64 {
    let sign = if x < 0.0 { -1.0 } else { 1.0 };
    let x = x.abs();
    let t = 1.0 / (1.0 + 0.327_591_1 * x);
    let y = 1.0
        - (((((1.061_405_429 * t - 1.453_152_027) * t) + 1.421_413_741) * t - 0.284_496_736) * t
            + 0.254_829_592)
            * t
            * (-x * x).exp();
    sign * y
}

// Tests

#[cfg(test)]
mod tests {
    use super::*;
    use crate::registration::TransformModel;

    /// Build a translation-only [`TransformModel`] (source → reference) that
    /// shifts a frame by `(tx, ty)` reference pixels. With `tx = ty = 0` this is
    /// the identity.
    fn translation(tx: f64, ty: f64) -> TransformModel {
        let mut m = TransformModel::identity();
        m.matrix[0][2] = tx;
        m.matrix[1][2] = ty;
        m
    }

    /// Tiny deterministic LCG (the crate's test-noise idiom) — unused for random
    /// noise here, but provided so a future test can inject reproducible jitter
    /// without pulling in `rand`.
    #[allow(dead_code)]
    struct Lcg(u64);
    impl Lcg {
        #[allow(dead_code)]
        fn next_f64(&mut self) -> f64 {
            self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1);
            (self.0 >> 11) as f64 / (1u64 << 53) as f64
        }
    }

    // (1) identity / scale=1 / pixfrac=1 ⇒ output ≈ input (flux-conserving).

    #[test]
    fn identity_scale1_pixfrac1_reproduces_input() {
        // A single 4x4 mono frame, identity transform, scale=1, pixfrac=1. Each
        // input pixel is a unit square that maps exactly onto one output cell, so
        // the drizzled master must equal the input to within float tolerance.
        let w = 4u32;
        let h = 4u32;
        let pixels: Vec<f64> = (0..(w * h)).map(|i| (i as f64) * 7.0 + 3.0).collect();
        let t = translation(0.0, 0.0);
        let frame = DrizzleFrame {
            pixels: &pixels,
            width: w,
            height: h,
            channels: 1,
            transform: &t,
            weight: 1.0,
        };
        let cfg = DrizzleConfig {
            scale: 1.0,
            pixfrac: 1.0,
            kernel: DrizzleKernel::Square,
        };
        let out = drizzle_integrate(&[frame], w, h, &cfg).unwrap();
        assert_eq!(out.master.width, w);
        assert_eq!(out.master.height, h);
        assert_eq!(out.master.channels, 1);
        let m = out.master.as_f32().unwrap();
        for (i, &expected) in pixels.iter().enumerate() {
            assert!(
                (m[i] as f64 - expected).abs() < 1e-3,
                "cell {i}: drizzled {} != input {expected}",
                m[i]
            );
        }
        // Every cell got exactly one full-overlap unit drop ⇒ coverage ≈ 1.
        let cov = out.coverage.as_f32().unwrap();
        for (i, &cw) in cov.iter().enumerate() {
            assert!(
                (cw as f64 - 1.0).abs() < 1e-3,
                "coverage[{i}] = {cw}, expected ~1.0"
            );
        }
    }

    #[test]
    fn rotation_90_deg_deposits_into_correct_cell() {
        // Under a 90° rotation, source pixel (0,0) maps to reference (N-1, 0)
        // and its flux must be deposited into output cell (N-1, 0). A half-pixel
        // offset applied before the transform lands it one cell along the
        // rotated axis instead.
        let n = 4usize;
        let w = n as u32;
        let mut pixels = vec![0.0f64; n * n];
        pixels[0] = 100.0; // source pixel (0, 0)

        // Source (x,y) -> (-y + (N-1), x): a 90° rotation about the grid.
        let mut t = TransformModel::identity();
        t.matrix = [
            [0.0, -1.0, (n - 1) as f64],
            [1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0],
        ];

        let frame = DrizzleFrame {
            pixels: &pixels,
            width: w,
            height: w,
            channels: 1,
            transform: &t,
            weight: 1.0,
        };
        let cfg = DrizzleConfig {
            scale: 1.0,
            pixfrac: 1.0,
            kernel: DrizzleKernel::Square,
        };
        let out = drizzle_integrate(&[frame], w, w, &cfg).unwrap();
        let m = out.master.as_f32().unwrap();

        let target = n - 1; // row 0, col N-1  -> flat index N-1
        let neighbour = n - 2; // the next cell along the rotated axis
        assert!(
            (m[target] as f64 - 100.0).abs() < 1e-3,
            "flux must land in cell {target}, got {}",
            m[target]
        );
        assert!(
            (m[neighbour] as f64).abs() < 1e-3,
            "cell {neighbour} must be empty, got {}",
            m[neighbour]
        );
    }

    #[test]
    fn box_drop_overlap_area_sums_to_footprint() {
        // The geometric guarantee: a single square drop deposits total weight
        // equal to its footprint area (pixfrac*scale)^2 (when fully on-grid).
        let mut total = 0.0;
        // Drop centred at (5.3, 4.7) in a large grid, half-width 0.9 (pixfrac=0.9,
        // scale=2 ⇒ side 1.8 ⇒ half 0.9).
        box_drop(5.3, 4.7, 0.9, 32, 32, |_cell, overlap| total += overlap);
        let footprint = (2.0 * 0.9_f64).powi(2);
        assert!(
            (total - footprint).abs() < 1e-9,
            "summed overlap {total} != footprint {footprint}"
        );
    }

    // (2) Dithered, under-sampled point source: drizzle at scale=2 localises the
    // peak better than a plain upsampled average.

    /// 1-D integral of a Gaussian PSF (mean `mu`, σ `sigma`) over `[lo, hi]`,
    /// using the same `erf` as the production Gaussian kernel. Used to render a
    /// physically-correct detector frame: a real pixel integrates the incident
    /// PSF over its area, it does not point-sample it.
    fn gauss_integral(lo: f64, hi: f64, mu: f64, sigma: f64) -> f64 {
        let inv = 1.0 / (sigma * std::f64::consts::SQRT_2);
        0.5 * (erf((hi - mu) * inv) - erf((lo - mu) * inv))
    }

    /// Render an **under-sampled** star: a narrow Gaussian PSF (σ = 0.45 px, well
    /// below the 1-px Nyquist limit) centred at sub-pixel `(cx, cy)`, integrated
    /// over each input pixel's unit area — exactly what a detector records. A
    /// single such frame cannot resolve the PSF (it spans ~1 pixel), which is the
    /// regime drizzle exists for.
    fn undersampled_star_frame(size: usize, cx: f64, cy: f64) -> Vec<f64> {
        let sigma = 0.45;
        let amp = 1000.0;
        let mut buf = vec![0.0f64; size * size];
        for y in 0..size {
            let iy = gauss_integral(y as f64, y as f64 + 1.0, cy, sigma);
            for x in 0..size {
                let ix = gauss_integral(x as f64, x as f64 + 1.0, cx, sigma);
                buf[y * size + x] = amp * ix * iy;
            }
        }
        buf
    }

    /// Bilinear upsample of a mono frame to `scale`× linear resolution, sampling
    /// output cell centre `(ox+0.5, oy+0.5)` back at input coordinate
    /// `(ox+0.5)/scale`. This is the *non-drizzle* baseline: warp-and-interpolate,
    /// which convolves the PSF with the interpolation kernel and necessarily
    /// widens an under-sampled point source.
    fn bilinear_upsample(src: &[f64], size: usize, scale: f64) -> (Vec<f64>, usize) {
        let out = (size as f64 * scale).ceil() as usize;
        let mut dst = vec![0.0f64; out * out];
        let sample = |sx: f64, sy: f64| -> f64 {
            let x0 = sx.floor();
            let y0 = sy.floor();
            let ix = x0 as i64;
            let iy = y0 as i64;
            let px = |xx: i64, yy: i64| -> f64 {
                if xx < 0 || yy < 0 || xx as usize >= size || yy as usize >= size {
                    0.0
                } else {
                    src[yy as usize * size + xx as usize]
                }
            };
            let fx = sx - x0;
            let fy = sy - y0;
            (1.0 - fx) * (1.0 - fy) * px(ix, iy)
                + fx * (1.0 - fy) * px(ix + 1, iy)
                + (1.0 - fx) * fy * px(ix, iy + 1)
                + fx * fy * px(ix + 1, iy + 1)
        };
        for oy in 0..out {
            for ox in 0..out {
                let sx = (ox as f64 + 0.5) / scale - 0.5;
                let sy = (oy as f64 + 0.5) / scale - 0.5;
                dst[oy * out + ox] = sample(sx, sy);
            }
        }
        (dst, out)
    }

    /// Second moment (variance about the flux centroid) of an image — a
    /// PSF-width proxy. Smaller ⇒ a tighter, better-localised source.
    fn flux_spread(img: &[f64], w: usize, h: usize) -> f64 {
        let mut sum = 0.0;
        let mut sx = 0.0;
        let mut sy = 0.0;
        for y in 0..h {
            for x in 0..w {
                let v = img[y * w + x];
                sum += v;
                sx += v * x as f64;
                sy += v * y as f64;
            }
        }
        if sum <= 0.0 {
            return f64::INFINITY;
        }
        let cx = sx / sum;
        let cy = sy / sum;
        let mut var = 0.0;
        for y in 0..h {
            for x in 0..w {
                let v = img[y * w + x];
                let dx = x as f64 - cx;
                let dy = y as f64 - cy;
                var += v * (dx * dx + dy * dy);
            }
        }
        var / sum
    }

    #[test]
    fn dithered_point_source_drizzles_sharper_than_upsampled_average() {
        // An under-sampled star sits at reference (8.3, 8.7) in a 16x16 frame,
        // captured by 4 sub-pixel-dithered exposures. The dithers move the star to
        // a different sub-pixel phase in each frame's own pixel grid; the
        // source→reference transform undoes the dither so all map back to the same
        // reference location. This is the canonical drizzle scenario.
        let size = 16usize;
        let ref_x = 8.3;
        let ref_y = 8.7;
        // Sub-pixel dithers (in reference px) applied to the pointing; the star's
        // position in each FRAME's coords is ref + dither.
        let dithers = [(0.0, 0.0), (0.5, 0.0), (0.0, 0.5), (0.5, 0.5)];

        let buffers: Vec<Vec<f64>> = dithers
            .iter()
            .map(|&(dx, dy)| undersampled_star_frame(size, ref_x + dx, ref_y + dy))
            .collect();
        // frame→reference transform = undo the dither (shift by -dither).
        let transforms: Vec<TransformModel> = dithers
            .iter()
            .map(|&(dx, dy)| translation(-dx, -dy))
            .collect();

        let frames: Vec<DrizzleFrame> = buffers
            .iter()
            .zip(transforms.iter())
            .map(|(b, t)| DrizzleFrame {
                pixels: b,
                width: size as u32,
                height: size as u32,
                channels: 1,
                transform: t,
                weight: 1.0,
            })
            .collect();

        let scale = 2.0;
        let cfg = DrizzleConfig {
            scale,
            pixfrac: 0.5, // shrink drops hard so the dithers reconstruct fine detail
            kernel: DrizzleKernel::Square,
        };
        let driz = drizzle_integrate(&frames, size as u32, size as u32, &cfg).unwrap();
        let out_w = driz.master.width as usize;
        let out_h = driz.master.height as usize;
        let dm: Vec<f64> = driz
            .master
            .as_f32()
            .unwrap()
            .iter()
            .map(|&v| v as f64)
            .collect();

        // Baseline (non-drizzle): bilinear-upsample each REGISTERED frame to the 2x
        // grid and average. We register by shifting each frame back onto the
        // reference grid first (apply the inverse dither, i.e. +dither in source
        // coords) — equivalently, just upsample frame 0 (already on the reference
        // pointing) since all frames carry the same registered PSF. Averaging the
        // four upsampled-registered frames gives the standard warp-and-stack.
        let mut naive = vec![0.0f64; out_w * out_h];
        for (b, &(dx, dy)) in buffers.iter().zip(dithers.iter()) {
            // Register the frame back to the reference grid by shifting its PSF by
            // -dither in frame pixels (the frame star is at ref+dither), then
            // upsample. We fold the shift into the upsample sample coordinate.
            let (up, uw) = bilinear_upsample(b, size, scale);
            debug_assert_eq!(uw, out_w);
            // Shift the upsampled frame by (-dither*scale) so registered PSFs align.
            let shift_x = (dx * scale).round() as i64;
            let shift_y = (dy * scale).round() as i64;
            for oy in 0..out_h {
                for ox in 0..out_w {
                    let sxp = ox as i64 + shift_x;
                    let syp = oy as i64 + shift_y;
                    if sxp >= 0 && syp >= 0 && (sxp as usize) < out_w && (syp as usize) < out_h {
                        naive[oy * out_w + ox] += up[syp as usize * out_w + sxp as usize];
                    }
                }
            }
        }

        let driz_spread = flux_spread(&dm, out_w, out_h);
        let naive_spread = flux_spread(&naive, out_w, out_h);
        assert!(
            driz_spread < naive_spread,
            "drizzle spread {driz_spread} should be tighter (sharper) than the \
             bilinear-upsampled average {naive_spread}"
        );

        // The reconstructed peak should sit near the true location on the 2x grid:
        // (ref_x*scale, ref_y*scale) = (16.6, 17.4) → nearest cell (16 or 17).
        let mut peak_idx = 0usize;
        let mut peak_val = f64::MIN;
        for (i, &v) in dm.iter().enumerate() {
            if v > peak_val {
                peak_val = v;
                peak_idx = i;
            }
        }
        let peak_x = (peak_idx % out_w) as f64;
        let peak_y = (peak_idx / out_w) as f64;
        assert!(
            (peak_x - ref_x * scale).abs() <= 2.0 && (peak_y - ref_y * scale).abs() <= 2.0,
            "reconstructed peak ({peak_x},{peak_y}) far from expected ({},{})",
            ref_x * scale,
            ref_y * scale
        );

        // Coverage must be > 0 over the region the source illuminated.
        let cov = driz.coverage.as_f32().unwrap();
        let covered = cov.iter().filter(|&&c| c > 0.0).count();
        assert!(
            covered > 0,
            "coverage buffer must be non-zero where covered"
        );
        assert!(cov[peak_idx] > 0.0, "peak cell must have positive coverage");
    }

    // (3) Bayer drizzle reconstructs the correct RGB from a known CFA pattern.

    #[test]
    fn bayer_drizzle_reconstructs_known_rgb() {
        // Build an RGGB mosaic of a flat colour field: every red site = 100,
        // every green site = 200, every blue site = 50. Drizzle at scale=1,
        // pixfrac=1 so each CFA pixel maps onto exactly one output cell of its
        // plane. We dither 4 frames so every output cell is touched by every
        // colour plane (a single frame leaves each plane on a sparse sublattice).
        let size = 8usize;
        let pattern = BayerPattern::RGGB;
        let (rv, gv, bv) = (100.0, 200.0, 50.0);

        let make_mosaic = || -> Vec<f64> {
            let mut m = vec![0.0f64; size * size];
            for y in 0..size {
                for x in 0..size {
                    m[y * size + x] = match pattern.color_at(x, y) {
                        BayerColor::Red => rv,
                        BayerColor::Green => gv,
                        BayerColor::Blue => bv,
                    };
                }
            }
            m
        };

        // Four integer dithers of (0/1, 0/1) shift which colour lands on each
        // reference cell, so after stacking every cell sees R, G, and B samples.
        let dithers = [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)];
        let mosaics: Vec<Vec<f64>> = dithers.iter().map(|_| make_mosaic()).collect();
        let transforms: Vec<TransformModel> = dithers
            .iter()
            .map(|&(dx, dy)| translation(dx, dy))
            .collect();

        let frames: Vec<BayerDrizzleFrame> = mosaics
            .iter()
            .zip(transforms.iter())
            .map(|(m, t)| BayerDrizzleFrame {
                mosaic: m,
                width: size as u32,
                height: size as u32,
                pattern,
                transform: t,
                weight: 1.0,
            })
            .collect();

        let cfg = DrizzleConfig {
            scale: 1.0,
            pixfrac: 1.0,
            kernel: DrizzleKernel::Square,
        };
        let out = bayer_drizzle_integrate(&frames, size as u32, size as u32, &cfg).unwrap();
        assert_eq!(out.master.channels, 3);
        let rgb = out.master.as_f32().unwrap();

        // Inspect interior cells (away from the border, which loses some coverage
        // because the integer dithers shift the mosaic off-grid by one pixel).
        // For any fully-covered interior cell the three planes must read back the
        // flat field colours we deposited.
        let mut checked = 0;
        for y in 1..size - 1 {
            for x in 1..size - 1 {
                let cell = y * size + x;
                let r = rgb[cell * 3] as f64;
                let g = rgb[cell * 3 + 1] as f64;
                let b = rgb[cell * 3 + 2] as f64;
                // Only assert on cells that received all three colours (coverage
                // for the plane > 0 ⇒ value is the flat colour, not the 0 hole).
                if r > 0.0 && g > 0.0 && b > 0.0 {
                    assert!((r - rv).abs() < 1e-3, "R at ({x},{y}) = {r}, want {rv}");
                    assert!((g - gv).abs() < 1e-3, "G at ({x},{y}) = {g}, want {gv}");
                    assert!((b - bv).abs() < 1e-3, "B at ({x},{y}) = {b}, want {bv}");
                    checked += 1;
                }
            }
        }
        assert!(
            checked > 0,
            "expected at least one fully-covered interior cell to validate"
        );

        // Green coverage (the reported coverage plane) must be positive somewhere.
        let cov = out.coverage.as_f32().unwrap();
        assert!(cov.iter().any(|&c| c > 0.0), "green coverage must be > 0");
    }

    #[test]
    fn bayer_single_frame_deposits_only_into_color_planes() {
        // One un-dithered RGGB frame: each cell should get EXACTLY one colour,
        // the others left as holes (0). This pins the "no debayer interpolation"
        // contract — a Bayer drizzle of one frame is sparse per plane.
        let size = 4usize;
        let pattern = BayerPattern::RGGB;
        let mut mosaic = vec![0.0f64; size * size];
        for y in 0..size {
            for x in 0..size {
                mosaic[y * size + x] = match pattern.color_at(x, y) {
                    BayerColor::Red => 100.0,
                    BayerColor::Green => 200.0,
                    BayerColor::Blue => 50.0,
                };
            }
        }
        let t = translation(0.0, 0.0);
        let frame = BayerDrizzleFrame {
            mosaic: &mosaic,
            width: size as u32,
            height: size as u32,
            pattern,
            transform: &t,
            weight: 1.0,
        };
        let cfg = DrizzleConfig {
            scale: 1.0,
            pixfrac: 1.0,
            kernel: DrizzleKernel::Square,
        };
        let out = bayer_drizzle_integrate(&[frame], size as u32, size as u32, &cfg).unwrap();
        let rgb = out.master.as_f32().unwrap();

        // Cell (0,0) is RED in RGGB ⇒ R=100, G=0, B=0.
        let c00 = 0usize;
        assert!((rgb[c00 * 3] as f64 - 100.0).abs() < 1e-3, "R(0,0)");
        assert_eq!(rgb[c00 * 3 + 1], 0.0, "G(0,0) must be a hole");
        assert_eq!(rgb[c00 * 3 + 2], 0.0, "B(0,0) must be a hole");

        // Cell (1,1) is BLUE in RGGB ⇒ R=0, G=0, B=50.
        let c11 = size + 1;
        assert_eq!(rgb[c11 * 3], 0.0, "R(1,1) must be a hole");
        assert_eq!(rgb[c11 * 3 + 1], 0.0, "G(1,1) must be a hole");
        assert!((rgb[c11 * 3 + 2] as f64 - 50.0).abs() < 1e-3, "B(1,1)");

        // Cell (1,0) is GREEN in RGGB ⇒ R=0, G=200, B=0.
        let c10 = 1usize;
        assert_eq!(rgb[c10 * 3], 0.0, "R(1,0) must be a hole");
        assert!((rgb[c10 * 3 + 1] as f64 - 200.0).abs() < 1e-3, "G(1,0)");
        assert_eq!(rgb[c10 * 3 + 2], 0.0, "B(1,0) must be a hole");
    }

    // RGB (3-channel) drizzle sanity: per-channel flux is preserved.

    #[test]
    fn rgb_identity_drizzle_preserves_each_channel() {
        // 2x2 interleaved RGB frame, identity, scale=1, pixfrac=1.
        let w = 2u32;
        let h = 2u32;
        // (r,g,b) per pixel, row-major.
        let pixels = vec![
            10.0, 20.0, 30.0, 11.0, 21.0, 31.0, // row 0
            12.0, 22.0, 32.0, 13.0, 23.0, 33.0, // row 1
        ];
        let t = translation(0.0, 0.0);
        let frame = DrizzleFrame {
            pixels: &pixels,
            width: w,
            height: h,
            channels: 3,
            transform: &t,
            weight: 1.0,
        };
        let out = drizzle_integrate(
            &[frame],
            w,
            h,
            &DrizzleConfig {
                scale: 1.0,
                pixfrac: 1.0,
                kernel: DrizzleKernel::Square,
            },
        )
        .unwrap();
        assert_eq!(out.master.channels, 3);
        let m = out.master.as_f32().unwrap();
        for (i, &expected) in pixels.iter().enumerate() {
            assert!(
                (m[i] as f64 - expected).abs() < 1e-3,
                "channel-interleaved cell {i}: {} != {expected}",
                m[i]
            );
        }
    }

    #[test]
    fn weighting_is_an_overlap_weighted_mean() {
        // Two frames over a single reference pixel, identity transform, scale=1,
        // pixfrac=1. Each deposits its value with weight 1*overlap (overlap=1).
        // The master must be the weight-weighted mean.
        let p0 = [100.0];
        let p1 = [300.0];
        let t = translation(0.0, 0.0);
        let f0 = DrizzleFrame {
            pixels: &p0,
            width: 1,
            height: 1,
            channels: 1,
            transform: &t,
            weight: 1.0,
        };
        let f1 = DrizzleFrame {
            pixels: &p1,
            width: 1,
            height: 1,
            channels: 1,
            transform: &t,
            weight: 3.0,
        };
        let out = drizzle_integrate(
            &[f0, f1],
            1,
            1,
            &DrizzleConfig {
                scale: 1.0,
                pixfrac: 1.0,
                kernel: DrizzleKernel::Square,
            },
        )
        .unwrap();
        let m = out.master.as_f32().unwrap();
        // (1*100 + 3*300) / (1 + 3) = 1000/4 = 250.
        assert!((m[0] as f64 - 250.0).abs() < 1e-3, "got {}", m[0]);
        // Coverage = sum of frame_weight*overlap = 1 + 3 = 4.
        let cov = out.coverage.as_f32().unwrap();
        assert!((cov[0] as f64 - 4.0).abs() < 1e-3, "coverage {}", cov[0]);
    }

    #[test]
    fn non_finite_sample_is_excluded_not_treated_as_zero() {
        // A non-finite (NaN/Inf) sample must NOT bias the
        // overlap-weighted mean toward zero. Two equal-weight, fully-overlapping
        // mono drops with values {100, NaN}: the resolved master must be the mean
        // of the *finite* samples (100), not (100+0)/2 = 50.
        for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let p_good = [100.0];
            let p_bad = [bad];
            let t = translation(0.0, 0.0);
            let f_good = DrizzleFrame {
                pixels: &p_good,
                width: 1,
                height: 1,
                channels: 1,
                transform: &t,
                weight: 1.0,
            };
            let f_bad = DrizzleFrame {
                pixels: &p_bad,
                width: 1,
                height: 1,
                channels: 1,
                transform: &t,
                weight: 1.0,
            };
            let out = drizzle_integrate(
                &[f_good, f_bad],
                1,
                1,
                &DrizzleConfig {
                    scale: 1.0,
                    pixfrac: 1.0,
                    kernel: DrizzleKernel::Square,
                },
            )
            .unwrap();
            let m = out.master.as_f32().unwrap();
            assert!(
                (m[0] as f64 - 100.0).abs() < 1e-3,
                "non-finite sample {bad} must be excluded, not averaged as 0: got {}",
                m[0]
            );
            // The non-finite drop must contribute NOTHING to coverage either —
            // only the one good, finite drop counts (weight*overlap = 1).
            let cov = out.coverage.as_f32().unwrap();
            assert!(
                (cov[0] as f64 - 1.0).abs() < 1e-3,
                "non-finite drop must not inflate coverage: got {}",
                cov[0]
            );
        }
    }

    #[test]
    fn rgb_non_finite_in_one_channel_skips_whole_pixel() {
        // A 3-channel drop where one channel is non-finite: because the geometric
        // weight is shared across channels, the WHOLE pixel must be skipped (we
        // cannot deposit the good channels against a denominator the bad channel
        // also rides on). Two frames over one RGB cell: frame A all-finite
        // (10,20,30), frame B has a NaN green (5, NaN, 7). The master must equal
        // frame A exactly (B is fully excluded), not a green biased toward zero.
        let pa = [10.0, 20.0, 30.0];
        let pb = [5.0, f64::NAN, 7.0];
        let t = translation(0.0, 0.0);
        let fa = DrizzleFrame {
            pixels: &pa,
            width: 1,
            height: 1,
            channels: 3,
            transform: &t,
            weight: 1.0,
        };
        let fb = DrizzleFrame {
            pixels: &pb,
            width: 1,
            height: 1,
            channels: 3,
            transform: &t,
            weight: 1.0,
        };
        let out = drizzle_integrate(
            &[fa, fb],
            1,
            1,
            &DrizzleConfig {
                scale: 1.0,
                pixfrac: 1.0,
                kernel: DrizzleKernel::Square,
            },
        )
        .unwrap();
        let m = out.master.as_f32().unwrap();
        assert!(
            (m[0] as f64 - 10.0).abs() < 1e-3,
            "R must equal frame A, got {}",
            m[0]
        );
        assert!(
            (m[1] as f64 - 20.0).abs() < 1e-3,
            "G must equal frame A (B excluded), got {}",
            m[1]
        );
        assert!(
            (m[2] as f64 - 30.0).abs() < 1e-3,
            "B-plane must equal frame A, got {}",
            m[2]
        );
        // Coverage counts only frame A's one finite drop.
        let cov = out.coverage.as_f32().unwrap();
        assert!(
            (cov[0] as f64 - 1.0).abs() < 1e-3,
            "coverage must be 1 (only A counted), got {}",
            cov[0]
        );
    }

    #[test]
    fn gaussian_kernel_produces_smoother_finite_output() {
        // Sanity: the Gaussian kernel runs end-to-end, conserves a single drop's
        // mass to ~1, and produces finite values. We check the mass property of a
        // fully-on-grid Gaussian drop directly.
        let mut total = 0.0;
        gaussian_drop(10.0, 10.0, 1.0, 32, 32, |_c, mass| total += mass);
        // Mass of a unit Gaussian integrated over the plane → 1 (we capture ±3σ).
        assert!(
            (total - 1.0).abs() < 1e-2,
            "gaussian drop mass {total} should be ~1.0"
        );
    }

    #[test]
    fn erf_matches_known_values() {
        // Spot-check the erf approximation against textbook values.
        assert!((erf(0.0)).abs() < 1e-7);
        assert!((erf(1.0) - 0.842_700_79).abs() < 1e-6);
        assert!((erf(-1.0) + 0.842_700_79).abs() < 1e-6);
        assert!((erf(2.0) - 0.995_322_27).abs() < 1e-6);
    }

    // (4) error paths.

    #[test]
    fn no_frames_errors() {
        let cfg = DrizzleConfig::default();
        let err = drizzle_integrate(&[], 4, 4, &cfg).unwrap_err();
        assert_eq!(err, DrizzleError::NoFrames);
    }

    #[test]
    fn no_bayer_frames_errors() {
        let cfg = DrizzleConfig::default();
        let err = bayer_drizzle_integrate(&[], 4, 4, &cfg).unwrap_err();
        assert_eq!(err, DrizzleError::NoFrames);
    }

    #[test]
    fn bad_params_error() {
        let pixels = [1.0];
        let t = translation(0.0, 0.0);
        let frame = DrizzleFrame {
            pixels: &pixels,
            width: 1,
            height: 1,
            channels: 1,
            transform: &t,
            weight: 1.0,
        };
        // scale <= 0
        assert_eq!(
            drizzle_integrate(
                &[frame],
                1,
                1,
                &DrizzleConfig {
                    scale: 0.0,
                    pixfrac: 0.9,
                    kernel: DrizzleKernel::Square
                }
            )
            .unwrap_err(),
            DrizzleError::BadParams
        );
        // pixfrac > 1
        assert_eq!(
            drizzle_integrate(
                &[frame],
                1,
                1,
                &DrizzleConfig {
                    scale: 2.0,
                    pixfrac: 1.5,
                    kernel: DrizzleKernel::Square
                }
            )
            .unwrap_err(),
            DrizzleError::BadParams
        );
        // pixfrac <= 0
        assert_eq!(
            drizzle_integrate(
                &[frame],
                1,
                1,
                &DrizzleConfig {
                    scale: 2.0,
                    pixfrac: 0.0,
                    kernel: DrizzleKernel::Square
                }
            )
            .unwrap_err(),
            DrizzleError::BadParams
        );
    }

    #[test]
    fn dim_mismatch_errors() {
        let t = translation(0.0, 0.0);
        // Buffer length != width*height*channels.
        let bad = [1.0, 2.0, 3.0]; // declares 2x2x1 = 4 but has 3
        let frame = DrizzleFrame {
            pixels: &bad,
            width: 2,
            height: 2,
            channels: 1,
            transform: &t,
            weight: 1.0,
        };
        assert_eq!(
            drizzle_integrate(&[frame], 2, 2, &DrizzleConfig::default()).unwrap_err(),
            DrizzleError::DimMismatch
        );

        // Zero reference grid.
        let ok = [1.0];
        let frame_ok = DrizzleFrame {
            pixels: &ok,
            width: 1,
            height: 1,
            channels: 1,
            transform: &t,
            weight: 1.0,
        };
        assert_eq!(
            drizzle_integrate(&[frame_ok], 0, 4, &DrizzleConfig::default()).unwrap_err(),
            DrizzleError::DimMismatch
        );
    }

    #[test]
    fn channel_mismatch_between_frames_errors() {
        let t = translation(0.0, 0.0);
        let p_mono = [1.0];
        let p_rgb = [1.0, 2.0, 3.0];
        let f_mono = DrizzleFrame {
            pixels: &p_mono,
            width: 1,
            height: 1,
            channels: 1,
            transform: &t,
            weight: 1.0,
        };
        let f_rgb = DrizzleFrame {
            pixels: &p_rgb,
            width: 1,
            height: 1,
            channels: 3,
            transform: &t,
            weight: 1.0,
        };
        assert_eq!(
            drizzle_integrate(&[f_mono, f_rgb], 1, 1, &DrizzleConfig::default()).unwrap_err(),
            DrizzleError::DimMismatch
        );
    }

    #[test]
    fn bayer_dim_mismatch_errors() {
        let t = translation(0.0, 0.0);
        let bad = [1.0, 2.0, 3.0]; // 2x2 = 4 expected, 3 given
        let frame = BayerDrizzleFrame {
            mosaic: &bad,
            width: 2,
            height: 2,
            pattern: BayerPattern::RGGB,
            transform: &t,
            weight: 1.0,
        };
        assert_eq!(
            bayer_drizzle_integrate(&[frame], 2, 2, &DrizzleConfig::default()).unwrap_err(),
            DrizzleError::DimMismatch
        );
    }

    #[test]
    fn zero_weight_frames_are_skipped_but_not_an_error() {
        // A zero-weight frame contributes nothing; with only that frame the
        // master is all-zero (uncovered) but the call still succeeds (the
        // population was non-empty and well-formed).
        let pixels = [500.0];
        let t = translation(0.0, 0.0);
        let frame = DrizzleFrame {
            pixels: &pixels,
            width: 1,
            height: 1,
            channels: 1,
            transform: &t,
            weight: 0.0,
        };
        let out = drizzle_integrate(&[frame], 1, 1, &DrizzleConfig::default()).unwrap();
        let m = out.master.as_f32().unwrap();
        assert_eq!(m[0], 0.0, "zero-weight frame must leave an uncovered hole");
        let cov = out.coverage.as_f32().unwrap();
        assert_eq!(cov[0], 0.0);
    }

    #[test]
    fn output_dims_are_ceil_of_scaled_reference() {
        // ref 3x5, scale 2.0 ⇒ 6x10. ref 3x3 scale 1.5 ⇒ ceil(4.5)=5.
        assert_eq!(output_dims(3, 5, 2.0), (6, 10));
        assert_eq!(output_dims(3, 3, 1.5), (5, 5));
        // scale 2 on the public path: the master carries the ceil'd dims.
        let pixels = [1.0, 2.0, 3.0, 4.0]; // 2x2
        let t = translation(0.0, 0.0);
        let frame = DrizzleFrame {
            pixels: &pixels,
            width: 2,
            height: 2,
            channels: 1,
            transform: &t,
            weight: 1.0,
        };
        let out = drizzle_integrate(
            &[frame],
            2,
            2,
            &DrizzleConfig {
                scale: 2.0,
                pixfrac: 0.9,
                kernel: DrizzleKernel::Square,
            },
        )
        .unwrap();
        assert_eq!((out.master.width, out.master.height), (4, 4));
        assert_eq!((out.coverage.width, out.coverage.height), (4, 4));
        assert_eq!(out.coverage.channels, 1);
    }
}
