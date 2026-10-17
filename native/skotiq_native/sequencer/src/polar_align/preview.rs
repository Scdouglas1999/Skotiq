//! Live-preview image preparation for polar alignment.
//!
//! Shared between three-point and all-sky polar alignment: applies
//! debayer + stretch + JPEG encoding so the UI can show the framing
//! while the wizard runs.

use super::PolarAlignmentImageData;
use skotiq_imaging::{
    apply_stretch, apply_stretch_rgb, auto_stretch_rgb, auto_stretch_stf, debayer, BayerPattern,
    DebayerAlgorithm, ImageData as ImagingImageData, PixelType,
};

/// Prepare image data for display by applying debayering (if color)
/// and stretching, then encoding to JPEG.
pub fn prepare_image_for_display(
    image_data: &ImagingImageData,
    is_color: bool,
    bayer_pattern: Option<BayerPattern>,
) -> Result<Vec<u8>, String> {
    use image::ImageEncoder;

    let (display_data, width, height, color_type) = if is_color {
        // Why: defaults to RGGB (most common OSC layout —
        // QHY/ZWO/Atik OSC all use RGGB). User-overridable per camera.
        let pattern = bayer_pattern.unwrap_or(BayerPattern::RGGB);

        let rgb_image = debayer(
            &image_data.data,
            image_data.width,
            image_data.height,
            pattern,
            DebayerAlgorithm::Bilinear,
        );

        let rgb16_data = rgb_image.to_rgb16();
        let (_r_params, g_params, _b_params) =
            auto_stretch_rgb(&rgb16_data, rgb_image.width, rgb_image.height);
        let stretched =
            apply_stretch_rgb(&rgb16_data, rgb_image.width, rgb_image.height, &g_params);
        (
            stretched,
            rgb_image.width,
            rgb_image.height,
            image::ColorType::Rgb8,
        )
    } else {
        let params = auto_stretch_stf(image_data);
        let stretched = apply_stretch(image_data, &params);
        (
            stretched,
            image_data.width,
            image_data.height,
            image::ColorType::L8,
        )
    };

    let mut jpeg_data = Vec::new();
    {
        let mut cursor = std::io::Cursor::new(&mut jpeg_data);
        let encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut cursor, 85);
        encoder
            .write_image(&display_data, width, height, color_type)
            .map_err(|e| format!("Failed to encode JPEG: {}", e))?;
    }

    Ok(jpeg_data)
}

/// Convert a raw camera frame into a `PolarAlignmentImageData`
/// snapshot and hand it to the image callback. Used by both the
/// three-point and all-sky polar wizards.
pub(crate) fn emit_preview<I>(
    image_data: &crate::device_ops::ImageData,
    image_callback: &I,
    solved_ra: Option<f64>,
    solved_dec: Option<f64>,
    point: i32,
    phase: &str,
) where
    I: Fn(PolarAlignmentImageData),
{
    let is_color = image_data.sensor_type.as_deref() == Some("Color");
    let bayer_pattern = image_data.bayer_offset.map(|(x, y)| match (x % 2, y % 2) {
        (0, 0) => BayerPattern::RGGB,
        (1, 0) => BayerPattern::GRBG,
        (0, 1) => BayerPattern::GBRG,
        (1, 1) => BayerPattern::BGGR,
        _ => BayerPattern::RGGB,
    });

    let packed_data: Vec<u8> = image_data
        .data
        .iter()
        .flat_map(|&v| v.to_le_bytes())
        .collect();
    let imaging_image_data = ImagingImageData {
        width: image_data.width,
        height: image_data.height,
        channels: 1,
        pixel_type: PixelType::U16,
        data: packed_data,
    };

    if let Ok(jpeg_data) = prepare_image_for_display(&imaging_image_data, is_color, bayer_pattern) {
        image_callback(PolarAlignmentImageData {
            image_data: jpeg_data,
            width: image_data.width,
            height: image_data.height,
            solved_ra,
            solved_dec,
            point,
            phase: phase.to_string(),
        });
    }
}
