//! Mosaic stitching — project N plate-solved panel masters onto one common
//! tangent-plane canvas and blend them into a single mosaic master.
//!
//! # Why this module exists
//!
//! A wide-field mosaic is captured as an N×M grid of overlapping panels, each
//! integrated to its own master with its own plate-solved WCS (the `WcsInfo`
//! CD-matrix that rides on every `integrated_masters` row). This is the only
//! place in the imaging crate that puts spatially-offset panels onto a shared
//! output frame: [`registration`](crate::registration) warps a frame onto the
//! *reference's exact pixel grid* (so it cannot grow a canvas), and
//! [`normalization`](crate::normalization) matches a sub onto a *reference's
//! photometric scale* over the *same grid*. What this module adds is a
//! variable-size, WCS-driven reprojection plus an overlap-region global
//! photometric solve plus seam feathering.
//!
//! # Algorithm
//!
//! 1. **TAN projection helpers** ([`WcsProjection`]) — exact spherical gnomonic
//!    (RA---TAN / DEC--TAN) forward (pixel→world) and inverse (world→pixel)
//!    derived from a [`WcsInfo`] CD matrix. This is the FITS-standard projection,
//!    not the small-angle linearisation `wcs_overlay.dart` uses for screen grids;
//!    a mosaic spans degrees and must not accumulate small-angle error across the
//!    canvas. Round-trips to < 1e-6 px (see tests).
//!
//! 2. **Output canvas** ([`build_output_wcs`]) — the reference projection centre
//!    is the median of the panel `CRVAL` centres; the output pixel scale is the
//!    median panel scale (or a caller override). Every panel's four corners are
//!    projected onto the output tangent plane; the bounding box (+1 px margin)
//!    fixes the canvas width/height and `CRPIX` so the union maps into
//!    `[0, w) × [0, h)`. A `CanvasTooLarge` guard rejects absurd canvases.
//!
//! 3. **Cross-panel normalization** ([`solve_panel_photometry`]) — for every
//!    pair of panels whose canvas footprints overlap, matched (panel_i, panel_j)
//!    samples over the shared sky are fitted to a relative scale+offset with the
//!    crate's co-located pixel-pair line fit
//!    ([`crate::normalization::NormEstimator::CoLocatedPairFit`]) — valid here
//!    precisely because both panels are resampled onto one canvas first, so
//!    paired samples share a sky coordinate. A single global
//!    least-squares then solves per-panel gain `g_k` and offset `o_k`, anchored
//!    to a reference panel (`g_ref = 1`, `o_ref = 0`), so all panels share one
//!    photometric scale. Panels with no overlap default to `g = 1`, `o = 0`.
//!
//! 4. **Render** ([`render_canvas`], rayon over output rows) — for each output
//!    pixel: world ← output WCS; for each panel whose footprint contains that
//!    world point, pixel ← panel WCS, sample with `cfg.resampler`, apply
//!    `g_k·sample + o_k`, accumulate with a blend weight (Feather: distance from
//!    the panel edge, clamped to `feather_px`; None: 1). The output is the
//!    weighted mean `Σ(w·v)/Σw` per channel, and the coverage plane is `Σw`.
//!
//! All internal arithmetic is `f64`; inputs and outputs are `F32`
//! [`ImageData`](crate::ImageData). Failures are explicit [`MosaicError`]s — a
//! degenerate WCS or an empty panel list is never papered over with a blank
//! canvas.

use rayon::prelude::*;
use thiserror::Error;

use crate::normalization::{
    estimate_normalization, CoverageMask, NormEstimator, NormalizationConfig,
};
use crate::registration::Interpolator;
use crate::robust_stats::median_in_place as median;
use crate::{ImageData, WcsInfo};

/// Hard upper bound on the output canvas in pixels (per channel-plane). At
/// ~400 megapixels a single F32 plane is 1.6 GB; beyond this the caller almost
/// certainly passed garbage WCS (e.g. a panel solved to the wrong field), so the
/// stitch errors rather than trying to allocate a terabyte. The tunable knob
/// lives here, not scattered through the renderer.
const MAX_CANVAS_PIXELS: u64 = 400_000_000;

/// One panel feeding a mosaic: a linear master plus the WCS that places it on
/// the sky.
///
/// `image` is the integrated, plate-solved panel master (any pixel type the
/// integration pipeline emits — `F32` linear is canonical, `U16` is accepted —
/// decoded to `f64` internally). `wcs` is its solved CD-matrix astrometry; the
/// stitcher projects each panel directly through this WCS, never re-deriving
/// geometry from stars.
#[derive(Debug, Clone)]
pub struct MosaicPanel {
    /// Linear panel master (typically `F32`).
    pub image: ImageData,
    /// Solved CD-matrix WCS for this panel.
    pub wcs: WcsInfo,
}

/// Seam-blending strategy across panel overlaps.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum MosaicBlend {
    /// Hard average: every contributing panel gets weight 1 in the overlap. A
    /// visible seam appears wherever two photometrically-imperfect panels meet,
    /// but it is the cheapest and most faithful to the raw per-panel data.
    None,
    /// Feather: each panel's weight ramps from 0 at its frame edge to 1 at
    /// `feather_px` inside, so contributions cross-fade across the overlap and
    /// the seam dissolves. The default.
    #[default]
    Feather,
}

/// Tunables for [`stitch_mosaic`]. [`Default`] is a Lanczos-3, photometrically
/// normalized, feather-blended stitch at the median panel scale.
#[derive(Debug, Clone)]
pub struct MosaicStitchConfig {
    /// Resampling kernel for the per-panel reprojection. Default
    /// [`Interpolator::Lanczos3`].
    pub resampler: Interpolator,
    /// Cross-panel photometric matching (per-panel gain+offset global solve).
    /// Default `true`.
    pub normalize: bool,
    /// Seam-blend mode. Default [`MosaicBlend::Feather`].
    pub blend: MosaicBlend,
    /// Feather ramp width in output pixels. Ignored unless `blend == Feather`.
    /// Default `64.0`.
    pub feather_px: f64,
    /// Output pixel scale in arcsec/px. `None` ⇒ the median of the panel
    /// scales.
    pub output_pixel_scale_arcsec: Option<f64>,
}

impl Default for MosaicStitchConfig {
    fn default() -> Self {
        Self {
            resampler: Interpolator::Lanczos3,
            normalize: true,
            blend: MosaicBlend::Feather,
            feather_px: 64.0,
            output_pixel_scale_arcsec: None,
        }
    }
}

/// Diagnostics from a completed stitch.
#[derive(Debug, Clone, PartialEq)]
pub struct MosaicStitchStats {
    /// Number of panels stitched.
    pub panels: usize,
    /// Output canvas width in pixels.
    pub out_width: u32,
    /// Output canvas height in pixels.
    pub out_height: u32,
    /// Number of overlapping panel pairs found (the photometric adjacency edges).
    pub overlap_pairs: usize,
    /// Mean of the solved per-panel gains (1.0 when normalization is off or no
    /// overlaps were found). A sanity number for the report — far from 1.0 hints
    /// at very different panel exposures / transparency.
    pub mean_panel_gain: f64,
}

/// The result of a stitch.
#[derive(Debug, Clone)]
pub struct MosaicOutput {
    /// The stitched mosaic master (`F32`, same channel count as the panels).
    pub master: ImageData,
    /// Per-pixel contributing weight (`Σw`), single-channel `F32`. Zero where no
    /// panel covered the pixel; ~`n` in an n-panel overlap (None blend) or the
    /// summed feather weight (Feather blend).
    pub coverage: ImageData,
    /// The output canvas WCS.
    pub wcs: WcsInfo,
    /// Stitch diagnostics.
    pub stats: MosaicStitchStats,
}

/// Failure modes of [`stitch_mosaic`]. Each is an *expected* bad input or
/// resource limit, surfaced so the caller can report it — never a silent blank
/// canvas.
#[derive(Debug, Error, PartialEq)]
pub enum MosaicError {
    /// No panels were supplied.
    #[error("no panels supplied to the mosaic stitcher")]
    NoPanels,
    /// A panel has zero width or height (nothing to project).
    #[error("a panel has zero width or height")]
    Dimensionless,
    /// A panel's WCS CD matrix is singular (determinant ~0) so world↔pixel is
    /// not invertible.
    #[error("a panel has a degenerate (non-invertible) WCS")]
    DegenerateWcs,
    /// Panels disagree on channel count; the stitcher composites matching
    /// channels only.
    #[error("panels have mismatched channel counts")]
    ChannelMismatch,
    /// The computed output canvas exceeds [`MAX_CANVAS_PIXELS`].
    #[error("output canvas too large: {pixels} pixels")]
    CanvasTooLarge {
        /// Requested canvas size in pixels (`width × height`).
        pixels: u64,
    },
}

// WCS projection (gnomonic / TAN)

/// Forward / inverse gnomonic (RA---TAN, DEC--TAN) projection for one
/// CD-matrix [`WcsInfo`].
///
/// FITS WCS pipeline:
///   pixel (1-based `x, y`) ──CD──▶ intermediate world `(ξ, η)` in degrees
///   `(ξ, η)` ──TAN deproject──▶ native spherical `(φ, θ)`
///   `(φ, θ)` ──rotate by (CRVAL1, CRVAL2)──▶ celestial `(α, δ)`.
///
/// We pre-invert the CD matrix once so `world_to_pixel` is a closed form. The
/// pixel convention here is **0-based** (`x = 0` is the first column centre):
/// FITS `CRPIXn` is 1-based, so we carry the `-1` offset internally and expose a
/// 0-based interface that matches the rest of the imaging crate (the resampler,
/// `ImageData` indexing).
#[derive(Debug, Clone)]
pub struct WcsProjection {
    crval1_rad: f64,
    crval2_rad: f64,
    // 0-based reference pixel.
    crpix1_0: f64,
    crpix2_0: f64,
    cd1_1: f64,
    cd1_2: f64,
    cd2_1: f64,
    cd2_2: f64,
    // Inverse of the CD matrix (deg⁻¹), for world→pixel.
    inv_cd1_1: f64,
    inv_cd1_2: f64,
    inv_cd2_1: f64,
    inv_cd2_2: f64,
    // Precomputed trig of the reference declination.
    sin_dec0: f64,
    cos_dec0: f64,
}

impl WcsProjection {
    /// Build a projection from a [`WcsInfo`], or `None` if the CD matrix is
    /// singular (determinant below a small epsilon → world↔pixel non-invertible).
    pub fn new(wcs: &WcsInfo) -> Option<Self> {
        let det = wcs.cd1_1 * wcs.cd2_2 - wcs.cd1_2 * wcs.cd2_1;
        // A real CD matrix is ~ (scale)² with scale ~ arcsec/px in degrees, i.e.
        // tiny but never zero. 1e-18 deg² ≈ (3.6e-6 arcsec)² — far below any real
        // plate scale, so this rejects only genuine degeneracy.
        if !det.is_finite() || det.abs() < 1e-18 {
            return None;
        }
        let inv = 1.0 / det;
        let crval2_rad = wcs.crval2.to_radians();
        Some(Self {
            crval1_rad: wcs.crval1.to_radians(),
            crval2_rad,
            crpix1_0: wcs.crpix1 - 1.0,
            crpix2_0: wcs.crpix2 - 1.0,
            cd1_1: wcs.cd1_1,
            cd1_2: wcs.cd1_2,
            cd2_1: wcs.cd2_1,
            cd2_2: wcs.cd2_2,
            inv_cd1_1: wcs.cd2_2 * inv,
            inv_cd1_2: -wcs.cd1_2 * inv,
            inv_cd2_1: -wcs.cd2_1 * inv,
            inv_cd2_2: wcs.cd1_1 * inv,
            sin_dec0: crval2_rad.sin(),
            cos_dec0: crval2_rad.cos(),
        })
    }

    /// Forward projection: 0-based pixel `(x, y)` → celestial `(ra, dec)` in
    /// **degrees**. `ra` is normalised to `[0, 360)`.
    pub fn pixel_to_world(&self, x: f64, y: f64) -> (f64, f64) {
        // Pixel → intermediate world coordinates (degrees) via CD.
        let dx = x - self.crpix1_0;
        let dy = y - self.crpix2_0;
        let xi_deg = self.cd1_1 * dx + self.cd1_2 * dy;
        let eta_deg = self.cd2_1 * dx + self.cd2_2 * dy;
        // Intermediate world coords are standard coordinates on the tangent
        // plane in degrees. TAN deprojection (Calabretta & Greisen 2002):
        //   ξ = sin(φ)·R, η = -cos(φ)·R with R = cot(θ); equivalently use the
        // standard-coordinate form below.
        let xi = xi_deg.to_radians();
        let eta = eta_deg.to_radians();
        // ρ = angular distance from the tangent point, with r = tan(ρ).
        let r = (xi * xi + eta * eta).sqrt();
        if r < 1e-15 {
            // At the tangent point exactly.
            return (
                normalize_deg(self.crval1_rad.to_degrees()),
                self.crval2_rad.to_degrees(),
            );
        }
        let rho = r.atan();
        let sin_rho = rho.sin();
        let cos_rho = rho.cos();
        // Native longitude φ measured from the +η (north) axis.
        // Standard inverse-TAN spherical reconstruction:
        let sin_dec = cos_rho * self.sin_dec0 + (eta * sin_rho * self.cos_dec0) / r;
        let dec = sin_dec.clamp(-1.0, 1.0).asin();
        // RA offset.
        let y_term = xi * sin_rho;
        let x_term = r * self.cos_dec0 * cos_rho - eta * self.sin_dec0 * sin_rho;
        let ra = self.crval1_rad + y_term.atan2(x_term);
        (normalize_deg(ra.to_degrees()), dec.to_degrees())
    }

    /// Inverse projection: celestial `(ra, dec)` in **degrees** → 0-based pixel
    /// `(x, y)`. Returns `None` when the point is on the far hemisphere (behind
    /// the tangent plane), where the gnomonic projection diverges.
    pub fn world_to_pixel(&self, ra: f64, dec: f64) -> Option<(f64, f64)> {
        let ra_rad = ra.to_radians();
        let dec_rad = dec.to_radians();
        let sin_dec = dec_rad.sin();
        let cos_dec = dec_rad.cos();
        let dra = ra_rad - self.crval1_rad;
        let cos_dra = dra.cos();
        let sin_dra = dra.sin();
        // Cosine of angular separation from the tangent point. Gnomonic projects
        // only the visible hemisphere; cos_c <= 0 is behind the plane / diverging.
        let cos_c = self.sin_dec0 * sin_dec + self.cos_dec0 * cos_dec * cos_dra;
        if cos_c <= 1e-12 {
            return None;
        }
        // Standard coordinates (radians) on the tangent plane.
        let xi = (cos_dec * sin_dra) / cos_c;
        let eta = (self.cos_dec0 * sin_dec - self.sin_dec0 * cos_dec * cos_dra) / cos_c;
        // Radians → degrees (intermediate world coordinates).
        let xi_deg = xi.to_degrees();
        let eta_deg = eta.to_degrees();
        // Intermediate world coords → pixel via the inverse CD matrix.
        let dx = self.inv_cd1_1 * xi_deg + self.inv_cd1_2 * eta_deg;
        let dy = self.inv_cd2_1 * xi_deg + self.inv_cd2_2 * eta_deg;
        Some((dx + self.crpix1_0, dy + self.crpix2_0))
    }

    /// Approximate pixel scale in arcsec/px (geometric mean of the CD column
    /// norms). Used for the median-scale canvas default.
    pub fn pixel_scale_arcsec(&self) -> f64 {
        let s1 = (self.cd1_1 * self.cd1_1 + self.cd2_1 * self.cd2_1).sqrt();
        let s2 = (self.cd1_2 * self.cd1_2 + self.cd2_2 * self.cd2_2).sqrt();
        (s1 * s2).sqrt() * 3600.0
    }
}

/// Normalise an angle in degrees to `[0, 360)`.
fn normalize_deg(d: f64) -> f64 {
    let mut v = d % 360.0;
    if v < 0.0 {
        v += 360.0;
    }
    v
}

/// Signed RA difference `a − b` in degrees, wrapped to `(−180, 180]`. Used when
/// taking the centroid of panel RAs near the 0h/24h wrap.
fn delta_ra_deg(a: f64, b: f64) -> f64 {
    let mut d = (a - b) % 360.0;
    if d > 180.0 {
        d -= 360.0;
    }
    if d <= -180.0 {
        d += 360.0;
    }
    d
}

// Decoded panel (f64 planar-interleaved) + footprint

/// A panel decoded once to interleaved `f64` (`data[y·stride + x·channels + c]`,
/// matching the resampler's layout) plus its projection and canvas footprint.
struct DecodedPanel {
    data: Vec<f64>,
    width: usize,
    height: usize,
    channels: usize,
    proj: WcsProjection,
    /// Axis-aligned bounding box of this panel on the output canvas (inclusive
    /// integer pixel range, clamped to the canvas). `None` if the panel projects
    /// entirely off-canvas.
    bbox: Option<CanvasBox>,
}

/// Integer pixel bounding box on the output canvas.
#[derive(Debug, Clone, Copy)]
struct CanvasBox {
    x0: i64,
    y0: i64,
    x1: i64,
    y1: i64,
}

impl CanvasBox {
    fn overlaps(&self, other: &CanvasBox) -> bool {
        self.x0 <= other.x1 && other.x0 <= self.x1 && self.y0 <= other.y1 && other.y0 <= self.y1
    }
}

impl DecodedPanel {
    /// Decode a [`MosaicPanel`] into interleaved `f64`. Accepts `F32` and `U16`
    /// masters (the linear types the integration pipeline emits).
    fn decode(panel: &MosaicPanel) -> Result<Self, MosaicError> {
        let width = panel.image.width as usize;
        let height = panel.image.height as usize;
        let channels = panel.image.channels.max(1) as usize;
        if width == 0 || height == 0 {
            return Err(MosaicError::Dimensionless);
        }
        let proj = WcsProjection::new(&panel.wcs).ok_or(MosaicError::DegenerateWcs)?;
        let expected = width * height * channels;
        let data: Vec<f64> = if let Some(f) = panel.image.as_f32() {
            f.into_iter().map(|v| v as f64).collect()
        } else if let Some(u) = panel.image.as_u16() {
            u.into_iter().map(|v| v as f64).collect()
        } else {
            // Unknown layout: refuse rather than guess a gray buffer. Treat as
            // dimensionless-equivalent bad input.
            return Err(MosaicError::Dimensionless);
        };
        if data.len() != expected {
            return Err(MosaicError::Dimensionless);
        }
        Ok(Self {
            data,
            width,
            height,
            channels,
            proj,
            bbox: None,
        })
    }

    /// Sample channel `c` at fractional 0-based source pixel `(sx, sy)` with
    /// `interp`. Returns `None` when the interpolation support leaves the panel
    /// (no edge replication — a border smear would bleed a panel's frame into
    /// the seam).
    #[inline]
    fn sample(&self, c: usize, sx: f64, sy: f64, interp: Interpolator) -> Option<f64> {
        sample_plane(
            &self.data,
            self.width,
            self.height,
            self.channels,
            c,
            sx,
            sy,
            interp,
        )
    }
}

// Resampling kernels (mirrors registration.rs; private there so reimplemented)

/// Sample channel `c` at fractional `(sx, sy)` in an interleaved `f64` plane.
///
/// Mirrors `registration::sample`'s contract (zero-equivalent out-of-bounds →
/// `None`, separable Lanczos-3 / Catmull-Rom, 2×2 bilinear) but returns `None`
/// rather than `0.0` when the support window leaves the image, so the mosaic
/// renderer can *exclude* an uncovered panel from the weighted mean instead of
/// averaging a fabricated zero into the seam. `registration::sample` is private,
/// so the kernels are reimplemented here against the same math.
#[allow(clippy::too_many_arguments)]
fn sample_plane(
    src: &[f64],
    w: usize,
    h: usize,
    channels: usize,
    c: usize,
    sx: f64,
    sy: f64,
    interp: Interpolator,
) -> Option<f64> {
    let stride = w * channels;
    let px = |ix: i64, iy: i64| -> f64 {
        if ix < 0 || iy < 0 || ix as usize >= w || iy as usize >= h {
            0.0
        } else {
            src[iy as usize * stride + ix as usize * channels + c]
        }
    };
    match interp {
        Interpolator::Bilinear => {
            let x0 = sx.floor();
            let y0 = sy.floor();
            let ix = x0 as i64;
            let iy = y0 as i64;
            if ix < 0 || iy < 0 || (ix + 1) as usize >= w || (iy + 1) as usize >= h {
                return None;
            }
            let dx = sx - x0;
            let dy = sy - y0;
            let p00 = px(ix, iy);
            let p10 = px(ix + 1, iy);
            let p01 = px(ix, iy + 1);
            let p11 = px(ix + 1, iy + 1);
            Some(
                (1.0 - dx) * (1.0 - dy) * p00
                    + dx * (1.0 - dy) * p10
                    + (1.0 - dx) * dy * p01
                    + dx * dy * p11,
            )
        }
        Interpolator::CatmullRom => separable(&px, w, h, sx, sy, 2, catmull_rom),
        Interpolator::Lanczos3 => separable(&px, w, h, sx, sy, 3, lanczos3),
    }
}

/// Separable interpolation with a 1-D kernel of half-width `radius`; taps span
/// `[-radius+1, radius]` around the floor. Returns `None` if any tap leaves the
/// image, so out-of-panel support excludes the sample entirely.
fn separable<F, K>(
    px: &F,
    w: usize,
    h: usize,
    sx: f64,
    sy: f64,
    radius: i64,
    kernel: K,
) -> Option<f64>
where
    F: Fn(i64, i64) -> f64,
    K: Fn(f64) -> f64,
{
    let x0 = sx.floor() as i64;
    let y0 = sy.floor() as i64;
    let start = -(radius - 1);
    // Reject if the support window is not fully inside the image.
    if x0 + start < 0
        || y0 + start < 0
        || (x0 + radius) as usize >= w
        || (y0 + radius) as usize >= h
    {
        return None;
    }
    let fx = sx - x0 as f64;
    let fy = sy - y0 as f64;
    let taps = (2 * radius) as usize;
    let mut wx = [0.0f64; 6];
    let mut wy = [0.0f64; 6];
    let mut sum_wx = 0.0;
    let mut sum_wy = 0.0;
    for t in 0..taps {
        let off = (start + t as i64) as f64;
        let kx = kernel(fx - off);
        let ky = kernel(fy - off);
        wx[t] = kx;
        wy[t] = ky;
        sum_wx += kx;
        sum_wy += ky;
    }
    if sum_wx.abs() < f64::EPSILON || sum_wy.abs() < f64::EPSILON {
        return None;
    }
    let mut acc = 0.0;
    for (ty, &w_y) in wy.iter().enumerate().take(taps) {
        let iy = y0 + start + ty as i64;
        let mut row_acc = 0.0;
        for (tx, &w_x) in wx.iter().enumerate().take(taps) {
            let ix = x0 + start + tx as i64;
            row_acc += w_x * px(ix, iy);
        }
        acc += w_y * row_acc;
    }
    Some(acc / (sum_wx * sum_wy))
}

/// Catmull-Rom cubic kernel (a = −0.5) — matches `registration::catmull_rom`.
fn catmull_rom(x: f64) -> f64 {
    let a = -0.5;
    let x = x.abs();
    if x < 1.0 {
        (a + 2.0) * x.powi(3) - (a + 3.0) * x.powi(2) + 1.0
    } else if x < 2.0 {
        a * x.powi(3) - 5.0 * a * x.powi(2) + 8.0 * a * x - 4.0 * a
    } else {
        0.0
    }
}

/// Lanczos kernel with a = 3 — matches `registration::lanczos3`.
fn lanczos3(x: f64) -> f64 {
    const A: f64 = 3.0;
    if x.abs() < f64::EPSILON {
        1.0
    } else if x.abs() < A {
        let px = std::f64::consts::PI * x;
        (A * px.sin() * (px / A).sin()) / (px * px)
    } else {
        0.0
    }
}

// Output-canvas construction

/// Build the output canvas WCS + integer dimensions from the panel projections.
///
/// Reference centre = median panel `CRVAL` (RA centroid taken modulo the 0h
/// wrap). Output scale = `cfg.output_pixel_scale_arcsec` or the median panel
/// scale. Every panel's four corners are projected onto the output tangent
/// plane; the integer bounding box (+1 px margin each side) fixes `width`,
/// `height`, and `CRPIX` so the union maps into `[0, w) × [0, h)`.
fn build_output_wcs(
    panels: &[DecodedPanel],
    cfg: &MosaicStitchConfig,
) -> Result<(WcsInfo, WcsProjection, u32, u32), MosaicError> {
    // Reference projection centre: median CRVAL.
    // RA is taken relative to the first panel to handle the 0h/24h wrap, then
    // re-wrapped; Dec is a plain median.
    let ra0 = panels[0].proj.crval1_rad.to_degrees();
    let mut ra_offsets: Vec<f64> = panels
        .iter()
        .map(|p| delta_ra_deg(p.proj.crval1_rad.to_degrees(), ra0))
        .collect();
    let mut decs: Vec<f64> = panels
        .iter()
        .map(|p| p.proj.crval2_rad.to_degrees())
        .collect();
    let center_ra = normalize_deg(ra0 + median(&mut ra_offsets));
    let center_dec = median(&mut decs);

    // Output pixel scale (arcsec/px) → deg/px.
    let scale_arcsec = match cfg.output_pixel_scale_arcsec {
        Some(s) if s > 0.0 => s,
        _ => {
            let mut scales: Vec<f64> = panels.iter().map(|p| p.proj.pixel_scale_arcsec()).collect();
            median(&mut scales)
        }
    };
    let scale_deg = scale_arcsec / 3600.0;

    // Output CD matrix: axis-aligned (no rotation), standard RA-flips-left sign.
    // CRPIX is provisional (1,1); we finalise it after projecting the corners.
    let mut out_wcs = WcsInfo {
        crval1: center_ra,
        crval2: center_dec,
        crpix1: 1.0,
        crpix2: 1.0,
        cd1_1: -scale_deg,
        cd1_2: 0.0,
        cd2_1: 0.0,
        cd2_2: scale_deg,
    };
    let proj0 = WcsProjection::new(&out_wcs).ok_or(MosaicError::DegenerateWcs)?;

    // Project every panel corner onto the provisional output plane.
    let mut min_x = f64::INFINITY;
    let mut min_y = f64::INFINITY;
    let mut max_x = f64::NEG_INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    for p in panels {
        let w = p.width as f64;
        let h = p.height as f64;
        // 0-based corners: pixel centres at the four corners.
        let corners = [
            (0.0, 0.0),
            (w - 1.0, 0.0),
            (0.0, h - 1.0),
            (w - 1.0, h - 1.0),
        ];
        for (cx, cy) in corners {
            let (ra, dec) = p.proj.pixel_to_world(cx, cy);
            if let Some((ox, oy)) = proj0.world_to_pixel(ra, dec) {
                min_x = min_x.min(ox);
                min_y = min_y.min(oy);
                max_x = max_x.max(ox);
                max_y = max_y.max(oy);
            }
        }
    }
    if !min_x.is_finite() || !min_y.is_finite() || !max_x.is_finite() || !max_y.is_finite() {
        // No panel projected onto the canvas at all — only possible with WCS so
        // pathological every corner is on the far hemisphere.
        return Err(MosaicError::DegenerateWcs);
    }

    // Shift CRPIX so the bbox lands in [0, w)×[0, h) with a 1 px margin.
    let margin = 1.0;
    let lo_x = (min_x - margin).floor();
    let lo_y = (min_y - margin).floor();
    let hi_x = (max_x + margin).ceil();
    let hi_y = (max_y + margin).ceil();
    let out_w = (hi_x - lo_x + 1.0).max(1.0) as i64;
    let out_h = (hi_y - lo_y + 1.0).max(1.0) as i64;

    let pixels = (out_w as u64) * (out_h as u64);
    if pixels > MAX_CANVAS_PIXELS {
        return Err(MosaicError::CanvasTooLarge { pixels });
    }

    // Original proj0 had CRPIX = (1,1) ⇒ 0-based ref pixel (0,0). Shifting the
    // canvas origin to `(lo_x, lo_y)` means the new 0-based ref pixel is
    // `(-lo_x, -lo_y)`, i.e. 1-based CRPIX = `(-lo_x + 1, -lo_y + 1)`.
    out_wcs.crpix1 = -lo_x + 1.0;
    out_wcs.crpix2 = -lo_y + 1.0;
    let proj = WcsProjection::new(&out_wcs).ok_or(MosaicError::DegenerateWcs)?;

    Ok((out_wcs, proj, out_w as u32, out_h as u32))
}

/// Compute and stash each panel's integer canvas bounding box.
fn compute_footprints(
    panels: &mut [DecodedPanel],
    out_proj: &WcsProjection,
    out_w: u32,
    out_h: u32,
) {
    for p in panels.iter_mut() {
        let w = p.width as f64;
        let h = p.height as f64;
        let corners = [
            (0.0, 0.0),
            (w - 1.0, 0.0),
            (0.0, h - 1.0),
            (w - 1.0, h - 1.0),
        ];
        let mut min_x = f64::INFINITY;
        let mut min_y = f64::INFINITY;
        let mut max_x = f64::NEG_INFINITY;
        let mut max_y = f64::NEG_INFINITY;
        for (cx, cy) in corners {
            let (ra, dec) = p.proj.pixel_to_world(cx, cy);
            if let Some((ox, oy)) = out_proj.world_to_pixel(ra, dec) {
                min_x = min_x.min(ox);
                min_y = min_y.min(oy);
                max_x = max_x.max(ox);
                max_y = max_y.max(oy);
            }
        }
        if !min_x.is_finite() {
            p.bbox = None;
            continue;
        }
        let x0 = (min_x.floor() as i64).max(0);
        let y0 = (min_y.floor() as i64).max(0);
        let x1 = (max_x.ceil() as i64).min(out_w as i64 - 1);
        let y1 = (max_y.ceil() as i64).min(out_h as i64 - 1);
        p.bbox = if x0 <= x1 && y0 <= y1 {
            Some(CanvasBox { x0, y0, x1, y1 })
        } else {
            None
        };
    }
}

// Cross-panel photometric solve

/// Per-panel photometric correction `value ← gain·sample + offset`.
#[derive(Debug, Clone, Copy)]
struct PanelPhotometry {
    gain: f64,
    offset: f64,
}

/// Solve a per-panel gain+offset that equalises overlapping panels.
///
/// For each pair of footprint-overlapping panels `(i, j)` we sample matched
/// values across the shared canvas region (channel 0, the luminance proxy) and
/// fit a robust line `v_i ≈ s·v_j + o` via
/// [`crate::normalization::estimate_normalization`] under
/// [`crate::normalization::NormEstimator::CoLocatedPairFit`]. That
/// gives a pairwise constraint `g_i·v_i + o_i ≈ g_j·v_j + o_j` after a
/// log/linear reparametrisation. We then solve a single global least-squares
/// for all `(g_k, o_k)` anchored to panel 0 (`g_0 = 1`, `o_0 = 0`).
///
/// Panels with no overlap keep `gain = 1`, `offset = 0`. Returns the corrections
/// and the number of overlap pairs found.
// Index loops: the upper-triangular pairwise scan (`for j in (i+1)..n`) is the
// idiomatic way to visit each unordered panel pair once.
#[allow(clippy::needless_range_loop)]
fn solve_panel_photometry(
    panels: &[DecodedPanel],
    out_proj: &WcsProjection,
) -> (Vec<PanelPhotometry>, usize) {
    let n = panels.len();
    let mut corrections = vec![
        PanelPhotometry {
            gain: 1.0,
            offset: 0.0
        };
        n
    ];

    // Collect pairwise (scale, offset) relating panel j onto panel i's scale.
    // estimate_normalization regresses reference-on-frame: with reference = v_i,
    // frame = v_j it yields (s, o) s.t. s·v_j + o ≈ v_i.
    let mut pairs: Vec<(usize, usize, f64, f64)> = Vec::new();
    for i in 0..n {
        let bi = match panels[i].bbox {
            Some(b) => b,
            None => continue,
        };
        for j in (i + 1)..n {
            let bj = match panels[j].bbox {
                Some(b) => b,
                None => continue,
            };
            if !bi.overlaps(&bj) {
                continue;
            }
            if let Some((s, o)) = fit_overlap_pair(&panels[i], &panels[j], out_proj, &bi, &bj) {
                pairs.push((i, j, s, o));
            }
        }
    }
    let overlap_pairs = pairs.len();
    if pairs.is_empty() {
        return (corrections, 0);
    }

    // Global solve.
    // Model: corrected_i = g_i·v_i + o_i. For a pair giving s·v_j + o ≈ v_i,
    // i.e. v_i ≈ s·v_j + o, equalisation wants corrected_i ≈ corrected_j:
    //   g_i·v_i + o_i = g_j·v_j + o_j.
    // Substitute v_i ≈ s·v_j + o:
    //   g_i·(s·v_j + o) + o_i = g_j·v_j + o_j
    // Matching the v_j coefficient and the constant gives two residuals — the
    // multiplicative part is exact in log-space, the additive part is exact once
    // the gains are known:
    //   ln g_i + ln s = ln g_j      (gain chain)
    //   o_j − o_i = g_i·o           (offset chain)
    // The gain chain is independent of the offsets, so we solve it first. The
    // offset chain then uses the already-solved gains: each edge weight is the
    // pair offset `o` scaled by the solved gain of its reference panel `g_i`.
    // (Earlier this dropped the g_i factor — `o + o_i ≈ o_j`, valid only when
    // gains ≈ 1 — which accumulated (g_i−1)·o error along 3+ panel chains.)
    let log_gain = solve_anchored_chain(
        n,
        pairs.iter().map(|&(i, j, s, _)| (i, j, s.max(1e-9).ln())),
    );
    let offset = solve_anchored_chain(
        n,
        pairs
            .iter()
            .map(|&(i, j, _, o)| (i, j, log_gain[i].exp() * o)),
    );

    for k in 0..n {
        corrections[k] = PanelPhotometry {
            gain: log_gain[k].exp(),
            offset: offset[k],
        };
    }
    (corrections, overlap_pairs)
}

/// Solve `x_j − x_i = d_ij` for all pairs in a least-squares sense, anchored at
/// `x_0 = 0`. This is the normal-equation solve for a connected (or partly
/// connected) difference graph; unconnected nodes stay at 0. Used for both the
/// log-gain chain and the offset chain.
// Index loops are clearer than iterators here: we mutate symmetric matrix
// entries (`a[i][j]` *and* `a[j][i]`) keyed by the same indices.
#[allow(clippy::needless_range_loop)]
fn solve_anchored_chain(n: usize, edges: impl Iterator<Item = (usize, usize, f64)>) -> Vec<f64> {
    // Build the (n×n) Laplacian-style normal matrix A and RHS b for
    //   minimise Σ_(i,j) (x_j − x_i − d_ij)²
    // Each edge contributes to A[i][i]+=1, A[j][j]+=1, A[i][j]-=1, A[j][i]-=1,
    // b[i] -= d, b[j] += d. Anchor x_0 = 0 by pinning row/col 0.
    let mut a = vec![vec![0.0f64; n]; n];
    let mut b = vec![0.0f64; n];
    for (i, j, d) in edges {
        a[i][i] += 1.0;
        a[j][j] += 1.0;
        a[i][j] -= 1.0;
        a[j][i] -= 1.0;
        b[i] -= d;
        b[j] += d;
    }
    // Anchor node 0: x_0 = 0.
    for k in 0..n {
        a[0][k] = 0.0;
        a[k][0] = 0.0;
    }
    a[0][0] = 1.0;
    b[0] = 0.0;
    // Regularise isolated/under-determined nodes so the system is invertible
    // (Tikhonov toward 0 — an unconnected panel resolves to its default).
    for k in 1..n {
        a[k][k] += 1e-9;
    }
    gaussian_solve(a, b).unwrap_or_else(|| vec![0.0; n])
}

/// Dense Gaussian elimination with partial pivoting. `None` if singular.
// Index loops: row/column elimination is the natural index-keyed algorithm.
#[allow(clippy::needless_range_loop)]
fn gaussian_solve(mut a: Vec<Vec<f64>>, mut b: Vec<f64>) -> Option<Vec<f64>> {
    let n = b.len();
    for col in 0..n {
        // Pivot.
        let mut piv = col;
        let mut best = a[col][col].abs();
        for r in (col + 1)..n {
            let v = a[r][col].abs();
            if v > best {
                best = v;
                piv = r;
            }
        }
        if best < 1e-15 {
            return None;
        }
        a.swap(col, piv);
        b.swap(col, piv);
        // Eliminate.
        for r in (col + 1)..n {
            let f = a[r][col] / a[col][col];
            if f == 0.0 {
                continue;
            }
            for c in col..n {
                a[r][c] -= f * a[col][c];
            }
            b[r] -= f * b[col];
        }
    }
    // Back-substitute.
    let mut x = vec![0.0f64; n];
    for row in (0..n).rev() {
        let mut s = b[row];
        for c in (row + 1)..n {
            s -= a[row][c] * x[c];
        }
        x[row] = s / a[row][row];
    }
    Some(x)
}

/// Fit `v_i ≈ s·v_j + o` over the canvas region where panels `i` and `j` both
/// have valid samples, returning `(scale, offset)`. Channel 0 only (the
/// photometric anchor). Returns `None` if too few shared samples.
fn fit_overlap_pair(
    pi: &DecodedPanel,
    pj: &DecodedPanel,
    out_proj: &WcsProjection,
    bi: &CanvasBox,
    bj: &CanvasBox,
) -> Option<(f64, f64)> {
    // Intersection of the two canvas bboxes.
    let x0 = bi.x0.max(bj.x0);
    let y0 = bi.y0.max(bj.y0);
    let x1 = bi.x1.min(bj.x1);
    let y1 = bi.y1.min(bj.y1);
    if x0 > x1 || y0 > y1 {
        return None;
    }
    let w = (x1 - x0 + 1) as usize;
    let h = (y1 - y0 + 1) as usize;
    let len = w.checked_mul(h)?;

    // Build matched single-channel buffers over the overlap rectangle. Pixels
    // where either panel has no valid sample are flagged via the coverage mask
    // and excluded by estimate_normalization.
    let mut frame = vec![0.0f64; len]; // v_j
    let mut reference = vec![0.0f64; len]; // v_i
    let mut valid = vec![false; len];
    let interp = Interpolator::Bilinear; // robust + cheap for the fit sampling
    for (row, oy) in (y0..=y1).enumerate() {
        for (colp, ox) in (x0..=x1).enumerate() {
            let (ra, dec) = out_proj.pixel_to_world(ox as f64, oy as f64);
            let si = pi
                .proj
                .world_to_pixel(ra, dec)
                .and_then(|(sx, sy)| pi.sample(0, sx, sy, interp));
            let sj = pj
                .proj
                .world_to_pixel(ra, dec)
                .and_then(|(sx, sy)| pj.sample(0, sx, sy, interp));
            if let (Some(vi), Some(vj)) = (si, sj) {
                if vi.is_finite() && vj.is_finite() {
                    let idx = row * w + colp;
                    reference[idx] = vi;
                    frame[idx] = vj;
                    valid[idx] = true;
                }
            }
        }
    }
    let mask = CoverageMask::new(w, h, valid)?;
    // The loop above resampled BOTH panels onto the same output pixel grid via
    // their WCS, so `frame[i]` and `reference[i]` are two measurements of one
    // sky coordinate. That co-location is exactly the precondition the pixel-pair
    // OLS estimator needs, and it is why the panel fit keeps using it while
    // stacking uses additive-with-scaling: here we want the relative gain over
    // the SHARED overlap, and each panel's global statistics describe mostly
    // non-overlapping sky.
    let cfg = NormalizationConfig {
        estimator: NormEstimator::CoLocatedPairFit,
        ..NormalizationConfig::default()
    };
    let coeffs = estimate_normalization(&frame, &reference, &mask, w, h, &cfg).ok()?;
    // estimate_normalization returns identity (scale 1, offset 0, samples 0) when
    // it cannot fit honestly; treat that as "no usable constraint".
    if coeffs.samples_used < cfg.min_samples {
        return None;
    }
    Some((coeffs.scale, coeffs.offset))
}

// Render

/// Render the output canvas, one row per rayon task.
///
/// For each output pixel: world ← output WCS; for each panel whose footprint
/// contains the pixel, pixel ← panel WCS, sample, apply photometry, accumulate
/// with the blend weight. The master is `Σ(w·v)/Σw` per channel; coverage is
/// `Σw` (channel-independent — it is the geometric/weight property of the warp).
// Index loops: per-pixel/per-channel accumulation indexes several parallel
// buffers (`acc[c]`, `master_row[base + c]`) by the same `c`/`ox`.
#[allow(clippy::needless_range_loop)]
fn render_canvas(
    panels: &[DecodedPanel],
    photometry: &[PanelPhotometry],
    out_proj: &WcsProjection,
    out_w: u32,
    out_h: u32,
    channels: usize,
    cfg: &MosaicStitchConfig,
) -> (Vec<f32>, Vec<f32>) {
    let out_w = out_w as usize;
    let out_h = out_h as usize;
    let row_len = out_w * channels;

    // Render each row independently. Returns (master_row, coverage_row).
    let rows: Vec<(Vec<f32>, Vec<f32>)> = (0..out_h)
        .into_par_iter()
        .map(|oy| {
            let mut master_row = vec![0.0f32; row_len];
            let mut cov_row = vec![0.0f32; out_w];
            // Per-pixel accumulators reused across the row.
            let mut acc = vec![0.0f64; channels];
            for ox in 0..out_w {
                for a in acc.iter_mut() {
                    *a = 0.0;
                }
                let mut wsum = 0.0f64;
                let (ra, dec) = out_proj.pixel_to_world(ox as f64, oy as f64);
                for (pidx, p) in panels.iter().enumerate() {
                    // Quick footprint reject.
                    match p.bbox {
                        Some(b) => {
                            let xi = ox as i64;
                            let yi = oy as i64;
                            if xi < b.x0 || xi > b.x1 || yi < b.y0 || yi > b.y1 {
                                continue;
                            }
                        }
                        None => continue,
                    }
                    let (sx, sy) = match p.proj.world_to_pixel(ra, dec) {
                        Some(v) => v,
                        None => continue,
                    };
                    // The blend weight depends only on geometry; compute it from
                    // the (continuous) source position so it is smooth across the
                    // seam. Skip the panel if the sample window is out of bounds.
                    let weight = panel_weight(sx, sy, p.width, p.height, cfg);
                    if weight <= 0.0 {
                        continue;
                    }
                    let ph = photometry[pidx];
                    // Sample every channel. A channel is usable only if the
                    // sample is in-bounds *and* finite: a non-finite source pixel
                    // (NaN/inf — an all-rejected or div-by-zero master pixel, an
                    // expected input class — see normalization's "NaN untouched"
                    // contract) must be excluded exactly like an out-of-bounds
                    // sample, never folded into acc/wsum. With Lanczos/Catmull a
                    // single NaN otherwise smears across the whole support window
                    // and then poisons the weighted mean (acc=NaN, wsum finite).
                    // Track how many channels were committed so a mid-loop reject
                    // rolls back exactly those (and no more).
                    let mut ok = true;
                    let mut committed = 0usize;
                    for c in 0..channels {
                        match p.sample(c, sx, sy, cfg.resampler) {
                            Some(v) if v.is_finite() => {
                                acc[c] += weight * (ph.gain * v + ph.offset);
                                committed += 1;
                            }
                            _ => {
                                ok = false;
                                break;
                            }
                        }
                    }
                    if ok {
                        wsum += weight;
                    } else {
                        // Roll back this panel's partial contribution: undo only
                        // the channels we actually committed. Re-sampling is exact
                        // and finite for those (we only committed finite samples).
                        for c in 0..committed {
                            if let Some(v) = p.sample(c, sx, sy, cfg.resampler) {
                                acc[c] -= weight * (ph.gain * v + ph.offset);
                            }
                        }
                    }
                }
                if wsum > 0.0 {
                    let base = ox * channels;
                    for c in 0..channels {
                        master_row[base + c] = (acc[c] / wsum) as f32;
                    }
                    cov_row[ox] = wsum as f32;
                }
            }
            (master_row, cov_row)
        })
        .collect();

    // Stitch rows back into flat buffers.
    let mut master = vec![0.0f32; out_w * out_h * channels];
    let mut coverage = vec![0.0f32; out_w * out_h];
    for (oy, (mrow, crow)) in rows.into_iter().enumerate() {
        let mbase = oy * row_len;
        master[mbase..mbase + row_len].copy_from_slice(&mrow);
        let cbase = oy * out_w;
        coverage[cbase..cbase + out_w].copy_from_slice(&crow);
    }
    (master, coverage)
}

/// Blend weight for a panel at fractional source pixel `(sx, sy)`.
///
/// - [`MosaicBlend::None`]: 1.0 inside the panel, 0.0 outside.
/// - [`MosaicBlend::Feather`]: the distance from the nearest panel edge, clamped
///   to `feather_px` and normalised to `[0, 1]`, so the weight ramps from 0 at
///   the frame edge to 1 once `feather_px` inside. Cross-fades overlaps.
///
/// Returns 0.0 when the sample falls outside the panel bounds (so an
/// off-panel pixel never contributes).
fn panel_weight(sx: f64, sy: f64, width: usize, height: usize, cfg: &MosaicStitchConfig) -> f64 {
    let w = width as f64;
    let h = height as f64;
    // Outside the valid sampling region (need the full image extent).
    if sx < 0.0 || sy < 0.0 || sx > w - 1.0 || sy > h - 1.0 {
        return 0.0;
    }
    match cfg.blend {
        MosaicBlend::None => 1.0,
        MosaicBlend::Feather => {
            let feather = cfg.feather_px.max(1.0);
            // Distance to the nearest of the four edges.
            let d = sx.min(sy).min(w - 1.0 - sx).min(h - 1.0 - sy);
            (d / feather).clamp(0.0, 1.0)
        }
    }
}

// Public entry point

/// Stitch `panels` into a single mosaic master onto a common tangent-plane
/// canvas.
///
/// Pipeline (see the module docs for the full rationale):
/// 1. Decode each panel to `f64`, build its [`WcsProjection`] (fails
///    [`MosaicError::DegenerateWcs`] on a singular CD matrix).
/// 2. Build the output canvas WCS + dimensions ([`build_output_wcs`]); guard
///    [`MosaicError::CanvasTooLarge`].
/// 3. Compute each panel's canvas footprint.
/// 4. If `cfg.normalize`, solve per-panel gain+offset over the overlap graph
///    ([`solve_panel_photometry`]); else identity.
/// 5. Render ([`render_canvas`], rayon).
///
/// Returns the `F32` master, the `F32` coverage plane, the output WCS, and
/// [`MosaicStitchStats`].
///
/// # Errors
/// - [`MosaicError::NoPanels`] — empty input.
/// - [`MosaicError::Dimensionless`] — a panel has zero width/height.
/// - [`MosaicError::DegenerateWcs`] — a panel (or the canvas) has a singular WCS.
/// - [`MosaicError::ChannelMismatch`] — panels disagree on channel count.
/// - [`MosaicError::CanvasTooLarge`] — the union footprint exceeds the canvas cap.
pub fn stitch_mosaic(
    panels: &[MosaicPanel],
    cfg: &MosaicStitchConfig,
) -> Result<MosaicOutput, MosaicError> {
    if panels.is_empty() {
        return Err(MosaicError::NoPanels);
    }

    // Decode + validate.
    let mut decoded: Vec<DecodedPanel> = panels
        .iter()
        .map(DecodedPanel::decode)
        .collect::<Result<_, _>>()?;

    let channels = decoded[0].channels;
    if decoded.iter().any(|p| p.channels != channels) {
        return Err(MosaicError::ChannelMismatch);
    }

    // Output canvas.
    let (out_wcs, out_proj, out_w, out_h) = build_output_wcs(&decoded, cfg)?;

    // Footprints.
    compute_footprints(&mut decoded, &out_proj, out_w, out_h);

    // Photometric solve.
    let (photometry, overlap_pairs) = if cfg.normalize {
        solve_panel_photometry(&decoded, &out_proj)
    } else {
        // Still count overlaps for the stats (cheap, footprint-only).
        let pairs = count_overlaps(&decoded);
        (
            vec![
                PanelPhotometry {
                    gain: 1.0,
                    offset: 0.0
                };
                decoded.len()
            ],
            pairs,
        )
    };

    let mean_panel_gain = if photometry.is_empty() {
        1.0
    } else {
        photometry.iter().map(|p| p.gain).sum::<f64>() / photometry.len() as f64
    };

    // Render.
    let (master_data, coverage_data) = render_canvas(
        &decoded,
        &photometry,
        &out_proj,
        out_w,
        out_h,
        channels,
        cfg,
    );

    let master = ImageData::from_f32(out_w, out_h, channels as u32, &master_data);
    let coverage = ImageData::from_f32(out_w, out_h, 1, &coverage_data);

    Ok(MosaicOutput {
        master,
        coverage,
        wcs: out_wcs,
        stats: MosaicStitchStats {
            panels: decoded.len(),
            out_width: out_w,
            out_height: out_h,
            overlap_pairs,
            mean_panel_gain,
        },
    })
}

/// Count footprint-overlapping panel pairs (used for stats when normalization is
/// off, so `overlap_pairs` is always meaningful).
// Index loops: upper-triangular pairwise scan, same idiom as the solver.
#[allow(clippy::needless_range_loop)]
fn count_overlaps(panels: &[DecodedPanel]) -> usize {
    let n = panels.len();
    let mut count = 0;
    for i in 0..n {
        let bi = match panels[i].bbox {
            Some(b) => b,
            None => continue,
        };
        for j in (i + 1)..n {
            if let Some(bj) = panels[j].bbox {
                if bi.overlaps(&bj) {
                    count += 1;
                }
            }
        }
    }
    count
}

// Tests

#[cfg(test)]
mod tests {
    use super::*;
    use crate::PixelType;

    /// Build a WcsInfo for an axis-aligned tangent plane at `(ra, dec)` with the
    /// given pixel scale (arcsec/px) and image size. CRPIX is the centre
    /// (1-based). No rotation. RA flips left (standard sky convention).
    fn make_wcs(ra: f64, dec: f64, scale_arcsec: f64, w: u32, h: u32) -> WcsInfo {
        let scale_deg = scale_arcsec / 3600.0;
        WcsInfo {
            crval1: ra,
            crval2: dec,
            crpix1: w as f64 / 2.0 + 0.5,
            crpix2: h as f64 / 2.0 + 0.5,
            cd1_1: -scale_deg,
            cd1_2: 0.0,
            cd2_1: 0.0,
            cd2_2: scale_deg,
        }
    }

    /// Sample a smooth synthetic sky brightness at `(ra, dec)` — a slowly-varying
    /// gradient field that is identical no matter which panel observes it, so two
    /// panels viewing the same sky must agree in their overlap.
    fn sky_field(ra: f64, dec: f64, ra0: f64, dec0: f64) -> f64 {
        // Linear-ish gradient in degrees from a fixed origin, plus a constant
        // pedestal. Smooth enough that bilinear/Lanczos resampling reproduces it.
        let dra = delta_ra_deg(ra, ra0) * dec.to_radians().cos();
        let ddec = dec - dec0;
        1000.0 + 5000.0 * dra + 3000.0 * ddec
    }

    /// Build a panel master by sampling `sky_field` through a given WCS.
    fn synth_panel(
        wcs: &WcsInfo,
        w: u32,
        h: u32,
        ra0: f64,
        dec0: f64,
        gain: f64,
        offset: f64,
    ) -> MosaicPanel {
        let proj = WcsProjection::new(wcs).unwrap();
        let mut data = vec![0.0f32; (w * h) as usize];
        for y in 0..h {
            for x in 0..w {
                let (ra, dec) = proj.pixel_to_world(x as f64, y as f64);
                let v = sky_field(ra, dec, ra0, dec0);
                data[(y * w + x) as usize] = (gain * v + offset) as f32;
            }
        }
        MosaicPanel {
            image: ImageData::from_f32(w, h, 1, &data),
            wcs: wcs.clone(),
        }
    }

    // TAN projection

    #[test]
    fn tan_round_trip_is_subpixel() {
        let wcs = make_wcs(187.5, 12.3, 2.0, 1000, 800);
        let proj = WcsProjection::new(&wcs).unwrap();
        // Sweep a grid of pixels; world→pixel→world→pixel must close to < 1e-6.
        for &(x, y) in &[
            (0.0, 0.0),
            (999.0, 0.0),
            (0.0, 799.0),
            (999.0, 799.0),
            (500.0, 400.0),
            (123.4, 456.7),
        ] {
            let (ra, dec) = proj.pixel_to_world(x, y);
            let (rx, ry) = proj.world_to_pixel(ra, dec).expect("on-plane");
            assert!(
                (rx - x).abs() < 1e-6 && (ry - y).abs() < 1e-6,
                "round-trip ({x},{y}) -> ({ra},{dec}) -> ({rx},{ry})"
            );
        }
    }

    #[test]
    fn tan_center_pixel_maps_to_crval() {
        // The 0-based reference pixel is (crpix - 1).
        let wcs = make_wcs(45.0, -30.0, 1.5, 600, 600);
        let proj = WcsProjection::new(&wcs).unwrap();
        let cx = wcs.crpix1 - 1.0;
        let cy = wcs.crpix2 - 1.0;
        let (ra, dec) = proj.pixel_to_world(cx, cy);
        assert!((ra - 45.0).abs() < 1e-9, "ra {ra}");
        assert!((dec - (-30.0)).abs() < 1e-9, "dec {dec}");
    }

    #[test]
    fn tan_known_offset_matches_small_angle() {
        // One pixel east of centre at the equator: the standard coordinate is
        // ~ scale, so RA shifts by ~ scale/cos(dec). At dec=0, cos=1 and the CD
        // sign flips RA to the left, so +x ⇒ −RA.
        let scale = 3.0; // arcsec/px
        let wcs = make_wcs(100.0, 0.0, scale, 200, 200);
        let proj = WcsProjection::new(&wcs).unwrap();
        let cx = wcs.crpix1 - 1.0;
        let cy = wcs.crpix2 - 1.0;
        let (ra, _dec) = proj.pixel_to_world(cx + 1.0, cy);
        let expected_offset = scale / 3600.0; // degrees
        let got = delta_ra_deg(ra, 100.0);
        assert!(
            (got + expected_offset).abs() < 1e-6,
            "one-pixel RA offset {got}, expected ~{}",
            -expected_offset
        );
    }

    #[test]
    fn degenerate_wcs_is_rejected() {
        let mut wcs = make_wcs(10.0, 10.0, 2.0, 100, 100);
        wcs.cd1_1 = 0.0;
        wcs.cd1_2 = 0.0;
        wcs.cd2_1 = 0.0;
        wcs.cd2_2 = 0.0;
        assert!(WcsProjection::new(&wcs).is_none());
        let panel = MosaicPanel {
            image: ImageData::from_f32(100, 100, 1, &vec![1.0; 10000]),
            wcs,
        };
        let err = stitch_mosaic(&[panel], &MosaicStitchConfig::default()).unwrap_err();
        assert_eq!(err, MosaicError::DegenerateWcs);
    }

    // Stitch errors

    #[test]
    fn empty_panels_errors() {
        let err = stitch_mosaic(&[], &MosaicStitchConfig::default()).unwrap_err();
        assert_eq!(err, MosaicError::NoPanels);
    }

    #[test]
    fn channel_mismatch_errors() {
        let wcs_a = make_wcs(50.0, 0.0, 2.0, 64, 64);
        let wcs_b = make_wcs(50.0, 0.0, 2.0, 64, 64);
        let a = MosaicPanel {
            image: ImageData::from_f32(64, 64, 1, &vec![1.0; 64 * 64]),
            wcs: wcs_a,
        };
        let b = MosaicPanel {
            image: ImageData::from_f32(64, 64, 3, &vec![1.0; 64 * 64 * 3]),
            wcs: wcs_b,
        };
        let err = stitch_mosaic(&[a, b], &MosaicStitchConfig::default()).unwrap_err();
        assert_eq!(err, MosaicError::ChannelMismatch);
    }

    #[test]
    fn dimensionless_panel_errors() {
        let wcs = make_wcs(50.0, 0.0, 2.0, 0, 0);
        let panel = MosaicPanel {
            image: ImageData::new(0, 0, 1, PixelType::F32),
            wcs,
        };
        let err = stitch_mosaic(&[panel], &MosaicStitchConfig::default()).unwrap_err();
        assert_eq!(err, MosaicError::Dimensionless);
    }

    #[test]
    fn canvas_too_large_errors() {
        // Two small panels at absurdly different RAs and a very fine scale ⇒ the
        // union canvas blows past MAX_CANVAS_PIXELS and must be rejected *before*
        // any allocation/render. 40 deg apart at 0.05"/px ⇒ ~2.88M px wide; even
        // with a 256 px tall band that is > 700 MP, well over the 400 MP cap.
        let wcs_a = make_wcs(10.0, 0.0, 0.05, 256, 256);
        let wcs_b = make_wcs(50.0, 0.0, 0.05, 256, 256);
        let a = synth_panel(&wcs_a, 256, 256, 10.0, 0.0, 1.0, 0.0);
        let b = synth_panel(&wcs_b, 256, 256, 10.0, 0.0, 1.0, 0.0);
        let err = stitch_mosaic(&[a, b], &MosaicStitchConfig::default()).unwrap_err();
        assert!(
            matches!(err, MosaicError::CanvasTooLarge { .. }),
            "got {err:?}"
        );
    }

    // Single panel round-trips to ~itself

    #[test]
    fn single_panel_reproduces_itself() {
        let ra0 = 80.0;
        let dec0 = 5.0;
        let wcs = make_wcs(ra0, dec0, 2.0, 128, 128);
        let panel = synth_panel(&wcs, 128, 128, ra0, dec0, 1.0, 0.0);
        let original = panel.image.as_f32().unwrap();
        let out = stitch_mosaic(&[panel], &MosaicStitchConfig::default()).unwrap();
        assert_eq!(out.stats.panels, 1);
        // Output canvas should be ~128x128 (+ small margins).
        assert!(out.stats.out_width >= 128 && out.stats.out_width <= 134);
        assert!(out.stats.out_height >= 128 && out.stats.out_height <= 134);
        let stitched = out.master.as_f32().unwrap();
        let ow = out.stats.out_width as usize;
        let oh = out.stats.out_height as usize;
        // Compare the interior (avoid the feathered border) against the original
        // by re-projecting through the output WCS.
        let out_proj = WcsProjection::new(&out.wcs).unwrap();
        let in_proj = WcsProjection::new(&wcs).unwrap();
        let mut max_rel = 0.0f64;
        let mut checked = 0;
        for oy in (20..oh - 20).step_by(7) {
            for ox in (20..ow - 20).step_by(7) {
                let cov = out.coverage.as_f32().unwrap()[oy * ow + ox];
                if cov <= 0.0 {
                    continue;
                }
                let (ra, dec) = out_proj.pixel_to_world(ox as f64, oy as f64);
                let (sx, sy) = in_proj.world_to_pixel(ra, dec).unwrap();
                if sx < 2.0 || sy < 2.0 || sx > 125.0 || sy > 125.0 {
                    continue;
                }
                let expected = original[(sy.round() as usize) * 128 + (sx.round() as usize)] as f64;
                let got = stitched[oy * ow + ox] as f64;
                if expected.abs() > 1.0 {
                    max_rel = max_rel.max((got - expected).abs() / expected.abs());
                    checked += 1;
                }
            }
        }
        assert!(
            checked > 20,
            "expected many interior comparisons, got {checked}"
        );
        assert!(
            max_rel < 0.02,
            "single-panel self-reproduction rel err {max_rel}"
        );
    }

    // Two overlapping panels: seamless, doubled coverage

    /// Two panels offset in RA so they overlap by ~half. Same sky field ⇒ the
    /// overlap must be consistent and coverage ~2× a single-panel region.
    #[test]
    fn two_overlapping_panels_seamless() {
        let ra0: f64 = 150.0;
        let dec0: f64 = 20.0;
        let scale: f64 = 4.0;
        let w = 128;
        let h = 128;
        // Panel B shifted east by ~half a panel width in RA.
        let half_w_deg = (w as f64 / 2.0) * (scale / 3600.0) / dec0.to_radians().cos();
        let wcs_a = make_wcs(ra0, dec0, scale, w, h);
        let wcs_b = make_wcs(ra0 - half_w_deg, dec0, scale, w, h);
        let a = synth_panel(&wcs_a, w, h, ra0, dec0, 1.0, 0.0);
        let b = synth_panel(&wcs_b, w, h, ra0, dec0, 1.0, 0.0);

        let cfg = MosaicStitchConfig {
            blend: MosaicBlend::None, // hard average so coverage counts integer panels
            normalize: false,
            ..Default::default()
        };
        let out = stitch_mosaic(&[a, b], &cfg).unwrap();
        assert_eq!(out.stats.panels, 2);
        assert!(out.stats.overlap_pairs >= 1, "panels must overlap");

        // Union bbox: wider than a single panel.
        assert!(
            out.stats.out_width > w + 20,
            "union should be wider than one panel: {}",
            out.stats.out_width
        );

        let ow = out.stats.out_width as usize;
        let oh = out.stats.out_height as usize;
        let cov = out.coverage.as_f32().unwrap();

        // Find a single-panel region (coverage ~1) and a two-panel region
        // (coverage ~2).
        let mut single = 0usize;
        let mut doubled = 0usize;
        for oy in 10..oh - 10 {
            for ox in 10..ow - 10 {
                let c = cov[oy * ow + ox];
                if (c - 1.0).abs() < 0.05 {
                    single += 1;
                } else if (c - 2.0).abs() < 0.05 {
                    doubled += 1;
                }
            }
        }
        assert!(
            single > 100,
            "expected a single-coverage region, got {single}"
        );
        assert!(
            doubled > 100,
            "expected a 2x-coverage overlap, got {doubled}"
        );

        // Seam invisible: in the overlap, the stitched value must match the
        // sky field (both panels sampled the same field, hard-averaged).
        let out_proj = WcsProjection::new(&out.wcs).unwrap();
        let stitched = out.master.as_f32().unwrap();
        let mut max_diff = 0.0f64;
        let mut n = 0;
        for oy in 20..oh - 20 {
            for ox in 20..ow - 20 {
                if (cov[oy * ow + ox] - 2.0).abs() > 0.05 {
                    continue;
                }
                let (ra, dec) = out_proj.pixel_to_world(ox as f64, oy as f64);
                let expected = sky_field(ra, dec, ra0, dec0);
                let got = stitched[oy * ow + ox] as f64;
                max_diff = max_diff.max((got - expected).abs());
                n += 1;
            }
        }
        assert!(n > 50, "expected overlap pixels to check, got {n}");
        // Field spans thousands of ADU; a seamless overlap should match within a
        // few ADU (resampling error only).
        assert!(max_diff < 30.0, "overlap seam diff {max_diff} too large");
    }

    // Photometric matching equalises a gained panel

    #[test]
    fn normalization_equalizes_seam() {
        let ra0: f64 = 200.0;
        let dec0: f64 = -10.0;
        let scale: f64 = 4.0;
        let w = 128;
        let h = 128;
        let half_w_deg = (w as f64 / 2.0) * (scale / 3600.0) / dec0.to_radians().cos();
        let wcs_a = make_wcs(ra0, dec0, scale, w, h);
        let wcs_b = make_wcs(ra0 - half_w_deg, dec0, scale, w, h);
        // Panel A is the reference; panel B has a KNOWN gain+offset applied.
        let a = synth_panel(&wcs_a, w, h, ra0, dec0, 1.0, 0.0);
        let b = synth_panel(&wcs_b, w, h, ra0, dec0, 1.7, 400.0);

        let out_proj_test = |out: &MosaicOutput| WcsProjection::new(&out.wcs).unwrap();

        // With normalization OFF, the overlap shows a seam (A and B disagree).
        let cfg_off = MosaicStitchConfig {
            blend: MosaicBlend::None,
            normalize: false,
            ..Default::default()
        };
        let off = stitch_mosaic(&[a.clone(), b.clone()], &cfg_off).unwrap();
        let ow = off.stats.out_width as usize;
        let oh = off.stats.out_height as usize;
        let cov = off.coverage.as_f32().unwrap();
        let stitched_off = off.master.as_f32().unwrap();
        let proj_off = out_proj_test(&off);
        let mut max_err_off = 0.0f64;
        let mut n_off = 0;
        for oy in 20..oh - 20 {
            for ox in 20..ow - 20 {
                if (cov[oy * ow + ox] - 2.0).abs() > 0.05 {
                    continue;
                }
                let (ra, dec) = proj_off.pixel_to_world(ox as f64, oy as f64);
                let truth = sky_field(ra, dec, ra0, dec0);
                let got = stitched_off[oy * ow + ox] as f64;
                max_err_off = max_err_off.max((got - truth).abs());
                n_off += 1;
            }
        }
        assert!(n_off > 50);
        // Averaging A (truth) and B (1.7·truth+400) leaves a large bias.
        assert!(
            max_err_off > 200.0,
            "without normalization the seam should be large, got {max_err_off}"
        );

        // With normalization ON, the panels are equalised: B is brought back
        // onto A's scale, so the overlap matches the truth field closely.
        let cfg_on = MosaicStitchConfig {
            blend: MosaicBlend::None,
            normalize: true,
            ..Default::default()
        };
        let on = stitch_mosaic(&[a, b], &cfg_on).unwrap();
        let ow = on.stats.out_width as usize;
        let oh = on.stats.out_height as usize;
        let cov = on.coverage.as_f32().unwrap();
        let stitched_on = on.master.as_f32().unwrap();
        let proj_on = out_proj_test(&on);
        let mut max_err_on = 0.0f64;
        let mut n_on = 0;
        for oy in 20..oh - 20 {
            for ox in 20..ow - 20 {
                if (cov[oy * ow + ox] - 2.0).abs() > 0.05 {
                    continue;
                }
                let (ra, dec) = proj_on.pixel_to_world(ox as f64, oy as f64);
                let truth = sky_field(ra, dec, ra0, dec0);
                let got = stitched_on[oy * ow + ox] as f64;
                max_err_on = max_err_on.max((got - truth).abs());
                n_on += 1;
            }
        }
        assert!(n_on > 50);
        assert!(out_proj_overlap_pairs(&on) >= 1);
        // Equalised: the residual is a small fraction of the un-normalized seam.
        assert!(
            max_err_on < max_err_off * 0.2,
            "normalization should shrink the seam: on={max_err_on}, off={max_err_off}"
        );
    }

    fn out_proj_overlap_pairs(out: &MosaicOutput) -> usize {
        out.stats.overlap_pairs
    }

    // Non-overlapping panels both appear

    #[test]
    fn non_overlapping_panels_both_present() {
        let dec0: f64 = 0.0;
        let scale: f64 = 3.0;
        let w = 96;
        let h = 96;
        // Two panels separated by ~2 panel widths in RA (a gap between them).
        let panel_w_deg = (w as f64) * (scale / 3600.0);
        let ra_a = 300.0;
        let ra_b = 300.0 - 2.5 * panel_w_deg;
        let wcs_a = make_wcs(ra_a, dec0, scale, w, h);
        let wcs_b = make_wcs(ra_b, dec0, scale, w, h);
        let a = synth_panel(&wcs_a, w, h, ra_a, dec0, 1.0, 5000.0);
        let b = synth_panel(&wcs_b, w, h, ra_a, dec0, 1.0, 5000.0);

        let cfg = MosaicStitchConfig {
            blend: MosaicBlend::None,
            normalize: false,
            ..Default::default()
        };
        let out = stitch_mosaic(&[a, b], &cfg).unwrap();
        assert_eq!(out.stats.overlap_pairs, 0, "panels must not overlap");

        let ow = out.stats.out_width as usize;
        let oh = out.stats.out_height as usize;
        let cov = out.coverage.as_f32().unwrap();
        // There must be covered pixels near each panel centre.
        let out_proj = WcsProjection::new(&out.wcs).unwrap();
        for (ra, dec) in [(ra_a, dec0), (ra_b, dec0)] {
            let (ox, oy) = out_proj.world_to_pixel(ra, dec).unwrap();
            let oxi = ox.round() as usize;
            let oyi = oy.round() as usize;
            assert!(oxi < ow && oyi < oh, "panel centre on canvas");
            assert!(
                cov[oyi * ow + oxi] > 0.0,
                "panel centre ({ra},{dec}) must be covered"
            );
        }
    }

    // 3-panel chain: offset equalisation must account for per-panel gain

    /// A 3-panel RA chain A–B–C with *different* gains and offsets, perfect
    /// noiseless synthetic sky. After equalisation every overlap must collapse
    /// onto the same truth field — including the B–C overlap at the far end of
    /// the chain, which is where a linearised offset edge (`o` instead of
    /// `g_i·o`, valid only for `g_i ≈ 1`) leaves a `(g_i−1)·o` residual that
    /// accumulates along the chain.
    #[test]
    fn normalization_equalizes_three_panel_chain() {
        let ra0: f64 = 120.0;
        let dec0: f64 = 35.0;
        let scale: f64 = 4.0;
        let w = 128;
        let h = 128;
        // Each panel steps ~half a panel-width east in RA, so A∩B and B∩C both
        // overlap but A and C do not — a genuine 3-node chain (C is index ≥ 2).
        let step_deg = (w as f64 / 2.0) * (scale / 3600.0) / dec0.to_radians().cos();
        let wcs_a = make_wcs(ra0, dec0, scale, w, h);
        let wcs_b = make_wcs(ra0 - step_deg, dec0, scale, w, h);
        let wcs_c = make_wcs(ra0 - 2.0 * step_deg, dec0, scale, w, h);
        // A is the reference (gain 1, offset 0); B and C carry large, distinct
        // gain+offset distortions — exactly the transparency/exposure spread the
        // equaliser exists to remove.
        let a = synth_panel(&wcs_a, w, h, ra0, dec0, 1.0, 0.0);
        let b = synth_panel(&wcs_b, w, h, ra0, dec0, 1.5, 300.0);
        let c = synth_panel(&wcs_c, w, h, ra0, dec0, 3.0, 1000.0);

        let cfg = MosaicStitchConfig {
            blend: MosaicBlend::None, // hard average so a residual cannot hide in a ramp
            normalize: true,
            ..Default::default()
        };
        let out = stitch_mosaic(&[a, b, c], &cfg).unwrap();
        assert_eq!(out.stats.panels, 3);
        assert!(
            out.stats.overlap_pairs >= 2,
            "chain must have A∩B and B∩C overlaps, got {}",
            out.stats.overlap_pairs
        );

        let ow = out.stats.out_width as usize;
        let oh = out.stats.out_height as usize;
        let cov = out.coverage.as_f32().unwrap();
        let stitched = out.master.as_f32().unwrap();
        let proj = WcsProjection::new(&out.wcs).unwrap();

        // Check the residual in *every* 2-panel overlap against the truth
        // field. B–C, at the far end of the chain, is the strictest: with
        // d = g_i·o it must match within resampling error.
        let mut max_err = 0.0f64;
        let mut n = 0;
        for oy in 16..oh - 16 {
            for ox in 16..ow - 16 {
                if (cov[oy * ow + ox] - 2.0).abs() > 0.05 {
                    continue;
                }
                let (ra, dec) = proj.pixel_to_world(ox as f64, oy as f64);
                let truth = sky_field(ra, dec, ra0, dec0);
                let got = stitched[oy * ow + ox] as f64;
                max_err = max_err.max((got - truth).abs());
                n += 1;
            }
        }
        assert!(n > 100, "expected overlap pixels to check, got {n}");
        // Field spans thousands of ADU; the chain is noiseless, so only
        // resampling error remains. B–C is the far end of the chain and the
        // strictest case: a gain-blind offset chain drifts tens of ADU here.
        assert!(
            max_err < 15.0,
            "3-panel chain overlap residual {max_err} too large — \
             offset chain is not gain-aware"
        );
    }

    // A NaN source pixel must not poison the stitched output

    /// Inject a NaN into a covered pixel of a panel and assert the stitched
    /// master and coverage stay entirely finite. NaN/inf-bearing masters are an
    /// expected input class (all-rejected or div-by-zero pixels); the renderer
    /// must exclude a non-finite sample exactly like an out-of-bounds one, never
    /// fold it (and — under Lanczos/Catmull — its smeared support window) into
    /// the weighted mean.
    #[test]
    fn nan_source_pixel_does_not_poison_output() {
        let ra0: f64 = 80.0;
        let dec0: f64 = 5.0;
        let scale: f64 = 4.0;
        let w = 128u32;
        let h = 128u32;
        let half_w_deg = (w as f64 / 2.0) * (scale / 3600.0) / dec0.to_radians().cos();
        let wcs_a = make_wcs(ra0, dec0, scale, w, h);
        let wcs_b = make_wcs(ra0 - half_w_deg, dec0, scale, w, h);

        // Build panel A's buffer directly so we can poke a NaN into its centre —
        // a pixel that is firmly covered (and lands inside the A∩B overlap, so
        // the resampler's support window is exercised there too).
        let proj_a = WcsProjection::new(&wcs_a).unwrap();
        let mut data_a = vec![0.0f32; (w * h) as usize];
        for y in 0..h {
            for x in 0..w {
                let (ra, dec) = proj_a.pixel_to_world(x as f64, y as f64);
                data_a[(y * w + x) as usize] = sky_field(ra, dec, ra0, dec0) as f32;
            }
        }
        // Poison a band of pixels (one stray NaN would only smear locally; a band
        // guarantees several output pixels sample a non-finite support window).
        let cy = (h / 2) as usize;
        for dy in 0..3usize {
            for x in 0..w as usize {
                data_a[(cy + dy) * w as usize + x] = f32::NAN;
            }
        }
        // Also seed an inf to cover the inf arm of the finiteness check.
        data_a[cy * w as usize + 4] = f32::INFINITY;

        let a = MosaicPanel {
            image: ImageData::from_f32(w, h, 1, &data_a),
            wcs: wcs_a.clone(),
        };
        let b = synth_panel(&wcs_b, w, h, ra0, dec0, 1.0, 0.0);

        // Resampler with a wide support window — this is where a NaN would smear
        // before reaching the accumulator if unguarded.
        let cfg = MosaicStitchConfig {
            blend: MosaicBlend::Feather,
            normalize: true,
            resampler: Interpolator::Lanczos3,
            ..Default::default()
        };
        let out = stitch_mosaic(&[a, b], &cfg).unwrap();

        let master = out.master.as_f32().unwrap();
        let coverage = out.coverage.as_f32().unwrap();
        assert!(
            master.iter().all(|v| v.is_finite()),
            "a NaN/inf source pixel must not produce a non-finite master pixel"
        );
        assert!(
            coverage.iter().all(|v| v.is_finite()),
            "coverage must stay finite"
        );
        // The poison must not silently erase the whole canvas: real sky still
        // stitches. There must be plenty of positively-covered, finite pixels.
        let covered = coverage.iter().filter(|&&c| c > 0.0).count();
        assert!(
            covered > (w * h) as usize / 2,
            "the mosaic must still render real coverage, got {covered}"
        );
    }
}
