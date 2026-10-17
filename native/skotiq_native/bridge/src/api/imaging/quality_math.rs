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

    let mut tile_metrics = Vec::with_capacity(rows * cols * 5);
    let mut tile_medians = Vec::with_capacity(rows * cols);
    let mut tile_noises = Vec::with_capacity(rows * cols);
    let mut tile_p05 = Vec::with_capacity(rows * cols);
    let mut tile_p95 = Vec::with_capacity(rows * cols);
    let mut tile_grad_x = Vec::with_capacity(rows * cols);
    let mut tile_grad_y = Vec::with_capacity(rows * cols);

    let mut global_count: usize = 0;
    let mut global_sum = 0.0;
    let mut global_sum_sq = 0.0;
    let mut global_low_clip: usize = 0;
    let mut global_high_clip: usize = 0;

    let image_mid_x = width / 2;
    let image_mid_y = height / 2;

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

            let mut samples = Vec::new();
            let mut sum = 0.0;
            let mut sum_sq = 0.0;
            let mut tile_low_clip: usize = 0;
            let mut tile_high_clip: usize = 0;
            let mut left_sum = 0.0;
            let mut right_sum = 0.0;
            let mut top_sum = 0.0;
            let mut bottom_sum = 0.0;
            let mut left_count: usize = 0;
            let mut right_count: usize = 0;
            let mut top_count: usize = 0;
            let mut bottom_count: usize = 0;

            for y in y_start..y_end {
                let is_top = y < image_mid_y;
                let row_base = y * width;
                for x in x_start..x_end {
                    let value = linear_data[row_base + x];
                    if !value.is_finite() {
                        continue;
                    }

                    samples.push(value);
                    sum += value;
                    sum_sq += value * value;
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

                    if x < image_mid_x {
                        left_sum += value;
                        left_count += 1;
                    } else {
                        right_sum += value;
                        right_count += 1;
                    }

                    if is_top {
                        top_sum += value;
                        top_count += 1;
                    } else {
                        bottom_sum += value;
                        bottom_count += 1;
                    }
                }
            }

            if samples.is_empty() {
                continue;
            }

            samples.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));

            let count = samples.len();
            let count_f64 = count as f64;
            let mean_value = sum / count_f64;
            let variance = ((sum_sq / count_f64) - (mean_value * mean_value)).max(0.0);
            let std_dev = variance.sqrt();
            let p05 = percentile_sorted(&samples, 0.05);
            let p50 = percentile_sorted(&samples, 0.50);
            let p95 = percentile_sorted(&samples, 0.95);
            let cv = if mean_value.abs() < 1e-6 {
                0.0
            } else {
                std_dev / mean_value.abs()
            };
            let low_clip_percent = 100.0 * (tile_low_clip as f64) / count_f64;
            let high_clip_percent = 100.0 * (tile_high_clip as f64) / count_f64;
            let snr = if std_dev <= 0.0 {
                0.0
            } else {
                mean_value / std_dev
            };

            let left_mean = if left_count == 0 {
                mean_value
            } else {
                left_sum / left_count as f64
            };
            let right_mean = if right_count == 0 {
                mean_value
            } else {
                right_sum / right_count as f64
            };
            let top_mean = if top_count == 0 {
                mean_value
            } else {
                top_sum / top_count as f64
            };
            let bottom_mean = if bottom_count == 0 {
                mean_value
            } else {
                bottom_sum / bottom_count as f64
            };
            let grad_x = right_mean - left_mean;
            let grad_y = bottom_mean - top_mean;
            let grad_mag = (grad_x * grad_x + grad_y * grad_y).sqrt();

            tile_medians.push(p50);
            tile_noises.push(std_dev);
            tile_p05.push(p05);
            tile_p95.push(p95);
            tile_grad_x.push(grad_x);
            tile_grad_y.push(grad_y);

            let tile_row = row as u32;
            let tile_col = col as u32;
            let sample_count = count.min(u32::MAX as usize) as u32;
            tile_metrics.push(QualityTileMetricApi {
                layer_type: "uniformity".to_string(),
                tile_row,
                tile_col,
                sample_count,
                value: cv,
                p05,
                p50,
                p95,
                aux_value: grad_mag,
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
                aux_value: tile_low_clip as f64,
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
                aux_value: tile_high_clip as f64,
            });
            tile_metrics.push(QualityTileMetricApi {
                layer_type: "background".to_string(),
                tile_row,
                tile_col,
                sample_count,
                value: p50,
                p05,
                p50,
                p95,
                aux_value: std_dev,
            });
            tile_metrics.push(QualityTileMetricApi {
                layer_type: "snr".to_string(),
                tile_row,
                tile_col,
                sample_count,
                value: snr,
                p05: 0.0,
                p50: snr,
                p95: snr,
                aux_value: std_dev,
            });
        }
    }

    let safe_count = global_count.max(1) as f64;
    let global_mean = global_sum / safe_count;
    let global_std_dev = ((global_sum_sq / safe_count) - (global_mean * global_mean))
        .max(0.0)
        .sqrt();
    let median_value = if tile_medians.is_empty() {
        0.0
    } else {
        median(&tile_medians)
    };
    let mad_value = if tile_medians.is_empty() {
        0.0
    } else {
        mad(&tile_medians, median_value)
    };
    let background = if tile_medians.is_empty() {
        global_mean
    } else {
        median(&tile_medians)
    };
    let noise = if tile_noises.is_empty() {
        global_std_dev
    } else {
        median(&tile_noises)
    };
    let snr = if noise <= 0.0 {
        0.0
    } else {
        global_mean / noise
    };
    let p1 = if tile_p05.is_empty() {
        0.0
    } else {
        percentile(&tile_p05, 0.2)
    };
    let p99 = if tile_p95.is_empty() {
        0.0
    } else {
        percentile(&tile_p95, 0.8)
    };
    let dynamic_range = (p99 - p1).max(0.0);
    let gradient_x = if tile_grad_x.is_empty() {
        0.0
    } else {
        tile_grad_x.iter().sum::<f64>() / tile_grad_x.len() as f64
    };
    let gradient_y = if tile_grad_y.is_empty() {
        0.0
    } else {
        tile_grad_y.iter().sum::<f64>() / tile_grad_y.len() as f64
    };

    Ok(QualityMapsResultApi {
        frame: QualityFrameMetricsApi {
            median: median_value,
            mean: global_mean,
            std_dev: global_std_dev,
            mad: mad_value,
            background,
            noise,
            snr,
            dynamic_range_p1_p99: dynamic_range,
            low_clip_percent: 100.0 * (global_low_clip as f64) / safe_count,
            high_clip_percent: 100.0 * (global_high_clip as f64) / safe_count,
            uniformity_cv: if background.abs() < 1e-6 {
                0.0
            } else {
                global_std_dev / background.abs()
            },
            gradient_x,
            gradient_y,
            processing_tier: processing_tier.to_string(),
            processing_ms: 0,
        },
        tiles: tile_metrics,
    })
}
