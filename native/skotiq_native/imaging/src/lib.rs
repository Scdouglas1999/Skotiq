//! Skotiq Imaging Library
//!
//! Provides real image I/O, processing, and analysis functionality:
//! - FITS file reading and writing
//! - XISF file support (PixInsight format)
//! - Image debayering for color cameras
//! - Image statistics and star detection
//! - Auto-stretch algorithms
//! - File naming patterns
//! - Camera control abstraction
//! - Plate solving via ASTAP
//! - PHD2 guiding integration
//! - Buffer pooling for efficient image capture

pub mod background_extraction; // NEW: DBE/ABE-style background gradient extraction
pub mod buffer_pool;
pub mod calibration;
pub mod calibration_master_stream; // Memory-bounded dark/bias masters straight from frame files
pub mod calibration_masters; // NEW: Master-flat build + cosmetic (hot/cold) correction
pub mod color_calibration; // NEW: Photometric color calibration (per-channel white balance)
pub mod deconvolution; // NEW: PSF estimation + Richardson-Lucy deconvolution
pub mod defect_map;
pub mod depthlock;
pub mod detection_plane;
pub mod difference_image; // NEW: Difference imaging (Pillar B — First Light) transient detection
pub mod drizzle; // NEW: Drizzle (variable-pixel linear reconstruction) integration

mod debayer;
mod fits;
pub mod fits_layout;
pub mod fits_reader;
mod frame_shape; // Per-frame star size/shape for grading (local background, adaptive moments)
pub mod frame_weighting; // NEW: Per-sub quality weighting for batch integration
pub mod integration; // NEW: Advanced weighted batch integration + pixel rejection
pub mod master_accumulation; // NEW: Multi-night accumulating master frame
pub mod mosaic_stitch; // NEW: WCS-driven panel mosaic stitching
mod naming;
pub mod normalization; // NEW: Light-frame normalization to a reference (batch integration)
mod numeric;
pub mod optimizer; // NEW: Marginal-SNR integration optimizer (subset recommendation)
mod phd2;
mod platesolve;
mod frame_io;
mod raw;
mod raw_exif;
pub mod recipe; // Darkroom recipe engine: non-destructive, replayable op stack
pub mod registration; // NEW: High-quality star-based registration
mod resample;
mod robust_stats; // The crate's one set of order statistics (median / percentile conventions)
pub mod samples;
pub mod sky_atlas; // NEW: HEALPix-tiled additive all-sky accumulator (the 5.0 keystone)
pub mod stack_master; // NEW: the live stack's FITS master (synthesized EXPTIME/DATE-OBS)
pub mod stacking;
mod star_detect; // Star detection: background/noise maps, matched filter, deblending
pub mod star_reduction; // NEW: Star-size reduction (morphological + screen recombine)
pub mod sample_range;
mod stats;
mod stretch;
mod thumbnail;
mod trail; // Star trailing from the autocorrelation of the bright pixels
pub mod wcs_sip; // NEW: SIP-aware (CD + forward/inverse SIP) gnomonic projection
pub mod xisf;

pub use background_extraction::*; // NEW: Export background-extraction types
pub use buffer_pool::*;
pub use calibration::*;
pub use calibration_masters::*; // NEW: Export master-flat / cosmetic-correction types
pub use color_calibration::*; // NEW: Export color-calibration types
pub use debayer::*;
pub use deconvolution::*; // NEW: Export deconvolution types
pub use detection_plane::{ChannelCollapse, DetectionPlane, Quantize};
pub use difference_image::*; // NEW: Export difference-imaging (First Light) types
pub use drizzle::*; // NEW: Export drizzle types
pub use fits::*;
pub use frame_shape::*;
pub use frame_weighting::*; // NEW: Export frame-weighting types
pub use integration::*; // NEW: Export batch-integration types
pub use master_accumulation::*; // NEW: Export accumulating-master types
pub use mosaic_stitch::*; // NEW: Export mosaic-stitching types
pub use naming::*;
pub use normalization::*; // NEW: Export normalization types
pub use optimizer::*; // NEW: Export integration-optimizer types
pub use phd2::*;
pub use platesolve::*;
pub use frame_io::*;
pub use raw::*;
/// The color-composite stages, under the name the bridge imports them by.
pub use recipe::composite as color_composite;
pub use registration::*; // NEW: Export registration types
pub use sample_range::{SampleRange, ADU_FULL_SCALE};
pub use sky_atlas::*; // NEW: Export sky-atlas (keystone) types
pub use star_reduction::*; // NEW: Export star-reduction types
pub use stats::*;
pub use stretch::*;
pub use thumbnail::thumbnail;
pub use trail::{measure_frame_trail, FrameTrail, TRAIL_MIN_AXIS_RATIO};
pub use wcs_sip::*; // NEW: Export SIP-aware projection types
pub use xisf::{
    read_xisf_unit, ChecksumAlgorithm, XisfCodec, XisfCompression, XisfError, XisfUnit,
    XisfWriteOptions,
};

use rayon::prelude::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PixelType {
    U8,
    #[default]
    U16,
    U32,
    F32,
    F64,
}

impl PixelType {
    pub fn byte_size(&self) -> usize {
        match self {
            PixelType::U8 => 1,
            PixelType::U16 => 2,
            PixelType::U32 | PixelType::F32 => 4,
            PixelType::F64 => 8,
        }
    }

    pub fn bit_depth(&self) -> u32 {
        match self {
            PixelType::U8 => 8,
            PixelType::U16 => 16,
            PixelType::U32 | PixelType::F32 => 32,
            PixelType::F64 => 64,
        }
    }
}

/// Errors produced by `ImageData` display-conversion routines.
///
/// These are typed rather than papered over with a synthetic gray buffer: a
/// mid-gray image at the display layer is indistinguishable from a failed
/// capture, so hiding an unsupported channel layout hides debayer and reader
/// bugs with it. Callers decide how to report the failure (snackbar, log,
/// abort frame, etc.).
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ImageDisplayError {
    /// The image has a channel count the display pipeline does not know how
    /// to render. Supported layouts are 1 (mono), 3 (RGB), and 4 (RGBA).
    #[error(
        "unsupported channel layout for display: a {channels}-channel image; supported counts are 1 (mono), 3 (RGB), and 4 (RGBA)"
    )]
    UnsupportedChannelLayout { channels: u32 },
}

#[derive(Debug, Clone)]
pub struct ImageData {
    pub width: u32,
    pub height: u32,
    pub channels: u32,
    pub pixel_type: PixelType,
    pub data: Vec<u8>,
    /// The sample values of black and full scale. [`SampleRange::of`] the
    /// pixel type unless the image's source or producer says otherwise.
    pub range: SampleRange,
}

impl Default for ImageData {
    fn default() -> Self {
        Self::new(0, 0, 1, PixelType::U16)
    }
}

impl ImageData {
    pub fn new(width: u32, height: u32, channels: u32, pixel_type: PixelType) -> Self {
        let bytes_per_pixel = pixel_type.byte_size();
        let size = (width as usize) * (height as usize) * (channels as usize) * bytes_per_pixel;

        Self {
            width,
            height,
            channels,
            pixel_type,
            data: vec![0u8; size],
            range: SampleRange::of(pixel_type),
        }
    }

    /// The same samples, declared to span `range`.
    pub fn with_range(mut self, range: SampleRange) -> Self {
        self.range = range;
        self
    }

    pub fn bytes_per_pixel(&self) -> usize {
        self.pixel_type.byte_size()
    }

    pub fn pixel_count(&self) -> usize {
        (self.width as usize) * (self.height as usize) * (self.channels as usize)
    }

    pub fn is_empty(&self) -> bool {
        self.width == 0 || self.height == 0 || self.data.is_empty()
    }

    pub fn as_u16(&self) -> Option<Vec<u16>> {
        if self.pixel_type != PixelType::U16 {
            return None;
        }

        Some(
            self.data
                .as_chunks::<2>()
                .0
                .iter()
                .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
                .collect(),
        )
    }

    /// The samples of an `F32` image in 16-bit ADU; `None` for another type.
    pub fn as_f32(&self) -> Option<Vec<f32>> {
        (self.pixel_type == PixelType::F32).then(|| self.samples_f32())
    }

    pub fn from_u16(width: u32, height: u32, channels: u32, data: &[u16]) -> Self {
        let bytes: Vec<u8> = data.iter().flat_map(|&v| v.to_le_bytes()).collect();

        Self {
            width,
            height,
            channels,
            pixel_type: PixelType::U16,
            data: bytes,
            range: SampleRange::ADU,
        }
    }

    pub fn from_f32(width: u32, height: u32, channels: u32, data: &[f32]) -> Self {
        let bytes: Vec<u8> = data.iter().flat_map(|&v| v.to_le_bytes()).collect();

        Self {
            width,
            height,
            channels,
            pixel_type: PixelType::F32,
            data: bytes,
            range: SampleRange::ADU,
        }
    }

    /// Convert to 8-bit for display, auto-stretched. An 8-bit image is taken
    /// as display-ready.
    pub fn to_display_u8(&self) -> Vec<u8> {
        if self.pixel_type == PixelType::U8 {
            return self.data.clone();
        }
        if self.channels == 3 {
            let rgb = stretch::display_levels(self).unwrap_or_else(|| self.adu_levels());
            let (r, g, b) = auto_stretch_rgb(&rgb, self.width, self.height);
            return apply_stretch_rgb_per_channel(&rgb, self.width, self.height, &r, &g, &b);
        }
        apply_stretch(self, &auto_stretch_stf(self))
    }

    /// Convert to RGBA for Flutter display.
    ///
    /// Handles channel counts of 1 (mono), 3 (RGB), and 4 (RGBA). Any other
    /// channel count returns `ImageDisplayError::UnsupportedChannelLayout`
    /// rather than silently producing a mid-gray buffer; a gray frame at the
    /// display layer is indistinguishable from a failed capture and hides
    /// real upstream bugs (debayer, reader, calibration).
    ///
    /// This is the critical fix for the Fujifilm X-Trans / 3-channel RGB case
    /// that NINA couldn't handle.
    pub fn to_rgba(&self) -> Result<Vec<u8>, ImageDisplayError> {
        let display = self.to_display_u8();
        let pixels = (self.width as usize) * (self.height as usize);

        match self.channels {
            1 => {
                let mut rgba = vec![255u8; pixels * 4];
                rgba.par_chunks_mut(4 << 12)
                    .zip(display.par_chunks(1 << 12))
                    .for_each(|(rgba, gray)| {
                        for (out, &v) in rgba.as_chunks_mut::<4>().0.iter_mut().zip(gray) {
                            out[..3].fill(v);
                        }
                    });
                Ok(rgba)
            }
            3 => {
                let mut rgba = vec![255u8; pixels * 4];
                rgba.par_chunks_mut(4 << 12)
                    .zip(display.par_chunks(3 << 12))
                    .for_each(|(rgba, rgb)| {
                        for (out, rgb) in rgba
                            .as_chunks_mut::<4>()
                            .0
                            .iter_mut()
                            .zip(rgb.as_chunks::<3>().0)
                        {
                            out[..3].copy_from_slice(rgb);
                        }
                    });
                Ok(rgba)
            }
            // Already RGBA (some TIFFs, PNGs)
            4 => Ok(display),
            // Fail loudly so the caller can surface a real error to the user
            // instead of displaying a gray placeholder.
            other => Err(ImageDisplayError::UnsupportedChannelLayout { channels: other }),
        }
    }
}

/// A frame read from disk with what describes it.
#[derive(Debug)]
pub struct ImageReadResult {
    pub image: ImageData,
    /// The file's metadata, cards in file order with their comments.
    pub header: FitsHeader,
    /// The frame's color filter at its pixel (0, 0). `None` for a mono frame.
    pub cfa: Option<ColorFilterArray>,
}

/// Write an image to TIFF format (16-bit if possible, otherwise 8-bit)
pub fn write_tiff(path: &std::path::Path, image: &ImageData) -> Result<(), String> {
    use image::{GrayImage, ImageBuffer, RgbImage};
    use std::fs::File;
    use std::io::BufWriter;

    let file = File::create(path).map_err(|e| format!("Failed to create TIFF file: {}", e))?;
    let writer = BufWriter::new(file);

    match (image.channels, image.pixel_type) {
        // 16-bit mono - use raw encoder
        (1, PixelType::U16) => {
            use image::ImageEncoder;
            let pixels: Vec<u16> = image
                .data
                .as_chunks::<2>()
                .0
                .iter()
                .map(|c| u16::from_le_bytes([c[0], c[1]]))
                .collect();

            let encoder = image::codecs::tiff::TiffEncoder::new(writer);
            encoder
                .write_image(
                    bytemuck::cast_slice(&pixels),
                    image.width,
                    image.height,
                    image::ColorType::L16,
                )
                .map_err(|e| format!("Failed to encode TIFF: {}", e))?;
        }
        (1, PixelType::U8) => {
            let img: GrayImage =
                ImageBuffer::from_raw(image.width, image.height, image.data.clone())
                    .ok_or_else(|| "Failed to create grayscale image buffer".to_string())?;
            img.save(path)
                .map_err(|e| format!("Failed to save TIFF: {}", e))?;
        }
        (3, PixelType::U16) => {
            use image::ImageEncoder;
            let pixels: Vec<u16> = image
                .data
                .as_chunks::<2>()
                .0
                .iter()
                .map(|c| u16::from_le_bytes([c[0], c[1]]))
                .collect();

            let encoder = image::codecs::tiff::TiffEncoder::new(writer);
            encoder
                .write_image(
                    bytemuck::cast_slice(&pixels),
                    image.width,
                    image.height,
                    image::ColorType::Rgb16,
                )
                .map_err(|e| format!("Failed to encode TIFF: {}", e))?;
        }
        (3, PixelType::U8) => {
            let img: RgbImage =
                ImageBuffer::from_raw(image.width, image.height, image.data.clone())
                    .ok_or_else(|| "Failed to create RGB image buffer".to_string())?;
            img.save(path)
                .map_err(|e| format!("Failed to save TIFF: {}", e))?;
        }
        // Other formats: convert to 8-bit first
        _ => {
            let display_data = image.to_display_u8();
            if image.channels == 1 {
                let img: GrayImage = ImageBuffer::from_raw(image.width, image.height, display_data)
                    .ok_or_else(|| "Failed to create grayscale image buffer".to_string())?;
                img.save(path)
                    .map_err(|e| format!("Failed to save TIFF: {}", e))?;
            } else if image.channels >= 3 {
                // Multi-channel: display_data contains interleaved channel bytes.
                // Extract the first 3 channels as RGB.
                let pixel_count = (image.width as usize) * (image.height as usize);
                let rgb_data = if image.channels == 3 {
                    display_data
                } else {
                    let mut rgb = Vec::with_capacity(pixel_count * 3);
                    for chunk in display_data.chunks_exact(image.channels as usize) {
                        rgb.push(chunk[0]);
                        rgb.push(chunk[1]);
                        rgb.push(chunk[2]);
                    }
                    rgb
                };
                let img: RgbImage = ImageBuffer::from_raw(image.width, image.height, rgb_data)
                    .ok_or_else(|| "Failed to create RGB image buffer".to_string())?;
                img.save(path)
                    .map_err(|e| format!("Failed to save TIFF: {}", e))?;
            } else {
                return Err(format!(
                    "Unsupported channel count {} for TIFF encoding",
                    image.channels
                ));
            }
        }
    }

    Ok(())
}

/// Write an image to PNG format (8-bit or 16-bit)
pub fn write_png(path: &std::path::Path, image: &ImageData) -> Result<(), String> {
    use image::{GrayImage, ImageBuffer, ImageEncoder, RgbImage};
    use std::fs::File;
    use std::io::BufWriter;

    let file = File::create(path).map_err(|e| format!("Failed to create PNG file: {}", e))?;
    let writer = BufWriter::new(file);

    match (image.channels, image.pixel_type) {
        (1, PixelType::U16) => {
            let pixels: Vec<u16> = image
                .data
                .as_chunks::<2>()
                .0
                .iter()
                .map(|c| u16::from_le_bytes([c[0], c[1]]))
                .collect();

            let encoder = image::codecs::png::PngEncoder::new(writer);
            encoder
                .write_image(
                    bytemuck::cast_slice(&pixels),
                    image.width,
                    image.height,
                    image::ColorType::L16,
                )
                .map_err(|e| format!("Failed to encode PNG: {}", e))?;
        }
        (1, PixelType::U8) => {
            let img: GrayImage =
                ImageBuffer::from_raw(image.width, image.height, image.data.clone())
                    .ok_or_else(|| "Failed to create grayscale image buffer".to_string())?;
            img.save(path)
                .map_err(|e| format!("Failed to save PNG: {}", e))?;
        }
        (3, PixelType::U16) => {
            let pixels: Vec<u16> = image
                .data
                .as_chunks::<2>()
                .0
                .iter()
                .map(|c| u16::from_le_bytes([c[0], c[1]]))
                .collect();

            let encoder = image::codecs::png::PngEncoder::new(writer);
            encoder
                .write_image(
                    bytemuck::cast_slice(&pixels),
                    image.width,
                    image.height,
                    image::ColorType::Rgb16,
                )
                .map_err(|e| format!("Failed to encode PNG: {}", e))?;
        }
        (3, PixelType::U8) => {
            let img: RgbImage =
                ImageBuffer::from_raw(image.width, image.height, image.data.clone())
                    .ok_or_else(|| "Failed to create RGB image buffer".to_string())?;
            img.save(path)
                .map_err(|e| format!("Failed to save PNG: {}", e))?;
        }
        // Other formats: convert to 8-bit
        _ => {
            let display_data = image.to_display_u8();
            if image.channels == 1 {
                let img: GrayImage = ImageBuffer::from_raw(image.width, image.height, display_data)
                    .ok_or_else(|| "Failed to create grayscale image buffer".to_string())?;
                img.save(path)
                    .map_err(|e| format!("Failed to save PNG: {}", e))?;
            } else if image.channels >= 3 {
                // Multi-channel: display_data contains interleaved channel bytes.
                // Extract the first 3 channels as RGB.
                let pixel_count = (image.width as usize) * (image.height as usize);
                let rgb_data = if image.channels == 3 {
                    display_data
                } else {
                    let mut rgb = Vec::with_capacity(pixel_count * 3);
                    for chunk in display_data.chunks_exact(image.channels as usize) {
                        rgb.push(chunk[0]);
                        rgb.push(chunk[1]);
                        rgb.push(chunk[2]);
                    }
                    rgb
                };
                let img: RgbImage = ImageBuffer::from_raw(image.width, image.height, rgb_data)
                    .ok_or_else(|| "Failed to create RGB image buffer".to_string())?;
                img.save(path)
                    .map_err(|e| format!("Failed to save PNG: {}", e))?;
            } else {
                return Err(format!(
                    "Unsupported channel count {} for PNG encoding",
                    image.channels
                ));
            }
        }
    }

    Ok(())
}

/// Write an image to JPEG format (always 8-bit, with quality setting)
pub fn write_jpeg(path: &std::path::Path, image: &ImageData, quality: u8) -> Result<(), String> {
    use image::ImageEncoder;
    use std::fs::File;
    use std::io::BufWriter;

    let file = File::create(path).map_err(|e| format!("Failed to create JPEG file: {}", e))?;
    let writer = BufWriter::new(file);

    let encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(writer, quality);

    // JPEG only supports 8-bit, so always convert to display format
    let display_data = image.to_display_u8();

    if image.channels == 1 {
        encoder
            .write_image(
                &display_data,
                image.width,
                image.height,
                image::ColorType::L8,
            )
            .map_err(|e| format!("Failed to encode JPEG: {}", e))?;
    } else if image.channels >= 3 {
        // RGB JPEG - display_data for multi-channel images contains interleaved
        // RGB bytes (channels * width * height). Extract 3 channels as RGB8.
        let pixel_count = (image.width as usize) * (image.height as usize);
        let rgb_data =
            if display_data.len() == pixel_count * image.channels as usize && image.channels >= 3 {
                // display_data has interleaved channel data; take the first 3 channels
                if image.channels == 3 {
                    display_data
                } else {
                    // channels > 3 (e.g. RGBA): strip extra channels, keep RGB
                    let mut rgb = Vec::with_capacity(pixel_count * 3);
                    for chunk in display_data.chunks_exact(image.channels as usize) {
                        rgb.push(chunk[0]);
                        rgb.push(chunk[1]);
                        rgb.push(chunk[2]);
                    }
                    rgb
                }
            } else {
                // Fallback: replicate mono data to RGB if display_data is single-channel
                let mut rgb = Vec::with_capacity(pixel_count * 3);
                for &v in &display_data[..pixel_count.min(display_data.len())] {
                    rgb.push(v);
                    rgb.push(v);
                    rgb.push(v);
                }
                rgb
            };

        encoder
            .write_image(&rgb_data, image.width, image.height, image::ColorType::Rgb8)
            .map_err(|e| format!("Failed to encode JPEG: {}", e))?;
    } else {
        return Err(format!(
            "Unsupported channel count {} for JPEG encoding",
            image.channels
        ));
    }

    Ok(())
}

/// Read a frame in any format the app opens, with its metadata and color
/// filter.
pub fn read_image(path: &std::path::Path) -> Result<ImageReadResult, String> {
    let (image, header) = read_frame(path).map_err(|e| e.to_string())?;
    let cfa = read_color_filter_array(&header);
    Ok(ImageReadResult { image, header, cfa })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The header comes back as the file holds it: typed values, card order,
    /// comments and COMMENT/HISTORY lines.
    #[test]
    fn read_image_keeps_the_header_as_written() {
        let dir = std::env::temp_dir().join(format!(
            "skotiq-read-image-header-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        let light = dir.join("light.fits");

        let image = ImageData::from_u16(2, 2, 1, &[100, 200, 300, 400]);
        let mut source = FitsHeader::new();
        source.set_string("OBJECT", "61");
        source.set_float("EXPTIME", 120.0);
        source.set_comment("EXPTIME", "exposure time (s)");
        source.set_int("GAIN", 100);
        source.set_bool("FOCUSED", true);
        source.set_string("DARKFILE", "/data/darks/master_dark.fits");
        source.add_comment("taken with Skotiq");
        source.add_history("calibrated");
        write_fits(&light, &image, &source).expect("write light frame");

        let read = read_image(&light).expect("read light frame");
        let header = &read.header;
        assert_eq!(header.get_string("OBJECT"), Some("61"));
        assert_eq!(header.get_float("EXPTIME"), Some(120.0));
        assert_eq!(header.get_comment("EXPTIME"), Some("exposure time (s)"));
        assert_eq!(header.get_int("GAIN"), Some(100));
        assert_eq!(header.get_bool("FOCUSED"), Some(true));
        assert_eq!(header.get_string("DARKFILE"), Some("/data/darks/master_dark.fits"));
        assert_eq!(header.comments, vec!["taken with Skotiq".to_string()]);
        assert_eq!(header.history, vec!["calibrated".to_string()]);
        let order: Vec<&str> = header
            .cards()
            .map(|(key, _, _)| key)
            .filter(|key| source.get(key).is_some())
            .collect();
        assert_eq!(order, ["OBJECT", "EXPTIME", "GAIN", "FOCUSED", "DARKFILE"]);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn to_display_u8_preserves_rgb_channel_differences_for_u16_images() {
        let image = ImageData::from_u16(1, 2, 3, &[65535, 0, 0, 0, 32768, 65535]);
        let display = image.to_display_u8();

        assert_eq!(display.len(), 6);
        assert!(display[0] > display[1]);
        assert!(display[0] > display[2]);
        assert!(display[5] >= display[4]);
    }

    #[test]
    fn to_rgba_returns_ok_for_supported_mono_layout() {
        // 2x2 mono u16 image; supported, must not error.
        let image = ImageData::from_u16(2, 2, 1, &[0, 32768, 32768, 65535]);
        let rgba = image
            .to_rgba()
            .expect("mono (1-channel) layout must be supported");
        assert_eq!(rgba.len(), 2 * 2 * 4);
        // Alpha channel must be fully opaque on every pixel.
        for px in rgba.as_chunks::<4>().0.iter() {
            assert_eq!(px[3], 255);
        }
    }

    #[test]
    fn to_rgba_returns_ok_for_supported_rgb_layout() {
        let image = ImageData::from_u16(1, 2, 3, &[65535, 0, 0, 0, 32768, 65535]);
        let rgba = image
            .to_rgba()
            .expect("3-channel RGB layout must be supported");
        // 1 x 2 pixels x 4 bytes (RGBA).
        assert_eq!(rgba.len(), 2 * 4);
    }

    #[test]
    fn to_rgba_returns_ok_for_supported_rgba_layout() {
        let image = ImageData {
            width: 1,
            height: 1,
            channels: 4,
            pixel_type: PixelType::U8,
            data: vec![10, 20, 30, 200],
            range: crate::SampleRange::of(PixelType::U8),
        };
        let rgba = image
            .to_rgba()
            .expect("4-channel RGBA layout must be supported");
        assert_eq!(rgba, vec![10, 20, 30, 200]);
    }

    #[test]
    fn to_rgba_returns_loud_error_on_unsupported_five_channel_layout() {
        // An unsupported channel count must surface a typed error naming the
        // count, never a gray buffer indistinguishable from a failed capture.
        let image = ImageData {
            width: 4,
            height: 4,
            channels: 5,
            pixel_type: PixelType::U16,
            data: vec![0u8; 4 * 4 * 5 * 2],
            range: crate::SampleRange::of(PixelType::U16),
        };

        let err = image
            .to_rgba()
            .expect_err("5-channel layout must surface an error, not a gray fallback");

        assert_eq!(
            err,
            ImageDisplayError::UnsupportedChannelLayout { channels: 5 }
        );

        // The display message must name the offending channel count so it is
        // useful in a snackbar / log without further inspection.
        let msg = err.to_string();
        assert!(
            msg.contains('5'),
            "error message must name the channel count, got: {msg}"
        );
        assert!(
            msg.to_lowercase().contains("channel"),
            "error message must reference channels, got: {msg}"
        );
    }

    #[test]
    fn to_rgba_returns_loud_error_on_zero_channel_layout() {
        // Degenerate-but-possible case from a corrupt header; must error,
        // not produce a gray buffer.
        let image = ImageData {
            width: 1,
            height: 1,
            channels: 0,
            pixel_type: PixelType::U16,
            data: vec![],
            range: crate::SampleRange::of(PixelType::U16),
        };
        assert_eq!(
            image.to_rgba().unwrap_err(),
            ImageDisplayError::UnsupportedChannelLayout { channels: 0 }
        );
    }

    /// RAII guard so the temp FITS fixture is removed even if an assertion panics.
    struct TempFitsFixture {
        path: std::path::PathBuf,
    }

    impl Drop for TempFitsFixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.path);
        }
    }

    /// Write a 2x2 mono u16 FITS frame to a unique temp path, optionally tagging
    /// it with a `BAYERPAT`/offset CFA header. Returns an RAII fixture whose
    /// `path` feeds `read_image`.
    fn write_temp_fits(suffix: &str, bayerpat: Option<(&str, i64, i64)>) -> TempFitsFixture {
        let image = ImageData::from_u16(2, 2, 1, &[0, 16384, 32768, 65535]);
        let mut header = fits::FitsHeader::new();
        if let Some((pat, x_off, y_off)) = bayerpat {
            header.set_string("BAYERPAT", pat);
            header.set_int("XBAYROFF", x_off);
            header.set_int("YBAYROFF", y_off);
        }
        let path = std::env::temp_dir().join(format!(
            "skotiq_read_image_bayer_{}_{}.fits",
            std::process::id(),
            suffix
        ));
        write_fits(&path, &image, &header).expect("write_fits should succeed");
        TempFitsFixture { path }
    }

    #[test]
    fn read_image_exposes_the_color_filter_of_cfa_fits() {
        let fixture = write_temp_fits("rggb", Some(("RGGB", 0, 0)));
        let result = read_image(&fixture.path).expect("read_image should succeed for CFA FITS");
        assert_eq!(result.cfa, Some(ColorFilterArray::Bayer(BayerPattern::RGGB)));
    }

    #[test]
    fn read_image_composes_subframe_offsets_into_the_color_filter() {
        // An odd X offset makes an RGGB sensor read GRBG at the crop's origin.
        let fixture = write_temp_fits("rggb_xoff", Some(("RGGB", 1, 0)));
        let result = read_image(&fixture.path).expect("read_image should succeed");
        assert_eq!(result.cfa, Some(ColorFilterArray::Bayer(BayerPattern::GRBG)));
    }

    #[test]
    fn read_image_reads_an_xtrans_bayerpat() {
        let letters = "GGRGGBGGBGGRBRGRBGGGBGGRGGRGGBRBGBRG";
        let fixture = write_temp_fits("xtrans", Some((letters, 0, 0)));
        let result = read_image(&fixture.path).expect("read_image should succeed");
        assert_eq!(result.cfa.map(|c| c.letters()).as_deref(), Some(letters));
    }

    #[test]
    fn read_image_yields_no_color_filter_for_mono_fits() {
        // A mono frame must never take the one-shot-color path.
        let fixture = write_temp_fits("mono", None);
        let result = read_image(&fixture.path).expect("read_image should succeed for mono FITS");
        assert_eq!(result.cfa, None);
    }
}
