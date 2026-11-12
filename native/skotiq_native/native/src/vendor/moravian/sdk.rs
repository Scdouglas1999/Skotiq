//! The Moravian camera libraries and the one interface the driver uses for all of them.
//!
//! Moravian ships two different C APIs. On Linux and macOS, `libgxccd`
//! (gxccd.h, the library INDI's `indi_mi_ccd` links) drives every camera with
//! `gxccd_*` calls that return 0 on success and -1 on failure. On Windows the
//! cameras are driven by the SIPS driver DLLs (cxusb.h, gxusb.h and
//! MoravianCameraDriver.pdf in Moravian's Windows SDK, the DLLs NINA loads):
//! `cXusb.dll` for the C1x, C2-9000, C3, C4 and C5 lines and `gXusb.dll` for
//! the G0-G4 CCD and the C0, C1, C1+ and C2 lines, with undecorated
//! `Initialize`/`GetValue`/... entry points that return a one-byte BOOLEAN.
//! There is no gxccd library for Windows. `gXeth.dll` (the Ethernet adapter)
//! is not loaded: it needs the adapter's address configured first.
//!
//! The two families also expose exposures differently. gxccd and cXusb let
//! the camera time the exposure (start, poll "image ready", read); gXusb lets
//! the computer time it (begin, wait, end, read).

use super::*;
use crate::vendor::sdk_loader::SdkGuard;

/// The library a camera is reached through.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Library {
    /// `libgxccd` on Linux and macOS.
    Gxccd,
    /// `cXusb.dll` on Windows.
    CxUsb,
    /// `gXusb.dll` on Windows.
    GxUsb,
}

impl Library {
    /// The libraries this platform's Moravian drivers come as.
    pub(crate) fn on_this_platform() -> &'static [Library] {
        if cfg!(windows) {
            &[Library::CxUsb, Library::GxUsb]
        } else {
            &[Library::Gxccd]
        }
    }

    /// The prefix of a device address on this library. gxccd addresses are the
    /// bare camera id, as they were before the Windows libraries were added.
    pub(crate) fn address_tag(self) -> Option<&'static str> {
        match self {
            Library::Gxccd => None,
            Library::CxUsb => Some("cx"),
            Library::GxUsb => Some("gx"),
        }
    }

    pub(crate) fn file_name(self) -> &'static str {
        match self {
            Library::Gxccd => "libgxccd",
            Library::CxUsb => "cXusb.dll",
            Library::GxUsb => "gXusb.dll",
        }
    }

    pub(crate) fn is_available(self) -> bool {
        match self {
            Library::Gxccd => GxccdSdk::is_available(),
            Library::CxUsb => CxUsbSdk::is_available(),
            Library::GxUsb => GxUsbSdk::is_available(),
        }
    }

    /// Load the library if needed and take the lock that serializes calls into it.
    pub(crate) async fn lock(self) -> Result<ApiGuard, DriverError> {
        Ok(match self {
            Library::Gxccd => ApiGuard::Gxccd(GxccdSdk::lock().await?),
            Library::CxUsb => ApiGuard::CxUsb(CxUsbSdk::lock().await?),
            Library::GxUsb => ApiGuard::GxUsb(GxUsbSdk::lock().await?),
        })
    }
}

/// A loaded Moravian library with its lock held.
pub(crate) enum ApiGuard {
    Gxccd(SdkGuard<GxccdSdk>),
    CxUsb(SdkGuard<CxUsbSdk>),
    GxUsb(SdkGuard<GxUsbSdk>),
}

impl ApiGuard {
    pub(crate) fn api(&self) -> &dyn Api {
        match self {
            ApiGuard::Gxccd(sdk) => &**sdk,
            ApiGuard::CxUsb(sdk) => &**sdk,
            ApiGuard::GxUsb(sdk) => &**sdk,
        }
    }
}

/// Who counts the exposure time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Timing {
    /// Start, poll "image ready", read (gxccd, cXusb).
    Camera,
    /// Begin, wait, end, read (gXusb); the frame is exposed from the begin
    /// call to the end call.
    Computer,
}

/// One Moravian library behind the calls the driver makes. The `raw_` methods
/// take a camera handle and must only be called with a handle this library's
/// `initialize` returned and that has not been released; [`Session`] is the
/// safe way in.
pub(crate) trait Api: Send + Sync {
    fn library(&self) -> Library;
    fn timing(&self) -> Timing;
    /// The read frame's first row is the bottom row of the image
    /// (gxccd.h:416-434). The Windows drivers deliver the top row first, as
    /// NINA reads them.
    fn bottom_up(&self) -> bool;
    /// Camera ids currently connected.
    fn enumerate(&self) -> Vec<u32>;
    /// A handle, or `None` when the camera is unplugged or held by another program.
    fn initialize(&self, id: u32) -> Option<PCCamera>;

    unsafe fn raw_release(&self, handle: PCCamera);
    unsafe fn raw_boolean(&self, handle: PCCamera, index: c_int) -> Option<bool>;
    unsafe fn raw_integer(&self, handle: PCCamera, index: c_int) -> Option<i32>;
    unsafe fn raw_string(&self, handle: PCCamera, index: c_int) -> Option<String>;
    unsafe fn raw_value(&self, handle: PCCamera, index: c_int) -> Option<f32>;
    unsafe fn raw_last_error(&self, handle: PCCamera) -> String;
    unsafe fn raw_set_temperature(&self, handle: PCCamera, celsius: f32) -> bool;
    unsafe fn raw_set_binning(&self, handle: PCCamera, x: u32, y: u32) -> bool;
    unsafe fn raw_read_mode_name(&self, handle: PCCamera, index: u32) -> Option<String>;
    unsafe fn raw_set_read_mode(&self, handle: PCCamera, index: u32) -> bool;
    /// `None` when the library has no gain call.
    unsafe fn raw_set_gain(&self, handle: PCCamera, gain: u16) -> Option<bool>;

    // Camera timing.
    unsafe fn raw_start_exposure(
        &self,
        handle: PCCamera,
        seconds: f64,
        open_shutter: bool,
        roi: SdkRoi,
    ) -> bool;
    unsafe fn raw_abort_exposure(&self, handle: PCCamera, keep_image: bool) -> bool;
    unsafe fn raw_image_ready(&self, handle: PCCamera) -> Option<bool>;
    unsafe fn raw_read_image(&self, handle: PCCamera, pixels: &mut [u16]) -> bool;

    // Computer timing.
    unsafe fn raw_begin_exposure(&self, handle: PCCamera, open_shutter: bool) -> bool;
    unsafe fn raw_end_exposure(&self, handle: PCCamera, open_shutter: bool, discard: bool) -> bool;
    unsafe fn raw_get_image(&self, handle: PCCamera, roi: SdkRoi, pixels: &mut [u16]) -> bool;
}

/// An open camera on one library: the safe face of the [`Api`] calls.
pub(crate) struct Session<'a> {
    api: &'a dyn Api,
    handle: PCCamera,
}

impl<'a> Session<'a> {
    /// # Safety
    /// `handle` came from `api.initialize` and has not been released.
    pub(crate) unsafe fn new(api: &'a dyn Api, handle: PCCamera) -> Self {
        Self { api, handle }
    }

    pub(crate) fn release(self) {
        // SAFETY: the handle is live (Session::new contract) and is not used after this.
        unsafe { self.api.raw_release(self.handle) }
    }

    pub(crate) fn boolean(&self, index: c_int) -> Option<bool> {
        // SAFETY: live handle (Session::new contract).
        unsafe { self.api.raw_boolean(self.handle, index) }
    }

    pub(crate) fn integer(&self, index: c_int) -> Option<i32> {
        // SAFETY: live handle (Session::new contract).
        unsafe { self.api.raw_integer(self.handle, index) }
    }

    pub(crate) fn string(&self, index: c_int) -> Option<String> {
        // SAFETY: live handle (Session::new contract).
        unsafe { self.api.raw_string(self.handle, index) }
    }

    pub(crate) fn value(&self, index: c_int) -> Option<f32> {
        // SAFETY: live handle (Session::new contract).
        unsafe { self.api.raw_value(self.handle, index) }
    }

    /// The library's reason for the last failed call.
    pub(crate) fn last_error(&self) -> String {
        // SAFETY: live handle (Session::new contract).
        let text = unsafe { self.api.raw_last_error(self.handle) };
        if text.is_empty() {
            "the camera driver gave no reason".to_string()
        } else {
            text
        }
    }

    pub(crate) fn set_temperature(&self, celsius: f32) -> bool {
        // SAFETY: live handle (Session::new contract).
        unsafe { self.api.raw_set_temperature(self.handle, celsius) }
    }

    pub(crate) fn set_binning(&self, x: u32, y: u32) -> bool {
        // SAFETY: live handle (Session::new contract).
        unsafe { self.api.raw_set_binning(self.handle, x, y) }
    }

    pub(crate) fn read_mode_name(&self, index: u32) -> Option<String> {
        // SAFETY: live handle (Session::new contract).
        unsafe { self.api.raw_read_mode_name(self.handle, index) }
    }

    pub(crate) fn set_read_mode(&self, index: u32) -> bool {
        // SAFETY: live handle (Session::new contract).
        unsafe { self.api.raw_set_read_mode(self.handle, index) }
    }

    pub(crate) fn set_gain(&self, gain: u16) -> Option<bool> {
        // SAFETY: live handle (Session::new contract).
        unsafe { self.api.raw_set_gain(self.handle, gain) }
    }

    pub(crate) fn start_exposure(&self, seconds: f64, open_shutter: bool, roi: SdkRoi) -> bool {
        // SAFETY: live handle (Session::new contract).
        unsafe {
            self.api
                .raw_start_exposure(self.handle, seconds, open_shutter, roi)
        }
    }

    pub(crate) fn abort_exposure(&self, keep_image: bool) -> bool {
        // SAFETY: live handle (Session::new contract).
        unsafe { self.api.raw_abort_exposure(self.handle, keep_image) }
    }

    pub(crate) fn image_ready(&self) -> Option<bool> {
        // SAFETY: live handle (Session::new contract).
        unsafe { self.api.raw_image_ready(self.handle) }
    }

    pub(crate) fn read_image(&self, pixels: &mut [u16]) -> bool {
        // SAFETY: live handle (Session::new contract); `pixels` is a valid
        // buffer and its true size is what the call passes on.
        unsafe { self.api.raw_read_image(self.handle, pixels) }
    }

    pub(crate) fn begin_exposure(&self, open_shutter: bool) -> bool {
        // SAFETY: live handle (Session::new contract).
        unsafe { self.api.raw_begin_exposure(self.handle, open_shutter) }
    }

    pub(crate) fn end_exposure(&self, open_shutter: bool, discard: bool) -> bool {
        // SAFETY: live handle (Session::new contract).
        unsafe {
            self.api
                .raw_end_exposure(self.handle, open_shutter, discard)
        }
    }

    pub(crate) fn get_image(&self, roi: SdkRoi, pixels: &mut [u16]) -> bool {
        // SAFETY: live handle (Session::new contract); `pixels` is a valid
        // buffer and its true size is what the call passes on.
        unsafe { self.api.raw_get_image(self.handle, roi, pixels) }
    }
}

// ---------------------------------------------------------------------------
// Enumeration: both APIs report cameras through a plain C callback.

static FOUND: std::sync::Mutex<Vec<u32>> = std::sync::Mutex::new(Vec::new());
static ENUMERATING: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn found(id: u32) {
    FOUND.lock().unwrap_or_else(|e| e.into_inner()).push(id);
}

pub(crate) unsafe extern "C" fn gxccd_found(id: c_int) {
    if let Ok(id) = u32::try_from(id) {
        found(id);
    }
}

/// NINA ignores id 0 from the Windows drivers' enumeration (MoravianCxUsbSdk.cs Scan).
pub(crate) unsafe extern "C" fn sips_found(id: u32) {
    if id != 0 {
        found(id);
    }
}

/// Run one library's enumeration and collect the ids its callback reported.
pub(crate) fn collect_enumeration(enumerate: impl FnOnce()) -> Vec<u32> {
    let _turn = ENUMERATING.lock().unwrap_or_else(|e| e.into_inner());
    FOUND.lock().unwrap_or_else(|e| e.into_inner()).clear();
    enumerate();
    std::mem::take(&mut *FOUND.lock().unwrap_or_else(|e| e.into_inner()))
}

/// Read a NUL-terminated string a library writes into a 256-byte buffer.
fn read_text(fill: impl FnOnce(*mut c_char, usize) -> bool) -> Option<String> {
    let mut buffer = [0 as c_char; 256];
    if !fill(buffer.as_mut_ptr(), buffer.len()) {
        return None;
    }
    buffer[buffer.len() - 1] = 0;
    // SAFETY: the buffer is zero-initialized and its last byte is NUL.
    let text = unsafe { std::ffi::CStr::from_ptr(buffer.as_ptr()) };
    Some(text.to_string_lossy().trim().to_string())
}

/// The Windows drivers return INVALID_HANDLE_VALUE when a camera cannot be
/// used (MoravianCameraDriver.pdf, Initialize); NINA also treats 0 as failure.
fn usable_sips_handle(handle: PCCamera) -> Option<PCCamera> {
    let raw = handle as usize;
    (raw != 0 && raw != usize::MAX && raw != 0xFFFF_FFFF).then_some(handle)
}

fn byte_len(pixels: &[u16]) -> usize {
    std::mem::size_of_val(pixels)
}

// ---------------------------------------------------------------------------
// libgxccd (Linux, macOS). Signatures verbatim from gxccd.h.

pub(crate) type GxccdEnumCallback = unsafe extern "C" fn(camera_id: c_int);
pub(crate) type GxccdEnumerateUsb = unsafe extern "C" fn(callback: GxccdEnumCallback);
pub(crate) type GxccdInitializeUsb = unsafe extern "C" fn(camera_id: c_int) -> PCCamera;
pub(crate) type GxccdRelease = unsafe extern "C" fn(camera: PCCamera);
pub(crate) type GxccdGetBoolean =
    unsafe extern "C" fn(camera: PCCamera, index: c_int, value: *mut GxBool) -> c_int;
pub(crate) type GxccdGetInteger =
    unsafe extern "C" fn(camera: PCCamera, index: c_int, value: *mut c_int) -> c_int;
pub(crate) type GxccdGetString =
    unsafe extern "C" fn(camera: PCCamera, index: c_int, buf: *mut c_char, size: usize) -> c_int;
pub(crate) type GxccdGetValue =
    unsafe extern "C" fn(camera: PCCamera, index: c_int, value: *mut c_float) -> c_int;
pub(crate) type GxccdSetTemperature =
    unsafe extern "C" fn(camera: PCCamera, temp: c_float) -> c_int;
pub(crate) type GxccdSetBinning =
    unsafe extern "C" fn(camera: PCCamera, x: c_int, y: c_int) -> c_int;
pub(crate) type GxccdSetGain = unsafe extern "C" fn(camera: PCCamera, gain: u16) -> c_int;
pub(crate) type GxccdSetReadMode = unsafe extern "C" fn(camera: PCCamera, mode: c_int) -> c_int;
pub(crate) type GxccdEnumerateReadModes =
    unsafe extern "C" fn(camera: PCCamera, index: c_int, buf: *mut c_char, size: usize) -> c_int;
pub(crate) type GxccdStartExposure = unsafe extern "C" fn(
    camera: PCCamera,
    exp_time: c_double,
    use_shutter: GxBool,
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
) -> c_int;
pub(crate) type GxccdAbortExposure =
    unsafe extern "C" fn(camera: PCCamera, download: GxBool) -> c_int;
pub(crate) type GxccdImageReady =
    unsafe extern "C" fn(camera: PCCamera, ready: *mut GxBool) -> c_int;
pub(crate) type GxccdReadImage =
    unsafe extern "C" fn(camera: PCCamera, buf: *mut c_void, size: usize) -> c_int;
pub(crate) type GxccdGetLastError =
    unsafe extern "C" fn(camera: PCCamera, buf: *mut c_char, size: usize);

pub(crate) fn gxccd_candidate_paths() -> Vec<std::path::PathBuf> {
    crate::vendor::sdk_loader::vendor_library_candidates(
        &[
            "libgxccd.so",
            "libgxccd.so.0",
            "libgxccd.so.2",
            "libgxccd.so.1",
            "libgxccd.dylib",
        ],
        &[],
    )
}

crate::load_vendor_sdk! {
    /// `libgxccd`, Moravian's camera library for Linux and macOS.
    vendor_name: "Moravian",
    sdk_struct: GxccdSdk,
    sdk_static: GXCCD,
    candidate_paths_fn: gxccd_candidate_paths,
    symbols: {
        enumerate_usb: b"gxccd_enumerate_usb\0" => GxccdEnumerateUsb,
        initialize_usb: b"gxccd_initialize_usb\0" => GxccdInitializeUsb,
        release: b"gxccd_release\0" => GxccdRelease,
        get_boolean_parameter: b"gxccd_get_boolean_parameter\0" => GxccdGetBoolean,
        get_integer_parameter: b"gxccd_get_integer_parameter\0" => GxccdGetInteger,
        get_string_parameter: b"gxccd_get_string_parameter\0" => GxccdGetString,
        get_value: b"gxccd_get_value\0" => GxccdGetValue,
        set_temperature: b"gxccd_set_temperature\0" => GxccdSetTemperature,
        set_binning: b"gxccd_set_binning\0" => GxccdSetBinning,
        set_gain: b"gxccd_set_gain\0" => GxccdSetGain,
        set_read_mode: b"gxccd_set_read_mode\0" => GxccdSetReadMode,
        enumerate_read_modes: b"gxccd_enumerate_read_modes\0" => GxccdEnumerateReadModes,
        start_exposure: b"gxccd_start_exposure\0" => GxccdStartExposure,
        abort_exposure: b"gxccd_abort_exposure\0" => GxccdAbortExposure,
        image_ready: b"gxccd_image_ready\0" => GxccdImageReady,
        read_image: b"gxccd_read_image\0" => GxccdReadImage,
        get_last_error: b"gxccd_get_last_error\0" => GxccdGetLastError,
    }
}

impl Api for GxccdSdk {
    fn library(&self) -> Library {
        Library::Gxccd
    }

    fn timing(&self) -> Timing {
        Timing::Camera
    }

    fn bottom_up(&self) -> bool {
        true
    }

    fn enumerate(&self) -> Vec<u32> {
        // SAFETY: `gxccd_found` matches enum_callback_t and only records ids.
        collect_enumeration(|| unsafe { (self.enumerate_usb)(gxccd_found) })
    }

    fn initialize(&self, id: u32) -> Option<PCCamera> {
        let id = c_int::try_from(id).ok()?;
        // SAFETY: gxccd_initialize_usb takes any id and returns NULL on error.
        let handle = unsafe { (self.initialize_usb)(id) };
        (!handle.is_null()).then_some(handle)
    }

    unsafe fn raw_release(&self, handle: PCCamera) {
        (self.release)(handle)
    }

    unsafe fn raw_boolean(&self, handle: PCCamera, index: c_int) -> Option<bool> {
        let mut value: GxBool = 0;
        ((self.get_boolean_parameter)(handle, index, &mut value) == 0).then_some(value != 0)
    }

    unsafe fn raw_integer(&self, handle: PCCamera, index: c_int) -> Option<i32> {
        let mut value: c_int = 0;
        ((self.get_integer_parameter)(handle, index, &mut value) == 0).then_some(value)
    }

    unsafe fn raw_string(&self, handle: PCCamera, index: c_int) -> Option<String> {
        read_text(|buf, size| (self.get_string_parameter)(handle, index, buf, size) == 0)
    }

    unsafe fn raw_value(&self, handle: PCCamera, index: c_int) -> Option<f32> {
        let mut value: c_float = 0.0;
        ((self.get_value)(handle, index, &mut value) == 0).then_some(value)
    }

    unsafe fn raw_last_error(&self, handle: PCCamera) -> String {
        read_text(|buf, size| {
            (self.get_last_error)(handle, buf, size);
            true
        })
        .unwrap_or_default()
    }

    unsafe fn raw_set_temperature(&self, handle: PCCamera, celsius: f32) -> bool {
        (self.set_temperature)(handle, celsius) == 0
    }

    unsafe fn raw_set_binning(&self, handle: PCCamera, x: u32, y: u32) -> bool {
        match (c_int::try_from(x), c_int::try_from(y)) {
            (Ok(x), Ok(y)) => (self.set_binning)(handle, x, y) == 0,
            _ => false,
        }
    }

    unsafe fn raw_read_mode_name(&self, handle: PCCamera, index: u32) -> Option<String> {
        let index = c_int::try_from(index).ok()?;
        read_text(|buf, size| (self.enumerate_read_modes)(handle, index, buf, size) == 0)
    }

    unsafe fn raw_set_read_mode(&self, handle: PCCamera, index: u32) -> bool {
        c_int::try_from(index).is_ok_and(|index| (self.set_read_mode)(handle, index) == 0)
    }

    unsafe fn raw_set_gain(&self, handle: PCCamera, gain: u16) -> Option<bool> {
        Some((self.set_gain)(handle, gain) == 0)
    }

    unsafe fn raw_start_exposure(
        &self,
        handle: PCCamera,
        seconds: f64,
        open_shutter: bool,
        roi: SdkRoi,
    ) -> bool {
        (self.start_exposure)(
            handle,
            seconds,
            open_shutter as GxBool,
            roi.x,
            roi.y,
            roi.w,
            roi.h,
        ) == 0
    }

    unsafe fn raw_abort_exposure(&self, handle: PCCamera, keep_image: bool) -> bool {
        (self.abort_exposure)(handle, keep_image as GxBool) == 0
    }

    unsafe fn raw_image_ready(&self, handle: PCCamera) -> Option<bool> {
        let mut ready: GxBool = 0;
        ((self.image_ready)(handle, &mut ready) == 0).then_some(ready != 0)
    }

    unsafe fn raw_read_image(&self, handle: PCCamera, pixels: &mut [u16]) -> bool {
        (self.read_image)(handle, pixels.as_mut_ptr().cast(), byte_len(pixels)) == 0
    }

    unsafe fn raw_begin_exposure(&self, _handle: PCCamera, _open_shutter: bool) -> bool {
        false
    }

    unsafe fn raw_end_exposure(&self, _: PCCamera, _: bool, _: bool) -> bool {
        false
    }

    unsafe fn raw_get_image(&self, _: PCCamera, _: SdkRoi, _: &mut [u16]) -> bool {
        false
    }
}

// ---------------------------------------------------------------------------
// The Windows SIPS driver DLLs. Signatures verbatim from cxusb.h / gxusb.h
// (CARDINAL = u32, INTEGER = int, BOOLEAN = u8, REAL = float, LONGREAL = double;
// the one x64 calling convention, so `__cdecl` is the C ABI).

pub(crate) type SipsEnumCallback = unsafe extern "C" fn(camera_id: u32);
pub(crate) type SipsEnumerate = unsafe extern "C" fn(callback: SipsEnumCallback);
pub(crate) type SipsInitialize = unsafe extern "C" fn(id: u32) -> PCCamera;
pub(crate) type SipsRelease = unsafe extern "C" fn(camera: PCCamera);
pub(crate) type SipsGetBoolean =
    unsafe extern "C" fn(camera: PCCamera, index: u32, value: *mut GxBool) -> GxBool;
pub(crate) type SipsGetInteger =
    unsafe extern "C" fn(camera: PCCamera, index: u32, value: *mut c_int) -> GxBool;
/// `high` is the highest character index of the buffer, its length minus one.
pub(crate) type SipsGetString =
    unsafe extern "C" fn(camera: PCCamera, index: u32, high: u32, buf: *mut c_char) -> GxBool;
pub(crate) type SipsGetValue =
    unsafe extern "C" fn(camera: PCCamera, index: u32, value: *mut c_float) -> GxBool;
pub(crate) type SipsGetLastErrorString =
    unsafe extern "C" fn(camera: PCCamera, high: u32, buf: *mut c_char);
pub(crate) type SipsSetTemperature =
    unsafe extern "C" fn(camera: PCCamera, temp: c_float) -> GxBool;
pub(crate) type SipsSetBinning = unsafe extern "C" fn(camera: PCCamera, x: u32, y: u32) -> GxBool;
pub(crate) type SipsEnumerateReadModes =
    unsafe extern "C" fn(camera: PCCamera, index: u32, high: u32, buf: *mut c_char) -> GxBool;
pub(crate) type SipsSetReadMode = unsafe extern "C" fn(camera: PCCamera, mode: u32) -> GxBool;
pub(crate) type SipsSetGain = unsafe extern "C" fn(camera: PCCamera, gain: u32) -> GxBool;
pub(crate) type SipsStartExposure = unsafe extern "C" fn(
    camera: PCCamera,
    exp_time: c_double,
    use_shutter: GxBool,
    x: c_int,
    y: c_int,
    w: c_int,
    d: c_int,
) -> GxBool;
pub(crate) type SipsAbortExposure =
    unsafe extern "C" fn(camera: PCCamera, download: GxBool) -> GxBool;
pub(crate) type SipsImageReady =
    unsafe extern "C" fn(camera: PCCamera, ready: *mut GxBool) -> GxBool;
pub(crate) type SipsReadImage =
    unsafe extern "C" fn(camera: PCCamera, buffer_len: u32, buffer: *mut c_void) -> GxBool;
pub(crate) type SipsBeginExposure =
    unsafe extern "C" fn(camera: PCCamera, use_shutter: GxBool) -> GxBool;
pub(crate) type SipsEndExposure =
    unsafe extern "C" fn(camera: PCCamera, use_shutter: GxBool, abort_data: GxBool) -> GxBool;
pub(crate) type SipsGetImage = unsafe extern "C" fn(
    camera: PCCamera,
    x: c_int,
    y: c_int,
    w: c_int,
    d: c_int,
    buffer_len: u32,
    buffer: *mut c_void,
) -> GxBool;

pub(crate) fn cxusb_candidate_paths() -> Vec<std::path::PathBuf> {
    crate::vendor::sdk_loader::vendor_library_candidates(&["cXusb.dll"], &[])
}

pub(crate) fn gxusb_candidate_paths() -> Vec<std::path::PathBuf> {
    crate::vendor::sdk_loader::vendor_library_candidates(&["gXusb.dll"], &[])
}

crate::load_vendor_sdk! {
    /// `cXusb.dll`, Moravian's Windows driver for the C1x, C2-9000, C3, C4 and C5 lines.
    vendor_name: "Moravian cXusb",
    sdk_struct: CxUsbSdk,
    sdk_static: CXUSB,
    candidate_paths_fn: cxusb_candidate_paths,
    symbols: {
        enumerate: b"Enumerate\0" => SipsEnumerate,
        initialize: b"Initialize\0" => SipsInitialize,
        release: b"Release\0" => SipsRelease,
        get_boolean_parameter: b"GetBooleanParameter\0" => SipsGetBoolean,
        get_integer_parameter: b"GetIntegerParameter\0" => SipsGetInteger,
        get_string_parameter: b"GetStringParameter\0" => SipsGetString,
        get_value: b"GetValue\0" => SipsGetValue,
        get_last_error_string: b"GetLastErrorString\0" => SipsGetLastErrorString,
        set_temperature: b"SetTemperature\0" => SipsSetTemperature,
        set_binning: b"SetBinning\0" => SipsSetBinning,
        enumerate_read_modes: b"EnumerateReadModes\0" => SipsEnumerateReadModes,
        set_read_mode: b"SetReadMode\0" => SipsSetReadMode,
        start_exposure: b"StartExposure\0" => SipsStartExposure,
        abort_exposure: b"AbortExposure\0" => SipsAbortExposure,
        image_ready: b"ImageReady\0" => SipsImageReady,
        read_image: b"ReadImage\0" => SipsReadImage,
    },
    optional_symbols: {
        set_gain: b"SetGain\0" => SipsSetGain,
    }
}

crate::load_vendor_sdk! {
    /// `gXusb.dll`, Moravian's Windows driver for the G0-G4 CCD and the C0, C1, C1+ and C2 lines.
    vendor_name: "Moravian gXusb",
    sdk_struct: GxUsbSdk,
    sdk_static: GXUSB,
    candidate_paths_fn: gxusb_candidate_paths,
    symbols: {
        enumerate: b"Enumerate\0" => SipsEnumerate,
        initialize: b"Initialize\0" => SipsInitialize,
        release: b"Release\0" => SipsRelease,
        get_boolean_parameter: b"GetBooleanParameter\0" => SipsGetBoolean,
        get_integer_parameter: b"GetIntegerParameter\0" => SipsGetInteger,
        get_string_parameter: b"GetStringParameter\0" => SipsGetString,
        get_value: b"GetValue\0" => SipsGetValue,
        get_last_error_string: b"GetLastErrorString\0" => SipsGetLastErrorString,
        set_temperature: b"SetTemperature\0" => SipsSetTemperature,
        set_binning: b"SetBinning\0" => SipsSetBinning,
        enumerate_read_modes: b"EnumerateReadModes\0" => SipsEnumerateReadModes,
        set_read_mode: b"SetReadMode\0" => SipsSetReadMode,
        begin_exposure: b"BeginExposure\0" => SipsBeginExposure,
        end_exposure: b"EndExposure\0" => SipsEndExposure,
        get_image: b"GetImage\0" => SipsGetImage,
    },
    optional_symbols: {
        set_gain: b"SetGain\0" => SipsSetGain,
    }
}

/// The calls cXusb and gXusb share, written once.
macro_rules! sips_common {
    () => {
        fn enumerate(&self) -> Vec<u32> {
            // SAFETY: `sips_found` matches the CallbackProc type and only records ids.
            collect_enumeration(|| unsafe { (self.enumerate)(sips_found) })
        }

        fn initialize(&self, id: u32) -> Option<PCCamera> {
            // SAFETY: Initialize takes any id and returns an invalid handle on error.
            usable_sips_handle(unsafe { (self.initialize)(id) })
        }

        unsafe fn raw_release(&self, handle: PCCamera) {
            (self.release)(handle)
        }

        unsafe fn raw_boolean(&self, handle: PCCamera, index: c_int) -> Option<bool> {
            let index = u32::try_from(index).ok()?;
            let mut value: GxBool = 0;
            ((self.get_boolean_parameter)(handle, index, &mut value) != 0).then_some(value != 0)
        }

        unsafe fn raw_integer(&self, handle: PCCamera, index: c_int) -> Option<i32> {
            let index = u32::try_from(index).ok()?;
            let mut value: c_int = 0;
            ((self.get_integer_parameter)(handle, index, &mut value) != 0).then_some(value)
        }

        unsafe fn raw_string(&self, handle: PCCamera, index: c_int) -> Option<String> {
            let index = u32::try_from(index).ok()?;
            read_text(|buf, size| {
                (self.get_string_parameter)(handle, index, size as u32 - 1, buf) != 0
            })
        }

        unsafe fn raw_value(&self, handle: PCCamera, index: c_int) -> Option<f32> {
            let index = u32::try_from(index).ok()?;
            let mut value: c_float = 0.0;
            ((self.get_value)(handle, index, &mut value) != 0).then_some(value)
        }

        unsafe fn raw_last_error(&self, handle: PCCamera) -> String {
            read_text(|buf, size| {
                (self.get_last_error_string)(handle, size as u32 - 1, buf);
                true
            })
            .unwrap_or_default()
        }

        unsafe fn raw_set_temperature(&self, handle: PCCamera, celsius: f32) -> bool {
            (self.set_temperature)(handle, celsius) != 0
        }

        unsafe fn raw_set_binning(&self, handle: PCCamera, x: u32, y: u32) -> bool {
            (self.set_binning)(handle, x, y) != 0
        }

        unsafe fn raw_read_mode_name(&self, handle: PCCamera, index: u32) -> Option<String> {
            read_text(|buf, size| {
                (self.enumerate_read_modes)(handle, index, size as u32 - 1, buf) != 0
            })
        }

        unsafe fn raw_set_read_mode(&self, handle: PCCamera, index: u32) -> bool {
            (self.set_read_mode)(handle, index) != 0
        }

        unsafe fn raw_set_gain(&self, handle: PCCamera, gain: u16) -> Option<bool> {
            self.set_gain
                .map(|set_gain| set_gain(handle, u32::from(gain)) != 0)
        }
    };
}

impl Api for CxUsbSdk {
    fn library(&self) -> Library {
        Library::CxUsb
    }

    fn timing(&self) -> Timing {
        Timing::Camera
    }

    fn bottom_up(&self) -> bool {
        false
    }

    sips_common!();

    unsafe fn raw_start_exposure(
        &self,
        handle: PCCamera,
        seconds: f64,
        open_shutter: bool,
        roi: SdkRoi,
    ) -> bool {
        (self.start_exposure)(
            handle,
            seconds,
            open_shutter as GxBool,
            roi.x,
            roi.y,
            roi.w,
            roi.h,
        ) != 0
    }

    unsafe fn raw_abort_exposure(&self, handle: PCCamera, keep_image: bool) -> bool {
        (self.abort_exposure)(handle, keep_image as GxBool) != 0
    }

    unsafe fn raw_image_ready(&self, handle: PCCamera) -> Option<bool> {
        let mut ready: GxBool = 0;
        ((self.image_ready)(handle, &mut ready) != 0).then_some(ready != 0)
    }

    unsafe fn raw_read_image(&self, handle: PCCamera, pixels: &mut [u16]) -> bool {
        u32::try_from(byte_len(pixels))
            .is_ok_and(|len| (self.read_image)(handle, len, pixels.as_mut_ptr().cast()) != 0)
    }

    unsafe fn raw_begin_exposure(&self, _: PCCamera, _: bool) -> bool {
        false
    }

    unsafe fn raw_end_exposure(&self, _: PCCamera, _: bool, _: bool) -> bool {
        false
    }

    unsafe fn raw_get_image(&self, _: PCCamera, _: SdkRoi, _: &mut [u16]) -> bool {
        false
    }
}

impl Api for GxUsbSdk {
    fn library(&self) -> Library {
        Library::GxUsb
    }

    fn timing(&self) -> Timing {
        Timing::Computer
    }

    fn bottom_up(&self) -> bool {
        false
    }

    sips_common!();

    unsafe fn raw_start_exposure(&self, _: PCCamera, _: f64, _: bool, _: SdkRoi) -> bool {
        false
    }

    unsafe fn raw_abort_exposure(&self, _: PCCamera, _: bool) -> bool {
        false
    }

    unsafe fn raw_image_ready(&self, _: PCCamera) -> Option<bool> {
        None
    }

    unsafe fn raw_read_image(&self, _: PCCamera, _: &mut [u16]) -> bool {
        false
    }

    unsafe fn raw_begin_exposure(&self, handle: PCCamera, open_shutter: bool) -> bool {
        (self.begin_exposure)(handle, open_shutter as GxBool) != 0
    }

    unsafe fn raw_end_exposure(&self, handle: PCCamera, open_shutter: bool, discard: bool) -> bool {
        (self.end_exposure)(handle, open_shutter as GxBool, discard as GxBool) != 0
    }

    unsafe fn raw_get_image(&self, handle: PCCamera, roi: SdkRoi, pixels: &mut [u16]) -> bool {
        u32::try_from(byte_len(pixels)).is_ok_and(|len| {
            (self.get_image)(
                handle,
                roi.x,
                roi.y,
                roi.w,
                roi.h,
                len,
                pixels.as_mut_ptr().cast(),
            ) != 0
        })
    }
}

// SAFETY: each table holds only function pointers and the library they point
// into, kept loaded for the program's lifetime; every call goes through its
// slot's lock (`Library::lock`), so no library sees concurrent calls.
unsafe impl Send for GxccdSdk {}
// SAFETY: as for `Send`.
unsafe impl Sync for GxccdSdk {}
// SAFETY: as for `GxccdSdk`.
unsafe impl Send for CxUsbSdk {}
// SAFETY: as for `GxccdSdk`.
unsafe impl Sync for CxUsbSdk {}
// SAFETY: as for `GxccdSdk`.
unsafe impl Send for GxUsbSdk {}
// SAFETY: as for `GxccdSdk`.
unsafe impl Sync for GxUsbSdk {}

// A child of this module, so the tests can build library tables of their own.
#[cfg(test)]
#[path = "tests.rs"]
mod driver_tests;
