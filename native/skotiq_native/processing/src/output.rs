//! Writing a pipeline's output files: the folder they go in and the stretched
//! preview beside a master.

use skotiq_imaging::{
    apply_stretch, apply_stretch_rgb_per_channel, auto_stretch_rgb_with_mode, auto_stretch_stf,
    ImageData, PixelType, RgbStretchMode,
};
use std::path::Path;

/// Write a stretched 8-bit preview PNG of a (U16 or F32) master.
///
/// F32 masters are first rescaled into U16 (preserving relative tone) so the
/// existing STF auto-stretch + `apply_stretch` path applies; the result is an
/// 8-bit (mono) or interleaved-RGB PNG written via the `image` crate.
pub(crate) fn write_preview_png(master: &ImageData, path: &Path) -> Result<(), String> {
    write_preview_png_with_mode(master, path, RgbStretchMode::Linked)
}

/// [`write_preview_png`] with the color STF chosen: `Unlinked` stretches each
/// channel from its own median and MAD, PixInsight's default auto-stretch,
/// so a color cast in the linear data does not leave two channels black.
pub(crate) fn write_preview_png_with_mode(
    master: &ImageData,
    path: &Path,
    mode: RgbStretchMode,
) -> Result<(), String> {
    ensure_parent_dir(path)?;
    let u16_master = to_u16_for_preview(master);

    let width = u16_master.width;
    let height = u16_master.height;
    let channels = u16_master.channels;

    if channels == 1 {
        let params = auto_stretch_stf(&u16_master);
        let eight = apply_stretch(&u16_master, &params);
        let img = image::GrayImage::from_raw(width, height, eight)
            .ok_or_else(|| "failed to build preview buffer".to_string())?;
        img.save(path)
            .map_err(|e| format!("failed to write preview PNG: {e}"))
    } else if channels == 3 {
        let rgb = u16_master
            .as_u16()
            .ok_or_else(|| "RGB preview requires u16 master".to_string())?;
        let (r, g, b) = auto_stretch_rgb_with_mode(&rgb, width, height, mode);
        let eight = apply_stretch_rgb_per_channel(&rgb, width, height, &r, &g, &b);
        let img: image::RgbImage = image::ImageBuffer::from_raw(width, height, eight)
            .ok_or_else(|| "failed to build RGB preview buffer".to_string())?;
        img.save(path)
            .map_err(|e| format!("failed to write preview PNG: {e}"))
    } else {
        Err(format!("unsupported channel count {channels} for preview"))
    }
}

/// Convert any master into a U16 image for the auto-stretch preview path.
/// U16 is passed through; F32 is rescaled from its finite min..max into 0..65535.
pub(crate) fn to_u16_for_preview(master: &ImageData) -> ImageData {
    if master.pixel_type == PixelType::U16 {
        return master.clone();
    }
    let data = master.as_f32().unwrap_or_default();
    if data.is_empty() {
        return ImageData::from_u16(master.width, master.height, master.channels, &[]);
    }
    let mut lo = f64::INFINITY;
    let mut hi = f64::NEG_INFINITY;
    for &v in &data {
        let v = v as f64;
        if v.is_finite() {
            lo = lo.min(v);
            hi = hi.max(v);
        }
    }
    let u16data: Vec<u16> = if !lo.is_finite() || !hi.is_finite() || hi <= lo {
        vec![0u16; data.len()]
    } else {
        let range = hi - lo;
        data.iter()
            .map(|&v| {
                let n = ((v as f64 - lo) / range).clamp(0.0, 1.0);
                (n * 65535.0).round() as u16
            })
            .collect()
    };
    ImageData::from_u16(master.width, master.height, master.channels, &u16data)
}

/// Creates the folder an output file goes in.
pub(crate) fn ensure_parent_dir(path: &Path) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("failed to create directory {}: {e}", parent.display()))?;
        }
    }
    Ok(())
}
