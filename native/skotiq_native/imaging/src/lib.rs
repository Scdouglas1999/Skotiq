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
pub mod calibration_masters; // NEW: Master-flat build + cosmetic (hot/cold) correction
pub mod channel_combine; // NEW: Narrowband/LRGB channel combination
pub mod color_calibration; // NEW: Photometric color calibration (per-channel white balance)
pub mod color_composite;
pub mod deconvolution; // NEW: PSF estimation + Richardson-Lucy deconvolution
pub mod defect_map;
pub mod depthlock;
pub mod difference_image; // NEW: Difference imaging (Pillar B — First Light) transient detection
pub mod drizzle; // NEW: Drizzle (variable-pixel linear reconstruction) integration

mod camera;
mod debayer;
mod fits;
mod frame_shape; // Per-frame star size/shape for grading (local background, adaptive moments)
pub mod frame_weighting; // NEW: Per-sub quality weighting for batch integration
pub mod integration; // NEW: Advanced weighted batch integration + pixel rejection
pub mod master_accumulation; // NEW: Multi-night accumulating master frame
pub mod mosaic_stitch; // NEW: WCS-driven panel mosaic stitching
mod naming;
pub mod normalization; // NEW: Light-frame normalization to a reference (batch integration)
pub mod optimizer; // NEW: Marginal-SNR integration optimizer (subset recommendation)
mod phd2;
mod platesolve;
mod processing; // NEW: Tiled image processing
mod raw; // NEW: RAW file support
mod reader; // NEW: Memory-mapped readers
pub mod recipe; // Darkroom recipe engine: non-destructive, replayable op stack
pub mod registration; // NEW: High-quality star-based registration
mod robust_stats; // The crate's one set of order statistics (median / percentile conventions)
pub mod sky_atlas; // NEW: HEALPix-tiled additive all-sky accumulator (the 5.0 keystone)
pub mod stack_master; // NEW: the live stack's FITS master (synthesized EXPTIME/DATE-OBS)
pub mod stacking;
mod star_detect; // Star detection: background/noise maps, matched filter, deblending
pub mod star_reduction; // NEW: Star-size reduction (morphological + screen recombine)
mod stats;
mod stretch;
pub mod wcs_sip; // NEW: SIP-aware (CD + forward/inverse SIP) gnomonic projection
mod xisf;

pub use background_extraction::*; // NEW: Export background-extraction types
pub use buffer_pool::*;
pub use calibration::*;
pub use calibration_masters::*; // NEW: Export master-flat / cosmetic-correction types
pub use camera::*;
pub use channel_combine::*; // NEW: Export channel-combination types
pub use color_calibration::*; // NEW: Export color-calibration types
pub use debayer::*;
pub use deconvolution::*; // NEW: Export deconvolution types
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
pub use processing::*; // NEW: Export processing types
pub use raw::*; // NEW: Export RAW types
pub use reader::*; // NEW: Export reader types
pub use registration::*; // NEW: Export registration types
pub use sky_atlas::*; // NEW: Export sky-atlas (keystone) types
pub use star_reduction::*; // NEW: Export star-reduction types
pub use stats::*;
pub use stretch::*;
pub use wcs_sip::*; // NEW: Export SIP-aware projection types
pub use xisf::*;

use rayon::prelude::*;

/// Image format supported by Skotiq
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ImageFormat {
    #[default]
    Fits,
    Xisf,
    Tiff,
    Png,
    Jpeg,
    // RAW formats
    CanonCR2,
    CanonCR3,
    NikonNEF,
    SonyARW,
    FujifilmRAF,
    PentaxPEF,
    OlympusORF,
    PanasonicRW2,
    GenericRAW,
}

impl ImageFormat {
    /// Get the file extension for this format
    pub fn extension(&self) -> &'static str {
        match self {
            ImageFormat::Fits => "fits",
            ImageFormat::Xisf => "xisf",
            ImageFormat::Tiff => "tiff",
            ImageFormat::Png => "png",
            ImageFormat::Jpeg => "jpg",
            ImageFormat::CanonCR2 => "cr2",
            ImageFormat::CanonCR3 => "cr3",
            ImageFormat::NikonNEF => "nef",
            ImageFormat::SonyARW => "arw",
            ImageFormat::FujifilmRAF => "raf",
            ImageFormat::PentaxPEF => "pef",
            ImageFormat::OlympusORF => "orf",
            ImageFormat::PanasonicRW2 => "rw2",
            ImageFormat::GenericRAW => "raw",
        }
    }

    /// Parse from file extension
    pub fn from_extension(ext: &str) -> Option<Self> {
        match ext.to_lowercase().as_str() {
            "fits" | "fit" | "fts" => Some(ImageFormat::Fits),
            "xisf" => Some(ImageFormat::Xisf),
            "tiff" | "tif" => Some(ImageFormat::Tiff),
            "png" => Some(ImageFormat::Png),
            "jpg" | "jpeg" => Some(ImageFormat::Jpeg),
            // RAW formats
            "cr2" => Some(ImageFormat::CanonCR2),
            "cr3" => Some(ImageFormat::CanonCR3),
            "nef" | "nrw" => Some(ImageFormat::NikonNEF),
            "arw" | "srf" | "sr2" => Some(ImageFormat::SonyARW),
            "raf" => Some(ImageFormat::FujifilmRAF),
            "pef" | "dng" => Some(ImageFormat::PentaxPEF),
            "orf" => Some(ImageFormat::OlympusORF),
            "rw2" => Some(ImageFormat::PanasonicRW2),
            "raw" | "crw" | "mrw" | "erf" | "3fr" => Some(ImageFormat::GenericRAW),
            _ => None,
        }
    }

    /// Detect image format from magic bytes (file signature)
    /// Returns None if format cannot be determined
    pub fn from_magic_bytes(data: &[u8]) -> Option<Self> {
        if data.len() < 16 {
            return None;
        }

        // FITS: "SIMPLE  ="
        if data.starts_with(b"SIMPLE  =") {
            return Some(ImageFormat::Fits);
        }

        // XISF: "XISF0100"
        if data.starts_with(b"XISF0100") {
            return Some(ImageFormat::Xisf);
        }

        // TIFF: "II" (little-endian) or "MM" (big-endian) followed by 42 (0x2A)
        if (data[0..2] == [0x49, 0x49] || data[0..2] == [0x4D, 0x4D])
            && (data[2] == 0x2A || data[3] == 0x2A)
        {
            // Could be TIFF or various RAW formats that use TIFF container
            // Check for specific RAW signatures

            // Canon CR2: TIFF header + "CR" at offset 8-9
            if data.len() > 10 && &data[8..10] == b"CR" {
                return Some(ImageFormat::CanonCR2);
            }

            // Nikon NEF: Check for "NIKON" in first 1024 bytes
            if data.len() > 1024 && data[..1024].windows(5).any(|w| w == b"NIKON") {
                return Some(ImageFormat::NikonNEF);
            }

            // Sony ARW: Check for "SONY" signature
            if data.len() > 1024 && data[..1024].windows(4).any(|w| w == b"SONY") {
                return Some(ImageFormat::SonyARW);
            }

            // Olympus ORF: Check for "OLYMP" signature
            if data.len() > 1024 && data[..1024].windows(5).any(|w| w == b"OLYMP") {
                return Some(ImageFormat::OlympusORF);
            }

            // Pentax PEF: Check for "PENTAX" signature
            if data.len() > 1024 && data[..1024].windows(6).any(|w| w == b"PENTAX") {
                return Some(ImageFormat::PentaxPEF);
            }

            // Panasonic RW2: Check for "Panasonic"
            if data.len() > 1024 && data[..1024].windows(9).any(|w| w == b"Panasonic") {
                return Some(ImageFormat::PanasonicRW2);
            }

            // Generic TIFF if no RAW signature found
            return Some(ImageFormat::Tiff);
        }

        // Canon CR3: ISO Base Media File Format (ftyp box)
        if data.len() > 12
            && &data[4..8] == b"ftyp"
            && (&data[8..12] == b"crx " || data[8..11] == *b"cr3")
        {
            return Some(ImageFormat::CanonCR3);
        }

        // Fujifilm RAF: "FUJIFILMCCD-RAW"
        if data.starts_with(b"FUJIFILMCCD-RAW") {
            return Some(ImageFormat::FujifilmRAF);
        }

        // PNG: 0x89 "PNG" 0x0D 0x0A 0x1A 0x0A
        if data.starts_with(&[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return Some(ImageFormat::Png);
        }

        // JPEG: 0xFF 0xD8 0xFF
        if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
            return Some(ImageFormat::Jpeg);
        }

        None
    }

    /// Check if this format is a RAW camera format
    pub fn is_raw(&self) -> bool {
        matches!(
            self,
            ImageFormat::CanonCR2
                | ImageFormat::CanonCR3
                | ImageFormat::NikonNEF
                | ImageFormat::SonyARW
                | ImageFormat::FujifilmRAF
                | ImageFormat::PentaxPEF
                | ImageFormat::OlympusORF
                | ImageFormat::PanasonicRW2
                | ImageFormat::GenericRAW
        )
    }

    /// Check if this format can be processed by LibRaw
    pub fn is_libraw_supported(&self) -> bool {
        self.is_raw()
    }
}

/// Pixel data types
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
    /// Get the number of bytes per pixel
    pub fn byte_size(&self) -> usize {
        match self {
            PixelType::U8 => 1,
            PixelType::U16 => 2,
            PixelType::U32 | PixelType::F32 => 4,
            PixelType::F64 => 8,
        }
    }

    /// Get the bit depth
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

/// Image data container
#[derive(Debug, Clone)]
pub struct ImageData {
    pub width: u32,
    pub height: u32,
    pub channels: u32,
    pub pixel_type: PixelType,
    pub data: Vec<u8>,
}

impl Default for ImageData {
    fn default() -> Self {
        Self::new(0, 0, 1, PixelType::U16)
    }
}

impl ImageData {
    /// Create a new image with the given dimensions
    pub fn new(width: u32, height: u32, channels: u32, pixel_type: PixelType) -> Self {
        let bytes_per_pixel = pixel_type.byte_size();
        let size = (width as usize) * (height as usize) * (channels as usize) * bytes_per_pixel;

        Self {
            width,
            height,
            channels,
            pixel_type,
            data: vec![0u8; size],
        }
    }

    /// Get the number of bytes per pixel
    pub fn bytes_per_pixel(&self) -> usize {
        self.pixel_type.byte_size()
    }

    /// Get the total size in bytes
    pub fn size_bytes(&self) -> usize {
        self.data.len()
    }

    /// Get total pixel count
    pub fn pixel_count(&self) -> usize {
        (self.width as usize) * (self.height as usize) * (self.channels as usize)
    }

    /// Check if image has data
    pub fn is_empty(&self) -> bool {
        self.width == 0 || self.height == 0 || self.data.is_empty()
    }

    /// Get image data as u16 slice (for 16-bit images)
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

    /// Get image data as f32 slice
    pub fn as_f32(&self) -> Option<Vec<f32>> {
        if self.pixel_type != PixelType::F32 {
            return None;
        }

        Some(
            self.data
                .as_chunks::<4>()
                .0
                .iter()
                .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
                .collect(),
        )
    }

    /// Create from u16 data
    pub fn from_u16(width: u32, height: u32, channels: u32, data: &[u16]) -> Self {
        let bytes: Vec<u8> = data.iter().flat_map(|&v| v.to_le_bytes()).collect();

        Self {
            width,
            height,
            channels,
            pixel_type: PixelType::U16,
            data: bytes,
        }
    }

    /// Create from f32 data
    pub fn from_f32(width: u32, height: u32, channels: u32, data: &[f32]) -> Self {
        let bytes: Vec<u8> = data.iter().flat_map(|&v| v.to_le_bytes()).collect();

        Self {
            width,
            height,
            channels,
            pixel_type: PixelType::F32,
            data: bytes,
        }
    }

    /// Convert to 8-bit for display (auto-stretched)
    pub fn to_display_u8(&self) -> Vec<u8> {
        if self.pixel_type == PixelType::U16 {
            if self.channels == 3 {
                if let Some(rgb_data) = self.as_u16() {
                    let (r_params, g_params, b_params) =
                        auto_stretch_rgb(&rgb_data, self.width, self.height);
                    let pixel_count = (self.width * self.height) as usize;
                    let mut stretched = vec![0u8; pixel_count * 3];
                    let channel_params = [&r_params, &g_params, &b_params];

                    for idx in 0..pixel_count {
                        for (channel, params) in channel_params.iter().enumerate() {
                            let normalized = rgb_data[idx * 3 + channel] as f64 / 65535.0;
                            let range = params.highlights - params.shadows;
                            let value = if range <= 0.0 {
                                0.0
                            } else {
                                let stretched_value =
                                    ((normalized - params.shadows) / range).clamp(0.0, 1.0);
                                display_mtf(stretched_value, params.midtones)
                            };
                            stretched[idx * 3 + channel] = (value.clamp(0.0, 1.0) * 255.0) as u8;
                        }
                    }

                    stretched
                } else {
                    vec![0u8; self.pixel_count()]
                }
            } else {
                let params = auto_stretch_stf(self);
                apply_stretch(self, &params)
            }
        } else {
            // For other types, simple linear conversion
            match self.pixel_type {
                PixelType::U8 => self.data.clone(),
                PixelType::F32 => {
                    // Parallel conversion for F32
                    self.data
                        .par_chunks_exact(4)
                        .map(|chunk| {
                            let val = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                            (val.clamp(0.0, 1.0) * 255.0) as u8
                        })
                        .collect()
                }
                _ => vec![128u8; self.pixel_count()],
            }
        }
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
        let grayscale = self.to_display_u8();

        match self.channels {
            // Mono camera FITS or grayscale images
            1 => {
                // Convert grayscale to RGBA by replicating to R=G=B
                // Parallel processing for large images
                Ok(grayscale
                    .par_iter()
                    .flat_map(|&v| [v, v, v, 255u8])
                    .collect())
            }

            // Fujifilm X-Trans RGB or Bayer demosaiced RGB
            3 => {
                // Add alpha channel to RGB data
                // Parallel processing
                Ok(grayscale
                    .par_chunks_exact(3)
                    .flat_map(|chunk| [chunk[0], chunk[1], chunk[2], 255u8])
                    .collect())
            }

            // Already RGBA (some TIFFs, PNGs)
            4 => Ok(grayscale),

            // Unsupported channel count: fail loudly so the caller can surface
            // a real error to the user instead of displaying a gray placeholder.
            other => Err(ImageDisplayError::UnsupportedChannelLayout { channels: other }),
        }
    }
}

fn display_mtf(x: f64, m: f64) -> f64 {
    if x <= 0.0 {
        0.0
    } else if x >= 1.0 {
        1.0
    } else if (x - m).abs() < f64::EPSILON {
        0.5
    } else {
        let numerator = (m - 1.0) * x;
        let denominator = (2.0 * m - 1.0) * x - m;
        if denominator.abs() < f64::EPSILON {
            0.5
        } else {
            numerator / denominator
        }
    }
}

/// Image read result
#[derive(Debug)]
pub struct ImageReadResult {
    pub image: ImageData,
    pub format: ImageFormat,
    pub header: std::collections::HashMap<String, String>,
    /// Parsed Bayer/CFA geometry for the frame, when the source format records it.
    ///
    /// Why: the `header` HashMap flattens every keyword through `format!("{:?}")`,
    /// which quotes string values (e.g. `BAYERPAT` becomes `"\"RGGB\""`) and loses
    /// the offset composition — making it unreliable as the OSC-detection signal.
    /// This field carries the geometry parsed by [`read_bayer_geometry`] directly
    /// from the typed FITS header, with `XBAYROFF`/`YBAYROFF` already composed into
    /// `effective`. `None` means the frame is mono / not a CFA frame, or the format
    /// (XISF, RAW) does not surface a Bayer pattern through this reader path.
    pub bayer: Option<BayerGeometry>,
}

// Image writing functions

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
        // 8-bit mono
        (1, PixelType::U8) => {
            let img: GrayImage =
                ImageBuffer::from_raw(image.width, image.height, image.data.clone())
                    .ok_or_else(|| "Failed to create grayscale image buffer".to_string())?;
            img.save(path)
                .map_err(|e| format!("Failed to save TIFF: {}", e))?;
        }
        // 16-bit RGB
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
        // 8-bit RGB
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
        // 16-bit mono
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
        // 8-bit mono
        (1, PixelType::U8) => {
            let img: GrayImage =
                ImageBuffer::from_raw(image.width, image.height, image.data.clone())
                    .ok_or_else(|| "Failed to create grayscale image buffer".to_string())?;
            img.save(path)
                .map_err(|e| format!("Failed to save PNG: {}", e))?;
        }
        // 16-bit RGB
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
        // 8-bit RGB
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
        // Grayscale JPEG
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

/// Read an image file (auto-detect format)
pub fn read_image(path: &std::path::Path) -> Result<ImageReadResult, String> {
    // Why: path with no extension OR with a non-UTF-8 extension
    // returns empty string; `ImageFormat::from_extension("")` returns None and the
    // ?-propagating ok_or_else fails CLOSED with "Unsupported file extension:" on the
    // next line. Silent fallback to empty is the correct funneling into the error
    // path.
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");

    let format = ImageFormat::from_extension(ext)
        .ok_or_else(|| format!("Unsupported file extension: {}", ext))?;

    match format {
        ImageFormat::Fits => {
            let (image, fits_header) = read_fits(path).map_err(|e| e.to_string())?;

            // Why: read the typed Bayer geometry BEFORE `fits_header.keywords`
            // is consumed into the flattened HashMap below. The flattened form
            // is value text with the type discarded, so the typed header is the
            // only place the geometry can be parsed without guessing.
            let bayer = read_bayer_geometry(&fits_header);

            let header: std::collections::HashMap<String, String> = fits_header
                .keywords
                .into_iter()
                .map(|(k, v)| (k, v.to_header_string()))
                .collect();

            Ok(ImageReadResult {
                image,
                format,
                header,
                bayer,
            })
        }
        ImageFormat::Xisf => {
            let (image, xisf_metadata) = read_xisf(path).map_err(|e| e.to_string())?;

            // `fits_keywords` already arrive as on-card value text; the XISF
            // properties are typed, so they get the same treatment the FITS
            // branch gives `FitsValue`.
            let mut header: std::collections::HashMap<String, String> = xisf_metadata.fits_keywords;
            for (k, v) in xisf_metadata.properties {
                header.insert(k, v.to_header_string());
            }

            Ok(ImageReadResult {
                image,
                format,
                header,
                // Why: the XISF reader exposes CFA metadata only as flattened FITS
                // keywords/properties (already in `header`); there is no typed
                // geometry parse on this path, so we report `None` rather than
                // guess from the stringified values. OSC detection for XISF is
                // handled separately at the metadata layer.
                bayer: None,
            })
        }
        // Handle all RAW formats
        ImageFormat::CanonCR2
        | ImageFormat::CanonCR3
        | ImageFormat::NikonNEF
        | ImageFormat::SonyARW
        | ImageFormat::FujifilmRAF
        | ImageFormat::PentaxPEF
        | ImageFormat::OlympusORF
        | ImageFormat::PanasonicRW2
        | ImageFormat::GenericRAW => {
            let (image, raw_metadata) = read_raw(path, None).map_err(|e| e.to_string())?;

            // Convert raw metadata to hashmap
            let mut header = std::collections::HashMap::new();
            header.insert("MAKE".to_string(), raw_metadata.camera_make);
            header.insert("MODEL".to_string(), raw_metadata.camera_model);

            if let Some(iso) = raw_metadata.iso_speed {
                header.insert("ISO".to_string(), iso.to_string());
            }
            if let Some(shutter) = raw_metadata.shutter_speed {
                header.insert("EXPTIME".to_string(), shutter.to_string());
            }
            if let Some(aperture) = raw_metadata.aperture {
                header.insert("APERTURE".to_string(), aperture.to_string());
            }
            if let Some(focal) = raw_metadata.focal_length {
                header.insert("FOCALLEN".to_string(), focal.to_string());
            }
            if let Some(ts) = raw_metadata.timestamp {
                if let Some(dt) = chrono::DateTime::<chrono::Utc>::from_timestamp(ts, 0) {
                    header.insert("DATETIME".to_string(), dt.to_rfc3339());
                } else {
                    header.insert("DATETIME".to_string(), ts.to_string());
                }
            }

            Ok(ImageReadResult {
                image,
                format,
                header,
                // Why: LibRaw decodes RAW frames into the demosaiced RGB image
                // already (the returned `image` is not a CFA mosaic), so there is
                // no Bayer geometry to apply downstream — `None` is correct here.
                bayer: None,
            })
        }
        _ => Err(format!(
            "Reading {:?} is not supported by the current image reader pipeline",
            format
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A calibrated frame must inherit the light frame's science metadata as
    /// real FITS cards.
    ///
    /// The calibrate-and-save path reads the light with `read_image`, carries
    /// `ImageReadResult::header` over into a fresh `FitsHeader`, and writes it.
    /// While the flattening used `format!("{:?}", value)` that shipped
    /// `EXPTIME  = 'Float(120.0)'` and `GAIN = 'Integer(100)'` — every value a
    /// string carrying its Rust variant name, so our own `get_float` and every
    /// external tool read nothing.
    #[test]
    fn calibrated_frame_header_carries_numeric_exptime_and_gain() {
        let dir = std::env::temp_dir().join(format!(
            "skotiq-header-carry-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        let light = dir.join("light.fits");
        let calibrated = dir.join("calibrated.fits");

        let image = ImageData::from_u16(2, 2, 1, &[100, 200, 300, 400]);
        let mut source = FitsHeader::new();
        source.set_float("EXPTIME", 120.0);
        source.set_int("GAIN", 100);
        source.set_string("FILTER", "Ha");
        source.set_bool("FOCUSED", true);
        source.set_string("DARKFILE", "/data/darks/master_dark.fits");
        write_fits(&light, &image, &source).expect("write light frame");

        let read = read_image(&light).expect("read light frame");

        // The flattened header must carry plain value text, never Rust Debug.
        for (key, value) in &read.header {
            assert!(
                !value.contains("Float(")
                    && !value.contains("Integer(")
                    && !value.contains("String(")
                    && !value.contains("Boolean("),
                "{key} flattened to Rust variant syntax: {value}"
            );
        }
        assert_eq!(
            read.header.get("EXPTIME").map(String::as_str),
            Some("120.0")
        );
        assert_eq!(read.header.get("GAIN").map(String::as_str), Some("100"));
        assert_eq!(read.header.get("FILTER").map(String::as_str), Some("Ha"));

        // Reproduce the calibrate-and-save carry-over.
        let mut carried = FitsHeader::new();
        for (key, value) in &read.header {
            carried.set_value_token(key, value);
        }
        carried.set_string("CALSTAT", "calibrated by Skotiq");
        write_fits(&calibrated, &image, &carried).expect("write calibrated frame");

        let (_, round_tripped) = read_fits(&calibrated).expect("read calibrated frame");
        assert_eq!(round_tripped.get_float("EXPTIME"), Some(120.0));
        assert_eq!(round_tripped.get_int("GAIN"), Some(100));
        assert_eq!(round_tripped.get_string("FILTER"), Some("Ha"));
        assert_eq!(
            round_tripped.get("FOCUSED").and_then(|v| v.as_bool()),
            Some(true)
        );
        // A path value must survive intact: it is not a card body, so the
        // `/ comment` split must not be applied to it.
        assert_eq!(
            round_tripped.get_string("DARKFILE"),
            Some("/data/darks/master_dark.fits")
        );
        assert_eq!(
            round_tripped.get_string("CALSTAT"),
            Some("calibrated by Skotiq")
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A caller that has not migrated off `set_string` must still get a clean,
    /// readable string card out of the flattened header — never the doubly
    /// quoted `'''Ha'''` that quoting the flattened text would produce.
    #[test]
    fn flattened_header_survives_a_plain_set_string_carry_over() {
        let dir = std::env::temp_dir().join(format!(
            "skotiq-header-setstring-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        let light = dir.join("light.fits");
        let copy = dir.join("copy.fits");

        let image = ImageData::from_u16(2, 2, 1, &[1, 2, 3, 4]);
        let mut source = FitsHeader::new();
        source.set_string("FILTER", "Ha");
        source.set_float("EXPTIME", 120.0);
        write_fits(&light, &image, &source).expect("write light frame");

        let read = read_image(&light).expect("read light frame");
        let mut carried = FitsHeader::new();
        for (key, value) in &read.header {
            carried.set_string(key, value);
        }
        write_fits(&copy, &image, &carried).expect("write copy");

        let (_, round_tripped) = read_fits(&copy).expect("read copy");
        assert_eq!(round_tripped.get_string("FILTER"), Some("Ha"));
        assert_eq!(round_tripped.get_string("EXPTIME"), Some("120.0"));

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
    fn read_image_exposes_bayer_geometry_for_cfa_fits() {
        // A FITS frame tagged BAYERPAT='RGGB' (no offsets) must surface a
        // populated, typed geometry on the read result — not a quoted/unreliable
        // string buried in the flattened `header` HashMap.
        let fixture = write_temp_fits("rggb", Some(("RGGB", 0, 0)));

        let result = read_image(&fixture.path).expect("read_image should succeed for CFA FITS");

        assert_eq!(result.format, ImageFormat::Fits);
        let geo = result
            .bayer
            .expect("CFA FITS with BAYERPAT must yield a parsed BayerGeometry");
        assert_eq!(geo.effective, BayerPattern::RGGB);
        assert_eq!(geo.source, BayerPattern::RGGB);
        assert_eq!(geo.x_offset, 0);
        assert_eq!(geo.y_offset, 0);
    }

    #[test]
    fn read_image_composes_bayer_offsets_for_cfa_fits() {
        // Odd X offset shifts RGGB to GRBG at the in-memory origin; the read
        // result's `effective` must reflect the composition, while `source`
        // preserves the on-disk BAYERPAT (regression guard).
        let fixture = write_temp_fits("rggb_xoff", Some(("RGGB", 1, 0)));

        let result = read_image(&fixture.path).expect("read_image should succeed");
        let geo = result.bayer.expect("CFA FITS must yield geometry");

        assert_eq!(geo.source, BayerPattern::RGGB);
        assert_eq!(geo.effective, BayerPattern::GRBG);
        assert_eq!(geo.x_offset, 1);
        assert_eq!(geo.y_offset, 0);
    }

    #[test]
    fn read_image_yields_none_bayer_for_mono_fits() {
        // A mono FITS frame (no BAYERPAT) must report `bayer == None` so the OSC
        // path is never falsely triggered for a monochrome capture.
        let fixture = write_temp_fits("mono", None);

        let result = read_image(&fixture.path).expect("read_image should succeed for mono FITS");

        assert_eq!(result.format, ImageFormat::Fits);
        assert!(
            result.bayer.is_none(),
            "mono FITS (no BAYERPAT) must yield bayer == None, got {:?}",
            result.bayer
        );
    }
}
