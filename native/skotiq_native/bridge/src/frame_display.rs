//! A frame stretched for the screen: an 8-bit RGBA buffer and the 256-bin
//! histogram of the stretched values, the shape every image view in the app
//! draws.

use rayon::prelude::*;
use skotiq_imaging::ImageData;

pub(crate) struct DisplayImage {
    /// `width * height * 4` bytes, alpha 255.
    pub rgba: Vec<u8>,
    /// Counts of the stretched 8-bit values, every channel together.
    pub histogram: Vec<u32>,
}

/// A mono frame through PixInsight's auto STF.
pub(crate) fn mono(image: &ImageData) -> DisplayImage {
    let params = skotiq_imaging::auto_stretch_stf(image);
    let gray = skotiq_imaging::apply_stretch(image, &params);
    DisplayImage {
        histogram: histogram(&gray),
        rgba: gray_to_rgba(&gray),
    }
}

/// A colour sensor's raw mosaic: bilinear debayer (X-Trans: its one linear
/// method), histogram-peak white balance, then the STF per channel, unlinked
/// (PixInsight's default).
pub(crate) fn color(
    mosaic: &[u16],
    width: u32,
    height: u32,
    filter: skotiq_imaging::ColorFilterArray,
) -> DisplayImage {
    let mut rgb = filter
        .demosaic(mosaic, width, height, skotiq_imaging::DebayerAlgorithm::Bilinear)
        .to_rgb16();
    apply_auto_white_balance(&mut rgb);
    // A channel with no spread gets the identity curve, not a black frame.
    let (r, g, b) = skotiq_imaging::auto_stretch_rgb_with_mode(
        &rgb,
        width,
        height,
        skotiq_imaging::RgbStretchMode::Unlinked,
    );
    let rgb8 = skotiq_imaging::apply_stretch_rgb_per_channel(&rgb, width, height, &r, &g, &b);
    DisplayImage {
        histogram: histogram(&rgb8),
        rgba: rgb_to_rgba(&rgb8),
    }
}

/// A frame read from disk: in colour when its header names a colour filter
/// and it is still the one-plane mosaic, else mono.
pub(crate) fn for_file(image: &ImageData, header: &skotiq_imaging::FitsHeader) -> DisplayImage {
    match (skotiq_imaging::read_color_filter_array(header), image.channels, image.as_u16()) {
        (Some(filter), 1, Some(mosaic)) => color(&mosaic, image.width, image.height, filter),
        (_, 3, _) => {
            let rgb8 = image.to_display_u8();
            DisplayImage {
                histogram: histogram(&rgb8),
                rgba: rgb_to_rgba(&rgb8),
            }
        }
        _ => mono(image),
    }
}

/// The imaging crate's name for a device-reported color filter.
pub(crate) fn device_filter(pattern: skotiq_device::BayerPattern) -> skotiq_imaging::ColorFilterArray {
    skotiq_imaging::ColorFilterArray::parse(&pattern.fits_name())
        .expect("every device color filter has a BAYERPAT spelling the imaging crate reads")
}

fn histogram(values: &[u8]) -> Vec<u32> {
    let mut bins = vec![0u32; 256];
    for &value in values {
        bins[value as usize] += 1;
    }
    bins
}

pub(crate) fn gray_to_rgba(gray: &[u8]) -> Vec<u8> {
    let mut rgba = vec![0u8; gray.len() * 4];
    rgba.par_chunks_exact_mut(4)
        .zip(gray.par_iter())
        .for_each(|(dst, &value)| {
            dst[..3].fill(value);
            dst[3] = 255;
        });
    rgba
}

fn rgb_to_rgba(rgb: &[u8]) -> Vec<u8> {
    let mut rgba = vec![0u8; rgb.len() / 3 * 4];
    rgba.par_chunks_exact_mut(4)
        .zip(rgb.par_chunks_exact(3))
        .for_each(|(dst, src)| {
            dst[..3].copy_from_slice(src);
            dst[3] = 255;
        });
    rgba
}

/// Auto white balance by histogram peak: scale R and B so the sky
/// background's most common level matches G's.
fn apply_auto_white_balance(image: &mut [u16]) {
    if image.len() % 3 != 0 {
        return;
    }

    let mut hist_r = vec![0u32; 65536];
    let mut hist_g = vec![0u32; 65536];
    let mut hist_b = vec![0u32; 65536];

    // 1. Compute histograms
    for chunk in image.chunks(3) {
        hist_r[chunk[0] as usize] += 1;
        hist_g[chunk[1] as usize] += 1;
        hist_b[chunk[2] as usize] += 1;
    }

    // 2. The most common level per channel, above the clipped black floor.
    let start_idx = 100;

    let get_peak = |hist: &[u32]| -> u16 {
        let mut max_count = 0;
        let mut peak_idx = 0;
        for (i, &count) in hist.iter().enumerate().skip(start_idx) {
            if count > max_count {
                max_count = count;
                peak_idx = i;
            }
        }
        peak_idx as u16
    };

    let peak_r = get_peak(&hist_r);
    let peak_g = get_peak(&hist_g);
    let peak_b = get_peak(&hist_b);

    tracing::info!("AWB Peaks: R={}, G={}, B={}", peak_r, peak_g, peak_b);

    if peak_r == 0 || peak_g == 0 || peak_b == 0 {
        tracing::warn!("AWB failed: peak is 0");
        return;
    }

    // 3. Calculate scaling factors to align to Green
    let target = peak_g as f32;
    let scale_r = target / peak_r as f32;
    let scale_b = target / peak_b as f32;

    tracing::info!("AWB Scales: R={:.3}, B={:.3}", scale_r, scale_b);

    // 4. Apply scaling
    image.par_chunks_mut(3).for_each(|pixel| {
        // R
        pixel[0] = (pixel[0] as f32 * scale_r).min(65535.0) as u16;
        // G (unchanged)
        // B
        pixel[2] = (pixel[2] as f32 * scale_b).min(65535.0) as u16;
    });
}
