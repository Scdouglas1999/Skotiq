//! The 8-bit preview written with each image (section 11.12), stretched with
//! the adaptive display function of section 8.5.7 so a linear frame is
//! visible in a file browser.

use crate::{ImageData, PixelType};
use rayon::prelude::*;

/// The longest side of a thumbnail.
const MAX_SIDE: u32 = 512;

pub(crate) fn make(image: &ImageData) -> ImageData {
    let channels = if image.channels >= 3 { 3 } else { 1 };
    let mut factor = image.width.max(image.height).div_ceil(MAX_SIDE).max(1);
    // An even factor averages whole Bayer cells, so a mosaic frame shows as
    // gray instead of a checkerboard.
    if factor > 1 && factor % 2 == 1 {
        factor += 1;
    }
    let (w, h) = (
        image.width.div_ceil(factor).max(1),
        image.height.div_ceil(factor).max(1),
    );
    let size = image.pixel_type.byte_size();
    let stride = size * image.channels as usize;
    let scale = match image.pixel_type {
        PixelType::U8 => 1.0 / u8::MAX as f64,
        PixelType::U16 => 1.0 / u16::MAX as f64,
        PixelType::U32 => 1.0 / u32::MAX as f64,
        PixelType::F32 | PixelType::F64 => 1.0,
    };

    // Each thumbnail row averages its own band of the image, in parallel.
    let rows: Vec<Vec<[f64; 3]>> = (0..h)
        .into_par_iter()
        .map(|ty| {
            (0..w)
                .map(|tx| {
                    let (mut sum, mut n) = ([0f64; 3], 0u32);
                    for y in ty * factor..((ty + 1) * factor).min(image.height) {
                        let row = y as usize * image.width as usize;
                        for x in tx * factor..((tx + 1) * factor).min(image.width) {
                            let at = (row + x as usize) * stride;
                            for (c, s) in sum.iter_mut().enumerate().take(channels) {
                                let v = crate::samples::sample_from_le(
                                    &image.data[at + c * size..at + (c + 1) * size],
                                    image.pixel_type,
                                );
                                if v.is_finite() {
                                    *s += v * scale;
                                }
                            }
                            n += 1;
                        }
                    }
                    sum.map(|s| s / n.max(1) as f64)
                })
                .collect()
        })
        .collect();
    let planes: Vec<Vec<f64>> = (0..channels)
        .map(|c| rows.iter().flatten().map(|pixel| pixel[c]).collect())
        .collect();

    let (shadows, midtones) = adaptive_stretch(&planes);
    let mut data = vec![0u8; (w * h) as usize * channels];
    for (i, out) in data.iter_mut().enumerate() {
        let v = planes[i % channels][i / channels];
        let clipped = ((v - shadows) / (1.0 - shadows)).clamp(0.0, 1.0);
        *out = (mtf(midtones, clipped) * 255.0).round() as u8;
    }
    ImageData {
        width: w,
        height: h,
        channels: channels as u32,
        pixel_type: PixelType::U8,
        data,
    }
}

/// The midtones transfer function (Equation 5).
fn mtf(m: f64, x: f64) -> f64 {
    if x <= 0.0 {
        0.0
    } else if x >= 1.0 {
        1.0
    } else {
        (m - 1.0) * x / ((2.0 * m - 1.0) * x - m)
    }
}

/// One shadows clipping point and midtones balance for all channels
/// (Equations 15-18) with the recommended target background 0.25 and
/// clipping point -2.8.
fn adaptive_stretch(planes: &[Vec<f64>]) -> (f64, f64) {
    const TARGET: f64 = 0.25;
    const CLIP: f64 = -2.8;
    let stats: Vec<(f64, f64)> = planes
        .iter()
        .map(|p| {
            let median = median_of(p.clone());
            let madn = 1.4826 * median_of(p.iter().map(|v| (v - median).abs()).collect());
            (median, madn)
        })
        .collect();
    let n = stats.len() as f64;
    let median = stats.iter().map(|s| s.0).sum::<f64>() / n;
    let madn = stats.iter().map(|s| s.1).sum::<f64>() / n;
    let shadows = if madn > 0.0 {
        (median + CLIP * madn).clamp(0.0, 1.0)
    } else {
        0.0
    };
    let midtones = mtf(TARGET, (median - shadows).max(0.0));
    (shadows.min(0.999), midtones)
}

fn median_of(mut values: Vec<f64>) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mid = values.len() / 2;
    let (_, m, _) = values.select_nth_unstable_by(mid, f64::total_cmp);
    *m
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thumbnail_is_small_eight_bit_and_stretched() {
        let (w, h) = (2000u32, 1200u32);
        let samples: Vec<u16> = (0..w * h).map(|i| 1000 + (i % 50) as u16).collect();
        let thumb = make(&ImageData::from_u16(w, h, 1, &samples));
        assert!(thumb.width <= MAX_SIDE && thumb.height <= MAX_SIDE);
        assert_eq!(thumb.pixel_type, PixelType::U8);
        let mean = thumb.data.iter().map(|&v| v as f64).sum::<f64>() / thumb.data.len() as f64;
        assert!(mean > 20.0, "a dark linear frame should be stretched, mean {mean}");
    }
}
