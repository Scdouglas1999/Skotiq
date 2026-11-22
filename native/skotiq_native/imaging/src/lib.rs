//! Skotiq Imaging Library
//!
//! Provides real image I/O, processing, and analysis functionality:
//! - FITS file reading and writing
//! - XISF file support (PixInsight format)
//! - Image debayering for color cameras
//! - Image statistics and star detection
//! - Auto-stretch algorithms
//! - Buffer pooling for efficient image capture

mod airmass;
pub mod atomic_file;
pub mod background_extraction;
pub mod calibration;
pub mod calibration_master_stream;
pub mod calibration_masters;
pub mod color_calibration;
pub mod deconvolution;
pub mod defect_map;
pub mod depthlock;
pub mod detection_plane;
pub mod difference_image;
pub mod drizzle;

mod debayer;
mod fits;
pub mod fits_layout;
pub mod fits_reader;
mod frame_cutouts;
mod frame_io;
mod frame_shape;
mod frame_validation;
pub mod frame_weighting;
pub mod integration;
pub mod live_stack_stretch;
pub mod master_accumulation;
pub mod mosaic_stitch;
pub mod normalization;
mod numeric;
pub mod optimizer;
pub mod product_header;
mod raster;
mod raw;
mod raw_exif;
pub mod recipe;
pub mod registration;
mod resample;
mod robust_stats;
pub mod sample_range;
pub mod samples;
pub mod sky_atlas;
pub mod stack_master;
pub mod stacking;
mod star_detect;
mod stats;
mod stretch;
mod thumbnail;
mod trail;
pub mod wcs_sip;
pub mod xisf;

pub use airmass::calculate_airmass;
pub use background_extraction::*;
pub use calibration::*;
pub use calibration_masters::*;
pub use color_calibration::*;
pub use debayer::*;
pub use deconvolution::*;
pub use detection_plane::{ChannelCollapse, DetectionPlane, Quantize};
pub use difference_image::*;
pub use drizzle::*;
pub use fits::*;
pub use frame_cutouts::read_frame_cutouts;
pub use frame_io::*;
pub use frame_shape::*;
pub use frame_validation::*;
pub use frame_weighting::*;
pub use integration::*;
pub use master_accumulation::*;
pub use mosaic_stitch::*;
pub use normalization::*;
pub use optimizer::*;
pub use product_header::{acquisition, CalibrationMarks, MasterProvenance, ProductCards};
pub use raster::{write_raster, RasterError, RasterFormat, DEFAULT_JPEG_QUALITY};
pub use raw::*;
pub use registration::*;
pub use sample_range::{SampleRange, ADU_FULL_SCALE};
pub use skotiq_frame::{
    Acquisition, AgreementPolicy, BayerColor, BayerPattern, CardReading, ColorFilterArray,
    Disagreement, ExposureTolerance, FrameKind, FrameType, NumberMatch, Setting, XTransPattern,
};
pub use sky_atlas::*;
pub use stats::*;
pub use stretch::*;
pub use thumbnail::thumbnail;
pub use trail::{measure_frame_trail, FrameTrail, TRAIL_MIN_AXIS_RATIO};
pub use wcs_sip::*;
pub use xisf::{
    read_xisf_unit, ChecksumAlgorithm, XisfCodec, XisfCompression, XisfError, XisfUnit,
    XisfWriteOptions,
};

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

    /// The samples of an `F32` image as it stores them, whatever its sample
    /// range; `None` for another type. For data that is not brightness (a
    /// coverage or weight map) and for tests; an algorithm reads
    /// [`ImageData::samples_f32`].
    pub fn as_f32(&self) -> Option<Vec<f32>> {
        (self.pixel_type == PixelType::F32).then(|| self.stored_f32())
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
        assert_eq!(
            header.get_string("DARKFILE"),
            Some("/data/darks/master_dark.fits")
        );
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
        assert_eq!(
            result.cfa,
            Some(ColorFilterArray::Bayer(BayerPattern::Rggb))
        );
    }

    #[test]
    fn read_image_composes_subframe_offsets_into_the_color_filter() {
        // An odd X offset makes an RGGB sensor read GRBG at the crop's origin.
        let fixture = write_temp_fits("rggb_xoff", Some(("RGGB", 1, 0)));
        let result = read_image(&fixture.path).expect("read_image should succeed");
        assert_eq!(
            result.cfa,
            Some(ColorFilterArray::Bayer(BayerPattern::Grbg))
        );
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
