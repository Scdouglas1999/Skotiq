//! Registering one target's per-filter masters onto a common reference.
//!
//! Each per-filter master was integrated onto its own reference sub-frame, so
//! two masters of one night can sit tens of pixels apart, and masters from two
//! nights can differ by a field rotation or a meridian flip. Combining them
//! pixel for pixel would put a red, a green and a blue image of every star in
//! three different places.
//!
//! The geometry is solved from the stars: [`register_onto`] fits a similarity
//! transform (rotation, uniform scale, translation) with the crate's
//! triangle-matching registration, falling back to a full affine fit when no
//! consistent similarity exists. [`warp_window`] resamples a master onto the
//! reference grid with a clamped Lanczos-3 kernel, PixInsight's default
//! interpolation for registration; the clamp limits each output sample to the
//! range of its four nearest source pixels, which removes the ringing Lanczos
//! leaves beside a bright star core. [`overlap_rect`] is the rectangle every
//! master covers, and [`alignment_check`] measures what is left: the offset of
//! each star's centroid between the reference and a resampled master.

use rayon::prelude::*;

use crate::recipe::ops::star_detect::detection_frame;
use crate::recipe::{OpContext, OpError, OpImage, CANCEL_POLL_PIXELS};
use crate::registration::{solve_registration, RegistrationConfig, TransformKind};
use crate::{detect_stars, StarDetectionConfig};

/// A 2-D affine map, `x' = m0·x + m1·y + m2`, `y' = m3·x + m4·y + m5`, taking a
/// master's pixel coordinates to the reference's.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Affine2 {
    /// Row-major coefficients.
    pub m: [f64; 6],
}

impl Affine2 {
    /// The identity map.
    pub const IDENTITY: Self = Self {
        m: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
    };

    /// The map stored as six numbers, or `None` when they are not finite or the
    /// map is singular.
    pub fn from_slice(values: &[f64]) -> Option<Self> {
        if values.len() != 6 || values.iter().any(|v| !v.is_finite()) {
            return None;
        }
        let m = [
            values[0], values[1], values[2], values[3], values[4], values[5],
        ];
        let out = Self { m };
        out.inverse().map(|_| out)
    }

    /// Map a point.
    #[inline]
    pub fn apply(&self, x: f64, y: f64) -> (f64, f64) {
        let m = &self.m;
        (m[0] * x + m[1] * y + m[2], m[3] * x + m[4] * y + m[5])
    }

    /// The inverse map, `None` when singular.
    pub fn inverse(&self) -> Option<Self> {
        let [a, b, c, d, e, f] = self.m;
        let det = a * e - b * d;
        if !det.is_finite() || det.abs() < 1e-12 {
            return None;
        }
        let ia = e / det;
        let ib = -b / det;
        let id = -d / det;
        let ie = a / det;
        Some(Self {
            m: [ia, ib, -(ia * c + ib * f), id, ie, -(id * c + ie * f)],
        })
    }

    /// The same map between two images of pyramid level `level`.
    ///
    /// A level-`n` pixel `i` is the box mean of level-0 pixels
    /// `[i·2ⁿ, (i+1)·2ⁿ − 1]`, so its centre sits at `s·i + c` in level-0
    /// coordinates with `s = 2ⁿ` and `c = (s − 1)/2`. The level map is therefore
    /// `T_n(x) = (T_0(s·x + c) − c)/s`.
    pub fn at_level(&self, level: u32) -> Self {
        if level == 0 {
            return *self;
        }
        let s = (1u64 << level.min(62)) as f64;
        let c = (s - 1.0) / 2.0;
        let [a, b, tx, d, e, ty] = self.m;
        // T_0(s·x + c, s·y + c) = (a·s·x + b·s·y + a·c + b·c + tx, …)
        let ox = (a * c + b * c + tx - c) / s;
        let oy = (d * c + e * c + ty - c) / s;
        Self {
            m: [a, b, ox, d, e, oy],
        }
    }

    /// Rotation in degrees, counter-clockwise in pixel coordinates.
    pub fn rotation_deg(&self) -> f64 {
        self.m[3].atan2(self.m[0]).to_degrees()
    }

    /// Geometric mean scale, `sqrt(|det|)`.
    pub fn scale(&self) -> f64 {
        (self.m[0] * self.m[4] - self.m[1] * self.m[3]).abs().sqrt()
    }

    /// Whether the map is within `1e-9` of the identity.
    pub fn is_identity(&self) -> bool {
        self.m
            .iter()
            .zip(Self::IDENTITY.m.iter())
            .all(|(a, b)| (a - b).abs() < 1e-9)
    }
}

/// How one master was registered onto the reference.
#[derive(Debug, Clone, PartialEq)]
pub struct Alignment {
    /// Master → reference, level 0.
    pub transform: Affine2,
    /// `similarity` or `affine`: the model that fitted.
    pub model: &'static str,
    /// Stars detected in the reference.
    pub reference_stars: usize,
    /// Stars detected in the master.
    pub frame_stars: usize,
    /// Star pairs consistent with the fitted geometry.
    pub inliers: usize,
    /// RMS distance of those pairs after the fit, in reference pixels.
    pub rms_px: f64,
}

/// Solve the geometry of `frame` onto `reference` from their stars.
///
/// A similarity is tried first because it is the model two masters from one
/// optical train actually differ by; an affine fit is the fallback for a pair
/// whose plate scale differs per axis. The error text is the registration's
/// own reason, for the report.
pub fn register_onto(
    reference: &OpImage,
    frame: &OpImage,
    ctx: &OpContext,
) -> Result<Alignment, String> {
    let reference_plane = detection_frame(reference, ctx)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "the reference master carries no measurable range".to_string())?;
    let frame_plane = detection_frame(frame, ctx)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "this master carries no measurable range".to_string())?;

    let mut last_error = String::new();
    for (kind, model) in [
        (TransformKind::Similarity, "similarity"),
        (TransformKind::Affine, "affine"),
    ] {
        let config = RegistrationConfig {
            transform_kind: kind,
            ..RegistrationConfig::default()
        };
        match solve_registration(&reference_plane, &frame_plane, &config) {
            Ok((transform, _)) => {
                let matrix = transform.matrix;
                let Some(affine) = Affine2::from_slice(&[
                    matrix[0][0],
                    matrix[0][1],
                    matrix[0][2],
                    matrix[1][0],
                    matrix[1][1],
                    matrix[1][2],
                ]) else {
                    last_error = "the fitted geometry is singular".to_string();
                    continue;
                };
                // The triangle match fits the brightest few dozen stars; every
                // isolated star the two frames share refines it.
                let reference_stars = precise_stars(reference, &reference_plane, REFINE_MAX_STARS);
                let frame_stars = precise_stars(frame, &frame_plane, REFINE_MAX_STARS);
                let fit_affine = kind == TransformKind::Affine
                    || affine.m[0] * affine.m[4] - affine.m[1] * affine.m[3] < 0.0;
                let Some(refined) = refine(affine, fit_affine, &reference_stars, &frame_stars)
                else {
                    last_error =
                        "too few stars are shared once the geometry is refined".to_string();
                    continue;
                };
                return Ok(Alignment {
                    transform: refined.transform,
                    model,
                    reference_stars: reference_stars.len(),
                    frame_stars: frame_stars.len(),
                    inliers: refined.pairs,
                    rms_px: refined.rms_px,
                });
            }
            Err(error) => last_error = error.to_string(),
        }
    }
    Err(last_error)
}

/// Stars closer than this to another star are left out of the refinement and
/// the check: a blend's centroid is not either star's position.
const ISOLATION_PX: f64 = 6.0;
/// Fewest pairs a refined fit is accepted from.
const REFINE_MIN_PAIRS: usize = 8;

/// A refined geometry and what it was fitted from.
struct Refined {
    transform: Affine2,
    pairs: usize,
    rms_px: f64,
}

/// Brightest isolated stars the refinement fits.
const REFINE_MAX_STARS: usize = 800;

/// The brightest `max` isolated stars of `image`, at windowed-centroid
/// precision.
///
/// The detector's centroid is good to about a tenth of a pixel, which is the
/// size of the residual a color composite cannot hide. Each detection is
/// re-centred with SExtractor's windowed centroid (`XWIN`): a Gaussian-weighted
/// first moment of the background-subtracted pixels, iterated to convergence,
/// which reaches a few hundredths of a pixel on a well-exposed star.
fn precise_stars(image: &OpImage, plane: &crate::ImageData, max: usize) -> Vec<(f64, f64)> {
    let mut stars = detect_stars(plane, &StarDetectionConfig::default());
    stars.sort_by(|a, b| b.flux.total_cmp(&a.flux));
    let index = StarIndex::new(stars.iter().map(|s| (s.x, s.y)).collect());
    let mean = channel_mean(image);
    let (w, h) = (image.width() as usize, image.height() as usize);
    stars
        .iter()
        .filter(|s| index.count_within(s.x, s.y, ISOLATION_PX) == 1)
        .take(max)
        .filter_map(|s| {
            let sigma = (s.fwhm / 2.355).clamp(0.8, 4.0);
            windowed_centroid(
                &mean,
                w,
                h,
                s.x,
                s.y,
                if sigma.is_finite() { sigma } else { 1.5 },
            )
        })
        .collect()
}

/// Gaussian sigma of a Gaussian star whose half-flux radius is `hfr`:
/// `HFR = σ·sqrt(2·ln 2)`.
const HFR_PER_SIGMA: f64 = 1.177_410_022_515_474_6;

/// The Gaussian sigma, in pixels, of a typical star in `image`: the median
/// half-flux radius of its isolated detections, measured on the linear pixels
/// out to a fixed radius, divided by `sqrt(2·ln 2)`. `None` when it holds too
/// few.
///
/// The detector's own HFR is read off a quantised plane and is only good for
/// ranking; comparing two masters' star sizes needs the flux profile itself.
pub fn star_sigma(image: &OpImage, ctx: &OpContext) -> Result<Option<f64>, OpError> {
    let Some(plane) = detection_frame(image, ctx)? else {
        return Ok(None);
    };
    let stars = detect_stars(&plane, &StarDetectionConfig::default());
    let index = StarIndex::new(stars.iter().map(|s| (s.x, s.y)).collect());
    let mean = channel_mean(image);
    let (w, h) = (image.width() as usize, image.height() as usize);
    let mut radii: Vec<f64> = stars
        .iter()
        .filter(|s| index.count_within(s.x, s.y, 3.0 * PROFILE_RADIUS_PX) == 1)
        .filter_map(|s| half_flux_radius(&mean, w, h, s.x, s.y))
        .collect();
    if radii.len() < 20 {
        return Ok(None);
    }
    radii.sort_by(f64::total_cmp);
    Ok(Some(radii[radii.len() / 2] / HFR_PER_SIGMA))
}

/// Radius the half-flux measurement integrates to, in pixels.
const PROFILE_RADIUS_PX: f64 = 12.0;

/// The radius holding half the background-subtracted flux within
/// [`PROFILE_RADIUS_PX`] of `(x, y)`, the sky read from a ring beyond it.
fn half_flux_radius(plane: &[f32], width: usize, height: usize, x: f64, y: f64) -> Option<f64> {
    let outer = PROFILE_RADIUS_PX + 6.0;
    let reach = outer.ceil() as i64;
    let (cx, cy) = (x.round() as i64, y.round() as i64);
    if cx - reach < 0 || cy - reach < 0 || cx + reach >= width as i64 || cy + reach >= height as i64
    {
        return None;
    }
    let mut sky = Vec::new();
    let mut profile: Vec<(f64, f64)> = Vec::new();
    for dy in -reach..=reach {
        for dx in -reach..=reach {
            let px = cx + dx;
            let py = cy + dy;
            let r = ((px as f64 - x).powi(2) + (py as f64 - y).powi(2)).sqrt();
            let v = plane[py as usize * width + px as usize] as f64;
            if r <= PROFILE_RADIUS_PX {
                profile.push((r, v));
            } else if r > PROFILE_RADIUS_PX + 2.0 && r <= outer {
                sky.push(v);
            }
        }
    }
    sky.sort_by(f64::total_cmp);
    let background = *sky.get(sky.len() / 2)?;
    profile.sort_by(|a, b| a.0.total_cmp(&b.0));
    let total: f64 = profile.iter().map(|(_, v)| v - background).sum();
    if total <= 0.0 {
        return None;
    }
    let mut cumulative = 0.0;
    let mut previous = (0.0, 0.0);
    for &(r, v) in &profile {
        let next = cumulative + (v - background);
        if next >= total / 2.0 {
            let span = next - cumulative;
            let t = if span > 0.0 {
                (total / 2.0 - cumulative) / span
            } else {
                0.0
            };
            return Some(previous.0 + t * (r - previous.0));
        }
        cumulative = next;
        previous = (r, cumulative);
    }
    None
}

/// The mean across channels, as one plane.
fn channel_mean(image: &OpImage) -> Vec<f32> {
    let channels = image.channels() as usize;
    if channels == 1 {
        return image.data().to_vec();
    }
    image
        .data()
        .chunks_exact(channels)
        .map(|p| p.iter().sum::<f32>() / channels as f32)
        .collect()
}

/// SExtractor's windowed centroid around `(x, y)`; `None` when the window
/// leaves the frame or the iteration does not settle near the start.
fn windowed_centroid(
    plane: &[f32],
    width: usize,
    height: usize,
    x: f64,
    y: f64,
    sigma: f64,
) -> Option<(f64, f64)> {
    let radius = (4.0 * sigma).ceil() as i64;
    let ring = radius + 3;
    let (cx, cy) = (x.round() as i64, y.round() as i64);
    if cx - ring < 0 || cy - ring < 0 || cx + ring >= width as i64 || cy + ring >= height as i64 {
        return None;
    }
    // Local sky: the median of a ring just outside the window.
    let mut sky: Vec<f64> = Vec::new();
    for dy in -ring..=ring {
        for dx in -ring..=ring {
            let r2 = dx * dx + dy * dy;
            if r2 > radius * radius && r2 <= ring * ring {
                sky.push(plane[(cy + dy) as usize * width + (cx + dx) as usize] as f64);
            }
        }
    }
    sky.sort_by(f64::total_cmp);
    let background = *sky.get(sky.len() / 2)?;
    let (mut px, mut py) = (x, y);
    let inv = 1.0 / (2.0 * sigma * sigma);
    for _ in 0..16 {
        let (mut sw, mut sx, mut sy) = (0.0, 0.0, 0.0);
        for dy in -radius..=radius {
            for dx in -radius..=radius {
                let ix = cx + dx;
                let iy = cy + dy;
                let v = plane[iy as usize * width + ix as usize] as f64 - background;
                let rx = ix as f64 - px;
                let ry = iy as f64 - py;
                let w = (-(rx * rx + ry * ry) * inv).exp() * v;
                sw += w;
                sx += w * rx;
                sy += w * ry;
            }
        }
        if sw <= 0.0 {
            return None;
        }
        let (stepx, stepy) = (2.0 * sx / sw, 2.0 * sy / sw);
        px += stepx;
        py += stepy;
        if (px - x).abs() > 2.0 || (py - y).abs() > 2.0 {
            return None;
        }
        if stepx.abs() < 1e-4 && stepy.abs() < 1e-4 {
            break;
        }
    }
    Some((px, py))
}

/// A uniform-grid index over star positions.
struct StarIndex {
    points: Vec<(f64, f64)>,
    cells: std::collections::HashMap<(i64, i64), Vec<usize>>,
}

impl StarIndex {
    const CELL: f64 = 8.0;

    fn new(points: Vec<(f64, f64)>) -> Self {
        let mut cells: std::collections::HashMap<(i64, i64), Vec<usize>> = Default::default();
        for (i, (x, y)) in points.iter().enumerate() {
            cells
                .entry((
                    (x / Self::CELL).floor() as i64,
                    (y / Self::CELL).floor() as i64,
                ))
                .or_default()
                .push(i);
        }
        Self { points, cells }
    }

    fn candidates(&self, x: f64, y: f64, radius: f64) -> impl Iterator<Item = usize> + '_ {
        let span = (radius / Self::CELL).ceil() as i64;
        let cx = (x / Self::CELL).floor() as i64;
        let cy = (y / Self::CELL).floor() as i64;
        (cy - span..=cy + span)
            .flat_map(move |gy| (cx - span..=cx + span).map(move |gx| (gx, gy)))
            .filter_map(|cell| self.cells.get(&cell))
            .flatten()
            .copied()
    }

    fn count_within(&self, x: f64, y: f64, radius: f64) -> usize {
        self.candidates(x, y, radius)
            .filter(|&i| {
                let (px, py) = self.points[i];
                (px - x).powi(2) + (py - y).powi(2) <= radius * radius
            })
            .count()
    }

    /// The nearest point within `radius`, with its index; the lowest index wins
    /// a tie so the answer never depends on hash order.
    fn nearest(&self, x: f64, y: f64, radius: f64) -> Option<(usize, f64)> {
        let mut best: Option<(usize, f64)> = None;
        for i in self.candidates(x, y, radius) {
            let (px, py) = self.points[i];
            let d2 = (px - x).powi(2) + (py - y).powi(2);
            if d2 > radius * radius {
                continue;
            }
            let better = match best {
                None => true,
                Some((bi, bd)) => d2 < bd || (d2 == bd && i < bi),
            };
            if better {
                best = Some((i, d2));
            }
        }
        best
    }
}

/// Re-fit `initial` by least squares over every isolated star pair it brings
/// within a pixel or two, clipping outlying pairs, a few rounds.
fn refine(
    initial: Affine2,
    affine: bool,
    refs: &[(f64, f64)],
    frames: &[(f64, f64)],
) -> Option<Refined> {
    let index = StarIndex::new(refs.to_vec());
    let mut transform = initial;
    let mut result = None;
    for (round, radius) in [2.0, 1.0, 0.75, 0.75].into_iter().enumerate() {
        let mut pairs: Vec<((f64, f64), (f64, f64))> = Vec::new();
        let mut taken = vec![false; refs.len()];
        for &(fx, fy) in frames {
            let (mx, my) = transform.apply(fx, fy);
            if let Some((i, _)) = index.nearest(mx, my, radius) {
                if !taken[i] {
                    taken[i] = true;
                    pairs.push(((fx, fy), refs[i]));
                }
            }
        }
        if round > 0 && pairs.len() > REFINE_MIN_PAIRS {
            let mut residuals: Vec<f64> = pairs
                .iter()
                .map(|(p, q)| {
                    let (mx, my) = transform.apply(p.0, p.1);
                    ((mx - q.0).powi(2) + (my - q.1).powi(2)).sqrt()
                })
                .collect();
            let mut sorted = residuals.clone();
            sorted.sort_by(f64::total_cmp);
            let limit = (3.0 * sorted[sorted.len() / 2] * 1.4826).max(0.05);
            let mut kept = Vec::with_capacity(pairs.len());
            for (pair, r) in pairs.into_iter().zip(residuals.drain(..)) {
                if r <= limit {
                    kept.push(pair);
                }
            }
            pairs = kept;
        }
        if pairs.len() < REFINE_MIN_PAIRS {
            return result;
        }
        let fitted = if affine {
            fit_affine_ls(&pairs)
        } else {
            fit_similarity_ls(&pairs)
        }?;
        transform = fitted;
        let rms = (pairs
            .iter()
            .map(|(p, q)| {
                let (mx, my) = transform.apply(p.0, p.1);
                (mx - q.0).powi(2) + (my - q.1).powi(2)
            })
            .sum::<f64>()
            / pairs.len() as f64)
            .sqrt();
        result = Some(Refined {
            transform,
            pairs: pairs.len(),
            rms_px: rms,
        });
    }
    result
}

/// Least-squares rotation + uniform scale + translation taking each pair's
/// first point onto its second.
fn fit_similarity_ls(pairs: &[((f64, f64), (f64, f64))]) -> Option<Affine2> {
    let n = pairs.len() as f64;
    let (pmx, pmy) = pairs
        .iter()
        .fold((0.0, 0.0), |a, (p, _)| (a.0 + p.0, a.1 + p.1));
    let (qmx, qmy) = pairs
        .iter()
        .fold((0.0, 0.0), |a, (_, q)| (a.0 + q.0, a.1 + q.1));
    let (pmx, pmy, qmx, qmy) = (pmx / n, pmy / n, qmx / n, qmy / n);
    let (mut sa, mut sb, mut ss) = (0.0, 0.0, 0.0);
    for (p, q) in pairs {
        let (dx, dy) = (p.0 - pmx, p.1 - pmy);
        let (ex, ey) = (q.0 - qmx, q.1 - qmy);
        sa += dx * ex + dy * ey;
        sb += dx * ey - dy * ex;
        ss += dx * dx + dy * dy;
    }
    if ss <= 0.0 {
        return None;
    }
    let (a, b) = (sa / ss, sb / ss);
    Affine2::from_slice(&[
        a,
        -b,
        qmx - a * pmx + b * pmy,
        b,
        a,
        qmy - b * pmx - a * pmy,
    ])
}

/// Least-squares six-parameter affine map taking each pair's first point onto
/// its second.
fn fit_affine_ls(pairs: &[((f64, f64), (f64, f64))]) -> Option<Affine2> {
    let mut ata = [[0.0f64; 3]; 3];
    let mut atx = [0.0f64; 3];
    let mut aty = [0.0f64; 3];
    for (p, q) in pairs {
        let row = [p.0, p.1, 1.0];
        for i in 0..3 {
            for j in 0..3 {
                ata[i][j] += row[i] * row[j];
            }
            atx[i] += row[i] * q.0;
            aty[i] += row[i] * q.1;
        }
    }
    let solve = |b: [f64; 3]| -> Option<[f64; 3]> {
        let m = ata;
        let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
        if det.abs() < 1e-12 {
            return None;
        }
        let replace = |col: usize| {
            let mut c = m;
            for r in 0..3 {
                c[r][col] = b[r];
            }
            c[0][0] * (c[1][1] * c[2][2] - c[1][2] * c[2][1])
                - c[0][1] * (c[1][0] * c[2][2] - c[1][2] * c[2][0])
                + c[0][2] * (c[1][0] * c[2][1] - c[1][1] * c[2][0])
        };
        Some([replace(0) / det, replace(1) / det, replace(2) / det])
    };
    let x = solve(atx)?;
    let y = solve(aty)?;
    Affine2::from_slice(&[x[0], x[1], x[2], y[0], y[1], y[2]])
}

/// An axis-aligned rectangle in reference pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    /// Left edge.
    pub x: u32,
    /// Top edge.
    pub y: u32,
    /// Width.
    pub width: u32,
    /// Height.
    pub height: u32,
}

impl Rect {
    /// The rectangle at pyramid level `level`. Exact when every edge is a
    /// multiple of `2^level`, which [`overlap_rect`] guarantees up to its
    /// alignment.
    pub fn at_level(&self, level: u32) -> Self {
        Self {
            x: self.x >> level,
            y: self.y >> level,
            width: (self.width >> level).max(1),
            height: (self.height >> level).max(1),
        }
    }
}

/// Grid step, in reference pixels, the coverage test runs at.
const COVERAGE_STEP: u32 = 4;

/// The largest axis-aligned rectangle of the reference grid that every master
/// covers, with `margin` pixels of source support on every side of every
/// sample, its edges rounded inward to multiples of `alignment`.
///
/// `inputs` holds each master's master → reference map and its size. The
/// alignment is what keeps a preview truthful: cropping a pyramid level by
/// `rect >> n` is then exactly the level-`n` image of the full-resolution crop.
pub fn overlap_rect(
    reference_width: u32,
    reference_height: u32,
    inputs: &[(Affine2, u32, u32)],
    margin: f64,
    alignment: u32,
) -> Option<Rect> {
    let alignment = alignment.max(1);
    let inverses: Vec<(Affine2, f64, f64)> = inputs
        .iter()
        .map(|(t, w, h)| t.inverse().map(|inv| (inv, *w as f64, *h as f64)))
        .collect::<Option<_>>()?;
    let cols = (reference_width / COVERAGE_STEP) as usize;
    let rows = (reference_height / COVERAGE_STEP) as usize;
    if cols == 0 || rows == 0 {
        return None;
    }
    let covered = |x: f64, y: f64| {
        inverses.iter().all(|(inv, w, h)| {
            let (sx, sy) = inv.apply(x, y);
            sx >= margin && sy >= margin && sx <= w - 1.0 - margin && sy <= h - 1.0 - margin
        })
    };
    // A cell is usable when all four of its corners are covered; the coverage
    // region is convex per master, so the cell between them is too.
    let corner = |col: usize, row: usize| {
        covered(
            (col as u32 * COVERAGE_STEP) as f64,
            (row as u32 * COVERAGE_STEP) as f64,
        )
    };
    let corners: Vec<Vec<bool>> = (0..=rows)
        .into_par_iter()
        .map(|row| (0..=cols).map(|col| corner(col, row)).collect())
        .collect();

    // Largest rectangle of usable cells: one histogram pass per row.
    let mut heights = vec![0usize; cols];
    let mut best: Option<(usize, usize, usize, usize, usize)> = None; // area, col0, row0, w, h
    for row in 0..rows {
        for (col, height) in heights.iter_mut().enumerate() {
            let usable = corners[row][col]
                && corners[row][col + 1]
                && corners[row + 1][col]
                && corners[row + 1][col + 1];
            *height = if usable { *height + 1 } else { 0 };
        }
        let mut stack: Vec<usize> = Vec::new();
        for col in 0..=cols {
            let h = if col < cols { heights[col] } else { 0 };
            while let Some(&top) = stack.last() {
                if heights[top] <= h {
                    break;
                }
                stack.pop();
                let height = heights[top];
                let left = stack.last().map(|&l| l + 1).unwrap_or(0);
                let width = col - left;
                let area = width * height;
                if best.is_none_or(|b| area > b.0) {
                    best = Some((area, left, row + 1 - height, width, height));
                }
            }
            stack.push(col);
        }
    }
    let (_, col0, row0, w, h) = best?;
    let x0 = col0 as u32 * COVERAGE_STEP;
    let y0 = row0 as u32 * COVERAGE_STEP;
    let x1 = x0 + w as u32 * COVERAGE_STEP;
    let y1 = y0 + h as u32 * COVERAGE_STEP;
    let ax0 = x0.div_ceil(alignment) * alignment;
    let ay0 = y0.div_ceil(alignment) * alignment;
    let ax1 = (x1 / alignment) * alignment;
    let ay1 = (y1 / alignment) * alignment;
    if ax1 <= ax0 || ay1 <= ay0 {
        return None;
    }
    Some(Rect {
        x: ax0,
        y: ay0,
        width: ax1 - ax0,
        height: ay1 - ay0,
    })
}

/// Lanczos-3 kernel samples per unit of distance in the lookup table.
const LANCZOS_LUT_RESOLUTION: usize = 1024;

fn lanczos3(x: f64) -> f64 {
    const A: f64 = 3.0;
    let x = x.abs();
    if x < 1e-12 {
        1.0
    } else if x < A {
        let px = std::f64::consts::PI * x;
        (A * px.sin() * (px / A).sin()) / (px * px)
    } else {
        0.0
    }
}

fn lanczos_table() -> &'static [f32] {
    static TABLE: std::sync::OnceLock<Vec<f32>> = std::sync::OnceLock::new();
    TABLE.get_or_init(|| {
        (0..=3 * LANCZOS_LUT_RESOLUTION + 1)
            .map(|i| lanczos3(i as f64 / LANCZOS_LUT_RESOLUTION as f64) as f32)
            .collect()
    })
}

#[inline]
fn kernel(table: &[f32], x: f64) -> f64 {
    let pos = x.abs() * LANCZOS_LUT_RESOLUTION as f64;
    let i = pos as usize;
    if i + 1 >= table.len() {
        return 0.0;
    }
    let t = pos - i as f64;
    table[i] as f64 * (1.0 - t) + table[i + 1] as f64 * t
}

/// Resample `src` onto the `out` window of the reference grid, through
/// `transform` (master → reference at the render level), with clamped
/// Lanczos-3.
///
/// Source taps outside the master repeat its edge pixel, so a window that runs
/// to the edge of the support darkens nothing. The result is interleaved with
/// `src`'s channel count.
pub fn warp_window(
    src: &OpImage,
    transform: &Affine2,
    out: Rect,
    ctx: &OpContext,
) -> Result<Vec<f32>, OpError> {
    let inverse = transform.inverse().ok_or_else(|| OpError::Failed {
        op_id: "channel_combine",
        op_version: 1,
        reason: "a master's registration transform is singular".to_string(),
    })?;
    let channels = src.channels() as usize;
    let sw = src.width() as i64;
    let sh = src.height() as i64;
    let data = src.data();
    let table = lanczos_table();
    let ow = out.width as usize;
    let rows_per_poll = (CANCEL_POLL_PIXELS / ow.max(1)).max(1);

    let mut result = vec![0.0_f32; ow * out.height as usize * channels];
    result
        .par_chunks_mut(ow * channels * rows_per_poll)
        .enumerate()
        .for_each(|(chunk, block)| {
            if ctx.cancel_requested() {
                return;
            }
            let first_row = chunk * rows_per_poll;
            for (r, row) in block.chunks_mut(ow * channels).enumerate() {
                let y = (out.y as usize + first_row + r) as f64;
                for (i, pixel) in row.chunks_mut(channels).enumerate() {
                    let x = (out.x as usize + i) as f64;
                    let (sx, sy) = inverse.apply(x, y);
                    let x0 = sx.floor() as i64;
                    let y0 = sy.floor() as i64;
                    let fx = sx - x0 as f64;
                    let fy = sy - y0 as f64;
                    let mut wx = [0.0f64; 6];
                    let mut wy = [0.0f64; 6];
                    let mut sum_x = 0.0;
                    let mut sum_y = 0.0;
                    for t in 0..6 {
                        let offset = t as f64 - 2.0;
                        wx[t] = kernel(table, fx - offset);
                        wy[t] = kernel(table, fy - offset);
                        sum_x += wx[t];
                        sum_y += wy[t];
                    }
                    let norm = sum_x * sum_y;
                    for (c, slot) in pixel.iter_mut().enumerate() {
                        let at = |ix: i64, iy: i64| -> f64 {
                            let cx = ix.clamp(0, sw - 1) as usize;
                            let cy = iy.clamp(0, sh - 1) as usize;
                            data[(cy * sw as usize + cx) * channels + c] as f64
                        };
                        let mut acc = 0.0;
                        for (ty, wyv) in wy.iter().enumerate() {
                            let iy = y0 + ty as i64 - 2;
                            let mut row_acc = 0.0;
                            for (tx, wxv) in wx.iter().enumerate() {
                                row_acc += wxv * at(x0 + tx as i64 - 2, iy);
                            }
                            acc += wyv * row_acc;
                        }
                        let value = if norm.abs() > f64::EPSILON {
                            acc / norm
                        } else {
                            at(x0, y0)
                        };
                        let n = [
                            at(x0, y0),
                            at(x0 + 1, y0),
                            at(x0, y0 + 1),
                            at(x0 + 1, y0 + 1),
                        ];
                        let lo = n.iter().copied().fold(f64::INFINITY, f64::min);
                        let hi = n.iter().copied().fold(f64::NEG_INFINITY, f64::max);
                        *slot = value.clamp(lo, hi) as f32;
                    }
                }
            }
        });
    ctx.check_cancel()?;
    Ok(result)
}

/// What remains of the registration: star centroid offsets between the
/// reference and a resampled master.
#[derive(Debug, Clone, PartialEq)]
pub struct AlignmentCheck {
    /// Stars matched between the two images.
    pub stars: usize,
    /// Median offset length, in pixels.
    pub median_px: f64,
    /// RMS offset length, in pixels.
    pub rms_px: f64,
    /// Mean offset, x, in pixels: a systematic shift shows here.
    pub mean_dx: f64,
    /// Mean offset, y, in pixels.
    pub mean_dy: f64,
}

/// Brightest isolated stars the check compares.
const CHECK_MAX_STARS: usize = 400;
/// Farthest a star may move between the two images and still be paired.
const CHECK_MATCH_RADIUS_PX: f64 = 2.0;

/// Measure star centroid offsets between `reference` and `aligned`, two
/// single-plane images of one size on one grid.
pub fn alignment_check(
    reference: &OpImage,
    aligned: &OpImage,
    ctx: &OpContext,
) -> Result<Option<AlignmentCheck>, OpError> {
    let (Some(ref_plane), Some(aligned_plane)) = (
        detection_frame(reference, ctx)?,
        detection_frame(aligned, ctx)?,
    ) else {
        return Ok(None);
    };
    let ref_points = precise_stars(reference, &ref_plane, CHECK_MAX_STARS);
    let index = StarIndex::new(precise_stars(aligned, &aligned_plane, CHECK_MAX_STARS * 4));

    let mut offsets: Vec<(f64, f64)> = Vec::new();
    for &(x, y) in &ref_points {
        if let Some((i, _)) = index.nearest(x, y, CHECK_MATCH_RADIUS_PX) {
            let (ox, oy) = index.points[i];
            offsets.push((ox - x, oy - y));
        }
    }
    if offsets.is_empty() {
        return Ok(None);
    }
    let n = offsets.len() as f64;
    let mut lengths: Vec<f64> = offsets
        .iter()
        .map(|(dx, dy)| (dx * dx + dy * dy).sqrt())
        .collect();
    let rms = (lengths.iter().map(|l| l * l).sum::<f64>() / n).sqrt();
    lengths.sort_by(f64::total_cmp);
    let median = lengths[lengths.len() / 2];
    Ok(Some(AlignmentCheck {
        stars: offsets.len(),
        median_px: median,
        rms_px: rms,
        mean_dx: offsets.iter().map(|o| o.0).sum::<f64>() / n,
        mean_dy: offsets.iter().map(|o| o.1).sum::<f64>() / n,
    }))
}

#[cfg(test)]
#[path = "align_tests.rs"]
mod align_tests;
