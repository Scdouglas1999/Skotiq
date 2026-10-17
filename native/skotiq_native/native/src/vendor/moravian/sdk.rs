//! Moravian SDK function signatures and singleton loader.

use super::*;

// SDK function types; signatures verbatim from gxccd.h.

/// `typedef void (*enum_callback_t)(int device_id);` (gxccd.h:63)
pub(crate) type EnumCallback = unsafe extern "C" fn(camera_id: c_int);
/// `void gxccd_enumerate_usb(enum_callback_t callback);` (gxccd.h:188)
pub(crate) type EnumerateUsb = unsafe extern "C" fn(callback: EnumCallback);
/// `camera_t *gxccd_initialize_usb(int camera_id);` (gxccd.h:202)
pub(crate) type InitializeUsb = unsafe extern "C" fn(camera_id: c_int) -> PCCamera;
/// `void gxccd_release(camera_t *camera);` (gxccd.h:211)
pub(crate) type Release = unsafe extern "C" fn(camera: PCCamera);
/// `int gxccd_get_boolean_parameter(camera_t*, int index, bool *value);` (gxccd.h:260)
pub(crate) type GetBooleanParameter =
    unsafe extern "C" fn(camera: PCCamera, index: c_int, value: *mut GxBool) -> c_int;
/// `int gxccd_get_integer_parameter(camera_t*, int index, int *value);` (gxccd.h:296)
pub(crate) type GetIntegerParameter =
    unsafe extern "C" fn(camera: PCCamera, index: c_int, value: *mut c_int) -> c_int;
/// `int gxccd_get_string_parameter(camera_t*, int index, char *buf, size_t size);` (gxccd.h:310)
pub(crate) type GetStringParameter =
    unsafe extern "C" fn(camera: PCCamera, index: c_int, buf: *mut c_char, size: usize) -> c_int;
/// `int gxccd_get_value(camera_t*, int index, float *value);` (gxccd.h:329)
pub(crate) type GetValue =
    unsafe extern "C" fn(camera: PCCamera, index: c_int, value: *mut c_float) -> c_int;
/// `int gxccd_set_temperature(camera_t*, float temp);` (gxccd.h:336)
pub(crate) type SetTemperature = unsafe extern "C" fn(camera: PCCamera, temp: c_float) -> c_int;
/// `int gxccd_set_binning(camera_t*, int x, int y);` (gxccd.h:349)
pub(crate) type SetBinning = unsafe extern "C" fn(camera: PCCamera, x: c_int, y: c_int) -> c_int;
/// `int gxccd_set_gain(camera_t*, uint16_t gain);` (gxccd.h:478)
pub(crate) type SetGain = unsafe extern "C" fn(camera: PCCamera, gain: u16) -> c_int;
/// `int gxccd_set_read_mode(camera_t*, int mode);` (gxccd.h:469)
pub(crate) type SetReadMode = unsafe extern "C" fn(camera: PCCamera, mode: c_int) -> c_int;
/// `int gxccd_enumerate_read_modes(camera_t*, int index, char *buf, size_t size);` (gxccd.h:462)
pub(crate) type EnumerateReadModes =
    unsafe extern "C" fn(camera: PCCamera, index: c_int, buf: *mut c_char, size: usize) -> c_int;
/// `int gxccd_start_exposure(camera_t*, double exp_time, bool use_shutter, int x, int y, int w, int h);` (gxccd.h:374)
pub(crate) type StartExposure = unsafe extern "C" fn(
    camera: PCCamera,
    exp_time: c_double,
    use_shutter: GxBool,
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
) -> c_int;
/// `int gxccd_abort_exposure(camera_t*, bool download);` (gxccd.h:391)
pub(crate) type AbortExposure = unsafe extern "C" fn(camera: PCCamera, download: GxBool) -> c_int;
/// `int gxccd_image_ready(camera_t*, bool *ready);` (gxccd.h:405)
pub(crate) type ImageReady = unsafe extern "C" fn(camera: PCCamera, ready: *mut GxBool) -> c_int;
/// `int gxccd_read_image(camera_t*, void *buf, size_t size);` (gxccd.h:435)
pub(crate) type ReadImage =
    unsafe extern "C" fn(camera: PCCamera, buf: *mut c_void, size: usize) -> c_int;
/// `void gxccd_get_last_error(camera_t*, char *buf, size_t size);` (gxccd.h:583)
pub(crate) type GetLastError =
    unsafe extern "C" fn(camera: PCCamera, buf: *mut c_char, size: usize);

// SDK singleton

/// Candidate paths for the Moravian gxccd library, in search order.
pub(crate) fn moravian_candidate_paths() -> Vec<std::path::PathBuf> {
    crate::vendor::sdk_loader::vendor_library_candidates(LIB_CANDIDATES, &[])
}

crate::load_vendor_sdk! {
    /// Moravian gxccd SDK wrapper with dynamically loaded functions
    vendor_name: "Moravian",
    sdk_struct: MoravianSdk,
    sdk_static: SDK,
    candidate_paths_fn: moravian_candidate_paths,
    symbols: {
        enumerate_usb: b"gxccd_enumerate_usb\0" => EnumerateUsb,
        initialize_usb: b"gxccd_initialize_usb\0" => InitializeUsb,
        release: b"gxccd_release\0" => Release,
        get_boolean_parameter: b"gxccd_get_boolean_parameter\0" => GetBooleanParameter,
        get_integer_parameter: b"gxccd_get_integer_parameter\0" => GetIntegerParameter,
        get_string_parameter: b"gxccd_get_string_parameter\0" => GetStringParameter,
        get_value: b"gxccd_get_value\0" => GetValue,
        set_temperature: b"gxccd_set_temperature\0" => SetTemperature,
        set_binning: b"gxccd_set_binning\0" => SetBinning,
        set_gain: b"gxccd_set_gain\0" => SetGain,
        set_read_mode: b"gxccd_set_read_mode\0" => SetReadMode,
        enumerate_read_modes: b"gxccd_enumerate_read_modes\0" => EnumerateReadModes,
        start_exposure: b"gxccd_start_exposure\0" => StartExposure,
        abort_exposure: b"gxccd_abort_exposure\0" => AbortExposure,
        image_ready: b"gxccd_image_ready\0" => ImageReady,
        read_image: b"gxccd_read_image\0" => ReadImage,
        get_last_error: b"gxccd_get_last_error\0" => GetLastError,
    }
}

// SAFETY: MoravianSdk holds only function pointers and a `libloading::Library` (memory-mapped shared object). The function pointers reference code in a library kept alive for the program's lifetime (we store the Library). Every actual SDK call is serialized through `moravian_mutex()`, so the underlying gxccd SDK never sees concurrent invocation.
unsafe impl Send for MoravianSdk {}
// SAFETY: Same justification as `impl Send`: pointer-and-handle aggregate that becomes safe under the moravian_mutex serialization used by every call site.
unsafe impl Sync for MoravianSdk {}

pub(crate) fn get_sdk() -> Result<&'static MoravianSdk, NativeError> {
    MoravianSdk::get_or_reason().map_err(|reason| NativeError::SdkError(reason.to_string()))
}

/// Fetch the SDK's human-readable description of the last failing call.
///
/// SAFETY: caller must hold `moravian_mutex()` and pass a valid, initialized
/// camera handle. `gxccd_get_last_error` writes a NUL-terminated string of at
/// most `size` bytes into `buf`.
pub(crate) unsafe fn sdk_last_error(sdk: &MoravianSdk, handle: PCCamera) -> String {
    let mut buf = [0 as c_char; 256];
    (sdk.get_last_error)(handle, buf.as_mut_ptr(), buf.len());
    std::ffi::CStr::from_ptr(buf.as_ptr())
        .to_string_lossy()
        .trim()
        .to_string()
}
