//! The live stack's own display stretch: per channel, a black point under
//! the sky by a noise-scaled margin and a midtone putting the sky at a target
//! level, both easing as frames accumulate. It is not the STF of
//! [`crate::stretch`]; the live stack keeps its look (owner call N4).

use rayon::prelude::*;

/// An 8-bit RGBA preview of a live stack.
#[derive(Debug, Clone, PartialEq)]
pub struct LiveStackPreview {
    pub width: u32,
    pub height: u32,
    /// 1 or 3: the channels the stack had.
    pub channels: u32,
    pub rgba: Vec<u8>,
}

/// Parallel area-average downscale for f32 mono or interleaved RGB images.
pub fn downscale_f32_area(
    width: u32,
    height: u32,
    channels: u32,
    data: &[f32],
    max_dimension: u32,
) -> (u32, u32, Vec<f32>) {
    let ch = if channels == 3 { 3usize } else { 1usize };
    let src_w = width as usize;
    let src_h = height as usize;
    let expected = src_w.checked_mul(src_h).and_then(|p| p.checked_mul(ch));
    if src_w == 0 || src_h == 0 || expected.is_none_or(|n| data.len() < n) {
        return (width, height, data.to_vec());
    }
    let max_dim = max_dimension as usize;
    if max_dim == 0 || src_w.max(src_h) <= max_dim {
        return (width, height, data.to_vec());
    }

    let (dst_w, dst_h) = if src_w >= src_h {
        let dw = max_dim.max(1);
        let dh = ((src_h as u64 * dw as u64) / src_w as u64).max(1) as usize;
        (dw, dh)
    } else {
        let dh = max_dim.max(1);
        let dw = ((src_w as u64 * dh as u64) / src_h as u64).max(1) as usize;
        (dw, dh)
    };

    let mut out = vec![0.0_f32; dst_w * dst_h * ch];
    let row_stride_dst = dst_w * ch;
    let row_stride_src = src_w * ch;

    out.par_chunks_exact_mut(row_stride_dst)
        .enumerate()
        .for_each(|(dy, dst_row)| {
            let sy0 = (dy * src_h) / dst_h;
            let sy1 = (((dy + 1) * src_h) / dst_h).max(sy0 + 1).min(src_h);
            for dx in 0..dst_w {
                let sx0 = (dx * src_w) / dst_w;
                let sx1 = (((dx + 1) * src_w) / dst_w).max(sx0 + 1).min(src_w);
                let inv_area = 1.0_f64 / ((sy1 - sy0) * (sx1 - sx0)) as f64;
                let dst_base = dx * ch;
                if ch == 1 {
                    let mut sum = 0.0_f64;
                    for sy in sy0..sy1 {
                        let row_off = sy * row_stride_src;
                        for sx in sx0..sx1 {
                            sum += data[row_off + sx] as f64;
                        }
                    }
                    dst_row[dst_base] = (sum * inv_area) as f32;
                } else {
                    let mut sum_r = 0.0_f64;
                    let mut sum_g = 0.0_f64;
                    let mut sum_b = 0.0_f64;
                    for sy in sy0..sy1 {
                        let row_off = sy * row_stride_src;
                        for sx in sx0..sx1 {
                            let idx = row_off + sx * 3;
                            sum_r += data[idx] as f64;
                            sum_g += data[idx + 1] as f64;
                            sum_b += data[idx + 2] as f64;
                        }
                    }
                    dst_row[dst_base] = (sum_r * inv_area) as f32;
                    dst_row[dst_base + 1] = (sum_g * inv_area) as f32;
                    dst_row[dst_base + 2] = (sum_b * inv_area) as f32;
                }
            }
        });

    (dst_w as u32, dst_h as u32, out)
}

#[derive(Debug, Clone, Copy)]
struct LiveStackChannelStretch {
    black_point: f64,
    inv_range: f64,
    midtone: f64,
}

impl LiveStackChannelStretch {
    #[inline]
    fn apply(self, val: f64) -> u8 {
        if self.inv_range <= 0.0 {
            return 0;
        }
        let x = ((val - self.black_point) * self.inv_range).clamp(0.0, 1.0);
        let y = live_mtf(x, self.midtone);
        (y * 255.0).round().clamp(0.0, 255.0) as u8
    }
}

#[inline]
fn live_mtf(x: f64, m: f64) -> f64 {
    if x <= 0.0 {
        0.0
    } else if x >= 1.0 {
        1.0
    } else if (x - m).abs() < 1e-12 {
        0.5
    } else {
        ((m - 1.0) * x) / ((2.0 * m - 1.0) * x - m)
    }
}

#[inline]
fn live_mtf_midtone(x: f64, target: f64) -> f64 {
    let denom = (2.0 * target - 1.0) * x - target;
    if denom.abs() < f64::EPSILON {
        return target;
    }
    (((target - 1.0) * x) / denom).clamp(1e-6, 0.999999)
}

#[inline]
fn sorted_quantile(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let idx = ((sorted.len() - 1) as f64 * q.clamp(0.0, 1.0)) as usize;
    sorted[idx.min(sorted.len() - 1)]
}

/// Compute progressive EAA live-stack stretch parameters for one channel from
/// native full-resolution floating-point pixels.
fn compute_live_stack_channel_stretch(
    data: &[f32],
    width: usize,
    height: usize,
    channels: usize,
    channel_idx: usize,
    stacked_frame_count: u32,
) -> LiveStackChannelStretch {
    const MAD_TO_SIGMA: f64 = 1.482602218505602;
    const DIFF_TO_SIGMA: f64 = 1.482602218505602 / std::f64::consts::SQRT_2;
    const SAMPLE_BUDGET: usize = 131_072;

    let pixel_count = width * height;
    if pixel_count == 0 {
        return LiveStackChannelStretch {
            black_point: 0.0,
            inv_range: 1.0 / 65535.0,
            midtone: 0.5,
        };
    }

    let stride = (pixel_count / SAMPLE_BUDGET).max(1);
    let mut samples = Vec::with_capacity((pixel_count / stride) + 1);
    let mut p = 0usize;
    while p < pixel_count {
        let v = data[p * channels + channel_idx] as f64;
        if v.is_finite() {
            samples.push(v);
        }
        p += stride;
    }
    if samples.is_empty() {
        return LiveStackChannelStretch {
            black_point: 0.0,
            inv_range: 1.0 / 65535.0,
            midtone: 0.5,
        };
    }

    samples.sort_unstable_by(f64::total_cmp);
    let median = sorted_quantile(&samples, 0.5);
    let p999 = sorted_quantile(&samples, 0.999);
    let max_val = *samples.last().unwrap_or(&65535.0);

    let mut deviations: Vec<f64> = samples.iter().map(|&v| (v - median).abs()).collect();
    deviations.sort_unstable_by(f64::total_cmp);
    let sigma_global = sorted_quantile(&deviations, 0.5) * MAD_TO_SIGMA;

    let pair_dx = if width >= 4 { 2usize } else { 1usize };
    let usable_w = width.saturating_sub(pair_dx);
    let sky_ceiling = median + 3.0 * sigma_global.max(1.0);
    let mut sigma_local = 0.0_f64;
    if usable_w > 0 {
        let row_step = (((height * usable_w) / SAMPLE_BUDGET) as f64)
            .sqrt()
            .floor() as usize;
        let step = row_step.max(1);
        let mut diffs = Vec::with_capacity(SAMPLE_BUDGET.min(pixel_count));
        let mut y = 0usize;
        while y < height {
            let row_base = y * width;
            let mut x = 0usize;
            while x < usable_w {
                let a = data[(row_base + x) * channels + channel_idx] as f64;
                let b = data[(row_base + x + pair_dx) * channels + channel_idx] as f64;
                if a.is_finite() && b.is_finite() && a <= sky_ceiling && b <= sky_ceiling {
                    diffs.push((b - a).abs());
                }
                x += step;
            }
            y += step;
        }
        if diffs.len() >= 64 {
            diffs.sort_unstable_by(f64::total_cmp);
            sigma_local = sorted_quantile(&diffs, 0.5) * DIFF_TO_SIGMA;
        }
    }

    let sigma_eff = if sigma_local > 1e-5 {
        sigma_local
    } else {
        sigma_global
    };

    if sigma_eff <= 1e-6 {
        let min_val = samples[0];
        let range = (max_val - min_val).max(1.0);
        return LiveStackChannelStretch {
            black_point: min_val,
            inv_range: 1.0 / range,
            midtone: 0.5,
        };
    }

    let n_sqrt = (stacked_frame_count.max(1) as f64).sqrt();
    let progress = 1.0 - (1.0 / n_sqrt);
    let shadow_sigma = 2.8 - 0.55 * progress;
    let target_bg = 0.14 + 0.06 * progress;

    let max_bound = max_val.max(65535.0);
    let black_point = (median - shadow_sigma * sigma_eff).clamp(0.0, (max_bound - 1e-4).max(0.0));
    let white_point = p999
        .max(median + 32.0 * sigma_eff)
        .clamp(black_point + 1e-4, max_bound);
    let range = white_point - black_point;
    let x_bg = ((median - black_point) / range).clamp(1e-6, 0.999);
    let midtone = live_mtf_midtone(x_bg, target_bg);

    LiveStackChannelStretch {
        black_point,
        inv_range: 1.0 / range,
        midtone,
    }
}

/// Render a progressive, noise-adaptive RGBA8 preview from un-quantized `f32`
/// running means (measuring native local sky noise *before* downscaling).
pub fn render_preview(
    width: u32,
    height: u32,
    channels: u32,
    data: &[f32],
    stacked_frame_count: u32,
    max_dimension: u32,
) -> Result<LiveStackPreview, String> {
    let ch = if channels == 3 { 3u32 } else { 1u32 };
    let expected = (width as usize)
        .checked_mul(height as usize)
        .and_then(|p| p.checked_mul(ch as usize))
        .ok_or_else(|| {
            format!(
                "Invalid image dimensions (overflow): {}x{}x{}",
                width, height, ch
            )
        })?;
    if width == 0 || height == 0 || data.len() < expected {
        return Err(format!(
            "Invalid image dimensions or buffer length: {}x{}x{} (got {} samples)",
            width,
            height,
            ch,
            data.len()
        ));
    }

    let native_slice = &data[..expected];
    let w_usize = width as usize;
    let h_usize = height as usize;

    let stretches: Vec<LiveStackChannelStretch> = (0..ch as usize)
        .map(|c| {
            compute_live_stack_channel_stretch(
                native_slice,
                w_usize,
                h_usize,
                ch as usize,
                c,
                stacked_frame_count,
            )
        })
        .collect();

    let (pw, ph, scaled_owned);
    let preview_slice: &[f32] = if max_dimension > 0 && width.max(height) > max_dimension {
        let (dw, dh, buf) = downscale_f32_area(width, height, ch, native_slice, max_dimension);
        pw = dw;
        ph = dh;
        scaled_owned = buf;
        &scaled_owned
    } else {
        pw = width;
        ph = height;
        native_slice
    };

    let rgba_len = (pw as usize)
        .checked_mul(ph as usize)
        .and_then(|p| p.checked_mul(4))
        .ok_or_else(|| format!("Preview dimensions overflow RGBA buffer: {}x{}", pw, ph))?;
    let mut rgba = vec![0u8; rgba_len];
    if ch == 3 {
        let sr = stretches[0];
        let sg = stretches[1];
        let sb = stretches[2];
        rgba.par_chunks_exact_mut(4)
            .zip(preview_slice.par_chunks_exact(3))
            .for_each(|(dst, src)| {
                dst[0] = sr.apply(src[0] as f64);
                dst[1] = sg.apply(src[1] as f64);
                dst[2] = sb.apply(src[2] as f64);
                dst[3] = 255;
            });
    } else {
        let sm = stretches[0];
        rgba.par_chunks_exact_mut(4)
            .zip(preview_slice.par_iter())
            .for_each(|(dst, &v)| {
                let g = sm.apply(v as f64);
                dst[0] = g;
                dst[1] = g;
                dst[2] = g;
                dst[3] = 255;
            });
    }

    Ok(LiveStackPreview {
        width: pw,
        height: ph,
        channels: ch,
        rgba,
    })
}
