//! Star detection: background and noise maps, a matched filter, connected
//! footprints, prominence deblending and whole-footprint measurement.
//!
//! The pipeline follows Source Extractor / SEP in outline:
//!
//! 1. A mesh of sigma-clipped medians gives a local background, so a
//!    gradient, vignetting or a galaxy's outer halo does not inflate the
//!    noise estimate or push one side of the frame over the threshold.
//! 2. The background-subtracted frame is smoothed with a Gaussian matched
//!    filter, and the threshold is applied to the smoothed frame against the
//!    noise measured *in the smoothed frame*. A single noisy pixel then cannot
//!    seed a detection, and `detection_sigma` is a false-alarm rate: at 5 the
//!    expected number of noise detections on a 16 MP frame is well under one.
//! 3. Pixels above threshold form 8-connected footprints. A footprint with
//!    more than one significant peak is split only when the secondary peak
//!    stands clear of the saddle joining it to the brighter one and lies
//!    farther away than the frame's own star size allows a single star to
//!    span. A defocused donut is one footprint with a ring of shallow maxima,
//!    so it stays one star.
//! 4. On a frame whose stars are much larger than the filter (defocus), the
//!    filter is widened to the measured star size and the frame is detected
//!    again, so faint donuts are found whole rather than as arcs.
//! 5. Each star is measured on the unsmoothed residual inside a circular
//!    aperture that covers its whole footprint, using signed values against a
//!    local annulus background, so noise averages out instead of adding a
//!    floor and a donut's half-flux radius is the donut's.
//!
//! Hot pixels (a peak pixel standing far above its four neighbors), sources
//! touching the frame edge, saturated stars, and sources much larger than the
//! frame's typical star (galaxies, nebula knots, foreground objects) are not
//! reported as stars.

use crate::stats::compute_snr;
use crate::{DetectedStar, ImageData, StarDetectionConfig};
use rayon::prelude::*;

/// Side of a background mesh cell in pixels.
const MESH_CELL: usize = 64;

/// Gaussian sigma of the matched filter for a focused frame. Close to the
/// PSF sigma of a well-sampled star (FWHM 2.5–4 px).
const BASE_KERNEL_SIGMA: f64 = 1.5;

/// Upper bound on the widened matched filter for strongly defocused frames.
const MAX_KERNEL_SIGMA: f64 = 8.0;

/// A secondary peak inside a footprint counts as its own star only when it
/// rises this many filtered-noise sigmas above the saddle joining it to a
/// brighter peak...
const DEBLEND_NSIGMA: f32 = 3.0;

/// ...and by at least this fraction of its own height.
const DEBLEND_CONTRAST: f32 = 0.15;

/// Closest two peaks may be and still be split into two stars, in pixels,
/// before the frame's star size is known.
const MIN_SEPARATION_PX: f64 = 3.0;

/// Shortest major-axis RMS length, in pixels, of a footprint treated as a
/// streak rather than split into stars.
const MIN_STREAK_LENGTH_PX: f64 = 8.0;

/// Minimum footprint area, in pixels, of a deblended secondary peak.
const MIN_CHILD_AREA: u32 = 5;

/// A pixel whose four direct neighbors average below this fraction of its own
/// height above background holds its flux in one pixel: a hot pixel or a
/// cosmic-ray hit, not a star seen through optics and atmosphere.
const HOT_PIXEL_NEIGHBOR_RATIO: f64 = 0.15;

/// Height above background, in raw-noise sigmas, from which a lone spike is
/// treated as a hot pixel by [`remove_hot_pixels`].
const HOT_PIXEL_SIGMA: f32 = 5.0;

/// See [`remove_hot_pixels`].
const HOT_PIXEL_MEDIAN_RATIO: f32 = 0.1;

/// Sources whose half-flux radius exceeds both this multiple of the frame's
/// typical star and the typical star plus [`EXTENDED_MIN_EXCESS_PX`] are
/// extended objects, not stars.
const EXTENDED_HFR_FACTOR: f64 = 2.5;
const EXTENDED_MIN_EXCESS_PX: f64 = 4.0;

/// A source this large (half-flux radius in pixels) is only a star if it is
/// a defocused one, and a defocused star is a disk or donut with a sharp
/// edge: 90% of its flux lies within about 1.2–1.4 half-flux radii. A
/// smooth blob whose 90% radius is beyond [`DIFFUSE_R90_RATIO`] half-flux
/// radii (a Gaussian is at 1.82) is something out of focus in the
/// foreground, a cloud edge or nebulosity. Focused stars this large would
/// need a FWHM above 24 px, which no imaging setup produces.
const DIFFUSE_MIN_HFR: f64 = 12.0;
const DIFFUSE_R90_RATIO: f64 = 1.7;

/// Stars needed before the frame's typical star size is trusted for the
/// extended-source cut.
const MIN_STARS_FOR_SIZE_CUT: usize = 10;

/// Detection output with the frame-level background and noise.
pub(crate) struct Detection {
    pub stars: Vec<DetectedStar>,
    pub background: f64,
    pub noise: f64,
}

/// Run the detector. Stars come back brightest (largest flux) first.
pub(crate) fn detect(image: &ImageData, config: &StarDetectionConfig) -> Detection {
    let width = image.width as usize;
    let height = image.height as usize;
    if width < 3 || height < 3 || image.data.len() < width * height * 2 {
        return Detection {
            stars: Vec::new(),
            background: 0.0,
            noise: 1.0,
        };
    }

    let raw: Vec<f32> = image.data[..width * height * 2]
        .par_chunks_exact(2)
        .map(|c| u16::from_le_bytes([c[0], c[1]]) as f32)
        .collect();

    let (back, noise) = mesh_grids(&raw, width, height, 1.0);
    let mut residual = raw;
    residual
        .par_chunks_mut(width)
        .enumerate()
        .for_each(|(y, row)| {
            let mut b = vec![0.0f32; width];
            back.sample_row(y, &mut b);
            for (v, bv) in row.iter_mut().zip(&b) {
                *v -= *bv;
            }
        });

    remove_hot_pixels(&mut residual, width, height, &noise);

    let frame = Frame {
        width,
        height,
        residual: &residual,
        back: &back,
        noise: &noise,
    };

    let first = FilteredPass::new(&frame, BASE_KERNEL_SIGMA, config);
    let typical_hfr = estimate_star_size(&frame, &first, config);

    let kernel = typical_hfr.map_or(BASE_KERNEL_SIGMA, |h| {
        (0.5 * h).clamp(BASE_KERNEL_SIGMA, MAX_KERNEL_SIGMA)
    });
    let pass = if kernel > BASE_KERNEL_SIGMA * 1.25 {
        FilteredPass::new(&frame, kernel, config)
    } else {
        first
    };
    // Two peaks closer than this are one star (a donut's ring, a lumpy core);
    // a streak longer than this is not a star.
    let min_separation =
        typical_hfr.map_or(MIN_SEPARATION_PX, |h| (2.5 * h).max(MIN_SEPARATION_PX));
    let max_star_length = typical_hfr.map_or(MIN_STREAK_LENGTH_PX, |h| {
        (4.0 * h).max(MIN_STREAK_LENGTH_PX)
    });

    let mut objects: Vec<Vec<u32>> = pass
        .components
        .par_iter()
        .flat_map_iter(|comp| {
            deblend(
                comp,
                &pass.significance,
                width,
                min_separation,
                max_star_length,
            )
        })
        .collect();
    objects.retain(|o| !o.is_empty());

    let mut labels = vec![0u32; width * height];
    for (i, obj) in objects.iter().enumerate() {
        for &p in obj {
            labels[p as usize] = i as u32 + 1;
        }
    }

    let measured: Vec<Measured> = objects
        .par_iter()
        .enumerate()
        .filter_map(|(i, obj)| {
            if obj.len() < config.min_area as usize || obj.len() > config.max_area as usize {
                return None;
            }
            measure(
                &frame,
                &labels,
                i as u32 + 1,
                obj,
                pass.kernel_sigma,
                config,
            )
        })
        .collect();

    let mut stars: Vec<DetectedStar> = measured
        .into_iter()
        .filter(|m| passes_filters(m, config))
        .map(|m| m.star)
        .collect();
    stars.sort_by(|a, b| b.flux.total_cmp(&a.flux));
    reject_extended(&mut stars);

    Detection {
        stars,
        background: back.median() as f64,
        noise: (noise.median() as f64).max(1.0),
    }
}

struct Frame<'a> {
    width: usize,
    height: usize,
    residual: &'a [f32],
    back: &'a Grid,
    noise: &'a Grid,
}

/// The frame smoothed by one matched filter, in units of its own noise, and
/// the footprints above the detection threshold.
struct FilteredPass {
    kernel_sigma: f64,
    significance: Vec<f32>,
    components: Vec<Component>,
}

struct Component {
    pixels: Vec<u32>,
}

impl FilteredPass {
    fn new(frame: &Frame, kernel_sigma: f64, config: &StarDetectionConfig) -> Self {
        let (w, h) = (frame.width, frame.height);
        let kernel = gaussian_kernel(kernel_sigma);
        let mut filtered = convolve_separable(frame.residual, w, h, &kernel);

        // The noise of the filtered frame, measured on the filtered frame, so
        // correlated and non-Gaussian noise set the threshold rather than a
        // white-noise assumption. The floor is what 1 ADU of white noise
        // becomes after filtering, which keeps noiseless synthetic frames
        // from dividing by zero.
        let floor = kernel.iter().map(|k| k * k).sum::<f32>();
        let (_, filtered_noise) = mesh_grids(&filtered, w, h, floor);
        filtered.par_chunks_mut(w).enumerate().for_each(|(y, row)| {
            let mut n = vec![0.0f32; w];
            filtered_noise.sample_row(y, &mut n);
            for (v, nv) in row.iter_mut().zip(&n) {
                *v /= nv.max(floor);
            }
        });

        let threshold = config.detection_sigma.max(0.0) as f32;
        let components = label_components(&filtered, w, h, threshold);
        Self {
            kernel_sigma,
            significance: filtered,
            components,
        }
    }
}

/// The frame's typical star half-flux radius, from the brightest whole
/// footprints of the first pass. `None` when too few stars stand out to say.
fn estimate_star_size(
    frame: &Frame,
    pass: &FilteredPass,
    config: &StarDetectionConfig,
) -> Option<f64> {
    let mut ranked: Vec<(f32, usize)> = pass
        .components
        .iter()
        .enumerate()
        .filter(|(_, c)| {
            c.pixels.len() >= config.min_area.max(MIN_CHILD_AREA) as usize
                && c.pixels.len() <= config.max_area as usize
        })
        .map(|(i, c)| {
            let peak = c
                .pixels
                .iter()
                .map(|&p| pass.significance[p as usize])
                .fold(f32::MIN, f32::max);
            (peak, i)
        })
        .collect();
    ranked.sort_by(|a, b| b.0.total_cmp(&a.0));
    ranked.truncate(100);

    let mut labels = vec![0u32; frame.width * frame.height];
    for (i, c) in pass.components.iter().enumerate() {
        for &p in &c.pixels {
            labels[p as usize] = i as u32 + 1;
        }
    }
    let mut hfrs: Vec<f64> = ranked
        .par_iter()
        .filter_map(|&(_, i)| {
            let m = measure(
                frame,
                &labels,
                i as u32 + 1,
                &pass.components[i].pixels,
                pass.kernel_sigma,
                config,
            )?;
            (!m.saturated && !m.hot && m.star.eccentricity <= 0.8 && m.star.hfr > 0.0)
                .then_some(m.star.hfr)
        })
        .collect();
    if hfrs.len() < 5 {
        return None;
    }
    hfrs.sort_by(f64::total_cmp);
    Some(hfrs[hfrs.len() / 2])
}

struct Measured {
    star: DetectedStar,
    saturated: bool,
    hot: bool,
    touches_edge: bool,
    diffuse: bool,
    area: u32,
}

fn passes_filters(m: &Measured, config: &StarDetectionConfig) -> bool {
    !m.saturated
        && !m.hot
        && !m.touches_edge
        && !m.diffuse
        && m.area >= config.min_area
        && m.star.hfr >= config.min_hfr
        && m.star.snr >= config.min_snr
        && m.star.eccentricity <= config.max_eccentricity
        && m.star.sharpness <= config.max_sharpness
}

/// Drop sources far larger than the frame's typical star: a galaxy core, a
/// nebula knot, an out-of-focus foreground object. Needs enough round stars
/// to know what typical is.
fn reject_extended(stars: &mut Vec<DetectedStar>) {
    let mut sizes: Vec<f64> = stars
        .iter()
        .filter(|s| s.eccentricity <= crate::SELECTION_MAX_ECCENTRICITY)
        .take(50)
        .map(|s| s.hfr)
        .collect();
    if sizes.len() < MIN_STARS_FOR_SIZE_CUT {
        return;
    }
    sizes.sort_by(f64::total_cmp);
    let typical = sizes[sizes.len() / 2];
    let limit = (EXTENDED_HFR_FACTOR * typical).max(typical + EXTENDED_MIN_EXCESS_PX);
    stars.retain(|s| s.hfr <= limit);
}

/// Measure one footprint on the unsmoothed residual.
fn measure(
    frame: &Frame,
    labels: &[u32],
    own: u32,
    pixels: &[u32],
    kernel_sigma: f64,
    config: &StarDetectionConfig,
) -> Option<Measured> {
    let (w, h) = (frame.width, frame.height);

    // The peak is taken from the residual, where hot pixels have already been
    // replaced, so a hot pixel inside a star's footprint neither marks it
    // saturated nor sets its sharpness.
    let mut touches_edge = false;
    let mut peak_idx = pixels[0] as usize;
    for &p in pixels {
        let p = p as usize;
        if frame.residual[p] > frame.residual[peak_idx] {
            peak_idx = p;
        }
    }
    let peak_raw =
        frame.residual[peak_idx] + frame.back.at((peak_idx % w) as f64, (peak_idx / w) as f64);
    let (mut sx, mut sy, mut sw) = (0.0f64, 0.0f64, 0.0f64);
    for &p in pixels {
        let p = p as usize;
        let (x, y) = (p % w, p / w);
        if x == 0 || y == 0 || x == w - 1 || y == h - 1 {
            touches_edge = true;
        }
        let v = frame.residual[p] as f64;
        if v > 0.0 {
            sx += v * x as f64;
            sy += v * y as f64;
            sw += v;
        }
    }
    if sw <= 0.0 {
        return None;
    }
    let (cx, cy) = (sx / sw, sy / sw);

    let extent = pixels
        .iter()
        .map(|&p| {
            let p = p as usize;
            ((p % w) as f64 - cx).hypot((p / w) as f64 - cy)
        })
        .fold(0.0f64, f64::max);
    let cap = (4 * config.hfr_radius.max(1)) as f64;
    let aperture = (extent + kernel_sigma.max(3.0)).min(cap).max(3.0);

    // Local background from an annulus outside the aperture, skipping other
    // sources, corrects what the coarse mesh leaves under a bright star or on
    // a nebula.
    let inner = aperture + 2.0;
    let outer = aperture + 6.0;
    let mut annulus = Vec::new();
    let mut ap: Vec<(f64, f64)> = Vec::new();
    let r_out = outer.ceil() as i64;
    let (icx, icy) = (cx.round() as i64, cy.round() as i64);
    for yy in (icy - r_out).max(0)..=(icy + r_out).min(h as i64 - 1) {
        for xx in (icx - r_out).max(0)..=(icx + r_out).min(w as i64 - 1) {
            let d = (xx as f64 - cx).hypot(yy as f64 - cy);
            if d > outer {
                continue;
            }
            let idx = yy as usize * w + xx as usize;
            let label = labels[idx];
            if d <= aperture {
                if label == 0 || label == own {
                    ap.push((d, frame.residual[idx] as f64));
                }
            } else if d >= inner && label == 0 {
                annulus.push(frame.residual[idx]);
            }
        }
    }
    let local = if annulus.len() >= 16 {
        let mid = annulus.len() / 2;
        *annulus.select_nth_unstable_by(mid, f32::total_cmp).1 as f64
    } else {
        0.0
    };

    let total: f64 = ap.iter().map(|&(_, v)| v - local).sum();
    if total <= 0.0 {
        return None;
    }
    ap.sort_by(|a, b| a.0.total_cmp(&b.0));
    let hfr = radius_enclosing(&ap, local, 0.5 * total);
    let r90 = radius_enclosing(&ap, local, 0.9 * total);

    // Second moments of the footprint for shape.
    let (mut mxx, mut myy, mut mxy, mut mw) = (0.0, 0.0, 0.0, 0.0);
    for &p in pixels {
        let p = p as usize;
        let v = frame.residual[p] as f64 - local;
        if v > 0.0 {
            let dx = (p % w) as f64 - cx;
            let dy = (p / w) as f64 - cy;
            mxx += v * dx * dx;
            myy += v * dy * dy;
            mxy += v * dx * dy;
            mw += v;
        }
    }
    let elongation_angle_deg = if mw > 0.0 {
        elongation_angle_deg(mxx / mw, myy / mw, mxy / mw)
    } else {
        0.0
    };
    let eccentricity = if mw > 0.0 {
        let (mxx, myy, mxy) = (mxx / mw, myy / mw, mxy / mw);
        let trace = mxx + myy;
        let disc = ((mxx - myy).powi(2) + 4.0 * mxy * mxy).sqrt();
        let l1 = (trace + disc) / 2.0;
        let l2 = (trace - disc) / 2.0;
        if l1 > 1e-10 {
            (1.0 - (l2.max(0.0) / l1)).max(0.0).sqrt()
        } else {
            0.0
        }
    } else {
        0.0
    };

    let back_here = frame.back.at(cx, cy) as f64 + local;
    let peak_above = frame.residual[peak_idx] as f64 - local;
    let hot = is_hot_pixel(frame, peak_idx, local);
    let sigma = frame.noise.at(cx, cy) as f64;
    let snr = compute_snr(
        total,
        ap.len() as f64,
        sigma.max(1.0),
        config.noise_model.as_ref(),
    );

    Some(Measured {
        star: DetectedStar {
            x: cx,
            y: cy,
            flux: total,
            hfr,
            fwhm: 2.0 * hfr,
            peak: peak_raw as f64,
            background: back_here,
            snr,
            eccentricity,
            elongation_angle_deg,
            sharpness: (peak_above / total).clamp(0.0, 1.0),
        },
        saturated: peak_raw as f64 > config.saturation_limit as f64,
        hot,
        touches_edge,
        diffuse: hfr > DIFFUSE_MIN_HFR && r90 > DIFFUSE_R90_RATIO * hfr,
        area: pixels.len() as u32,
    })
}

/// Direction of the major axis of second moments `mxx`, `myy`, `mxy`, in
/// degrees from +x toward +y, in `[0, 180)`.
pub(crate) fn elongation_angle_deg(mxx: f64, myy: f64, mxy: f64) -> f64 {
    (0.5 * (2.0 * mxy).atan2(mxx - myy))
        .to_degrees()
        .rem_euclid(180.0)
}

/// Replace single-pixel spikes with the median of their eight neighbors.
///
/// A pixel more than [`HOT_PIXEL_SIGMA`] above the background whose
/// neighbors' median sits below [`HOT_PIXEL_MEDIAN_RATIO`] of its height
/// cannot be light focused by optics through air: even a badly undersampled
/// star puts a fifth of its peak into the median neighbor. Hot pixels and
/// the pixels of a cosmic-ray track are like this, and so are clusters of
/// two or three warm pixels, which a smoothing filter would otherwise add up
/// into something star-sized.
fn remove_hot_pixels(residual: &mut [f32], w: usize, h: usize, noise: &Grid) {
    let src = residual.to_vec();
    residual
        .par_chunks_mut(w)
        .enumerate()
        .skip(1)
        .take(h.saturating_sub(2))
        .for_each(|(y, row)| {
            let mut sigma = vec![0.0f32; w];
            noise.sample_row(y, &mut sigma);
            for x in 1..w - 1 {
                let v = src[y * w + x];
                if v <= HOT_PIXEL_SIGMA * sigma[x] {
                    continue;
                }
                let mut n = [
                    src[(y - 1) * w + x - 1],
                    src[(y - 1) * w + x],
                    src[(y - 1) * w + x + 1],
                    src[y * w + x - 1],
                    src[y * w + x + 1],
                    src[(y + 1) * w + x - 1],
                    src[(y + 1) * w + x],
                    src[(y + 1) * w + x + 1],
                ];
                n.sort_by(f32::total_cmp);
                let median = 0.5 * (n[3] + n[4]);
                if median < HOT_PIXEL_MEDIAN_RATIO * v {
                    row[x] = median;
                }
            }
        });
}

fn is_hot_pixel(frame: &Frame, idx: usize, local: f64) -> bool {
    let w = frame.width;
    let (x, y) = (idx % w, idx / w);
    if x == 0 || y == 0 || x + 1 >= w || y + 1 >= frame.height {
        return false;
    }
    let peak = frame.residual[idx] as f64 - local;
    if peak <= 0.0 {
        return false;
    }
    let neighbors = [idx - 1, idx + 1, idx - w, idx + w]
        .iter()
        .map(|&i| frame.residual[i] as f64 - local)
        .sum::<f64>()
        / 4.0;
    neighbors < HOT_PIXEL_NEIGHBOR_RATIO * peak
}

/// Radius enclosing `target` flux, from `(distance, value)` pairs sorted by
/// distance.
///
/// Each pixel counts as a one-pixel-wide ring around its center distance,
/// entering the enclosed flux in proportion to the ring area inside the
/// radius. Treating pixels as points instead makes the enclosed flux a step
/// function whose steps fall at the few distances the pixel grid allows, which
/// biases a well-sampled star's HFR by several percent depending on where its
/// center falls within a pixel.
fn radius_enclosing(ap: &[(f64, f64)], local: f64, target: f64) -> f64 {
    const STEP: f64 = 0.05;
    let r_max = ap.last().map_or(0.0, |a| a.0 + 0.5);
    let mut full = 0usize;
    let mut full_sum = 0.0;
    let (mut prev_r, mut prev_cum) = (0.0, 0.0);
    let mut r = STEP;
    while r <= r_max + STEP {
        while full < ap.len() && ap[full].0 + 0.5 <= r {
            full_sum += ap[full].1 - local;
            full += 1;
        }
        let mut cum = full_sum;
        for &(d, v) in ap[full..].iter().take_while(|(d, _)| d - 0.5 < r) {
            let lo = (d - 0.5).max(0.0);
            let hi = d + 0.5;
            cum += (v - local) * ((r * r - lo * lo) / (hi * hi - lo * lo)).clamp(0.0, 1.0);
        }
        if cum >= target {
            let frac = if cum > prev_cum {
                (target - prev_cum) / (cum - prev_cum)
            } else {
                1.0
            };
            return prev_r + frac.clamp(0.0, 1.0) * (r - prev_r);
        }
        prev_r = r;
        prev_cum = cum;
        r += STEP;
    }
    prev_r
}

/// Split a footprint into stars by peak prominence. Returns one pixel list
/// per star; a footprint with one significant peak comes back whole.
///
/// A footprint that is a long thin streak (a trail or a satellite) is not
/// split: brightness ripples along a trail are not stars, and kept whole the
/// streak is rejected by the eccentricity ceiling.
fn deblend(
    comp: &Component,
    significance: &[f32],
    width: usize,
    min_sep: f64,
    max_star_length: f64,
) -> Vec<Vec<u32>> {
    let pixels = &comp.pixels;
    if pixels.len() < 2 * MIN_CHILD_AREA as usize
        || is_streak(pixels, significance, width, max_star_length)
    {
        return vec![pixels.clone()];
    }
    let (mut x0, mut y0, mut x1, mut y1) = (usize::MAX, usize::MAX, 0, 0);
    for &p in pixels {
        let (x, y) = (p as usize % width, p as usize / width);
        x0 = x0.min(x);
        y0 = y0.min(y);
        x1 = x1.max(x);
        y1 = y1.max(y);
    }
    let bw = x1 - x0 + 1;
    let bh = y1 - y0 + 1;
    let local_index = |p: u32| -> usize {
        let (x, y) = (p as usize % width, p as usize / width);
        (y - y0) * bw + (x - x0)
    };

    let mut order: Vec<u32> = pixels.clone();
    order.sort_by(|&a, &b| significance[b as usize].total_cmp(&significance[a as usize]));

    const NONE: u32 = u32::MAX;
    let mut basin_of = vec![NONE; bw * bh];
    let mut parent: Vec<u32> = Vec::new();
    let mut peak_val: Vec<f32> = Vec::new();
    let mut peak_pos: Vec<u32> = Vec::new();
    let mut area: Vec<u32> = Vec::new();
    let mut children: Vec<u32> = Vec::new();

    fn root(parent: &mut [u32], mut b: u32) -> u32 {
        while parent[b as usize] != b {
            parent[b as usize] = parent[parent[b as usize] as usize];
            b = parent[b as usize];
        }
        b
    }
    let dist = |a: u32, b: u32| -> f64 {
        let (ax, ay) = ((a as usize % width) as f64, (a as usize / width) as f64);
        let (bx, by) = ((b as usize % width) as f64, (b as usize / width) as f64);
        (ax - bx).hypot(ay - by)
    };

    for &p in &order {
        let level = significance[p as usize];
        let li = local_index(p);
        let (lx, ly) = (li % bw, li / bw);
        let mut roots: [u32; 8] = [NONE; 8];
        let mut n = 0;
        for dy in -1i64..=1 {
            for dx in -1i64..=1 {
                if dx == 0 && dy == 0 {
                    continue;
                }
                let nx = lx as i64 + dx;
                let ny = ly as i64 + dy;
                if nx < 0 || ny < 0 || nx >= bw as i64 || ny >= bh as i64 {
                    continue;
                }
                let b = basin_of[ny as usize * bw + nx as usize];
                if b == NONE {
                    continue;
                }
                let r = root(&mut parent, b);
                if !roots[..n].contains(&r) {
                    roots[n] = r;
                    n += 1;
                }
            }
        }
        if n == 0 {
            let b = parent.len() as u32;
            parent.push(b);
            peak_val.push(level);
            peak_pos.push(p);
            area.push(1);
            basin_of[li] = b;
            continue;
        }
        let dominant = *roots[..n]
            .iter()
            .max_by(|&&a, &&b| peak_val[a as usize].total_cmp(&peak_val[b as usize]))
            .expect("n > 0");
        for &r in &roots[..n] {
            if r == dominant {
                continue;
            }
            let ru = r as usize;
            let prominence = peak_val[ru] - level;
            let significant = prominence >= DEBLEND_NSIGMA
                && prominence >= DEBLEND_CONTRAST * peak_val[ru]
                && area[ru] >= MIN_CHILD_AREA
                && dist(peak_pos[ru], peak_pos[dominant as usize]) >= min_sep;
            if significant {
                children.push(peak_pos[ru]);
            }
            parent[ru] = dominant;
            area[dominant as usize] += area[ru];
        }
        area[dominant as usize] += 1;
        basin_of[li] = dominant;
    }

    if children.is_empty() {
        return vec![pixels.clone()];
    }
    // The brightest peak of the footprint is always a star.
    let top = order[0];
    children.push(top);
    // A secondary peak recorded against one neighbor may sit too close to a
    // peak recorded later; keep the brighter of any pair closer than min_sep.
    children.sort_by(|&a, &b| significance[b as usize].total_cmp(&significance[a as usize]));
    let mut kept: Vec<u32> = Vec::new();
    for c in children {
        if kept.iter().all(|&k| dist(k, c) >= min_sep) {
            kept.push(c);
        }
    }
    if kept.len() == 1 {
        return vec![pixels.clone()];
    }

    // Each pixel goes to its nearest peak. Peaks are bucketed on a coarse grid
    // so a nebula footprint carrying hundreds of stars stays linear in its
    // pixel count.
    let cell = min_sep.max(8.0);
    let gx = (bw as f64 / cell).ceil() as usize + 1;
    let gy = (bh as f64 / cell).ceil() as usize + 1;
    let cell_of = |p: u32| -> (usize, usize) {
        let (x, y) = (p as usize % width - x0, p as usize / width - y0);
        ((x as f64 / cell) as usize, (y as f64 / cell) as usize)
    };
    let mut buckets: Vec<Vec<usize>> = vec![Vec::new(); gx * gy];
    for (i, &k) in kept.iter().enumerate() {
        let (cx, cy) = cell_of(k);
        buckets[cy * gx + cx].push(i);
    }
    let mut out = vec![Vec::new(); kept.len()];
    for &p in pixels {
        let (cx, cy) = cell_of(p);
        let mut best = (f64::INFINITY, 0usize);
        for ring in 0..gx.max(gy) {
            // Every peak in ring `ring` is at least (ring - 1) cells away.
            if ring > 0 && ((ring - 1) as f64) * cell > best.0 {
                break;
            }
            let (ya, yb) = (cy.saturating_sub(ring), (cy + ring).min(gy - 1));
            let (xa, xb) = (cx.saturating_sub(ring), (cx + ring).min(gx - 1));
            for by in ya..=yb {
                for bx in xa..=xb {
                    if by.abs_diff(cy).max(bx.abs_diff(cx)) != ring {
                        continue;
                    }
                    for &i in &buckets[by * gx + bx] {
                        let d = dist(kept[i], p);
                        if d < best.0 {
                            best = (d, i);
                        }
                    }
                }
            }
        }
        out[best.1].push(p);
    }
    out
}

/// Axis ratio beyond 4:1 (eccentricity 0.97) with a major-axis RMS length
/// longer than any single star on this frame.
fn is_streak(pixels: &[u32], significance: &[f32], width: usize, max_star_length: f64) -> bool {
    let (mut sx, mut sy, mut sw) = (0.0f64, 0.0f64, 0.0f64);
    for &p in pixels {
        let v = significance[p as usize] as f64;
        sx += v * (p as usize % width) as f64;
        sy += v * (p as usize / width) as f64;
        sw += v;
    }
    if sw <= 0.0 {
        return false;
    }
    let (cx, cy) = (sx / sw, sy / sw);
    let (mut mxx, mut myy, mut mxy) = (0.0, 0.0, 0.0);
    for &p in pixels {
        let v = significance[p as usize] as f64;
        let dx = (p as usize % width) as f64 - cx;
        let dy = (p as usize / width) as f64 - cy;
        mxx += v * dx * dx;
        myy += v * dy * dy;
        mxy += v * dx * dy;
    }
    let (mxx, myy, mxy) = (mxx / sw, myy / sw, mxy / sw);
    let disc = ((mxx - myy).powi(2) + 4.0 * mxy * mxy).sqrt();
    let l1 = (mxx + myy + disc) / 2.0;
    let l2 = ((mxx + myy - disc) / 2.0).max(0.0);
    l1 > 0.0 && l2 / l1 < 1.0 - 0.97 * 0.97 && l1.sqrt() > max_star_length
}

/// 8-connected footprints of pixels above `threshold`.
fn label_components(sig: &[f32], w: usize, h: usize, threshold: f32) -> Vec<Component> {
    let mut seen = vec![false; w * h];
    let mut out = Vec::new();
    let mut stack = Vec::new();
    for start in 0..w * h {
        if seen[start] || sig[start] <= threshold {
            continue;
        }
        seen[start] = true;
        stack.push(start as u32);
        let mut pixels = Vec::new();
        while let Some(p) = stack.pop() {
            pixels.push(p);
            let (x, y) = (p as usize % w, p as usize / w);
            for ny in y.saturating_sub(1)..=(y + 1).min(h - 1) {
                for nx in x.saturating_sub(1)..=(x + 1).min(w - 1) {
                    let n = ny * w + nx;
                    if !seen[n] && sig[n] > threshold {
                        seen[n] = true;
                        stack.push(n as u32);
                    }
                }
            }
        }
        out.push(Component { pixels });
    }
    out
}

fn gaussian_kernel(sigma: f64) -> Vec<f32> {
    let radius = (3.0 * sigma).ceil() as i64;
    let mut k: Vec<f64> = (-radius..=radius)
        .map(|i| (-(i * i) as f64 / (2.0 * sigma * sigma)).exp())
        .collect();
    let sum: f64 = k.iter().sum();
    k.iter_mut().for_each(|v| *v /= sum);
    k.into_iter().map(|v| v as f32).collect()
}

/// Separable convolution with edge replication.
fn convolve_separable(src: &[f32], w: usize, h: usize, kernel: &[f32]) -> Vec<f32> {
    let r = kernel.len() / 2;
    let mut tmp = vec![0.0f32; w * h];
    tmp.par_chunks_mut(w).enumerate().for_each(|(y, out)| {
        let row = &src[y * w..(y + 1) * w];
        for (x, o) in out.iter_mut().enumerate() {
            let mut acc = 0.0f32;
            for (k, kv) in kernel.iter().enumerate() {
                let xx = (x + k).saturating_sub(r).min(w - 1);
                acc += kv * row[xx];
            }
            *o = acc;
        }
    });
    let mut out = vec![0.0f32; w * h];
    out.par_chunks_mut(w).enumerate().for_each(|(y, o)| {
        for (k, kv) in kernel.iter().enumerate() {
            let yy = (y + k).saturating_sub(r).min(h - 1);
            let row = &tmp[yy * w..(yy + 1) * w];
            for (ov, rv) in o.iter_mut().zip(row) {
                *ov += kv * rv;
            }
        }
    });
    out
}

/// A coarse grid of per-cell values, bilinearly interpolated between cell
/// centers.
struct Grid {
    nx: usize,
    cx: Vec<f64>,
    cy: Vec<f64>,
    v: Vec<f32>,
}

impl Grid {
    fn median(&self) -> f32 {
        let mut v = self.v.clone();
        let mid = v.len() / 2;
        *v.select_nth_unstable_by(mid, f32::total_cmp).1
    }

    fn bracket(c: &[f64], t: f64) -> (usize, usize, f64) {
        if t <= c[0] {
            return (0, 0, 0.0);
        }
        let last = c.len() - 1;
        if t >= c[last] {
            return (last, last, 0.0);
        }
        let i = c.partition_point(|&v| v <= t) - 1;
        (i, i + 1, (t - c[i]) / (c[i + 1] - c[i]))
    }

    fn at(&self, x: f64, y: f64) -> f32 {
        let (i0, i1, fx) = Self::bracket(&self.cx, x);
        let (j0, j1, fy) = Self::bracket(&self.cy, y);
        let g = |i: usize, j: usize| self.v[j * self.nx + i] as f64;
        let top = g(i0, j0) * (1.0 - fx) + g(i1, j0) * fx;
        let bot = g(i0, j1) * (1.0 - fx) + g(i1, j1) * fx;
        (top * (1.0 - fy) + bot * fy) as f32
    }

    fn sample_row(&self, y: usize, out: &mut [f32]) {
        let (j0, j1, fy) = Self::bracket(&self.cy, y as f64);
        let col: Vec<f64> = (0..self.nx)
            .map(|i| {
                self.v[j0 * self.nx + i] as f64 * (1.0 - fy) + self.v[j1 * self.nx + i] as f64 * fy
            })
            .collect();
        for (x, o) in out.iter_mut().enumerate() {
            let (i0, i1, fx) = Self::bracket(&self.cx, x as f64);
            *o = (col[i0] * (1.0 - fx) + col[i1] * fx) as f32;
        }
    }
}

/// Per-cell sigma-clipped level and noise, with cells dominated by sources
/// filled from their neighbors and both grids 3×3 median filtered.
fn mesh_grids(data: &[f32], w: usize, h: usize, noise_floor: f32) -> (Grid, Grid) {
    let cell = MESH_CELL.min(w).min(h).max(1);
    let nx = w.div_ceil(cell);
    let ny = h.div_ceil(cell);
    let stats: Vec<Option<(f32, f32)>> = (0..nx * ny)
        .into_par_iter()
        .map(|c| {
            let (i, j) = (c % nx, c / nx);
            let (xa, xb) = (i * cell, ((i + 1) * cell).min(w));
            let (ya, yb) = (j * cell, ((j + 1) * cell).min(h));
            // Every third pixel of each row, the start shifted by one per row,
            // samples a third of the cell (still over a thousand values) and
            // reaches every row and column parity, so sensor patterns with a
            // period of two pixels do not bias the estimate.
            let step = if cell >= 32 { 3 } else { 1 };
            let mut v = Vec::with_capacity((xb - xa) * (yb - ya) / step + yb - ya);
            for y in ya..yb {
                let start = (xa + y % step).min(xb);
                v.extend(data[y * w + start..y * w + xb].iter().step_by(step));
            }
            clipped_stats(v)
        })
        .collect();

    let fill = |pick: fn(&(f32, f32)) -> f32| -> Vec<f32> {
        let valid: Vec<f32> = stats.iter().flatten().map(pick).collect();
        let global = if valid.is_empty() {
            0.0
        } else {
            let mut v = valid.clone();
            let mid = v.len() / 2;
            *v.select_nth_unstable_by(mid, f32::total_cmp).1
        };
        let raw: Vec<Option<f32>> = stats.iter().map(|s| s.as_ref().map(pick)).collect();
        let mut grid = vec![0.0f32; nx * ny];
        for j in 0..ny {
            for i in 0..nx {
                grid[j * nx + i] = raw[j * nx + i].unwrap_or_else(|| {
                    // Nearest valid cells by ring, else the frame median.
                    for ring in 1..nx.max(ny) {
                        let mut near = Vec::new();
                        for jj in j.saturating_sub(ring)..=(j + ring).min(ny - 1) {
                            for ii in i.saturating_sub(ring)..=(i + ring).min(nx - 1) {
                                if let Some(v) = raw[jj * nx + ii] {
                                    near.push(v);
                                }
                            }
                        }
                        if !near.is_empty() {
                            let mid = near.len() / 2;
                            return *near.select_nth_unstable_by(mid, f32::total_cmp).1;
                        }
                    }
                    global
                });
            }
        }
        median3x3(&grid, nx, ny)
    };

    let centers = |n: usize, len: usize| -> Vec<f64> {
        (0..n)
            .map(|i| {
                let a = i * cell;
                let b = ((i + 1) * cell).min(len);
                (a + b) as f64 / 2.0 - 0.5
            })
            .collect()
    };
    let level = Grid {
        nx,
        cx: centers(nx, w),
        cy: centers(ny, h),
        v: fill(|s| s.0),
    };
    let mut noise = Grid {
        nx,
        cx: level.cx.clone(),
        cy: level.cy.clone(),
        v: fill(|s| s.1),
    };
    noise.v.iter_mut().for_each(|v| *v = v.max(noise_floor));
    (level, noise)
}

fn median3x3(grid: &[f32], nx: usize, ny: usize) -> Vec<f32> {
    let mut out = grid.to_vec();
    for j in 0..ny {
        for i in 0..nx {
            let mut v = Vec::with_capacity(9);
            for jj in j.saturating_sub(1)..=(j + 1).min(ny - 1) {
                for ii in i.saturating_sub(1)..=(i + 1).min(nx - 1) {
                    v.push(grid[jj * nx + ii]);
                }
            }
            let mid = v.len() / 2;
            out[j * nx + i] = *v.select_nth_unstable_by(mid, f32::total_cmp).1;
        }
    }
    out
}

/// Sigma-clipped median and standard deviation of one cell. `None` when
/// sources cover so much of the cell that what survives clipping is not sky.
fn clipped_stats(mut v: Vec<f32>) -> Option<(f32, f32)> {
    let n0 = v.len();
    if n0 == 0 {
        return None;
    }
    let mut sigma = 0.0f32;
    for _ in 0..5 {
        let mid = v.len() / 2;
        let median = *v.select_nth_unstable_by(mid, f32::total_cmp).1;
        let mut dev: Vec<f32> = v.iter().map(|x| (x - median).abs()).collect();
        let mad = *dev.select_nth_unstable_by(mid, f32::total_cmp).1;
        sigma = 1.4826 * mad;
        if sigma <= 0.0 {
            sigma = std_dev(&v, median);
        }
        if sigma <= 0.0 {
            break;
        }
        let (lo, hi) = (median - 3.0 * sigma, median + 3.0 * sigma);
        let before = v.len();
        v.retain(|&x| x >= lo && x <= hi);
        if v.len() < (n0 / 3).max(4) {
            return None;
        }
        if v.len() == before {
            break;
        }
    }
    let mid = v.len() / 2;
    let median = *v.select_nth_unstable_by(mid, f32::total_cmp).1;
    // Standard deviation of the clipped sample, corrected for the ±3σ
    // truncation of a normal distribution.
    let sd = std_dev(&v, median) / 0.9866;
    Some((median, if sd > 0.0 { sd } else { sigma }))
}

fn std_dev(v: &[f32], center: f32) -> f32 {
    if v.is_empty() {
        return 0.0;
    }
    let ss: f64 = v.iter().map(|&x| ((x - center) as f64).powi(2)).sum();
    (ss / v.len() as f64).sqrt() as f32
}
