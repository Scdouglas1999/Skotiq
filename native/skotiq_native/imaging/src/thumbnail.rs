//! The small 8-bit preview of a frame: the one a file browser, the session
//! list and an XISF file's `Thumbnail` show.
//!
//! One rule for every source. The frame is reduced by averaging whole boxes of
//! pixels (whole color-filter cells of a mosaic, so it shows gray instead of a
//! checkerboard), in 16-bit ADU as its sample range gives them, and then shown
//! as any frame is: [`ImageData::to_display_u8`], the PixInsight screen
//! transfer function.

use crate::{ImageData, PixelType};
use rayon::prelude::*;

/// A display-ready preview of `image` whose longer side is at most `max_side`:
/// 8-bit, one channel for a one-channel image and three otherwise.
///
/// `cfa_cell` is the side of the color-filter cell of a mosaic frame (2 for
/// Bayer, 6 for X-Trans), 1 for any other frame.
pub fn thumbnail(image: &ImageData, cfa_cell: u32, max_side: u32) -> ImageData {
    let channels = if image.channels >= 3 { 3 } else { 1 };
    let mut factor = image
        .width
        .max(image.height)
        .div_ceil(max_side.max(1))
        .max(1);
    if image.channels == 1 && cfa_cell > 1 {
        factor = factor.div_ceil(cfa_cell) * cfa_cell;
    }
    let (w, h) = (
        image.width.div_ceil(factor).max(1),
        image.height.div_ceil(factor).max(1),
    );
    let size = image.pixel_type.byte_size();
    let stride = size * image.channels.max(1) as usize;
    let (low, gain) = (image.range.low, image.range.adu_per_unit());

    // Each thumbnail row averages its own band of the image.
    let mut reduced = vec![0f32; (w * h) as usize * channels];
    if image.holds_all_samples() && !image.is_empty() {
        reduced
            .par_chunks_mut(w as usize * channels)
            .enumerate()
            .for_each(|(ty, out)| {
                let ty = ty as u32;
                for tx in 0..w {
                    let (mut sum, mut n) = ([0f64; 3], [0u32; 3]);
                    for y in ty * factor..((ty + 1) * factor).min(image.height) {
                        let row = y as usize * image.width as usize;
                        for x in tx * factor..((tx + 1) * factor).min(image.width) {
                            let at = (row + x as usize) * stride;
                            for c in 0..channels {
                                let v = crate::samples::sample_from_le(
                                    &image.data[at + c * size..at + (c + 1) * size],
                                    image.pixel_type,
                                );
                                if v.is_finite() {
                                    sum[c] += v;
                                    n[c] += 1;
                                }
                            }
                        }
                    }
                    for c in 0..channels {
                        let mean = sum[c] / f64::from(n[c].max(1));
                        out[tx as usize * channels + c] = ((mean - low) * gain) as f32;
                    }
                }
            });
    }
    let reduced = ImageData::from_f32(w, h, channels as u32, &reduced);
    let mut preview = ImageData::new(w, h, channels as u32, PixelType::U8);
    preview.data = reduced.to_display_u8();
    preview
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SampleRange;

    #[test]
    fn a_thumbnail_is_small_eight_bit_and_stretched() {
        let (w, h) = (2000u32, 1200u32);
        let samples: Vec<u16> = (0..w * h).map(|i| 1000 + (i % 50) as u16).collect();
        let thumb = thumbnail(&ImageData::from_u16(w, h, 1, &samples), 1, 512);
        assert!(thumb.width <= 512 && thumb.height <= 512);
        assert_eq!((thumb.pixel_type, thumb.channels), (PixelType::U8, 1));
        assert_eq!(thumb.data.len(), (thumb.width * thumb.height) as usize);
        let mean = thumb.data.iter().map(|&v| v as f64).sum::<f64>() / thumb.data.len() as f64;
        assert!(mean > 20.0, "a dark linear frame should be stretched, mean {mean}");
    }

    #[test]
    fn a_mosaic_is_reduced_by_whole_filter_cells() {
        // 2x2 cells of (100, 4000, 4000, 9000) with a gradient: point sampling
        // would show one filter; whole cells show the cell mean.
        let (w, h) = (1024u32, 1024u32);
        let cell = [100u16, 4000, 4000, 9000];
        let samples: Vec<u16> = (0..h)
            .flat_map(|y| (0..w).map(move |x| cell[((y % 2) * 2 + x % 2) as usize] + (x / 4) as u16))
            .collect();
        let image = ImageData::from_u16(w, h, 1, &samples);
        // 1024 / 400 asks for a factor of 3; the cell makes it 4.
        let thumb = thumbnail(&image, 2, 400);
        assert_eq!((thumb.width, thumb.height), (256, 256));
        let row = &thumb.data[..256];
        assert!(row.windows(2).all(|p| p[1] >= p[0]), "a smooth gradient, no checkerboard");
    }

    #[test]
    fn the_same_scene_gives_the_same_thumbnail_in_every_convention() {
        let (w, h) = (900u32, 600u32);
        let adu: Vec<u16> = (0..w * h)
            .map(|i| 900 + ((i * 7919) % 400) as u16 + if i % 9973 == 0 { 30_000 } else { 0 })
            .collect();
        let sixteen = ImageData::from_u16(w, h, 1, &adu);
        let float_adu: Vec<f32> = adu.iter().map(|&v| f32::from(v)).collect();
        let float_unit: Vec<f32> = adu.iter().map(|&v| f32::from(v) / 65535.0).collect();
        let reference = thumbnail(&sixteen, 1, 256).data;
        for (name, twin) in [
            ("ADU float", ImageData::from_f32(w, h, 1, &float_adu)),
            (
                "[0, 1] float",
                ImageData::from_f32(w, h, 1, &float_unit).with_range(SampleRange::UNIT),
            ),
        ] {
            let got = thumbnail(&twin, 1, 256).data;
            let worst = reference
                .iter()
                .zip(&got)
                .map(|(a, b)| a.abs_diff(*b))
                .max()
                .unwrap();
            assert!(worst <= 1, "{name}: thumbnails differ by {worst} levels");
        }
    }
}
