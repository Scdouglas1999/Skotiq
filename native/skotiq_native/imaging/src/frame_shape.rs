//! Per-frame star size and shape for frame grading, measured the way an
//! independent PSF fit measures them.
//!
//! # Why this exists
//!
//! [`detect_stars`] reports every star it can find, blends and faint stars
//! included, with a shape from its footprint's moments. A frame-grading value
//! needs fewer, better stars and the core shape a PSF fit reports: footprint
//! moments include the round seeing halo and under-read a trailed star's
//! elongation.
//!
//! # What it measures
//!
//! Only stars that can be measured honestly: unsaturated, isolated from any
//! comparably bright neighbor, and far enough from the edge for a background
//! annulus. For each, against a LOCAL background (median of an annulus):
//!
//! * the half-flux radius of the signed (unclipped) flux inside a circular
//!   aperture — noise then averages to zero instead of building a floor; and
//! * the eccentricity of adaptive, elliptical-Gaussian-weighted second moments
//!   (Bernstein & Jarvis 2002), which converge on the star's core shape. That
//!   is what a PSF fit, and PixInsight's FWHMEccentricity, report; plain
//!   aperture moments include the round seeing halo and under-read a smear.
//!
//! The frame value is the median over the brightest [`MAX_STARS`] such stars.

use crate::{detect_stars, DetectedStar, ImageData, StarDetectionConfig};

/// Aperture the half-flux radius is measured in, in pixels.
const APERTURE_RADIUS: f64 = 10.0;
/// Background annulus, in pixels from the star.
const ANNULUS_INNER: f64 = 14.0;
const ANNULUS_OUTER: i32 = 20;
/// A neighbor brighter than this fraction of the star's own peak, inside the
/// annulus, would bias both the background and the moments.
const ISOLATION_PEAK_FRACTION: f64 = 0.3;
/// Peaks above this fraction of the detector's saturation limit are on the
/// sensor's non-linear shoulder and read wider than they are.
const SATURATION_FRACTION: f64 = 0.8;
/// Stars aggregated into the frame value.
const MAX_STARS: usize = 50;
/// Fewer measurable stars than this and the frame has no honest median.
const MIN_STARS: usize = 5;
/// Below this half-flux radius a "star" is a hot pixel or a cosmic-ray hit.
const MIN_HFR: f64 = 1.0;
/// Detections closer than this are one star. The detector reports a trailed
/// or flat-topped star several times over (twelve detections inside 3 px of
/// one star on the 09-14 OIII frame), and those copies are neither neighbors
/// nor separate samples.
const SAME_STAR_RADIUS: f64 = 3.0;

/// A frame's median star size and shape.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FrameShape {
    /// Median half-flux radius, pixels.
    pub hfr: f64,
    /// Median eccentricity, `sqrt(1 - (b/a)²)`: 0 round, 1 a line.
    pub eccentricity: f64,
    /// How many stars the medians were taken over.
    pub stars_measured: usize,
    /// Mean direction of the stars' long axes, in degrees from the image +x
    /// axis toward +y, in `[0, 180)`, each star weighted by its eccentricity.
    pub elongation_angle_deg: f64,
    /// How well the stars agree on that direction: 1 when every star is
    /// stretched the same way, near 0 when the directions are random (round
    /// stars, or elongation from noise).
    pub elongation_consistency: f64,
}

/// Eccentricity-weighted mean of axial directions (degrees, period 180) and
/// the length of the mean resultant, 0 to 1.
fn axial_mean(stars: &[(f64, f64)]) -> (f64, f64) {
    let (mut c, mut s, mut w) = (0.0, 0.0, 0.0);
    for &(eccentricity, angle_deg) in stars {
        let doubled = (2.0 * angle_deg).to_radians();
        c += eccentricity * doubled.cos();
        s += eccentricity * doubled.sin();
        w += eccentricity;
    }
    if w <= 0.0 {
        return (0.0, 0.0);
    }
    let angle = (0.5 * s.atan2(c).to_degrees()).rem_euclid(180.0);
    (angle, (c.hypot(s) / w).clamp(0.0, 1.0))
}

/// Measure a frame's star size and shape for grading.
///
/// Returns `None` when fewer than five stars can be measured, which the
/// grader treats as "unknown"; a frame with no detections at all is graded
/// on its star count instead.
pub fn measure_frame_shape(image: &ImageData) -> Option<FrameShape> {
    let config = StarDetectionConfig::default();
    let candidates = detect_stars(image, &config);
    measure_frame_shape_from(image, &candidates, f64::from(config.saturation_limit))
}

/// [`measure_frame_shape`] over detections the caller already has.
pub fn measure_frame_shape_from(
    image: &ImageData,
    candidates: &[DetectedStar],
    saturation_limit: f64,
) -> Option<FrameShape> {
    let width = image.width as usize;
    let height = image.height as usize;
    if image.channels != 1 || width == 0 || height == 0 || image.data.len() < width * height * 2 {
        return None;
    }
    let pixels: Vec<f64> = image
        .data
        .as_chunks::<2>()
        .0
        .iter()
        .take(width * height)
        .map(|c| f64::from(u16::from_le_bytes(*c)))
        .collect();
    let frame = Frame {
        pixels: &pixels,
        width,
        height,
    };

    let seeds = seeds(&frame, candidates);
    let neighbors = NeighborGrid::new(&seeds);
    let mut hfrs = Vec::with_capacity(MAX_STARS);
    let mut eccentricities = Vec::with_capacity(MAX_STARS);
    let mut directions = Vec::with_capacity(MAX_STARS);
    for seed in &seeds {
        if hfrs.len() >= MAX_STARS {
            break;
        }
        if seed.raw_peak >= SATURATION_FRACTION * saturation_limit
            || neighbors.crowded(seed, ISOLATION_PEAK_FRACTION)
        {
            continue;
        }
        if let Some((hfr, eccentricity, angle)) = measure_star(&frame, seed) {
            hfrs.push(hfr);
            eccentricities.push(eccentricity);
            directions.push((eccentricity, angle));
        }
    }
    if hfrs.len() < MIN_STARS {
        return None;
    }
    let stars_measured = hfrs.len();
    let (elongation_angle_deg, elongation_consistency) = axial_mean(&directions);
    Some(FrameShape {
        hfr: crate::robust_stats::median_in_place(&mut hfrs),
        eccentricity: crate::robust_stats::median_in_place(&mut eccentricities),
        stars_measured,
        elongation_angle_deg,
        elongation_consistency,
    })
}

struct Frame<'a> {
    pixels: &'a [f64],
    width: usize,
    height: usize,
}

impl Frame<'_> {
    fn at(&self, x: i32, y: i32) -> f64 {
        self.pixels[y as usize * self.width + x as usize]
    }
}

/// One star to consider: a detection moved onto its brightest pixel.
struct Seed {
    x: i32,
    y: i32,
    raw_peak: f64,
    /// Peak above the frame's global background, for ranking and isolation.
    height: f64,
}

/// The detections as distinct stars, brightest first.
///
/// Neither the detector's centroid nor its `peak` can be used as they are:
/// both come from the clipped 41×41 box, so a faint detection beside a bright
/// star carries that star's peak, and a trailed or flat-topped star comes
/// back as several detections. Each detection is moved onto the brightest
/// pixel within 2 px and its peak read there; copies of one star collapse.
fn seeds(frame: &Frame, candidates: &[DetectedStar]) -> Vec<Seed> {
    let r = ANNULUS_OUTER + 2;
    let mut seeds: Vec<Seed> = candidates
        .iter()
        .filter_map(|star| {
            let (sx, sy) = (star.x.round() as i32, star.y.round() as i32);
            if sx < r || sy < r || sx >= frame.width as i32 - r || sy >= frame.height as i32 - r {
                return None;
            }
            let (mut x, mut y) = (sx, sy);
            for dy in -2..=2 {
                for dx in -2..=2 {
                    if frame.at(sx + dx, sy + dy) > frame.at(x, y) {
                        (x, y) = (sx + dx, sy + dy);
                    }
                }
            }
            let raw_peak = frame.at(x, y);
            Some(Seed {
                x,
                y,
                raw_peak,
                height: raw_peak - star.background,
            })
        })
        .collect();
    seeds.sort_by(|a, b| b.height.total_cmp(&a.height));
    let mut distinct: Vec<Seed> = Vec::with_capacity(seeds.len());
    let mut grid: std::collections::HashMap<(i32, i32), Vec<(i32, i32)>> =
        std::collections::HashMap::new();
    let cell = |x: i32, y: i32| (x.div_euclid(ANNULUS_OUTER), y.div_euclid(ANNULUS_OUTER));
    for seed in seeds {
        let (gx, gy) = cell(seed.x, seed.y);
        let duplicate = (gx - 1..=gx + 1).any(|cx| {
            (gy - 1..=gy + 1).any(|cy| {
                grid.get(&(cx, cy)).is_some_and(|kept| {
                    kept.iter().any(|&(x, y)| {
                        f64::from(x - seed.x).hypot(f64::from(y - seed.y)) <= SAME_STAR_RADIUS
                    })
                })
            })
        });
        if !duplicate {
            grid.entry((gx, gy)).or_default().push((seed.x, seed.y));
            distinct.push(seed);
        }
    }
    distinct
}

/// Seeds bucketed by position, so the isolation check is not quadratic on a
/// frame with 25,000 detections.
struct NeighborGrid<'a> {
    cells: std::collections::HashMap<(i32, i32), Vec<&'a Seed>>,
}

impl<'a> NeighborGrid<'a> {
    fn cell(x: i32, y: i32) -> (i32, i32) {
        (x.div_euclid(ANNULUS_OUTER), y.div_euclid(ANNULUS_OUTER))
    }

    fn new(seeds: &'a [Seed]) -> Self {
        let mut cells: std::collections::HashMap<(i32, i32), Vec<&Seed>> =
            std::collections::HashMap::new();
        for seed in seeds {
            cells
                .entry(Self::cell(seed.x, seed.y))
                .or_default()
                .push(seed);
        }
        Self { cells }
    }

    /// Whether another star inside the annulus' outer radius peaks above
    /// `fraction` of this one's peak.
    fn crowded(&self, seed: &Seed, fraction: f64) -> bool {
        let (gx, gy) = Self::cell(seed.x, seed.y);
        let limit = fraction * seed.height;
        (gx - 1..=gx + 1).any(|cx| {
            (gy - 1..=gy + 1).any(|cy| {
                self.cells.get(&(cx, cy)).is_some_and(|cell| {
                    cell.iter().any(|other| {
                        let distance =
                            f64::from(other.x - seed.x).hypot(f64::from(other.y - seed.y));
                        distance > SAME_STAR_RADIUS
                            && distance <= f64::from(ANNULUS_OUTER)
                            && other.height > limit
                    })
                })
            })
        })
    }
}

/// `(hfr, eccentricity, long-axis direction in degrees)` for one star, or
/// `None` when it cannot be measured honestly.
fn measure_star(frame: &Frame, seed: &Seed) -> Option<(f64, f64, f64)> {
    let r = ANNULUS_OUTER;
    let (px, py) = (seed.x, seed.y);

    let mut annulus = Vec::with_capacity(((2 * r + 1) * (2 * r + 1)) as usize);
    for dy in -r..=r {
        for dx in -r..=r {
            let d = f64::from(dx).hypot(f64::from(dy));
            if d >= ANNULUS_INNER && d <= f64::from(r) {
                annulus.push(frame.at(px + dx, py + dy));
            }
        }
    }
    let background = crate::robust_stats::median_in_place(&mut annulus);

    // Signed values in the aperture. The centroid is refined once, so the
    // aperture is centered on the star rather than on its brightest pixel.
    let aperture = |cx: f64, cy: f64| -> Vec<(f64, f64, f64)> {
        let mut out = Vec::new();
        for dy in -r..=r {
            for dx in -r..=r {
                let x = f64::from(px + dx);
                let y = f64::from(py + dy);
                if (x - cx).hypot(y - cy) <= APERTURE_RADIUS {
                    out.push((x, y, frame.at(px + dx, py + dy) - background));
                }
            }
        }
        out
    };
    let first = aperture(f64::from(px), f64::from(py));
    let flux: f64 = first.iter().map(|p| p.2).sum();
    if flux <= 0.0 {
        return None;
    }
    let cx = first.iter().map(|p| p.0 * p.2).sum::<f64>() / flux;
    let cy = first.iter().map(|p| p.1 * p.2).sum::<f64>() / flux;
    if (cx - f64::from(px)).abs() > 3.0 || (cy - f64::from(py)).abs() > 3.0 {
        return None;
    }
    let samples = aperture(cx, cy);
    let flux: f64 = samples.iter().map(|p| p.2).sum();
    if flux <= 0.0 {
        return None;
    }
    let peak = frame.at(px, py) - background;
    // A hot pixel or cosmic-ray hit puts most of its flux in one pixel.
    if peak / flux > 0.5 {
        return None;
    }

    let mut radial: Vec<(f64, f64)> = samples
        .iter()
        .map(|&(x, y, v)| ((x - cx).hypot(y - cy), v))
        .collect();
    radial.sort_by(|a, b| a.0.total_cmp(&b.0));
    let half = 0.5 * flux;
    let mut cumulative = 0.0;
    let mut hfr = radial.last().map(|s| s.0)?;
    for &(distance, value) in &radial {
        cumulative += value;
        if cumulative >= half {
            hfr = distance;
            break;
        }
    }
    if hfr < MIN_HFR {
        return None;
    }

    let (eccentricity, angle) =
        adaptive_eccentricity(frame, px, py, background, cx, cy, &samples, flux)?;
    Some((hfr, eccentricity, angle))
}

/// Eccentricity and long-axis direction (degrees) from adaptive second
/// moments: the weight is an elliptical Gaussian matched to the star's own
/// shape, iterated to convergence. For a Gaussian star the weighted moments
/// are half the star's covariance, so the converged weight is twice the
/// measured moments.
#[allow(clippy::too_many_arguments)]
fn adaptive_eccentricity(
    frame: &Frame,
    px: i32,
    py: i32,
    background: f64,
    cx: f64,
    cy: f64,
    samples: &[(f64, f64, f64)],
    flux: f64,
) -> Option<(f64, f64)> {
    // Start from the unweighted aperture moments.
    let (mut mxx, mut myy, mut mxy) = (0.0, 0.0, 0.0);
    for &(x, y, v) in samples {
        mxx += (x - cx) * (x - cx) * v;
        myy += (y - cy) * (y - cy) * v;
        mxy += (x - cx) * (y - cy) * v;
    }
    let (mut a, mut b, mut c) = ((mxx / flux).max(1.0), (myy / flux).max(1.0), mxy / flux);
    let (mut ax, mut ay) = (cx, cy);
    let r = ANNULUS_OUTER;
    let mut converged = false;
    for _ in 0..30 {
        let det = a * b - c * c;
        if det.is_nan() || det <= 0.0 || !a.is_finite() || !b.is_finite() {
            return None;
        }
        let (ia, ib, ic) = (b / det, a / det, -c / det);
        let (mut sw, mut sx, mut sy) = (0.0, 0.0, 0.0);
        let mut weighted = Vec::with_capacity(((2 * r + 1) * (2 * r + 1)) as usize);
        for dy in -r..=r {
            for dx in -r..=r {
                if f64::from(dx).hypot(f64::from(dy)) > f64::from(r) {
                    continue;
                }
                let x = f64::from(px + dx);
                let y = f64::from(py + dy);
                let (ux, uy) = (x - ax, y - ay);
                let q = ia * ux * ux + 2.0 * ic * ux * uy + ib * uy * uy;
                let w = (-0.5 * q).exp() * (frame.at(px + dx, py + dy) - background);
                sw += w;
                sx += w * x;
                sy += w * y;
                weighted.push((x, y, w));
            }
        }
        if sw <= 0.0 {
            return None;
        }
        let (nx, ny) = (sx / sw, sy / sw);
        let (mut wxx, mut wyy, mut wxy) = (0.0, 0.0, 0.0);
        for &(x, y, w) in &weighted {
            wxx += (x - nx) * (x - nx) * w;
            wyy += (y - ny) * (y - ny) * w;
            wxy += (x - nx) * (y - ny) * w;
        }
        let (na, nb, nc) = (2.0 * wxx / sw, 2.0 * wyy / sw, 2.0 * wxy / sw);
        let change = (na - a).abs().max((nb - b).abs()).max((nc - c).abs());
        (a, b, c, ax, ay) = (na, nb, nc, nx, ny);
        if (ax - cx).abs() > 3.0 || (ay - cy).abs() > 3.0 {
            return None;
        }
        if change < 1e-3 {
            converged = true;
            break;
        }
    }
    if !converged || a * b - c * c <= 0.0 {
        return None;
    }
    let trace = a + b;
    let root = ((a - b) * (a - b) + 4.0 * c * c).sqrt();
    let major = 0.5 * (trace + root);
    let minor = 0.5 * (trace - root);
    if major <= 0.0 || minor < 0.0 {
        return None;
    }
    Some((
        (1.0 - minor / major).max(0.0).sqrt(),
        crate::star_detect::elongation_angle_deg(a, b, c),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Stars on a noisy sky: `sigma_x`/`sigma_y` set the PSF, `pedestal`
    /// raises one half of the frame (a gradient the global background
    /// estimate cannot follow), and `hot_pixels` adds single-pixel spikes.
    /// Stars stretched along `angle_deg` (from +x toward +y): `sigma_long`
    /// along that direction, `sigma_short` across it, on a noisy sky.
    fn stretched_field(sigma_long: f64, sigma_short: f64, angle_deg: f64) -> ImageData {
        let (w, h) = (600usize, 600usize);
        let mut state = 0x9e37_79b9_7f4a_7c15u64;
        let mut noise = move || {
            let mut acc = 0.0;
            for _ in 0..4 {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                acc += (state >> 11) as f64 / (1u64 << 53) as f64;
            }
            (acc - 2.0) * 1.732
        };
        let (cos, sin) = (angle_deg.to_radians().cos(), angle_deg.to_radians().sin());
        let mut px = vec![0.0f64; w * h];
        for p in px.iter_mut() {
            *p = 600.0 + 60.0 * noise();
        }
        for row in 0..6 {
            for col in 0..6 {
                let (cx, cy) = (60.0 + col as f64 * 95.0, 60.0 + row as f64 * 95.0);
                for y in (cy as usize - 25)..(cy as usize + 25) {
                    for x in (cx as usize - 25)..(cx as usize + 25) {
                        let (dx, dy) = (x as f64 - cx, y as f64 - cy);
                        let along = dx * cos + dy * sin;
                        let across = -dx * sin + dy * cos;
                        px[y * w + x] += 9000.0
                            * (-0.5
                                * ((along / sigma_long).powi(2) + (across / sigma_short).powi(2)))
                            .exp();
                    }
                }
            }
        }
        let data: Vec<u16> = px.iter().map(|v| v.clamp(0.0, 65535.0) as u16).collect();
        ImageData::from_u16(w as u32, h as u32, 1, &data)
    }

    fn axial_difference(a: f64, b: f64) -> f64 {
        let d = (a - b).rem_euclid(180.0);
        d.min(180.0 - d)
    }

    #[test]
    fn the_direction_of_elongation_is_measured_and_agrees_across_stars() {
        for angle in [0.0, 30.0, 90.0, 135.0] {
            let shape = measure_frame_shape(&stretched_field(3.0, 1.8, angle))
                .unwrap_or_else(|| panic!("{angle}: no stars"));
            assert!(
                axial_difference(shape.elongation_angle_deg, angle) < 3.0,
                "{angle}: measured {}",
                shape.elongation_angle_deg
            );
            assert!(shape.elongation_consistency > 0.9, "{shape:?}");
        }
        let round = measure_frame_shape(&stretched_field(2.0, 2.0, 0.0)).expect("stars");
        assert!(round.eccentricity < 0.3, "{round:?}");
    }

    #[test]
    fn the_detector_reports_each_stars_direction() {
        let image = stretched_field(3.0, 1.8, 30.0);
        let stars = detect_stars(&image, &StarDetectionConfig::default());
        assert!(stars.len() >= 20, "{}", stars.len());
        let mut off = stars
            .iter()
            .map(|s| axial_difference(s.elongation_angle_deg, 30.0))
            .collect::<Vec<_>>();
        off.sort_by(f64::total_cmp);
        assert!(off[off.len() / 2] < 5.0, "{off:?}");
    }

    fn field(sigma_x: f64, sigma_y: f64, pedestal: f64, hot_pixels: bool) -> ImageData {
        let (w, h) = (600usize, 600usize);
        let mut state = 0x2545_f491_4f6c_dd1du64;
        let mut noise = move || {
            // Sum of uniforms: near-Gaussian, deterministic.
            let mut acc = 0.0;
            for _ in 0..4 {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                acc += (state >> 11) as f64 / (1u64 << 53) as f64;
            }
            (acc - 2.0) * 1.732
        };
        let mut px = vec![0.0f64; w * h];
        for (i, p) in px.iter_mut().enumerate() {
            let x = i % w;
            *p = 600.0 + 80.0 * noise() + if x >= w / 2 { pedestal } else { 0.0 };
        }
        for row in 0..6 {
            for col in 0..6 {
                let (cx, cy) = (
                    60.0 + col as f64 * 95.0 + 0.3,
                    60.0 + row as f64 * 95.0 + 0.6,
                );
                let peak = 6000.0 + 2500.0 * ((row * 6 + col) % 5) as f64;
                for y in (cy as usize - 25)..(cy as usize + 25) {
                    for x in (cx as usize - 25)..(cx as usize + 25) {
                        let (dx, dy) = (x as f64 - cx, y as f64 - cy);
                        px[y * w + x] +=
                            peak * (-0.5 * ((dx / sigma_x).powi(2) + (dy / sigma_y).powi(2))).exp();
                    }
                }
            }
        }
        if hot_pixels {
            for k in 0..40 {
                let (x, y) = (37 + (k * 131) % 520, 41 + (k * 197) % 520);
                px[y * w + x] += 20000.0;
            }
        }
        let data: Vec<u16> = px.iter().map(|v| v.clamp(0.0, 65535.0) as u16).collect();
        ImageData::from_u16(w as u32, h as u32, 1, &data)
    }

    #[test]
    fn a_round_gaussian_field_measures_its_own_half_flux_radius() {
        // HFR of a Gaussian is sigma * sqrt(2 ln 2) = 1.177 sigma.
        let shape = measure_frame_shape(&field(1.6, 1.6, 0.0, false)).expect("measurable");
        assert!(
            (shape.hfr - 1.177 * 1.6).abs() < 0.25,
            "HFR {:.2} for a 1.6 px sigma star",
            shape.hfr
        );
        assert!(
            shape.eccentricity < 0.35,
            "round stars read {:.2}",
            shape.eccentricity
        );
    }

    #[test]
    fn an_elongated_field_reads_its_axis_ratio() {
        // b/a = 0.5 -> e = sqrt(1 - 0.25) = 0.866.
        let shape = measure_frame_shape(&field(3.0, 1.5, 0.0, false)).expect("measurable");
        assert!(
            (shape.eccentricity - 0.866).abs() < 0.05,
            "a 2:1 star read e = {:.2}",
            shape.eccentricity
        );
    }

    #[test]
    fn a_background_step_and_hot_pixels_do_not_move_the_answer() {
        let clean = measure_frame_shape(&field(1.6, 1.6, 0.0, false)).expect("measurable");
        let dirty = measure_frame_shape(&field(1.6, 1.6, 150.0, true)).expect("measurable");
        assert!(
            (clean.hfr - dirty.hfr).abs() < 0.15,
            "a 150 ADU step and 40 hot pixels moved HFR {:.2} -> {:.2}",
            clean.hfr,
            dirty.hfr
        );
        assert!((clean.eccentricity - dirty.eccentricity).abs() < 0.1);
    }

    #[test]
    fn too_few_stars_is_no_answer() {
        let data = vec![600u16; 200 * 200];
        assert_eq!(
            measure_frame_shape(&ImageData::from_u16(200, 200, 1, &data)),
            None
        );
    }
}
