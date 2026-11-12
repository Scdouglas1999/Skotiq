//! Camera raw files (CR2, CR3, NEF, ARW, RAF, PEF, DNG, ORF, RW2 and every
//! other format LibRaw reads) as linear sensor data.
//!
//! A raw frame is the visible part of the sensor's color-filter mosaic, one
//! sample per pixel at the sensor's own bit depth, exactly as the camera
//! recorded it: not demosaiced, not white balanced, no tone curve, black level
//! not subtracted. That is the data calibration and stacking need, the same
//! shape a one-shot-color astronomy camera delivers.
//!
//! LibRaw does the decoding. Every read of its structs happens in
//! `libraw_shim.c`, which build.rs compiles against the headers of the linked
//! library, so struct layouts always agree with the library at run time.

use crate::{ColorFilterArray, FitsHeader, ImageData};
use std::ffi::CStr;
use std::os::raw::{c_char, c_float, c_int, c_longlong, c_uint, c_ushort, c_void};
use std::path::Path;

const LIBRAW_SUCCESS: c_int = 0;

/// LibRaw's value for a temperature the camera did not record.
const NOT_RECORDED: f32 = -1000.0;

#[repr(C)]
struct libraw_data_t {
    _private: [u8; 0],
}

/// Mirrors `skotiq_raw_info_t` in libraw_shim.c field for field.
#[repr(C)]
struct RawInfoFfi {
    make: [c_char; 64],
    model: [c_char; 64],
    lens: [c_char; 128],
    iso: c_float,
    shutter: c_float,
    aperture: c_float,
    focal_length: c_float,
    timestamp: c_longlong,
    sensor_temperature: c_float,
    sensor_temperature2: c_float,
    camera_temperature: c_float,
    width: c_int,
    height: c_int,
    top_margin: c_int,
    left_margin: c_int,
    raw_width: c_int,
    raw_height: c_int,
    raw_bps: c_int,
    white_level: c_uint,
    filters: c_uint,
    colors: c_int,
    dng_version: c_int,
    cfa_size: c_int,
    cfa: [c_char; 36],
    cfa_black: [c_uint; 36],
    has_mosaic: c_int,
}

extern "C" {
    fn skotiq_raw_describe(data: *mut libraw_data_t, info: *mut RawInfoFfi) -> c_int;
    fn skotiq_raw_copy_mosaic(data: *mut libraw_data_t, out: *mut c_ushort, out_len: usize)
        -> c_int;
}

#[cfg_attr(target_os = "windows", link(name = "libraw"))]
#[cfg_attr(not(target_os = "windows"), link(name = "raw"))]
extern "C" {
    fn libraw_init(flags: c_uint) -> *mut libraw_data_t;
    #[cfg(not(windows))]
    fn libraw_open_file(data: *mut libraw_data_t, path: *const c_char) -> c_int;
    #[cfg(windows)]
    fn libraw_open_wfile(data: *mut libraw_data_t, path: *const u16) -> c_int;
    fn libraw_open_buffer(data: *mut libraw_data_t, buffer: *const c_void, size: usize) -> c_int;
    fn libraw_unpack(data: *mut libraw_data_t) -> c_int;
    fn libraw_close(data: *mut libraw_data_t);
    fn libraw_strerror(errorcode: c_int) -> *const c_char;
}

#[derive(Debug)]
pub enum RawError {
    Io(std::io::Error),
    /// LibRaw could not open or decode the file; the text is LibRaw's.
    Decode(String),
    /// The file decodes, but not to one color-filter mosaic the app can
    /// calibrate (linear DNG, sRAW, Foveon, a CMYG or 16×16 filter).
    Unsupported(String),
}

impl std::fmt::Display for RawError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RawError::Io(e) => write!(f, "{e}"),
            RawError::Decode(e) => write!(f, "the camera raw file could not be decoded: {e}"),
            RawError::Unsupported(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for RawError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            RawError::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<std::io::Error> for RawError {
    fn from(e: std::io::Error) -> Self {
        RawError::Io(e)
    }
}

/// The camera maker, for the few facts makers record differently.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Maker {
    Canon,
    Nikon,
    Sony,
    Fujifilm,
    /// Pentax and Ricoh bodies share one maker-note format.
    Pentax,
    /// Olympus and OM Digital Solutions (OM System).
    Olympus,
    Panasonic,
    Other,
}

impl Maker {
    /// From LibRaw's normalized make (`idata.make`).
    pub fn from_make(make: &str) -> Self {
        let make = make.to_ascii_lowercase();
        if make.starts_with("canon") {
            Maker::Canon
        } else if make.starts_with("nikon") {
            Maker::Nikon
        } else if make.starts_with("sony") {
            Maker::Sony
        } else if make.starts_with("fuji") {
            Maker::Fujifilm
        } else if make.starts_with("pentax") || make.starts_with("ricoh") {
            Maker::Pentax
        } else if make.starts_with("olympus") || make.starts_with("om digital") {
            Maker::Olympus
        } else if make.starts_with("panasonic") || make.starts_with("leica") {
            // Leica's L-mount and compact bodies are Panasonic-made and write
            // Panasonic maker notes.
            Maker::Panasonic
        } else {
            Maker::Other
        }
    }

    /// Whether this maker's camera-body temperature is the reading to match
    /// darks on when the sensor itself has none.
    ///
    /// Canon writes only `CameraTemperature`, measured on the sensor board,
    /// which EOS capture tools report as the sensor temperature. LibRaw reads
    /// Pentax's `CameraTemperature` but not its `SensorTemperature`. Olympus,
    /// Sony, Nikon, Panasonic and Fujifilm either record the sensor itself or
    /// only an ambient or body value that does not track the sensor.
    fn body_temperature_stands_for_sensor(self) -> bool {
        matches!(self, Maker::Canon | Maker::Pentax)
    }
}

/// Where a frame's temperature reading comes from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TemperatureSource {
    Sensor,
    CameraBody,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SensorTemperature {
    pub celsius: f32,
    pub source: TemperatureSource,
}

/// What the camera recorded about a frame, in the app's terms.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RawMetadata {
    pub make: String,
    pub model: String,
    pub lens: Option<String>,
    pub iso: Option<f32>,
    pub exposure_seconds: Option<f64>,
    pub f_number: Option<f32>,
    pub focal_length_mm: Option<f32>,
    /// The camera clock read as local time on this computer, as LibRaw reads
    /// it: right when the camera is set to the local time zone.
    pub captured_at: Option<chrono::DateTime<chrono::Utc>>,
    pub temperature: Option<SensorTemperature>,
}

impl RawMetadata {
    pub fn maker(&self) -> Maker {
        Maker::from_make(&self.make)
    }
}

/// A camera raw frame: the visible color-filter mosaic and what describes it.
#[derive(Debug, Clone)]
pub struct RawFrame {
    pub width: u32,
    pub height: u32,
    /// Row-major, `width * height` samples, black level not subtracted.
    pub data: Vec<u16>,
    pub cfa: ColorFilterArray,
    /// The sensor's bit depth, from its white level.
    pub bits_per_pixel: u32,
    /// The saturation level: the largest value a pixel can hold.
    pub white_level: u32,
    /// Black level at each position of the filter cell, row-major
    /// (`cfa.cell_size()` squared entries).
    pub black_levels: Vec<u32>,
    pub metadata: RawMetadata,
}

impl RawFrame {
    /// The black level over the whole cell, rounded.
    pub fn black_level(&self) -> u32 {
        let sum: u64 = self.black_levels.iter().map(|&b| b as u64).sum();
        let count = self.black_levels.len().max(1) as u64;
        ((sum + count / 2) / count) as u32
    }

    /// The frame's FITS header: what the camera recorded plus the levels.
    pub fn header(&self) -> FitsHeader {
        let mut header = FitsHeader::new();
        describe_into(&mut header, &self.metadata, self.width, self.height, Some(&self.cfa));
        header.set_int("BLKLEVEL", self.black_level() as i64);
        header.set_comment("BLKLEVEL", "camera black level (ADU), not subtracted");
        header.set_int("DATAMAX", self.white_level as i64);
        header.set_comment("DATAMAX", "camera white (saturation) level (ADU)");
        header.set_int("BITDEPTH", self.bits_per_pixel as i64);
        header
    }

    pub fn to_image(&self) -> ImageData {
        ImageData::from_u16(self.width, self.height, 1, &self.data)
    }
}

/// The header cards every raw frame carries, known from the file's metadata
/// alone. One place maps camera metadata to FITS keywords: a raw file read
/// from disk and a frame converted from a camera download get the same cards.
fn describe_into(
    header: &mut FitsHeader,
    meta: &RawMetadata,
    width: u32,
    height: u32,
    cfa: Option<&ColorFilterArray>,
) {
    header.set_int("NAXIS1", width as i64);
    header.set_int("NAXIS2", height as i64);
    let instrument = [meta.make.as_str(), meta.model.as_str()]
        .iter()
        .filter(|s| !s.is_empty())
        .copied()
        .collect::<Vec<_>>()
        .join(" ");
    if !instrument.is_empty() {
        header.set_string("INSTRUME", &instrument);
    }
    if let Some(exposure) = meta.exposure_seconds {
        header.set_float("EXPTIME", exposure);
        header.set_comment("EXPTIME", "exposure time (s)");
    }
    if let Some(iso) = meta.iso {
        let iso = iso.round() as i64;
        header.set_int("ISOSPEED", iso);
        // Calibration matches frames on GAIN; for a camera the ISO is it.
        header.set_int("GAIN", iso);
        header.set_comment("GAIN", "camera ISO");
    }
    if let Some(temperature) = meta.temperature {
        header.set_float("CCD-TEMP", (temperature.celsius as f64 * 10.0).round() / 10.0);
        header.set_comment(
            "CCD-TEMP",
            match temperature.source {
                TemperatureSource::Sensor => "sensor temperature (C)",
                TemperatureSource::CameraBody => "camera body temperature (C)",
            },
        );
    }
    if let Some(at) = meta.captured_at {
        header.set_string("DATE-OBS", &at.format("%Y-%m-%dT%H:%M:%S").to_string());
        header.set_comment("DATE-OBS", "camera clock");
    }
    if let Some(focal) = meta.focal_length_mm {
        header.set_float("FOCALLEN", focal as f64);
        header.set_comment("FOCALLEN", "lens focal length (mm)");
    }
    if let Some(f_number) = meta.f_number {
        header.set_float("FOCRATIO", f_number as f64);
    }
    if let Some(lens) = &meta.lens {
        header.set_string("LENS", lens);
    }
    if let Some(cfa) = cfa {
        header.set_string("BAYERPAT", &cfa.letters());
        header.set_int("XBAYROFF", 0);
        header.set_int("YBAYROFF", 0);
    }
}

/// Owns a LibRaw processor and closes it when dropped.
struct Processor(*mut libraw_data_t);

impl Processor {
    fn new() -> Result<Self, RawError> {
        // SAFETY: libraw_init takes flags and returns an owned handle or null.
        let handle = unsafe { libraw_init(0) };
        if handle.is_null() {
            return Err(RawError::Decode("LibRaw could not start".to_string()));
        }
        Ok(Self(handle))
    }

    fn check(code: c_int, step: &str) -> Result<(), RawError> {
        if code == LIBRAW_SUCCESS {
            return Ok(());
        }
        // SAFETY: libraw_strerror returns a pointer to a static string.
        let text = unsafe {
            let ptr = libraw_strerror(code);
            if ptr.is_null() {
                format!("error {code}")
            } else {
                CStr::from_ptr(ptr).to_string_lossy().into_owned()
            }
        };
        Err(RawError::Decode(format!("{step}: {text}")))
    }

    fn open_path(path: &Path) -> Result<Self, RawError> {
        if !path.is_file() {
            return Err(RawError::Io(std::io::Error::new(
                std::io::ErrorKind::NotFound,
                format!("{} does not exist", path.display()),
            )));
        }
        let processor = Self::new()?;
        #[cfg(not(windows))]
        let code = {
            use std::os::unix::ffi::OsStrExt;
            let c_path = std::ffi::CString::new(path.as_os_str().as_bytes()).map_err(|_| {
                RawError::Io(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "the path contains a NUL byte",
                ))
            })?;
            // SAFETY: valid handle; LibRaw copies what it needs from the path.
            unsafe { libraw_open_file(processor.0, c_path.as_ptr()) }
        };
        #[cfg(windows)]
        let code = {
            use std::os::windows::ffi::OsStrExt;
            let wide: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
            // SAFETY: valid handle; `wide` is NUL-terminated UTF-16.
            unsafe { libraw_open_wfile(processor.0, wide.as_ptr()) }
        };
        Self::check(code, "opening the file")?;
        Ok(processor)
    }

    /// `bytes` must outlive the processor: LibRaw reads from the buffer during
    /// unpack.
    fn open_bytes(bytes: &[u8]) -> Result<Self, RawError> {
        if bytes.is_empty() {
            return Err(RawError::Decode("the file is empty".to_string()));
        }
        let processor = Self::new()?;
        // SAFETY: valid handle and a live buffer of the stated length.
        let code =
            unsafe { libraw_open_buffer(processor.0, bytes.as_ptr() as *const c_void, bytes.len()) };
        Self::check(code, "opening the file")?;
        Ok(processor)
    }

    fn unpack(&self) -> Result<(), RawError> {
        // SAFETY: valid, opened handle.
        Self::check(unsafe { libraw_unpack(self.0) }, "decoding the sensor data")
    }

    fn describe(&self) -> Result<RawInfoFfi, RawError> {
        // SAFETY: RawInfoFfi is plain old data; the shim fills every field.
        let mut info: RawInfoFfi = unsafe { std::mem::zeroed() };
        let code = unsafe { skotiq_raw_describe(self.0, &mut info) };
        if code != 0 {
            return Err(RawError::Decode(format!("reading the file's description (code {code})")));
        }
        Ok(info)
    }

    fn copy_mosaic(&self, width: u32, height: u32) -> Result<Vec<u16>, RawError> {
        let mut data = vec![0u16; width as usize * height as usize];
        // SAFETY: valid, unpacked handle; `data` holds width*height samples.
        let code = unsafe { skotiq_raw_copy_mosaic(self.0, data.as_mut_ptr(), data.len()) };
        if code != 0 {
            return Err(RawError::Decode(format!("copying the sensor data (code {code})")));
        }
        Ok(data)
    }
}

impl Drop for Processor {
    fn drop(&mut self) {
        // SAFETY: the handle came from libraw_init and is closed once.
        unsafe { libraw_close(self.0) }
    }
}

fn text(field: &[c_char]) -> String {
    let bytes: Vec<u8> = field.iter().take_while(|&&c| c != 0).map(|&c| c as u8).collect();
    String::from_utf8_lossy(&bytes).trim().to_string()
}

fn recorded(value: f32) -> Option<f32> {
    (value > NOT_RECORDED + 1.0).then_some(value)
}

fn positive(value: f32) -> Option<f32> {
    (value > 0.0).then_some(value)
}

/// The temperature to describe a frame by: the sensor's own reading when the
/// camera recorded one, else the body reading for makers whose body reading
/// tracks the sensor.
fn frame_temperature(maker: Maker, info: &RawInfoFfi) -> Option<SensorTemperature> {
    recorded(info.sensor_temperature)
        .or_else(|| recorded(info.sensor_temperature2))
        .map(|celsius| SensorTemperature {
            celsius,
            source: TemperatureSource::Sensor,
        })
        .or_else(|| {
            maker
                .body_temperature_stands_for_sensor()
                .then(|| recorded(info.camera_temperature))
                .flatten()
                .map(|celsius| SensorTemperature {
                    celsius,
                    source: TemperatureSource::CameraBody,
                })
        })
}

fn metadata_from(info: &RawInfoFfi) -> RawMetadata {
    let make = text(&info.make);
    let maker = Maker::from_make(&make);
    let lens = text(&info.lens);
    RawMetadata {
        make,
        model: text(&info.model),
        lens: (!lens.is_empty()).then_some(lens),
        iso: positive(info.iso),
        // LibRaw stores the exposure as f32; its shortest decimal is the value
        // the camera wrote (1/100 s reads 0.01, not 0.009999999776).
        exposure_seconds: positive(info.shutter)
            .map(|s| s.to_string().parse::<f64>().unwrap_or(s as f64)),
        f_number: positive(info.aperture),
        focal_length_mm: positive(info.focal_length),
        captured_at: (info.timestamp > 0)
            .then(|| chrono::DateTime::from_timestamp(info.timestamp, 0))
            .flatten(),
        temperature: frame_temperature(maker, info),
    }
}

fn color_filter_from(info: &RawInfoFfi) -> Result<ColorFilterArray, RawError> {
    let size = info.cfa_size.clamp(0, 6) as usize;
    let letters: String = info.cfa[..size * size].iter().map(|&c| c as u8 as char).collect();
    ColorFilterArray::parse(&letters).ok_or_else(|| {
        RawError::Unsupported(if size == 0 {
            "this raw file holds no color-filter mosaic (a linear DNG, a small sRAW or a \
             Foveon file); save full-size raw on the camera"
                .to_string()
        } else {
            format!("the sensor's color filter ({letters}) is not one Skotiq can process")
        })
    })
}

/// The smallest bit depth that holds the white level, between 8 and 16; the
/// container depth LibRaw reports when the white level is missing.
fn bits_for_white_level(white_level: u32, raw_bps: c_int) -> u32 {
    if white_level > 0 {
        (u32::BITS - white_level.leading_zeros()).clamp(8, 16)
    } else if (8..=16).contains(&raw_bps) {
        raw_bps as u32
    } else {
        16
    }
}

fn decode(processor: Processor) -> Result<RawFrame, RawError> {
    processor.unpack()?;
    let info = processor.describe()?;
    let cfa = color_filter_from(&info)?;
    if info.has_mosaic == 0 {
        return Err(RawError::Unsupported(
            "this raw file holds no color-filter mosaic (a linear DNG, a small sRAW or a \
             Foveon file); save full-size raw on the camera"
                .to_string(),
        ));
    }
    if info.width <= 0 || info.height <= 0 {
        return Err(RawError::Decode(format!(
            "the file reports an image of {} x {} pixels",
            info.width, info.height
        )));
    }
    let (width, height) = (info.width as u32, info.height as u32);
    let data = processor.copy_mosaic(width, height)?;
    drop(processor);

    let cell = cfa.cell_size();
    Ok(RawFrame {
        width,
        height,
        data,
        cfa,
        bits_per_pixel: bits_for_white_level(info.white_level, info.raw_bps),
        white_level: info.white_level,
        black_levels: info.cfa_black[..cell * cell].to_vec(),
        metadata: metadata_from(&info),
    })
}

/// Decode a raw file on disk.
pub fn read_raw_file(path: &Path) -> Result<RawFrame, RawError> {
    decode(Processor::open_path(path)?)
}

/// Decode a raw file held in memory, as a camera download delivers it.
pub fn read_raw_bytes(bytes: &[u8]) -> Result<RawFrame, RawError> {
    decode(Processor::open_bytes(bytes)?)
}

/// A raw file's header without decoding the sensor data. The black and white
/// levels are only final after decoding, so `BLKLEVEL`, `DATAMAX` and
/// `BITDEPTH` are left to [`read_raw_file`].
pub fn read_raw_header(path: &Path) -> Result<FitsHeader, RawError> {
    let processor = Processor::open_path(path)?;
    let info = processor.describe()?;
    let cfa = color_filter_from(&info).ok();
    let mut header = FitsHeader::new();
    describe_into(
        &mut header,
        &metadata_from(&info),
        info.width.max(0) as u32,
        info.height.max(0) as u32,
        cfa.as_ref(),
    );
    Ok(header)
}

/// The extension a raw file in `data` usually has, from its first bytes.
/// `None` when the bytes are not a camera raw format (a JPEG, for example).
pub fn raw_format_extension(data: &[u8]) -> Option<&'static str> {
    crate::ImageFormat::from_magic_bytes(data)
        .filter(|format| format.is_raw())
        .map(|format| format.extension())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn info() -> RawInfoFfi {
        // SAFETY: plain old data.
        let mut info: RawInfoFfi = unsafe { std::mem::zeroed() };
        info.sensor_temperature = NOT_RECORDED;
        info.sensor_temperature2 = NOT_RECORDED;
        info.camera_temperature = NOT_RECORDED;
        info
    }

    #[test]
    fn makers_are_named_from_libraw_make() {
        assert_eq!(Maker::from_make("Canon"), Maker::Canon);
        assert_eq!(Maker::from_make("Nikon"), Maker::Nikon);
        assert_eq!(Maker::from_make("Sony"), Maker::Sony);
        assert_eq!(Maker::from_make("Fujifilm"), Maker::Fujifilm);
        assert_eq!(Maker::from_make("Pentax"), Maker::Pentax);
        assert_eq!(Maker::from_make("Ricoh"), Maker::Pentax);
        assert_eq!(Maker::from_make("Olympus"), Maker::Olympus);
        assert_eq!(Maker::from_make("OM Digital"), Maker::Olympus);
        assert_eq!(Maker::from_make("Panasonic"), Maker::Panasonic);
        assert_eq!(Maker::from_make("Hasselblad"), Maker::Other);
    }

    #[test]
    fn a_sensor_reading_wins_over_a_body_reading() {
        let mut olympus = info();
        olympus.sensor_temperature = 32.0;
        olympus.camera_temperature = 5.0;
        assert_eq!(
            frame_temperature(Maker::Olympus, &olympus),
            Some(SensorTemperature { celsius: 32.0, source: TemperatureSource::Sensor })
        );
    }

    #[test]
    fn a_body_reading_is_used_only_where_it_tracks_the_sensor() {
        let mut body_only = info();
        body_only.camera_temperature = 21.0;
        let body = Some(SensorTemperature { celsius: 21.0, source: TemperatureSource::CameraBody });
        assert_eq!(frame_temperature(Maker::Canon, &body_only), body);
        assert_eq!(frame_temperature(Maker::Pentax, &body_only), body);
        for maker in [Maker::Nikon, Maker::Sony, Maker::Olympus, Maker::Panasonic, Maker::Fujifilm] {
            assert_eq!(frame_temperature(maker, &body_only), None, "{maker:?}");
        }
        assert_eq!(frame_temperature(Maker::Canon, &info()), None);
    }

    #[test]
    fn header_maps_camera_metadata_to_fits_cards() {
        let frame = RawFrame {
            width: 4,
            height: 2,
            data: vec![0; 8],
            cfa: ColorFilterArray::parse("RGGB").unwrap(),
            bits_per_pixel: 14,
            white_level: 16383,
            black_levels: vec![510, 511, 511, 510],
            metadata: RawMetadata {
                make: "Canon".into(),
                model: "EOS M50".into(),
                lens: Some("EF-M18-150mm f/3.5-6.3 IS STM".into()),
                iso: Some(800.0),
                exposure_seconds: Some(120.0),
                f_number: Some(3.5),
                focal_length_mm: Some(18.0),
                captured_at: chrono::DateTime::from_timestamp(1_620_691_714, 0),
                temperature: Some(SensorTemperature {
                    celsius: 32.0,
                    source: TemperatureSource::CameraBody,
                }),
            },
        };
        let header = frame.header();
        assert_eq!(header.get_string("INSTRUME"), Some("Canon EOS M50"));
        assert_eq!(header.get_float("EXPTIME"), Some(120.0));
        assert_eq!(header.get_int("GAIN"), Some(800));
        assert_eq!(header.get_int("ISOSPEED"), Some(800));
        assert_eq!(header.get_float("CCD-TEMP"), Some(32.0));
        assert_eq!(header.get_comment("CCD-TEMP"), Some("camera body temperature (C)"));
        assert_eq!(header.get_string("DATE-OBS"), Some("2021-05-11T00:08:34"));
        assert_eq!(header.get_string("BAYERPAT"), Some("RGGB"));
        assert_eq!(header.get_int("BLKLEVEL"), Some(511));
        assert_eq!(header.get_int("DATAMAX"), Some(16383));
        assert_eq!(header.get_float("FOCALLEN"), Some(18.0));
        assert_eq!(header.get_string("LENS"), Some("EF-M18-150mm f/3.5-6.3 IS STM"));
    }

    #[test]
    fn missing_metadata_writes_no_card() {
        let mut header = FitsHeader::new();
        describe_into(&mut header, &RawMetadata::default(), 2, 2, None);
        for key in ["INSTRUME", "EXPTIME", "GAIN", "CCD-TEMP", "DATE-OBS", "BAYERPAT", "LENS"] {
            assert!(header.get(key).is_none(), "{key}");
        }
    }

    #[test]
    fn bit_depth_comes_from_the_white_level() {
        assert_eq!(bits_for_white_level(16383, 14), 14);
        assert_eq!(bits_for_white_level(3651, 12), 12);
        assert_eq!(bits_for_white_level(4095, 12), 12);
        assert_eq!(bits_for_white_level(65535, 16), 16);
        assert_eq!(bits_for_white_level(0, 14), 14);
        assert_eq!(bits_for_white_level(0, 0), 16);
    }

    #[test]
    fn a_file_with_no_mosaic_says_what_to_change() {
        let err = color_filter_from(&info()).unwrap_err();
        assert!(err.to_string().contains("full-size raw"), "{err}");
    }

    #[test]
    fn an_unknown_filter_is_refused_by_name() {
        let mut cmyg = info();
        cmyg.cfa_size = 2;
        for (slot, letter) in cmyg.cfa.iter_mut().zip(b"CMYG") {
            *slot = *letter as c_char;
        }
        let err = color_filter_from(&cmyg).unwrap_err();
        assert!(err.to_string().contains("CMYG"), "{err}");
    }

    #[test]
    fn a_missing_file_is_an_io_error() {
        let err = read_raw_file(Path::new("/nonexistent/IMG_0001.CR2")).unwrap_err();
        assert!(matches!(err, RawError::Io(_)), "{err:?}");
    }

    #[test]
    fn bytes_that_are_no_raw_are_refused() {
        assert!(read_raw_bytes(&[]).is_err());
        assert!(read_raw_bytes(&[0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, b'J', b'F', b'I', b'F']).is_err());
        assert_eq!(raw_format_extension(&[0xFF; 64]), None);
    }
}
