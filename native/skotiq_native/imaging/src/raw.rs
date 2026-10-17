//! RAW image file support via LibRaw FFI
//!
//! Direct FFI bindings to libraw.dll for native X-Trans RGB support.
//! No synthetic Bayer conversion - preserves full X-Trans sharpness!
//!
//! Supports 600+ camera models including Fujifilm X-Trans sensors.
//!
//! # `unwrap_or` policy
//!
//! * `params.unwrap_or(&default_params)` — caller passing `None` selects
//!   the LibRaw out-of-the-box config (auto white-balance, no demosaic
//!   overrides). The default-params binding lives on this stack frame.
//! * The remaining sites (`user_sat.unwrap_or_default()`,
//!   `gamma.unwrap_or([0.0, 0.0])`, `chromatic_aberration.unwrap_or([0.0, 0.0])`,
//!   `max_memory_mb.unwrap_or_default()`) are all paired with a
//!   `has_user_sat`/`has_gamma`/`has_chromatic_aberration`/`has_max_memory_mb`
//!   flag set from `is_some()` on the same field. The C-side LibRaw config
//!   reads the value ONLY when the flag is non-zero — so the unwrap_or
//!   default value is dead code in the "absent" branch, present solely to
//!   satisfy the C struct's required field width.

use crate::{ImageData, PixelType};
use image::GenericImageView;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_double, c_float, c_int, c_uint, c_ushort, c_void};
use std::path::Path;

// LibRaw FFI declarations (matching libraw.dll structures and functions)

const LIBRAW_SUCCESS: i32 = 0;

// LibRaw image parameters structure
#[repr(C)]
struct libraw_iparams_t {
    make: [c_char; 64],
    model: [c_char; 64],
    software: [c_char; 64],
    raw_count: c_uint,
    dng_version: c_uint,
    is_foveon: c_uint,
    colors: c_int,
    filters: c_uint,
    cdesc: [c_char; 5],
}

// LibRaw other parameters (exposure, etc.)
#[repr(C)]
struct libraw_imgother_t {
    iso_speed: c_float,
    shutter: c_float,
    aperture: c_float,
    focal_len: c_float,
    timestamp: c_uint,
    shot_order: c_uint,
    gpsdata: [c_uint; 32],
    desc: [c_char; 512],
    artist: [c_char; 64],
}

#[repr(C)]
struct libraw_data_t {
    _private: [u8; 0],
}

#[repr(C)]
struct libraw_processed_image_t {
    type_: c_ushort,
    height: c_ushort,
    width: c_ushort,
    colors: c_ushort,
    bits: c_ushort,
    data_size: c_uint,
    // data follows immediately after
}

// Mirrors `skotiq_cfa_info_t` in libraw_shim.c. Field order and types MUST
// stay in lockstep with the C definition — the C side fills it from the real
// LibRaw struct, this is only a transport record.
#[repr(C)]
struct skotiq_cfa_info_t {
    width: c_int,
    height: c_int,
    raw_width: c_int,
    raw_height: c_int,
    top_margin: c_int,
    left_margin: c_int,
    raw_bps: c_int,
    maximum: c_uint,
    black: c_uint,
    filters: c_int,
    is_xtrans: c_int,
    cfa: [c_char; 8],
}

#[repr(C)]
struct skotiq_libraw_config_t {
    white_balance_mode: c_int,
    user_mul: [c_float; 4],
    output_color: c_int,
    output_bps: c_int,
    user_qual: c_int,
    highlight: c_int,
    bright: c_float,
    no_auto_bright: c_int,
    half_size: c_int,
    bad_pixels: *const c_char,
    dark_frame: *const c_char,
    user_sat: c_int,
    has_user_sat: c_int,
    gamma: [c_double; 2],
    has_gamma: c_int,
    chromatic_aberration: [c_double; 2],
    has_chromatic_aberration: c_int,
    max_memory_mb: c_uint,
    has_max_memory_mb: c_int,
}

// Platform-specific library name:
// - Windows: libraw.dll (linked as "libraw")
// - Linux/macOS: libraw.so/dylib (linked as "raw" since lib prefix is automatic)
extern "C" {
    fn skotiq_libraw_apply_config(data: *mut libraw_data_t, config: *const skotiq_libraw_config_t);
    // Fill a `skotiq_cfa_info_t` from an unpacked processor (dims, margins,
    // bit depth, saturation, CFA orientation). Returns 0 on success.
    fn skotiq_libraw_extract_cfa_info(
        data: *mut libraw_data_t,
        info: *mut skotiq_cfa_info_t,
    ) -> c_int;
    // Copy the visible single-channel CFA mosaic (margins trimmed) into
    // `out` (>= width*height u16 samples). Returns 0 on success.
    fn skotiq_libraw_copy_cfa_mosaic(
        data: *mut libraw_data_t,
        out: *mut c_ushort,
        out_len: usize,
    ) -> c_int;
}

#[cfg_attr(target_os = "windows", link(name = "libraw"))]
#[cfg_attr(not(target_os = "windows"), link(name = "raw"))]
extern "C" {
    fn libraw_init(flags: c_uint) -> *mut libraw_data_t;
    fn libraw_open_file(data: *mut libraw_data_t, path: *const c_char) -> c_int;
    fn libraw_open_buffer(data: *mut libraw_data_t, buffer: *const c_void, size: usize) -> c_int;
    fn libraw_unpack(data: *mut libraw_data_t) -> c_int;
    fn libraw_raw2image(data: *mut libraw_data_t) -> c_int;
    fn libraw_dcraw_process(data: *mut libraw_data_t) -> c_int;
    fn libraw_dcraw_make_mem_image(
        data: *mut libraw_data_t,
        errcode: *mut c_int,
    ) -> *mut libraw_processed_image_t;
    fn libraw_dcraw_make_mem_thumb(
        data: *mut libraw_data_t,
        errcode: *mut c_int,
    ) -> *mut libraw_processed_image_t;
    fn libraw_dcraw_clear_mem(image: *mut libraw_processed_image_t);
    fn libraw_close(data: *mut libraw_data_t);
    fn libraw_strerror(errorcode: c_int) -> *const c_char;
    fn libraw_unpack_thumb(data: *mut libraw_data_t) -> c_int;
    fn libraw_get_iparams(data: *mut libraw_data_t) -> *const libraw_iparams_t;
    fn libraw_get_imgother(data: *mut libraw_data_t) -> *const libraw_imgother_t;
    fn libraw_get_raw_width(data: *mut libraw_data_t) -> c_int;
    fn libraw_get_raw_height(data: *mut libraw_data_t) -> c_int;
}

/// RAW file error types
#[derive(Debug)]
pub enum RawError {
    Io(std::io::Error),
    LibRawError(String),
    UnsupportedFormat(String),
    InvalidPath(String),
    /// A user-supplied path could not be passed through the LibRaw C ABI
    /// because it contained an interior NUL byte. Carries `which` (which
    /// processing parameter — `bad_pixels` or `dark_frame`) plus the
    /// underlying `NulError` so callers can pinpoint the offending input.
    InvalidCStringPath {
        which: &'static str,
        path: String,
        source: std::ffi::NulError,
    },
    NullPointer,
}

impl std::fmt::Display for RawError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RawError::Io(e) => write!(f, "IO error: {}", e),
            RawError::LibRawError(s) => write!(f, "LibRaw error: {}", s),
            RawError::UnsupportedFormat(s) => write!(f, "Unsupported format: {}", s),
            RawError::InvalidPath(s) => write!(f, "Invalid path: {}", s),
            RawError::InvalidCStringPath {
                which,
                path,
                source,
            } => write!(
                f,
                "Invalid {} path {:?} (cannot be converted to a C string): {}",
                which, path, source
            ),
            RawError::NullPointer => write!(f, "Null pointer from LibRaw"),
        }
    }
}

impl std::error::Error for RawError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            RawError::Io(e) => Some(e),
            RawError::InvalidCStringPath { source, .. } => Some(source),
            _ => None,
        }
    }
}

impl From<std::io::Error> for RawError {
    fn from(e: std::io::Error) -> Self {
        RawError::Io(e)
    }
}

/// RAW file metadata
#[derive(Debug, Clone, Default)]
pub struct RawMetadata {
    pub camera_make: String,
    pub camera_model: String,
    pub iso_speed: Option<f32>,
    pub shutter_speed: Option<f32>,
    pub aperture: Option<f32>,
    pub focal_length: Option<f32>,
    pub timestamp: Option<i64>,
    pub color_desc: String,
    pub is_xtrans: bool,
    pub raw_width: u32,
    pub raw_height: u32,
}

/// White Balance Mode
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum WhiteBalanceMode {
    Camera,
    Auto,
    Custom(f32, f32, f32, f32), // R, G1, B, G2 multipliers
}

/// Output Color Space
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorSpace {
    Raw,
    SRGB,
    AdobeRGB,
    WideGamut,
    ProPhotoRGB,
    XYZ,
    ACES,
}

/// Demosaic Algorithm
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DemosaicAlgorithm {
    Linear,
    VNG,
    PPG,
    AHD,
    DCB,
    DHT, // Best for X-Trans
    AAHD,
}

/// Highlight Recovery Mode
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HighlightMode {
    Clip,
    Unclip,
    Blend,
    Rebuild(u32), // 3-9
}

/// RAW Processing Parameters
#[derive(Debug, Clone)]
pub struct RawProcessingParams {
    pub white_balance: WhiteBalanceMode,
    pub output_color: ColorSpace,
    pub output_bps: u32, // 8 or 16
    pub demosaic: DemosaicAlgorithm,
    pub highlight_mode: HighlightMode,
    pub brightness: f32,
    pub user_sat: Option<i32>,
    pub gamma: Option<(f64, f64)>, // power, slope
    pub auto_bright: bool,
    pub half_size: bool,
    pub bad_pixels_path: Option<std::path::PathBuf>,
    pub dark_frame_path: Option<std::path::PathBuf>,
    pub chromatic_aberration: Option<(f64, f64)>, // (red_scale, blue_scale)
    pub max_memory_mb: Option<usize>,
}

impl Default for RawProcessingParams {
    fn default() -> Self {
        Self {
            white_balance: WhiteBalanceMode::Camera,
            output_color: ColorSpace::SRGB,
            output_bps: 8,
            demosaic: DemosaicAlgorithm::DHT, // Good default for X-Trans
            highlight_mode: HighlightMode::Clip,
            brightness: 1.0,
            user_sat: None,
            gamma: None,        // Use default sRGB gamma
            auto_bright: false, // Disable auto brightness for consistency
            half_size: false,
            bad_pixels_path: None,
            dark_frame_path: None,
            chromatic_aberration: None,
            max_memory_mb: None,
        }
    }
}

/// Convert an optional filesystem `Path` into an owned `CString` for the
/// LibRaw FFI, surfacing every failure mode with full context.
///
/// `which` identifies which `RawProcessingParams` field the path came from
/// (e.g. `"bad_pixels"` / `"dark_frame"`) so the resulting `RawError` can
/// pinpoint the offending input. Errors are never swallowed: a non-UTF-8
/// path or an interior NUL byte both propagate.
fn path_to_cstring(which: &'static str, path: Option<&Path>) -> Result<Option<CString>, RawError> {
    let Some(path) = path else { return Ok(None) };
    let path_str = path.to_str().ok_or_else(|| {
        RawError::InvalidPath(format!(
            "{} path {:?} is not valid UTF-8 and cannot be passed to LibRaw",
            which, path
        ))
    })?;
    let c_str = CString::new(path_str).map_err(|source| RawError::InvalidCStringPath {
        which,
        path: path_str.to_string(),
        source,
    })?;
    Ok(Some(c_str))
}

/// Read a RAW file with native X-Trans support
///
/// Returns 3-channel RGB image data with NO synthetic Bayer conversion!
/// Read a RAW file with native X-Trans support
///
/// Returns 3-channel RGB image data with NO synthetic Bayer conversion!
pub fn read_raw(
    path: &Path,
    params: Option<&RawProcessingParams>,
) -> Result<(ImageData, RawMetadata), RawError> {
    let default_params = RawProcessingParams::default();
    let params = params.unwrap_or(&default_params);
    // Validate path
    let path_str = path
        .to_str()
        .ok_or_else(|| RawError::InvalidPath("Path contains invalid UTF-8".to_string()))?;

    if !path.exists() {
        return Err(RawError::Io(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "File not found",
        )));
    }

    tracing::info!("Reading RAW file: {}", path_str);

    // SAFETY: Calling FFI functions from LibRaw C library. The processor lifecycle is managed
    // carefully: init returns a valid pointer or null (checked), and we ensure cleanup via
    // libraw_close in all code paths (error and success).
    unsafe {
        // Initialize LibRaw processor
        let processor = libraw_init(0);
        if processor.is_null() {
            return Err(RawError::NullPointer);
        }

        // Open file
        let c_path = CString::new(path_str)
            .map_err(|_| RawError::InvalidPath("Path contains null bytes".to_string()))?;

        let ret = libraw_open_file(processor, c_path.as_ptr());
        if ret != LIBRAW_SUCCESS {
            let err_msg = get_error_string(ret);
            libraw_close(processor);
            return Err(RawError::LibRawError(format!(
                "libraw_open_file failed: {}",
                err_msg
            )));
        }

        // Access LibRaw metadata via its supported public getters.
        let iparams = libraw_get_iparams(processor);
        let other = libraw_get_imgother(processor);
        if iparams.is_null() || other.is_null() {
            libraw_close(processor);
            return Err(RawError::NullPointer);
        }

        let iparams = &*iparams;
        let other = &*other;

        let camera_make = CStr::from_ptr(iparams.make.as_ptr())
            .to_string_lossy()
            .trim()
            .to_string();

        let camera_model = CStr::from_ptr(iparams.model.as_ptr())
            .to_string_lossy()
            .trim()
            .to_string();

        let color_desc = CStr::from_ptr(iparams.cdesc.as_ptr())
            .to_string_lossy()
            .to_string();

        // Detect X-Trans (filters == 9 indicates X-Trans)
        let is_xtrans = iparams.filters == 9;

        // Extract exposure metadata
        let iso_speed = if other.iso_speed > 0.0 {
            Some(other.iso_speed)
        } else {
            None
        };

        let shutter_speed = if other.shutter > 0.0 {
            Some(other.shutter)
        } else {
            None
        };

        let aperture = if other.aperture > 0.0 {
            Some(other.aperture)
        } else {
            None
        };

        let focal_length = if other.focal_len > 0.0 {
            Some(other.focal_len)
        } else {
            None
        };

        let timestamp = if other.timestamp > 0 {
            Some(other.timestamp as i64)
        } else {
            None
        };
        // Why: keep CString storage alive until LibRaw finishes processing —
        // the FFI struct only holds raw pointers, not owned data.
        let mut _bad_pixels_c_str: Option<CString> = None;
        let mut _dark_frame_c_str: Option<CString> = None;

        let white_balance_mode = match params.white_balance {
            WhiteBalanceMode::Camera => 0,
            WhiteBalanceMode::Auto => 1,
            WhiteBalanceMode::Custom(_, _, _, _) => 2,
        };

        let user_mul = match params.white_balance {
            WhiteBalanceMode::Custom(r, g1, b, g2) => [r, g1, b, g2],
            _ => [0.0; 4],
        };

        // Why: a swallowed `CString::new` failure leaves LibRaw on its
        // defaults while the caller believes the bad-pixels / dark-frame path
        // is active. Surface the failure with enough context to identify which
        // path is at fault, and close the already-opened LibRaw processor
        // before propagating so it does not leak.
        match path_to_cstring("bad_pixels", params.bad_pixels_path.as_deref()) {
            Ok(value) => _bad_pixels_c_str = value,
            Err(err) => {
                libraw_close(processor);
                return Err(err);
            }
        }
        match path_to_cstring("dark_frame", params.dark_frame_path.as_deref()) {
            Ok(value) => _dark_frame_c_str = value,
            Err(err) => {
                libraw_close(processor);
                return Err(err);
            }
        }

        let config = skotiq_libraw_config_t {
            white_balance_mode,
            user_mul,
            output_color: match params.output_color {
                ColorSpace::Raw => 0,
                ColorSpace::SRGB => 1,
                ColorSpace::AdobeRGB => 2,
                ColorSpace::WideGamut => 3,
                ColorSpace::ProPhotoRGB => 4,
                ColorSpace::XYZ => 5,
                ColorSpace::ACES => 6,
            },
            output_bps: params.output_bps as c_int,
            user_qual: match params.demosaic {
                DemosaicAlgorithm::Linear => 0,
                DemosaicAlgorithm::VNG => 1,
                DemosaicAlgorithm::PPG => 2,
                DemosaicAlgorithm::AHD => 3,
                DemosaicAlgorithm::DCB => 4,
                DemosaicAlgorithm::DHT => 11,
                DemosaicAlgorithm::AAHD => 12,
            },
            highlight: match params.highlight_mode {
                HighlightMode::Clip => 0,
                HighlightMode::Unclip => 1,
                HighlightMode::Blend => 2,
                HighlightMode::Rebuild(n) => (3 + n).min(9) as c_int,
            },
            bright: params.brightness,
            no_auto_bright: if params.auto_bright { 0 } else { 1 },
            half_size: if params.half_size { 1 } else { 0 },
            bad_pixels: _bad_pixels_c_str
                .as_ref()
                .map_or(std::ptr::null(), |value| value.as_ptr()),
            dark_frame: _dark_frame_c_str
                .as_ref()
                .map_or(std::ptr::null(), |value| value.as_ptr()),
            user_sat: params.user_sat.unwrap_or_default(),
            has_user_sat: if params.user_sat.is_some() { 1 } else { 0 },
            gamma: params
                .gamma
                .map(|(power, slope)| [1.0 / power, slope])
                .unwrap_or([0.0, 0.0]),
            has_gamma: if params.gamma.is_some() { 1 } else { 0 },
            chromatic_aberration: params
                .chromatic_aberration
                .map(|(r, b)| [r, b])
                .unwrap_or([0.0, 0.0]),
            has_chromatic_aberration: if params.chromatic_aberration.is_some() {
                1
            } else {
                0
            },
            max_memory_mb: params.max_memory_mb.unwrap_or_default() as c_uint,
            has_max_memory_mb: if params.max_memory_mb.is_some() { 1 } else { 0 },
        };
        skotiq_libraw_apply_config(processor, &config);

        let metadata = RawMetadata {
            camera_make,
            camera_model,
            iso_speed,
            shutter_speed,
            aperture,
            focal_length,
            timestamp,
            color_desc,
            is_xtrans,
            raw_width: libraw_get_raw_width(processor) as u32,
            raw_height: libraw_get_raw_height(processor) as u32,
        };

        // Unpack the RAW data
        let ret = libraw_unpack(processor);
        if ret != LIBRAW_SUCCESS {
            let err_msg = get_error_string(ret);
            libraw_close(processor);
            return Err(RawError::LibRawError(format!(
                "libraw_unpack failed: {}",
                err_msg
            )));
        }

        // Process to RGB (LibRaw automatically handles X-Trans demosaicing!)
        let ret = libraw_dcraw_process(processor);
        if ret != LIBRAW_SUCCESS {
            let err_msg = get_error_string(ret);
            libraw_close(processor);
            return Err(RawError::LibRawError(format!(
                "libraw_dcraw_process failed: {}",
                err_msg
            )));
        }

        // Get processed RGB image
        let mut errcode = 0;
        let processed_image = libraw_dcraw_make_mem_image(processor, &mut errcode);
        if processed_image.is_null() {
            libraw_close(processor);
            return Err(RawError::LibRawError(format!(
                "libraw_dcraw_make_mem_image failed: {}",
                errcode
            )));
        }

        // Extract image data from the processed image structure
        let img = &*processed_image;
        let img_width = img.width as u32;
        let img_height = img.height as u32;
        let channels = img.colors as u32; // Should be 3 for RGB
        let bits = img.bits as u32;

        tracing::info!(
            "Processed: {}x{}, {} channels, {} bits - Native RGB!",
            img_width,
            img_height,
            channels,
            bits
        );

        let pixel_count = (img_width * img_height * channels) as usize;
        let data_size = img.data_size as usize;

        // Get pointer to image data (located right after the struct header)
        let header_size = std::mem::size_of::<libraw_processed_image_t>();
        let data_ptr = (processed_image as *const u8).add(header_size);

        let mut rgb_data = vec![0u16; pixel_count];

        if bits == 16 {
            let sample_size = std::mem::size_of::<u16>();
            let sample_count = data_size / sample_size;
            if !data_size.is_multiple_of(sample_size) || sample_count != pixel_count {
                libraw_dcraw_clear_mem(processed_image);
                libraw_close(processor);
                return Err(RawError::LibRawError(format!(
                    "LibRaw returned inconsistent 16-bit image size: {} bytes for {} samples",
                    data_size, pixel_count
                )));
            }

            std::ptr::copy_nonoverlapping(
                data_ptr as *const u16,
                rgb_data.as_mut_ptr(),
                sample_count,
            );
        } else if bits == 8 {
            if data_size != pixel_count {
                libraw_dcraw_clear_mem(processed_image);
                libraw_close(processor);
                return Err(RawError::LibRawError(format!(
                    "LibRaw returned inconsistent 8-bit image size: {} bytes for {} samples",
                    data_size, pixel_count
                )));
            }

            for (i, dest) in rgb_data.iter_mut().enumerate().take(pixel_count) {
                let val = *data_ptr.add(i);
                *dest = (val as u16) * 257; // Scale 0-255 to 0-65535
            }
        } else {
            libraw_dcraw_clear_mem(processed_image);
            libraw_close(processor);
            return Err(RawError::UnsupportedFormat(format!(
                "Unsupported bit depth: {}",
                bits
            )));
        }

        // Convert to byte array for ImageData
        let data: Vec<u8> = rgb_data.iter().flat_map(|&val| val.to_le_bytes()).collect();

        // Cleanup
        libraw_dcraw_clear_mem(processed_image);
        libraw_close(processor);

        // Create ImageData with 3 channels (native RGB!)
        let image = ImageData {
            width: img_width,
            height: img_height,
            channels, // 3 for RGB - NO synthetic Bayer conversion!
            pixel_type: PixelType::U16,
            data,
        };

        Ok((image, metadata))
    }
}

/// Get LibRaw error string
/// SAFETY: Calls libraw_strerror FFI function which returns a static string pointer.
/// The pointer is checked for null and converted to a Rust String.
unsafe fn get_error_string(code: c_int) -> String {
    let ptr = libraw_strerror(code);
    if ptr.is_null() {
        format!("Unknown error code: {}", code)
    } else {
        CStr::from_ptr(ptr).to_string_lossy().to_string()
    }
}

/// Extract thumbnail from RAW file (Fast Preview)
pub fn extract_thumbnail(path: &Path) -> Result<ImageData, RawError> {
    // Validate path
    let path_str = path
        .to_str()
        .ok_or_else(|| RawError::InvalidPath("Path contains invalid UTF-8".to_string()))?;

    if !path.exists() {
        return Err(RawError::Io(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "File not found",
        )));
    }

    // SAFETY: Calling FFI functions from LibRaw C library. The processor lifecycle is managed
    // carefully: init returns a valid pointer or null (checked), and we ensure cleanup via
    // libraw_close in all code paths (error and success).
    unsafe {
        // Initialize LibRaw processor
        let processor = libraw_init(0);
        if processor.is_null() {
            return Err(RawError::NullPointer);
        }

        // Open file
        let c_path = CString::new(path_str)
            .map_err(|_| RawError::InvalidPath("Path contains null bytes".to_string()))?;

        let ret = libraw_open_file(processor, c_path.as_ptr());
        if ret != LIBRAW_SUCCESS {
            libraw_close(processor);
            return Err(RawError::LibRawError("Failed to open file".to_string()));
        }

        // Unpack thumbnail
        let ret = libraw_unpack_thumb(processor);
        if ret != LIBRAW_SUCCESS {
            libraw_close(processor);
            return Err(RawError::LibRawError(
                "Failed to unpack thumbnail".to_string(),
            ));
        }

        // Make memory thumbnail
        let mut err = 0;
        let processed = libraw_dcraw_make_mem_thumb(processor, &mut err);

        if processed.is_null() || err != LIBRAW_SUCCESS {
            libraw_close(processor);
            return Err(RawError::LibRawError(format!(
                "Failed to create memory thumbnail: {}",
                err
            )));
        }

        // Convert to ImageData
        let width = (*processed).width as u32;
        let height = (*processed).height as u32;
        let colors = (*processed).colors as u32;
        let bits = (*processed).bits as u32;
        let data_size = (*processed).data_size as usize;

        let data_ptr = (processed as *mut u8).add(std::mem::size_of::<libraw_processed_image_t>());
        let data_slice = std::slice::from_raw_parts(data_ptr, data_size);

        // Thumbnails are usually JPEG (compressed) or RGB bitmap
        let type_ = (*processed).type_;

        let image = if type_ == 1 {
            // Bitmap (RGB)
            let mut pixels = Vec::with_capacity(data_size);
            pixels.extend_from_slice(data_slice);

            ImageData {
                width,
                height,
                channels: colors,
                pixel_type: if bits == 16 {
                    PixelType::U16
                } else {
                    PixelType::U8
                },
                data: pixels,
            }
        } else if type_ == 2 || type_ == 4 {
            // JPEG or KODAK_THUMB (usually JPEG)
            // Decode JPEG from memory
            let img = image::load_from_memory(data_slice).map_err(|e| {
                RawError::UnsupportedFormat(format!("Failed to decode thumbnail: {}", e))
            })?;

            let (w, h) = img.dimensions();
            let rgba = img.to_rgba8();
            let pixels = rgba.into_raw();

            // Convert RGBA to RGB if needed, or keep RGBA
            // ImageData supports 4 channels
            ImageData {
                width: w,
                height: h,
                channels: 4,
                pixel_type: PixelType::U8,
                data: pixels,
            }
        } else {
            // Other format
            libraw_dcraw_clear_mem(processed);
            libraw_close(processor);
            return Err(RawError::UnsupportedFormat(format!(
                "Unsupported thumbnail type: {}",
                type_
            )));
        };

        libraw_dcraw_clear_mem(processed);
        libraw_close(processor);

        Ok(image)
    }
}

/// Process multiple RAW files in parallel
pub fn process_raw_batch(
    paths: &[std::path::PathBuf],
    params: Option<&RawProcessingParams>,
) -> Vec<Result<(ImageData, RawMetadata), RawError>> {
    use rayon::prelude::*;

    paths
        .par_iter()
        .map(|path| read_raw(path, params))
        .collect()
}

/// Detect if a file is a supported RAW format
pub fn is_raw_file(path: &Path) -> bool {
    if let Some(ext) = path.extension() {
        if let Some(ext_str) = ext.to_str() {
            return matches!(
                ext_str.to_lowercase().as_str(),
                "cr2" | "cr3" | "crw"  // Canon
                | "nef" | "nrw"        // Nikon
                | "arw" | "srf" | "sr2" // Sony
                | "raf"                 // Fujifilm (X-Trans!)
                | "pef" | "dng"         // Pentax
                | "orf"                 // Olympus
                | "rw2"                 // Panasonic
                | "raw" | "rwl"         // Leica
                | "mrw"                 // Minolta
                | "erf"                 // Epson
                | "3fr"                 // Hasselblad
                | "ari"                 // ARRI
                | "bay"                 // Casio
                | "cap" | "iiq"         // Phase One
                | "dcs" | "dcr" | "drf" | "k25" | "kdc" // Kodak
                | "mef"                 // Mamiya
                | "mos"                 // Leaf
                | "ptx" | "pxn"         // Pentax
                | "r3d"                 // RED
                | "srw"                 // Samsung
                | "x3f" // Sigma
            );
        }
    }
    false
}

/// Read a RAW file from in-memory bytes
///
/// Since LibRaw requires file access, this writes to a temp file.
/// Used for processing DSLR images received via INDI BLOBs.
pub fn read_raw_from_bytes(
    data: &[u8],
    extension: &str,
    params: Option<&RawProcessingParams>,
) -> Result<(ImageData, RawMetadata), RawError> {
    use std::io::Write;

    // Create temp file with appropriate extension (LibRaw uses extension for format hints)
    let temp_dir = std::env::temp_dir();
    let temp_path = temp_dir.join(format!(
        "skotiq_raw_{}.{}",
        std::process::id(),
        extension.trim_start_matches('.')
    ));

    // Write data to temp file
    let mut file = std::fs::File::create(&temp_path).map_err(RawError::Io)?;
    file.write_all(data).map_err(RawError::Io)?;
    file.flush().map_err(RawError::Io)?;
    drop(file); // Close file before LibRaw opens it

    // Process with LibRaw
    let result = read_raw(&temp_path, params);

    // Clean up temp file (ignore errors)
    let _ = std::fs::remove_file(&temp_path);

    result
}

/// A 2×2 colour-filter-array (Bayer) pattern in sensor row-major order
/// (top-left, top-right, bottom-left, bottom-right).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CfaPattern {
    Rggb,
    Grbg,
    Gbrg,
    Bggr,
}

/// A decoded RAW frame as its native single-channel LINEAR CFA mosaic.
///
/// This is the astro-correct decode: `data` is the sensor's raw Bayer/X-Trans
/// mosaic at native bit depth — NO demosaic, white balance, gamma, or colour
/// transform — with the optical-black margins trimmed. `data.len()` is exactly
/// `width * height`. Contrast with [`read_raw`], which returns a processed
/// 3-channel sRGB image suitable only for previews/thumbnails and MUST NOT be
/// fed to the calibration/stacking/photometry pipeline.
///
/// The extraction mirrors the INDI reference driver `read_libraw()`
/// (indi-gphoto/gphoto_readimage.cpp:143-218): `unpack` + `raw2image`, then a
/// margin-trimmed, de-strided copy of `imgdata.rawdata.raw_image`.
#[derive(Debug, Clone)]
pub struct CfaImage {
    pub width: u32,
    pub height: u32,
    /// Single-channel, row-major, linear. `len() == width * height`.
    pub data: Vec<u16>,
    /// The 2×2 Bayer orientation, or `None` for X-Trans / non-CFA sensors
    /// whose mosaic cannot be faithfully described by a 2×2 pattern.
    pub cfa_pattern: Option<CfaPattern>,
    /// True for X-Trans (6×6) sensors; `cfa_pattern` is then `None`.
    pub is_xtrans: bool,
    /// True sensor bit depth (e.g. 12/14/16), derived from the saturation
    /// level so `(1 << bits) - 1` is a truthful max ADU for the data.
    pub bits_per_pixel: u32,
    /// Saturation / white level (max ADU) reported by LibRaw.
    pub max_value: u32,
    /// Global black level reported by LibRaw. Informational only — it is NOT
    /// subtracted, matching the reference driver which leaves the mosaic
    /// untouched so downstream calibration can model the pedestal itself.
    pub black_level: u32,
}

/// Derive the true sensor bit depth from LibRaw's saturation level.
///
/// The data samples span `0..=maximum` at native bit depth (LibRaw does NOT
/// left-shift the mosaic to fill 16 bits), so we report the smallest bit depth
/// that contains `maximum`. That makes `(1 << bits) - 1` a truthful max ADU —
/// unlike the reference driver, which hardcodes 16 and would tell the pipeline
/// a 14-bit frame saturates at 65535. `raw_bps` is a best-effort fallback for
/// the rare cameras where LibRaw leaves `maximum` at 0. Clamped to [8, 16].
fn derive_bits_per_pixel(maximum: u32, raw_bps: c_int) -> u32 {
    if maximum > 0 {
        (u32::BITS - maximum.leading_zeros()).clamp(8, 16)
    } else if (8..=16).contains(&raw_bps) {
        raw_bps as u32
    } else {
        16
    }
}

/// Map the 4-letter CFA descriptor (from `libraw_COLOR` × `cdesc`) to a 2×2
/// Bayer orientation. Returns `None` for X-Trans (6×6 — cannot be described by
/// a 2×2 pattern), for non-CFA data (`filters == 0`), and for any descriptor
/// that isn't one of the four canonical Bayer orders — honestly declining to
/// guess rather than silently mislabelling the mosaic for downstream debayer.
fn cfa_pattern_from_bytes(cfa: &[u8; 4], is_xtrans: bool, filters: c_int) -> Option<CfaPattern> {
    if is_xtrans || filters == 0 {
        return None;
    }
    match cfa {
        b"RGGB" => Some(CfaPattern::Rggb),
        b"GRBG" => Some(CfaPattern::Grbg),
        b"GBRG" => Some(CfaPattern::Gbrg),
        b"BGGR" => Some(CfaPattern::Bggr),
        _ => None,
    }
}

/// Read a RAW file into its native single-channel linear CFA mosaic.
///
/// See [`CfaImage`] for the contract. Use this (not [`read_raw`]) for any
/// astro capture path: DSLR/mirrorless light/dark/flat/bias frames.
pub fn read_cfa_mosaic(path: &Path) -> Result<(CfaImage, RawMetadata), RawError> {
    let path_str = path
        .to_str()
        .ok_or_else(|| RawError::InvalidPath("Path contains invalid UTF-8".to_string()))?;

    if !path.exists() {
        return Err(RawError::Io(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "File not found",
        )));
    }

    // SAFETY: FFI into LibRaw. `processor` is checked non-null; `open_file`
    // return code is checked; `decode_cfa_common` takes ownership of the
    // processor and closes it on every path (success and error).
    unsafe {
        let processor = libraw_init(0);
        if processor.is_null() {
            return Err(RawError::NullPointer);
        }

        let c_path = CString::new(path_str)
            .map_err(|_| RawError::InvalidPath("Path contains null bytes".to_string()))?;

        let ret = libraw_open_file(processor, c_path.as_ptr());
        if ret != LIBRAW_SUCCESS {
            let err_msg = get_error_string(ret);
            libraw_close(processor);
            return Err(RawError::LibRawError(format!(
                "libraw_open_file failed: {}",
                err_msg
            )));
        }

        decode_cfa_common(processor)
    }
}

/// Read a RAW frame from in-memory bytes into its native CFA mosaic.
///
/// Decodes directly from the buffer via `libraw_open_buffer` — no temp file,
/// so no filename collisions between concurrent captures. `extension` is only
/// used for diagnostics (LibRaw sniffs the real format from the bytes).
pub fn read_cfa_mosaic_from_bytes(
    data: &[u8],
    extension: &str,
) -> Result<(CfaImage, RawMetadata), RawError> {
    if data.is_empty() {
        return Err(RawError::LibRawError(
            "empty RAW buffer supplied for CFA decode".to_string(),
        ));
    }

    tracing::debug!(
        "read_cfa_mosaic_from_bytes: {} bytes, hint extension '{}'",
        data.len(),
        extension
    );

    // SAFETY: FFI into LibRaw. `processor` is checked non-null; `open_buffer`
    // borrows `data` only for the duration of the call (LibRaw copies what it
    // needs during identify/unpack); return code is checked; `decode_cfa_common`
    // owns and closes the processor on every path.
    unsafe {
        let processor = libraw_init(0);
        if processor.is_null() {
            return Err(RawError::NullPointer);
        }

        let ret = libraw_open_buffer(processor, data.as_ptr() as *const c_void, data.len());
        if ret != LIBRAW_SUCCESS {
            let err_msg = get_error_string(ret);
            libraw_close(processor);
            return Err(RawError::LibRawError(format!(
                "libraw_open_buffer failed: {}",
                err_msg
            )));
        }

        decode_cfa_common(processor)
    }
}

/// Shared tail for the CFA decode: metadata read, unpack + raw2image, then the
/// margin-trimmed single-channel copy. Takes ownership of `processor` and
/// ALWAYS closes it before returning.
///
/// SAFETY: `processor` must be a valid, freshly `libraw_open_*`-ed handle. The
/// caller must not use it after this returns.
unsafe fn decode_cfa_common(
    processor: *mut libraw_data_t,
) -> Result<(CfaImage, RawMetadata), RawError> {
    // Metadata (available post-open, pre-unpack)
    let iparams = libraw_get_iparams(processor);
    let other = libraw_get_imgother(processor);
    if iparams.is_null() || other.is_null() {
        libraw_close(processor);
        return Err(RawError::NullPointer);
    }
    let iparams = &*iparams;
    let other = &*other;

    let camera_make = CStr::from_ptr(iparams.make.as_ptr())
        .to_string_lossy()
        .trim()
        .to_string();
    let camera_model = CStr::from_ptr(iparams.model.as_ptr())
        .to_string_lossy()
        .trim()
        .to_string();
    let color_desc = CStr::from_ptr(iparams.cdesc.as_ptr())
        .to_string_lossy()
        .to_string();
    let is_xtrans_meta = iparams.filters == 9;

    let iso_speed = (other.iso_speed > 0.0).then_some(other.iso_speed);
    let shutter_speed = (other.shutter > 0.0).then_some(other.shutter);
    let aperture = (other.aperture > 0.0).then_some(other.aperture);
    let focal_length = (other.focal_len > 0.0).then_some(other.focal_len);
    let timestamp = (other.timestamp > 0).then_some(other.timestamp as i64);

    // Unpack + raw2image (NO dcraw_process → stays linear mono)
    let ret = libraw_unpack(processor);
    if ret != LIBRAW_SUCCESS {
        let err_msg = get_error_string(ret);
        libraw_close(processor);
        return Err(RawError::LibRawError(format!(
            "libraw_unpack failed: {}",
            err_msg
        )));
    }

    let ret = libraw_raw2image(processor);
    if ret != LIBRAW_SUCCESS {
        let err_msg = get_error_string(ret);
        libraw_close(processor);
        return Err(RawError::LibRawError(format!(
            "libraw_raw2image failed: {}",
            err_msg
        )));
    }

    // Extract geometry / CFA orientation / bit depth from the struct
    let mut info = skotiq_cfa_info_t {
        width: 0,
        height: 0,
        raw_width: 0,
        raw_height: 0,
        top_margin: 0,
        left_margin: 0,
        raw_bps: 0,
        maximum: 0,
        black: 0,
        filters: 0,
        is_xtrans: 0,
        cfa: [0; 8],
    };
    let ret = skotiq_libraw_extract_cfa_info(processor, &mut info);
    if ret != 0 {
        libraw_close(processor);
        return Err(RawError::UnsupportedFormat(format!(
            "this RAW has no single-channel CFA mosaic (LibRaw raw_image absent, code {}); \
             Foveon/sRAW/already-colour data is not supported by the CFA decode path",
            ret
        )));
    }

    if info.width <= 0 || info.height <= 0 {
        libraw_close(processor);
        return Err(RawError::LibRawError(format!(
            "LibRaw reported non-positive CFA dimensions: {}x{}",
            info.width, info.height
        )));
    }

    let width = info.width as u32;
    let height = info.height as u32;
    let pixel_count = (width as usize) * (height as usize);

    // Copy the visible mosaic (margins trimmed)
    let mut data = vec![0u16; pixel_count];
    let ret = skotiq_libraw_copy_cfa_mosaic(processor, data.as_mut_ptr(), data.len());
    if ret != 0 {
        libraw_close(processor);
        return Err(RawError::LibRawError(format!(
            "failed to copy CFA mosaic (code {})",
            ret
        )));
    }

    let raw_width_meta = info.raw_width.max(0) as u32;
    let raw_height_meta = info.raw_height.max(0) as u32;

    // Done with LibRaw — everything below is on owned Rust data.
    libraw_close(processor);

    // ---- True bit depth: derive from the saturation level so
    // `(1 << bits) - 1` is a truthful max ADU for the data. -----------------
    let max_value = info.maximum;
    let bits_per_pixel = derive_bits_per_pixel(max_value, info.raw_bps);

    // ---- CFA orientation. None for X-Trans (6×6, not a 2×2 pattern) and for
    // non-CFA data; a genuine 2×2 Bayer maps to one of the four orientations.
    let is_xtrans = info.is_xtrans != 0 || is_xtrans_meta;
    let cfa_bytes = [
        info.cfa[0] as u8,
        info.cfa[1] as u8,
        info.cfa[2] as u8,
        info.cfa[3] as u8,
    ];
    let cfa_pattern = cfa_pattern_from_bytes(&cfa_bytes, is_xtrans, info.filters);

    tracing::info!(
        "CFA decode: {}x{} mono mosaic, pattern={:?}, xtrans={}, {}-bit (max_adu={}, black={})",
        width,
        height,
        cfa_pattern,
        is_xtrans,
        bits_per_pixel,
        max_value,
        info.black,
    );

    let metadata = RawMetadata {
        camera_make,
        camera_model,
        iso_speed,
        shutter_speed,
        aperture,
        focal_length,
        timestamp,
        color_desc,
        is_xtrans,
        raw_width: raw_width_meta,
        raw_height: raw_height_meta,
    };

    let image = CfaImage {
        width,
        height,
        data,
        cfa_pattern,
        is_xtrans,
        bits_per_pixel,
        max_value,
        black_level: info.black,
    };

    Ok((image, metadata))
}

/// Get appropriate file extension for a detected RAW format
pub fn raw_format_extension(data: &[u8]) -> Option<&'static str> {
    use crate::ImageFormat;

    match ImageFormat::from_magic_bytes(data) {
        Some(ImageFormat::CanonCR2) => Some("cr2"),
        Some(ImageFormat::CanonCR3) => Some("cr3"),
        Some(ImageFormat::NikonNEF) => Some("nef"),
        Some(ImageFormat::SonyARW) => Some("arw"),
        Some(ImageFormat::FujifilmRAF) => Some("raf"),
        Some(ImageFormat::PentaxPEF) => Some("pef"),
        Some(ImageFormat::OlympusORF) => Some("orf"),
        Some(ImageFormat::PanasonicRW2) => Some("rw2"),
        Some(ImageFormat::GenericRAW) => Some("raw"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derive_bits_per_pixel_reports_true_depth_from_saturation() {
        // 14-bit DSLR (Canon/Nikon/Sony): maximum ~16383 -> 14, NOT 16.
        assert_eq!(derive_bits_per_pixel(16383, 14), 14);
        assert_eq!(derive_bits_per_pixel(16000, 14), 14); // white below full range
                                                          // 12-bit body.
        assert_eq!(derive_bits_per_pixel(4095, 12), 12);
        // 16-bit (e.g. GFX / some CCDs).
        assert_eq!(derive_bits_per_pixel(65535, 16), 16);
        // maximum missing -> fall back to raw_bps.
        assert_eq!(derive_bits_per_pixel(0, 14), 14);
        // both missing/bogus -> safe 16.
        assert_eq!(derive_bits_per_pixel(0, 0), 16);
        // never below 8 or above 16.
        assert_eq!(derive_bits_per_pixel(3, 0), 8);
        assert_eq!(derive_bits_per_pixel(u32::MAX, 99), 16);
    }

    #[test]
    fn cfa_pattern_maps_all_four_bayer_orientations() {
        // Standard Bayer filters value is non-zero; is_xtrans false.
        let f: c_int = 0x1949_4949; // any non-zero, non-9 Bayer filters mask
        assert_eq!(
            cfa_pattern_from_bytes(b"RGGB", false, f),
            Some(CfaPattern::Rggb)
        );
        assert_eq!(
            cfa_pattern_from_bytes(b"GRBG", false, f),
            Some(CfaPattern::Grbg)
        );
        assert_eq!(
            cfa_pattern_from_bytes(b"GBRG", false, f),
            Some(CfaPattern::Gbrg)
        );
        assert_eq!(
            cfa_pattern_from_bytes(b"BGGR", false, f),
            Some(CfaPattern::Bggr)
        );
    }

    #[test]
    fn cfa_pattern_is_none_for_xtrans_and_noncfa() {
        // X-Trans (6×6) cannot be a 2×2 pattern.
        assert_eq!(cfa_pattern_from_bytes(b"RGGB", true, 9), None);
        // filters == 0 => already-colour / no CFA.
        assert_eq!(cfa_pattern_from_bytes(b"RGGB", false, 0), None);
        // Unknown descriptor => decline to guess rather than mislabel.
        assert_eq!(cfa_pattern_from_bytes(b"XYZW", false, 0x1949_4949), None);
    }

    #[test]
    fn test_is_raw_file() {
        assert!(is_raw_file(Path::new("test.cr2")));
        assert!(is_raw_file(Path::new("test.NEF")));
        assert!(is_raw_file(Path::new("test.raf"))); // Fujifilm X-Trans!
        assert!(!is_raw_file(Path::new("test.fits")));
        assert!(!is_raw_file(Path::new("test.jpg")));
    }

    /// A `None` input must round-trip to `Ok(None)` (no error, no surprise
    /// allocation), while a normal path produces a usable CString.
    #[test]
    fn path_to_cstring_passes_through_normal_inputs() {
        assert!(matches!(path_to_cstring("bad_pixels", None), Ok(None)));

        let normal = std::path::PathBuf::from("/tmp/bad_pixels.txt");
        let c_str = path_to_cstring("bad_pixels", Some(normal.as_path()))
            .expect("clean path must succeed")
            .expect("clean path must produce Some(CString)");
        assert_eq!(c_str.to_str().unwrap(), "/tmp/bad_pixels.txt");
    }

    /// A path containing an interior NUL byte must propagate
    /// `RawError::InvalidCStringPath` with the offending field name and the
    /// original string; silently dropping the path leaves LibRaw quietly
    /// using its defaults.
    #[test]
    fn path_to_cstring_propagates_interior_nul() {
        // PathBuf::from accepts strings with NULs on Unix; on Windows we
        // synthesise the same scenario by going through OsString. Both
        // platforms surface the NUL via CString::new.
        let bad_path = std::path::PathBuf::from("contains\0nul");
        let err = path_to_cstring("bad_pixels", Some(bad_path.as_path()))
            .expect_err("interior NUL must produce RawError::InvalidCStringPath");
        match err {
            RawError::InvalidCStringPath { which, path, .. } => {
                assert_eq!(which, "bad_pixels");
                assert!(
                    path.contains('\0'),
                    "stored path should preserve the original (NUL-bearing) string for diagnostics"
                );
            }
            other => panic!(
                "expected RawError::InvalidCStringPath, got {:?} ({})",
                other, other
            ),
        }
    }

    /// Same propagation for `dark_frame` so both paths share a single helper
    /// (no copy-paste rot where one swallows and the other doesn't).
    #[test]
    fn path_to_cstring_dark_frame_path_propagates() {
        let bad_path = std::path::PathBuf::from("dark\0frame");
        let err = path_to_cstring("dark_frame", Some(bad_path.as_path()))
            .expect_err("interior NUL must produce RawError::InvalidCStringPath");
        match err {
            RawError::InvalidCStringPath { which, .. } => assert_eq!(which, "dark_frame"),
            other => panic!("expected RawError::InvalidCStringPath, got {:?}", other),
        }
    }
}
