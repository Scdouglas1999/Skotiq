//! Percentile/MAD statistics and the tiled quality-map computation used by the
//! FITS linear-read and quality-map API entry points.

use super::*;

pub(crate) fn percentile_sorted(sorted_values: &[f64], p: f64) -> f64 {
    if sorted_values.is_empty() {
        return 0.0;
    }
    let q = p.clamp(0.0, 1.0);
    let pos = ((sorted_values.len() - 1) as f64) * q;
    let lo = pos.floor() as usize;
    let hi = pos.ceil() as usize;
    if lo == hi {
        return sorted_values[lo];
    }
    let t = pos - lo as f64;
    sorted_values[lo] * (1.0 - t) + sorted_values[hi] * t
}

pub(crate) fn percentile(values: &[f64], p: f64) -> f64 {
    let mut sorted = values
        .iter()
        .copied()
        .filter(|value| value.is_finite())
        .collect::<Vec<_>>();
    if sorted.is_empty() {
        return 0.0;
    }
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    percentile_sorted(&sorted, p)
}

pub(crate) fn median(values: &[f64]) -> f64 {
    percentile(values, 0.5)
}

pub(crate) fn mad(values: &[f64], median_value: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let deviations = values
        .iter()
        .copied()
        .filter(|value| value.is_finite())
        .map(|value| (value - median_value).abs())
        .collect::<Vec<_>>();
    median(&deviations)
}

/// Robust scatter of one tile's pixels: the median and `1.4826 * MAD` of the
/// pixels left after iterative 3-sigma clipping about the median. Stars, a
/// galaxy and hot pixels sit in the upper tail and are clipped, so the value is
/// the sky noise and does not depend on how many sources the tile holds.
/// `sorted` must be ascending and finite.
fn clipped_median_sigma(sorted: &[f64]) -> (f64, f64) {
    const CLIP_SIGMA: f64 = 3.0;
    const MAX_ITERATIONS: usize = 5;
    if sorted.is_empty() {
        return (0.0, 0.0);
    }
    let (mut lo, mut hi) = (0usize, sorted.len());
    let mut deviations = Vec::with_capacity(sorted.len());
    let mut center = percentile_sorted(sorted, 0.5);
    let mut sigma = 0.0;
    for _ in 0..MAX_ITERATIONS {
        let kept = &sorted[lo..hi];
        center = percentile_sorted(kept, 0.5);
        deviations.clear();
        deviations.extend(kept.iter().map(|v| (v - center).abs()));
        let mid = deviations.len() / 2;
        deviations.select_nth_unstable_by(mid, |a, b| a.total_cmp(b));
        sigma = 1.4826 * deviations[mid];
        if sigma <= 0.0 {
            // Quantized flat data: fall back to the plain scatter of the
            // kept pixels.
            let n = kept.len() as f64;
            let mean = kept.iter().sum::<f64>() / n;
            sigma = (kept.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / n).sqrt();
            break;
        }
        let new_lo = sorted.partition_point(|v| *v < center - CLIP_SIGMA * sigma);
        let new_hi = sorted.partition_point(|v| *v <= center + CLIP_SIGMA * sigma);
        if (new_lo, new_hi) == (lo, hi) || new_hi <= new_lo {
            break;
        }
        (lo, hi) = (new_lo, new_hi);
    }
    (center, sigma)
}

/// Least-squares plane `z = a + bx*u + by*v` through tile backgrounds, where
/// `u`, `v` are the tile centers as fractions of the frame (-0.5 to 0.5).
/// `bx` and `by` are then the change in ADU across the full frame width and
/// height. One pass rejects tiles more than 3 robust sigmas off the first
/// fit, so a galaxy or a bright star does not tilt the plane.
fn background_plane(points: &[(f64, f64, f64)]) -> Option<(f64, f64, f64)> {
    fn solve(points: &[(f64, f64, f64)]) -> Option<(f64, f64, f64)> {
        if points.len() < 3 {
            return None;
        }
        let n = points.len() as f64;
        let (mut su, mut sv, mut sz) = (0.0, 0.0, 0.0);
        for &(u, v, z) in points {
            su += u;
            sv += v;
            sz += z;
        }
        let (mu, mv, mz) = (su / n, sv / n, sz / n);
        let (mut suu, mut svv, mut suv, mut suz, mut svz) = (0.0, 0.0, 0.0, 0.0, 0.0);
        for &(u, v, z) in points {
            let (du, dv, dz) = (u - mu, v - mv, z - mz);
            suu += du * du;
            svv += dv * dv;
            suv += du * dv;
            suz += du * dz;
            svz += dv * dz;
        }
        let det = suu * svv - suv * suv;
        if det.abs() < 1e-12 {
            return None;
        }
        let bx = (suz * svv - svz * suv) / det;
        let by = (svz * suu - suz * suv) / det;
        Some((mz - bx * mu - by * mv, bx, by))
    }

    let (a, bx, by) = solve(points)?;
    let residuals: Vec<f64> = points
        .iter()
        .map(|&(u, v, z)| z - (a + bx * u + by * v))
        .collect();
    let center = median(&residuals);
    let sigma = 1.4826 * mad(&residuals, center);
    if sigma <= 0.0 {
        return Some((a, bx, by));
    }
    let kept: Vec<(f64, f64, f64)> = points
        .iter()
        .zip(&residuals)
        .filter(|(_, r)| (**r - center).abs() <= 3.0 * sigma)
        .map(|(p, _)| *p)
        .collect();
    solve(&kept).or(Some((a, bx, by)))
}

/// Side of the square blocks the noise is measured in, pixels. Small enough
/// that a sky gradient or vignetting adds nothing measurable inside a block,
/// large enough for a stable MAD.
const NOISE_BLOCK: usize = 64;

/// Clipped robust scatter of each `NOISE_BLOCK` square, with the block's
/// center. Measuring noise in fixed small blocks instead of in the display
/// tiles keeps it independent of the grid and of gradients across a tile.
fn block_noise(width: usize, height: usize, data: &[f64]) -> Vec<(f64, f64, f64)> {
    let mut out = Vec::new();
    let mut samples = Vec::with_capacity(NOISE_BLOCK * NOISE_BLOCK);
    let mut y0 = 0;
    while y0 < height {
        let y1 = (y0 + NOISE_BLOCK).min(height);
        let mut x0 = 0;
        while x0 < width {
            let x1 = (x0 + NOISE_BLOCK).min(width);
            samples.clear();
            for y in y0..y1 {
                samples.extend(
                    data[y * width + x0..y * width + x1]
                        .iter()
                        .copied()
                        .filter(|v| v.is_finite()),
                );
            }
            // Edge slivers are too small for a stable estimate.
            if samples.len() >= NOISE_BLOCK * NOISE_BLOCK / 4 {
                samples.sort_by(|a, b| a.total_cmp(b));
                let (_, sigma) = clipped_median_sigma(&samples);
                out.push(((x0 + x1) as f64 / 2.0, (y0 + y1) as f64 / 2.0, sigma));
            }
            x0 = x1;
        }
        y0 = y1;
    }
    out
}

struct TileStats {
    row: u32,
    col: u32,
    count: usize,
    p05: f64,
    p50: f64,
    p95: f64,
    noise: f64,
    low_clip: usize,
    high_clip: usize,
}

/// Tile and frame quality metrics of a linear frame.
///
/// * `background` is the median of the tile medians, and each tile's
///   `background` layer value its own median.
/// * `noise` is the median of the clipped robust scatter (see
///   [`clipped_median_sigma`]) of small fixed blocks (see [`block_noise`]), so
///   it measures sky noise rather than stars, the galaxy or the gradient, and
///   does not change with the grid size. A tile's noise is the median over
///   the blocks centered in it.
/// * `gradient_x` / `gradient_y` are the plane fitted through the tile
///   backgrounds, as a fraction of the frame background across the full frame
///   width / height: `0.10` means the sky is 10% brighter on the +x (+y) edge
///   than on the opposite edge. The tile `uniformity` layer carries each
///   tile's departure from the frame background as a fraction of it, and its
///   local slope (same units as the frame gradient) in `aux_value`.
/// * `uniformity_cv` is the robust spread of the tile backgrounds over the
///   frame background: vignetting, gradients and obstructions, not stars.
/// * `snr` is not measured from pixels: whether a sub is sky- or
///   read-noise-limited needs the camera's gain and read noise, which the app
///   applies to `noise`. It is returned as 0, and the tile `snr` layer carries
///   the tile noise in `aux_value` for the same purpose.
#[allow(clippy::too_many_arguments)]
pub(crate) fn compute_quality_maps_from_linear_data(
    width: usize,
    height: usize,
    linear_data: &[f64],
    grid_rows: u32,
    grid_cols: u32,
    low_clip_adu: u32,
    high_clip_adu: u32,
    processing_tier: &str,
) -> Result<QualityMapsResultApi, SkotiqError> {
    if width == 0 || height == 0 {
        return Err(SkotiqError::InvalidInput(
            "Image dimensions must be non-zero".to_string(),
        ));
    }

    let expected = width.saturating_mul(height);
    if linear_data.len() < expected {
        return Err(SkotiqError::InvalidInput(format!(
            "Linear buffer too small: {} < {}",
            linear_data.len(),
            expected
        )));
    }

    let rows = grid_rows.clamp(2, 128) as usize;
    let cols = grid_cols.clamp(2, 128) as usize;
    let low_clip = low_clip_adu as f64;
    let high_clip = high_clip_adu as f64;

    let blocks = block_noise(width, height, &linear_data[..expected]);
    let mut tiles: Vec<TileStats> = Vec::with_capacity(rows * cols);
    let mut grid: Vec<Option<f64>> = vec![None; rows * cols];

    let mut global_count: usize = 0;
    let mut global_sum = 0.0;
    let mut global_sum_sq = 0.0;
    let mut global_low_clip: usize = 0;
    let mut global_high_clip: usize = 0;

    for row in 0..rows {
        let y_start = (row * height) / rows;
        let mut y_end = ((row + 1) * height) / rows;
        if y_end <= y_start {
            y_end = (y_start + 1).min(height);
        }

        for col in 0..cols {
            let x_start = (col * width) / cols;
            let mut x_end = ((col + 1) * width) / cols;
            if x_end <= x_start {
                x_end = (x_start + 1).min(width);
            }

            let mut samples = Vec::with_capacity((y_end - y_start) * (x_end - x_start));
            let mut tile_low_clip: usize = 0;
            let mut tile_high_clip: usize = 0;

            for y in y_start..y_end {
                let row_base = y * width;
                for &value in &linear_data[row_base + x_start..row_base + x_end] {
                    if !value.is_finite() {
                        continue;
                    }
                    samples.push(value);
                    global_sum += value;
                    global_sum_sq += value * value;
                    global_count += 1;
                    if value <= low_clip {
                        tile_low_clip += 1;
                        global_low_clip += 1;
                    }
                    if value >= high_clip {
                        tile_high_clip += 1;
                        global_high_clip += 1;
                    }
                }
            }

            if samples.is_empty() {
                continue;
            }
            samples.sort_by(|a, b| a.total_cmp(b));
            let in_tile: Vec<f64> = blocks
                .iter()
                .filter(|(bx, by, _)| {
                    *bx >= x_start as f64
                        && *bx < x_end as f64
                        && *by >= y_start as f64
                        && *by < y_end as f64
                })
                .map(|(_, _, sigma)| *sigma)
                .collect();
            let noise = if in_tile.is_empty() {
                clipped_median_sigma(&samples).1
            } else {
                median(&in_tile)
            };
            let p50 = percentile_sorted(&samples, 0.50);
            grid[row * cols + col] = Some(p50);
            tiles.push(TileStats {
                row: row as u32,
                col: col as u32,
                count: samples.len(),
                p05: percentile_sorted(&samples, 0.05),
                p50,
                p95: percentile_sorted(&samples, 0.95),
                noise,
                low_clip: tile_low_clip,
                high_clip: tile_high_clip,
            });
        }
    }

    let safe_count = global_count.max(1) as f64;
    let global_mean = global_sum / safe_count;
    let global_std_dev = ((global_sum_sq / safe_count) - (global_mean * global_mean))
        .max(0.0)
        .sqrt();
    let tile_medians: Vec<f64> = tiles.iter().map(|t| t.p50).collect();
    let background = if tile_medians.is_empty() {
        global_mean
    } else {
        median(&tile_medians)
    };
    let mad_value = if tile_medians.is_empty() {
        0.0
    } else {
        mad(&tile_medians, background)
    };
    let noise = if !blocks.is_empty() {
        median(&blocks.iter().map(|b| b.2).collect::<Vec<_>>())
    } else if !tiles.is_empty() {
        median(&tiles.iter().map(|t| t.noise).collect::<Vec<_>>())
    } else {
        global_std_dev
    };
    let background_scale = if background.abs() < 1e-6 {
        None
    } else {
        Some(background.abs())
    };

    let plane_points: Vec<(f64, f64, f64)> = tiles
        .iter()
        .map(|t| {
            (
                (t.col as f64 + 0.5) / cols as f64 - 0.5,
                (t.row as f64 + 0.5) / rows as f64 - 0.5,
                t.p50,
            )
        })
        .collect();
    let (gradient_x, gradient_y) = match (background_plane(&plane_points), background_scale) {
        (Some((_, bx, by)), Some(scale)) => (bx / scale, by / scale),
        _ => (0.0, 0.0),
    };

    // Local slope of the background at a tile, from its neighbors' medians,
    // in the frame-gradient units (fraction of background per frame extent).
    let local_slope = |row: usize, col: usize| -> f64 {
        let at = |r: usize, c: usize| grid[r * cols + c];
        let axis = |before: Option<f64>, here: Option<f64>, after: Option<f64>, n: usize| {
            let span = n as f64;
            match (before, here, after) {
                (Some(b), _, Some(a)) => (a - b) * span / 2.0,
                (None, Some(h), Some(a)) => (a - h) * span,
                (Some(b), Some(h), None) => (h - b) * span,
                _ => 0.0,
            }
        };
        let gx = axis(
            col.checked_sub(1).and_then(|c| at(row, c)),
            at(row, col),
            (col + 1 < cols).then(|| at(row, col + 1)).flatten(),
            cols,
        );
        let gy = axis(
            row.checked_sub(1).and_then(|r| at(r, col)),
            at(row, col),
            (row + 1 < rows).then(|| at(row + 1, col)).flatten(),
            rows,
        );
        match background_scale {
            Some(scale) => gx.hypot(gy) / scale,
            None => 0.0,
        }
    };

    let mut tile_metrics = Vec::with_capacity(tiles.len() * 5);
    for t in &tiles {
        let count_f64 = t.count as f64;
        let sample_count = t.count.min(u32::MAX as usize) as u32;
        let low_clip_percent = 100.0 * (t.low_clip as f64) / count_f64;
        let high_clip_percent = 100.0 * (t.high_clip as f64) / count_f64;
        let departure = match background_scale {
            Some(scale) => (t.p50 - background).abs() / scale,
            None => 0.0,
        };
        let (tile_row, tile_col) = (t.row, t.col);
        tile_metrics.push(QualityTileMetricApi {
            layer_type: "uniformity".to_string(),
            tile_row,
            tile_col,
            sample_count,
            value: departure,
            p05: t.p05,
            p50: t.p50,
            p95: t.p95,
            aux_value: local_slope(t.row as usize, t.col as usize),
        });
        tile_metrics.push(QualityTileMetricApi {
            layer_type: "clip_low".to_string(),
            tile_row,
            tile_col,
            sample_count,
            value: low_clip_percent,
            p05: low_clip_percent,
            p50: low_clip_percent,
            p95: low_clip_percent,
            aux_value: t.low_clip as f64,
        });
        tile_metrics.push(QualityTileMetricApi {
            layer_type: "clip_high".to_string(),
            tile_row,
            tile_col,
            sample_count,
            value: high_clip_percent,
            p05: high_clip_percent,
            p50: high_clip_percent,
            p95: high_clip_percent,
            aux_value: t.high_clip as f64,
        });
        tile_metrics.push(QualityTileMetricApi {
            layer_type: "background".to_string(),
            tile_row,
            tile_col,
            sample_count,
            value: t.p50,
            p05: t.p05,
            p50: t.p50,
            p95: t.p95,
            aux_value: t.noise,
        });
        tile_metrics.push(QualityTileMetricApi {
            layer_type: "snr".to_string(),
            tile_row,
            tile_col,
            sample_count,
            value: 0.0,
            p05: 0.0,
            p50: 0.0,
            p95: 0.0,
            aux_value: t.noise,
        });
    }

    let p1 = if tiles.is_empty() {
        0.0
    } else {
        percentile(&tiles.iter().map(|t| t.p05).collect::<Vec<_>>(), 0.2)
    };
    let p99 = if tiles.is_empty() {
        0.0
    } else {
        percentile(&tiles.iter().map(|t| t.p95).collect::<Vec<_>>(), 0.8)
    };

    Ok(QualityMapsResultApi {
        frame: QualityFrameMetricsApi {
            median: background,
            mean: global_mean,
            std_dev: global_std_dev,
            mad: mad_value,
            background,
            noise,
            snr: 0.0,
            dynamic_range_p1_p99: (p99 - p1).max(0.0),
            low_clip_percent: 100.0 * (global_low_clip as f64) / safe_count,
            high_clip_percent: 100.0 * (global_high_clip as f64) / safe_count,
            uniformity_cv: match background_scale {
                Some(scale) => 1.4826 * mad_value / scale,
                None => 0.0,
            },
            gradient_x,
            gradient_y,
            processing_tier: processing_tier.to_string(),
            processing_ms: 0,
        },
        tiles: tile_metrics,
    })
}
