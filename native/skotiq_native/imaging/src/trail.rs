//! Star trailing measured from the image itself, without detecting stars.
//!
//! A trailed frame defeats star-based shape measurement: the star detector
//! drops sources longer than about 3:1 as satellite streaks, so what is left
//! to measure are compact fragments and faint field stars, and the frame reads
//! round. The autocorrelation of the frame's bright pixels does not depend on
//! any star being accepted: every star contributes its own shape, trailed or
//! not, and since all stars are trailed the same way, the central peak of the
//! autocorrelation takes the trail's length and direction.
//!
//! # Method
//!
//! On the central crop (at most [`CROP`] px square): subtract a local
//! background (median of [`BLOCK`] px blocks), keep pixels above
//! [`THRESHOLD_SIGMA`] robust sigmas that touch at least [`MIN_NEIGHBORS`]
//! other kept pixels, clip them at [`CLIP_SIGMA`] so a few saturated stars do
//! not dominate, then form the autocorrelation over lags
//! up to [`MAX_LAG`] px. The central peak, above a quarter of its height and
//! connected to the zero lag, gives second moments; their eigenvalues give the
//! peak's length and width.
//!
//! On the owner's NGC 891 subs (0.79"/px) the length is 2.4-6.2 px with a
//! length-to-width ratio under 2 on every untrailed frame, and 20-25 px with a
//! ratio of 4.4-12 on the five frames trailed by a stalled mount.

use crate::ImageData;
use rayon::prelude::*;

/// Largest central crop analyzed, pixels per side.
const CROP: usize = 2048;
/// Background block size, pixels.
const BLOCK: usize = 64;
/// Pixels below this many robust sigmas above the background are dropped.
const THRESHOLD_SIGMA: f64 = 3.0;
/// Pixels are clipped at this many robust sigmas.
const CLIP_SIGMA: f64 = 30.0;
/// Largest lag of the autocorrelation, pixels.
const MAX_LAG: i32 = 40;
/// The central peak is the region above this fraction of its height.
const PEAK_FRACTION: f64 = 0.25;
/// A kept pixel needs this many kept neighbors (of 8) to count as part of a
/// star or trail.
const MIN_NEIGHBORS: usize = 3;
/// Fewer kept pixels than this and there is nothing to measure.
const MIN_PIXELS: usize = 200;

/// A frame's trailing, from the central peak of its autocorrelation.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FrameTrail {
    /// RMS extent of the peak along its long axis, pixels.
    pub length_px: f64,
    /// RMS extent across it, pixels.
    pub width_px: f64,
    /// Direction of the long axis, degrees from the image +x axis toward +y,
    /// in `[0, 180)`.
    pub angle_deg: f64,
}

impl FrameTrail {
    /// Length over width; 1 for round stars.
    pub fn axis_ratio(&self) -> f64 {
        if self.width_px <= 0.0 {
            f64::INFINITY
        } else {
            self.length_px / self.width_px
        }
    }

    /// Whether the stars are trailed: longer than [`TRAIL_MIN_AXIS_RATIO`]
    /// times their width.
    pub fn is_trailed(&self) -> bool {
        self.axis_ratio() >= TRAIL_MIN_AXIS_RATIO
    }
}

/// Length-to-width ratio at and above which a frame counts as trailed. A
/// round-star frame stays under 2 even with poor guiding (an eccentricity of
/// 0.8 is a 1.7:1 star); every frame trailed by a stalled mount on the owner's
/// rig measured above 4.
pub const TRAIL_MIN_AXIS_RATIO: f64 = 3.0;

/// Measure trailing on a mono 16-bit frame. `None` when the frame is not mono
/// 16-bit or has too few bright pixels to measure.
pub fn measure_frame_trail(image: &ImageData) -> Option<FrameTrail> {
    let width = image.width as usize;
    let height = image.height as usize;
    if image.channels != 1 || width == 0 || height == 0 || image.data.len() < width * height * 2 {
        return None;
    }
    let cw = width.min(CROP);
    let ch = height.min(CROP);
    let x0 = (width - cw) / 2;
    let y0 = (height - ch) / 2;
    let mut crop = vec![0.0f64; cw * ch];
    for y in 0..ch {
        let row = (y0 + y) * width + x0;
        for x in 0..cw {
            let i = (row + x) * 2;
            crop[y * cw + x] = f64::from(u16::from_le_bytes([image.data[i], image.data[i + 1]]));
        }
    }
    let signal = thresholded_signal(&crop, cw, ch)?;
    let acf = autocorrelation(&signal, cw, ch);
    peak_shape(&acf)
}

/// Background-subtracted, thresholded and clipped pixels of the crop.
fn thresholded_signal(crop: &[f64], w: usize, h: usize) -> Option<Vec<f64>> {
    let bx = w.div_ceil(BLOCK);
    let by = h.div_ceil(BLOCK);
    let mut medians = vec![0.0; bx * by];
    let mut sigmas = Vec::with_capacity(bx * by);
    let mut block = Vec::with_capacity(BLOCK * BLOCK);
    for j in 0..by {
        for i in 0..bx {
            block.clear();
            for y in j * BLOCK..((j + 1) * BLOCK).min(h) {
                block.extend_from_slice(&crop[y * w + i * BLOCK..y * w + ((i + 1) * BLOCK).min(w)]);
            }
            let median = crate::robust_stats::median_in_place(&mut block);
            let mut deviations: Vec<f64> = block.iter().map(|v| (v - median).abs()).collect();
            let mad = crate::robust_stats::median_in_place(&mut deviations);
            medians[j * bx + i] = median;
            sigmas.push(1.4826 * mad);
        }
    }
    let sigma = crate::robust_stats::median_in_place(&mut sigmas);
    if sigma <= 0.0 {
        return None;
    }
    let mut kept = 0usize;
    let signal: Vec<f64> = crop
        .iter()
        .enumerate()
        .map(|(k, v)| {
            let (x, y) = (k % w, k / w);
            let s = v - medians[(y / BLOCK) * bx + x / BLOCK];
            if s < THRESHOLD_SIGMA * sigma {
                0.0
            } else {
                kept += 1;
                s.min(CLIP_SIGMA * sigma)
            }
        })
        .collect();
    // A star or a trail covers many touching pixels; noise peaks, hot pixels
    // and cosmic-ray hits are one or two. Left in, they make a tight peak at
    // the smallest lags that outweighs faint trails on a sparse field.
    let neighbors = |k: usize| {
        let (x, y) = ((k % w) as i64, (k / w) as i64);
        let mut n = 0;
        for dy in -1i64..=1 {
            for dx in -1i64..=1 {
                let (xx, yy) = (x + dx, y + dy);
                if (dx, dy) != (0, 0)
                    && xx >= 0
                    && yy >= 0
                    && (xx as usize) < w
                    && (yy as usize) < h
                    && signal[yy as usize * w + xx as usize] > 0.0
                {
                    n += 1;
                }
            }
        }
        n
    };
    let mut cleaned = signal.clone();
    for (k, v) in cleaned.iter_mut().enumerate() {
        if *v > 0.0 && neighbors(k) < MIN_NEIGHBORS {
            *v = 0.0;
            kept -= 1;
        }
    }
    (kept >= MIN_PIXELS).then_some(cleaned)
}

/// Autocorrelation over lags `-MAX_LAG..=MAX_LAG`, row-major
/// `(2 MAX_LAG + 1)^2`, with the uncorrelated baseline subtracted.
fn autocorrelation(signal: &[f64], w: usize, h: usize) -> Vec<f64> {
    let side = (2 * MAX_LAG + 1) as usize;
    let nonzero: Vec<(usize, usize, f64)> = signal
        .iter()
        .enumerate()
        .filter(|(_, v)| **v > 0.0)
        .map(|(k, v)| (k % w, k / w, *v))
        .collect();
    // Half-plane of lags (dy > 0, or dy == 0 and dx >= 0); the rest follows
    // from A(-d) = A(d).
    let lags: Vec<(i32, i32)> = (0..=MAX_LAG)
        .flat_map(|dy| (-MAX_LAG..=MAX_LAG).map(move |dx| (dx, dy)))
        .filter(|&(dx, dy)| dy > 0 || dx >= 0)
        .collect();
    let values: Vec<f64> = lags
        .par_iter()
        .map(|&(dx, dy)| {
            let mut sum = 0.0;
            for &(x, y, v) in &nonzero {
                let (xx, yy) = (x as i32 + dx, y as i32 + dy);
                if xx >= 0 && yy >= 0 && (xx as usize) < w && (yy as usize) < h {
                    sum += v * signal[yy as usize * w + xx as usize];
                }
            }
            sum
        })
        .collect();
    let total: f64 = nonzero.iter().map(|p| p.2).sum();
    let baseline = total * total / (w * h) as f64;
    let mut acf = vec![0.0; side * side];
    let at = |dx: i32, dy: i32| ((dy + MAX_LAG) as usize) * side + (dx + MAX_LAG) as usize;
    for (&(dx, dy), &v) in lags.iter().zip(&values) {
        acf[at(dx, dy)] = v - baseline;
        acf[at(-dx, -dy)] = v - baseline;
    }
    // The zero lag carries every pixel's noise squared; replace it with its
    // neighbors' mean so the peak is the stars' shape, not a noise spike.
    acf[at(0, 0)] = (acf[at(1, 0)] + acf[at(-1, 0)] + acf[at(0, 1)] + acf[at(0, -1)]) / 4.0;
    acf
}

/// Length, width and direction of the autocorrelation's central peak.
fn peak_shape(acf: &[f64]) -> Option<FrameTrail> {
    let side = (2 * MAX_LAG + 1) as usize;
    let center = MAX_LAG as usize;
    let peak = acf[center * side + center];
    if peak <= 0.0 {
        return None;
    }
    let level = PEAK_FRACTION * acf.iter().copied().fold(f64::MIN, f64::max);
    let mut inside = vec![false; side * side];
    let mut stack = vec![(center, center)];
    inside[center * side + center] = true;
    while let Some((x, y)) = stack.pop() {
        for (dx, dy) in [(-1i32, 0i32), (1, 0), (0, -1), (0, 1)] {
            let (nx, ny) = (x as i32 + dx, y as i32 + dy);
            if nx < 0 || ny < 0 || nx as usize >= side || ny as usize >= side {
                continue;
            }
            let k = ny as usize * side + nx as usize;
            if !inside[k] && acf[k] > level {
                inside[k] = true;
                stack.push((nx as usize, ny as usize));
            }
        }
    }
    let (mut w, mut mxx, mut myy, mut mxy) = (0.0, 0.0, 0.0, 0.0);
    for y in 0..side {
        for x in 0..side {
            let k = y * side + x;
            if !inside[k] {
                continue;
            }
            let (dx, dy) = (x as f64 - center as f64, y as f64 - center as f64);
            let a = acf[k];
            w += a;
            mxx += a * dx * dx;
            myy += a * dy * dy;
            mxy += a * dx * dy;
        }
    }
    if w <= 0.0 {
        return None;
    }
    let (mxx, myy, mxy) = (mxx / w, myy / w, mxy / w);
    let half_diff = ((mxx - myy) / 2.0).hypot(mxy);
    let l1 = (mxx + myy) / 2.0 + half_diff;
    let l2 = ((mxx + myy) / 2.0 - half_diff).max(0.0);
    Some(FrameTrail {
        length_px: l1.sqrt(),
        width_px: l2.sqrt(),
        angle_deg: (0.5 * (2.0 * mxy).atan2(mxx - myy))
            .to_degrees()
            .rem_euclid(180.0),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A sky of 1000 ADU with deterministic noise of about 20 ADU and a grid of
    /// stars, each smeared along `angle_deg` by `trail_px` (0 for round).
    fn field(trail_px: f64, angle_deg: f64) -> ImageData {
        let (w, h) = (600usize, 600usize);
        let mut state = 0x2545_F491_4F6C_DD1Du64;
        let mut uniform = || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            ((state >> 11) as f64 + 0.5) / (1u64 << 53) as f64
        };
        let mut px: Vec<f64> = (0..w * h)
            .map(|_| 1000.0 + 20.0 * (uniform() + uniform() + uniform() - 1.5) * 2.0)
            .collect();
        let (c, s) = (angle_deg.to_radians().cos(), angle_deg.to_radians().sin());
        let steps = (trail_px.ceil() as usize).max(1);
        for gy in 0..12 {
            for gx in 0..12 {
                let (cx, cy) = (25.0 + gx as f64 * 47.0, 25.0 + gy as f64 * 47.0);
                let peak = 3000.0 * (0.3 + uniform());
                for step in 0..steps {
                    let t = if steps == 1 {
                        0.0
                    } else {
                        step as f64 / (steps - 1) as f64 - 0.5
                    };
                    let (sx, sy) = (cx + t * trail_px * c, cy + t * trail_px * s);
                    for dy in -6i32..=6 {
                        for dx in -6i32..=6 {
                            let (x, y) = (sx as i32 + dx, sy as i32 + dy);
                            if x < 0 || y < 0 || x >= w as i32 || y >= h as i32 {
                                continue;
                            }
                            let d2 = (x as f64 - sx).powi(2) + (y as f64 - sy).powi(2);
                            px[y as usize * w + x as usize] +=
                                peak / steps as f64 * (-d2 / (2.0 * 1.5 * 1.5)).exp();
                        }
                    }
                }
            }
        }
        let data: Vec<u16> = px.iter().map(|v| v.clamp(0.0, 65535.0) as u16).collect();
        ImageData::from_u16(w as u32, h as u32, 1, &data)
    }

    #[test]
    fn round_stars_are_not_trailed() {
        let trail = measure_frame_trail(&field(0.0, 0.0)).unwrap();
        assert!(!trail.is_trailed(), "{trail:?}");
        assert!(trail.axis_ratio() < 1.5, "{trail:?}");
    }

    #[test]
    fn a_twenty_pixel_trail_is_measured_with_its_direction() {
        let trail = measure_frame_trail(&field(20.0, 30.0)).unwrap();
        assert!(trail.is_trailed(), "{trail:?}");
        assert!((trail.angle_deg - 30.0).abs() < 5.0, "{trail:?}");
    }

    #[test]
    fn mild_elongation_is_not_called_a_trail() {
        // A 4 px smear on 3.5 px FWHM stars is about 0.8 eccentricity: the
        // eccentricity grade's job, not a trail.
        let trail = measure_frame_trail(&field(4.0, 120.0)).unwrap();
        assert!(!trail.is_trailed(), "{trail:?}");
    }
}
