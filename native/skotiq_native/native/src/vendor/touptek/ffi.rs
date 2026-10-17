//! Ogmacam (ToupTek-family) SDK types, constants and function signatures.

use super::*;

/// Opaque handle to a camera
pub(crate) type HOgmacam = *mut c_void;

/// Maximum number of cameras supported
pub(crate) const OGMACAM_MAX: usize = 128;

// Camera flags
pub(crate) const OGMACAM_FLAG_MONO: u64 = 0x00000010;
pub(crate) const OGMACAM_FLAG_TEC: u64 = 0x00000080;
pub(crate) const OGMACAM_FLAG_TEC_ONOFF: u64 = 0x00020000;
pub(crate) const OGMACAM_FLAG_ST4: u64 = 0x00000200;
pub(crate) const OGMACAM_FLAG_ROI_HARDWARE: u64 = 0x00000008;
pub(crate) const OGMACAM_FLAG_BINSKIP_SUPPORTED: u64 = 0x00000020;
pub(crate) const OGMACAM_FLAG_FAN: u64 = 0x00010000;
pub(crate) const OGMACAM_FLAG_HEAT: u64 = 0x0000008000000000;

// Options (values verified against toupcam.h / ogmacam.h)
pub(crate) const OGMACAM_OPTION_TEC: c_uint = 0x08;
// 0x06 = TOUPCAM_OPTION_BITDEPTH (0 = 8-bit, 1 = 16-bit). Do not confuse with 0x04
// (OPTION_RAW): writing bit depth to 0x04 re-sets RAW and leaves the camera in 8-bit,
// while download parses W*H bytes as W*H*2 u16 garbage.
pub(crate) const OGMACAM_OPTION_BITDEPTH: c_uint = 0x06;
// 0x17 = TOUPCAM_OPTION_BINNING. Do not confuse with 0x01 (OPTION_NOFRAME_TIMEOUT,
// minimum 500ms): writing a bin factor there sets a frame timeout and never bins.
pub(crate) const OGMACAM_OPTION_BINNING: c_uint = 0x17;
pub(crate) const OGMACAM_OPTION_RAW: c_uint = 0x04;
/// [RW] cooling fan speed, 0 = off, [1, `maxfanspeed`] otherwise.
pub(crate) const OGMACAM_OPTION_FAN: c_uint = 0x07;
/// [RW] anti-fogging heater level, 0 = off.
pub(crate) const OGMACAM_OPTION_HEAT: c_uint = 0x37;
/// [RW] USB bandwidth as a percentage, [1, 100].
pub(crate) const OGMACAM_OPTION_BANDWIDTH: c_uint = 0x2e;
// 0x0b = TOUPCAM_OPTION_TRIGGER. Value 1 selects software/simulated trigger mode, the
// prerequisite for the software-trigger + pull-mode capture pipeline used below.
pub(crate) const OGMACAM_OPTION_TRIGGER: c_uint = 0x0b;

// Pull-mode event codes delivered to the StartPullModeWithCallback callback.
// A software-triggered frame arrives as EVENT_IMAGE (live image), pulled with bStill = 0.
pub(crate) const OGMACAM_EVENT_IMAGE: c_uint = 0x0004;
pub(crate) const OGMACAM_EVENT_ERROR: c_uint = 0x0080;
pub(crate) const OGMACAM_EVENT_DISCONNECTED: c_uint = 0x0081;
pub(crate) const OGMACAM_EVENT_NOFRAMETIMEOUT: c_uint = 0x0082;

/// Camera model information
#[repr(C)]
#[derive(Debug, Clone)]
pub struct OgmacamModelV2 {
    pub name: *const c_char,
    pub flag: u64,
    pub maxspeed: c_uint,
    pub preview: c_uint,
    pub still: c_uint,
    pub maxfanspeed: c_uint,
    pub ioctrol: c_uint,
    pub xpixsz: f32,
    pub ypixsz: f32,
    pub res: [OgmacamResolution; 16],
}

/// Resolution info
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct OgmacamResolution {
    pub width: c_uint,
    pub height: c_uint,
}

#[cfg(windows)]
pub type OgmacamChar = u16;
#[cfg(not(windows))]
pub type OgmacamChar = c_char;

/// Device info for enumeration. The SDK uses UTF-16 on Windows and narrow C strings elsewhere.
#[repr(C)]
pub struct OgmacamDeviceV2 {
    pub displayname: [OgmacamChar; 64],
    pub id: [OgmacamChar; 64],
    pub model: *const OgmacamModelV2,
}

impl Clone for OgmacamDeviceV2 {
    fn clone(&self) -> Self {
        Self {
            displayname: self.displayname,
            id: self.id,
            model: self.model, // Copy the pointer
        }
    }
}

/// Frame info structure
#[repr(C)]
#[derive(Debug, Clone, Default)]
pub struct OgmacamFrameInfoV3 {
    pub width: c_uint,
    pub height: c_uint,
    pub flag: c_uint,
    pub seq: c_uint,
    pub timestamp: u64,
    pub shutterseq: c_uint,
    pub expotime: c_uint,
    pub expogain: u16,
    pub blacklevel: u16,
}

// SDK function types

pub(crate) type OgmacamEnumV2 = unsafe extern "system" fn(arr: *mut OgmacamDeviceV2) -> c_uint;
pub(crate) type OgmacamOpen = unsafe extern "system" fn(id: *const c_void) -> HOgmacam;
pub(crate) type OgmacamClose = unsafe extern "system" fn(h: HOgmacam);
pub(crate) type OgmacamStop = unsafe extern "system" fn(h: HOgmacam) -> i32;

// Frame pulling
pub(crate) type OgmacamPullImageV3 = unsafe extern "system" fn(
    h: HOgmacam,
    p_image_data: *mut c_void,
    b_still: c_int,
    bits: c_int,
    row_pitch: c_int,
    p_info: *mut OgmacamFrameInfoV3,
) -> i32;

// Exposure
pub(crate) type OgmacamPutExpoTime = unsafe extern "system" fn(h: HOgmacam, time: c_uint) -> i32;

// Gain
pub(crate) type OgmacamGetExpoAGain = unsafe extern "system" fn(h: HOgmacam, gain: *mut u16) -> i32;
pub(crate) type OgmacamPutExpoAGain = unsafe extern "system" fn(h: HOgmacam, gain: u16) -> i32;
pub(crate) type OgmacamGetExpoAGainRange = unsafe extern "system" fn(
    h: HOgmacam,
    n_min: *mut u16,
    n_max: *mut u16,
    n_def: *mut u16,
) -> i32;

// Temperature
pub(crate) type OgmacamGetTemperature =
    unsafe extern "system" fn(h: HOgmacam, temp: *mut i16) -> i32;
pub(crate) type OgmacamPutTemperature = unsafe extern "system" fn(h: HOgmacam, temp: i16) -> i32;
pub(crate) type OgmacamGetRawFormat = unsafe extern "system" fn(
    h: HOgmacam,
    p_fourcc: *mut c_uint,
    p_bits_per_pixel: *mut c_uint,
) -> i32;

// Options
pub(crate) type OgmacamPutOption =
    unsafe extern "system" fn(h: HOgmacam, opt: c_uint, val: c_int) -> i32;
pub(crate) type OgmacamGetOption =
    unsafe extern "system" fn(h: HOgmacam, opt: c_uint, val: *mut c_int) -> i32;

// Resolution/ROI
pub(crate) type OgmacamGetSize =
    unsafe extern "system" fn(h: HOgmacam, w: *mut c_int, h_: *mut c_int) -> i32;
pub(crate) type OgmacamPutRoi = unsafe extern "system" fn(
    h: HOgmacam,
    x_offset: c_uint,
    y_offset: c_uint,
    x_width: c_uint,
    y_height: c_uint,
) -> i32;

/// Final output size after ROI, rotate and binning (Ogmacam_get_FinalSize).
pub(crate) type OgmacamGetFinalSize =
    unsafe extern "system" fn(h: HOgmacam, w: *mut c_int, h_: *mut c_int) -> i32;

// Serial number and info
pub(crate) type OgmacamGetSerialNumber =
    unsafe extern "system" fn(h: HOgmacam, sn: *mut c_char) -> i32;

// Software trigger + pull-mode streaming.
// Matches `typedef void (__stdcall* PTOUPCAM_EVENT_CALLBACK)(unsigned nEvent, void* ctxEvent)`
// (toupcam.h:412). `__stdcall` == Rust `extern "system"` on Win32 and the C ABI elsewhere.
pub(crate) type OgmacamEventCallback = unsafe extern "system" fn(n_event: c_uint, ctx: *mut c_void);
pub(crate) type OgmacamStartPullModeWithCallback = unsafe extern "system" fn(
    h: HOgmacam,
    fun_event: OgmacamEventCallback,
    ctx_event: *mut c_void,
) -> i32;
/// Ogmacam_Trigger(h, nNumber): nNumber = 1 fires one software-triggered frame, 0 cancels.
pub(crate) type OgmacamTrigger = unsafe extern "system" fn(h: HOgmacam, n_number: c_ushort) -> i32;

// SDK metadata
pub(crate) type OgmacamVersion = unsafe extern "system" fn() -> *const c_char;

/// Heap-stable state shared with the SDK's pull-mode event callback.
///
/// Owned by a `Box` inside [`TouptekCamera`] so its address is stable across moves of the
/// camera struct (the camera is moved into a `HashMap` after connect). The callback only
/// ever reads/writes these two atomics — it never calls back into the SDK, which is
/// mandatory: `Ogmacam_Stop`/`Ogmacam_Close` deadlock if invoked from the callback context
/// (toupcam.h:410).
pub(crate) struct TouptekEventState {
    /// Set true on EVENT_IMAGE — a software-triggered frame is ready to pull.
    pub(crate) image_ready: AtomicBool,
    /// Set true on EVENT_ERROR / EVENT_DISCONNECTED / EVENT_NOFRAMETIMEOUT.
    pub(crate) error: AtomicBool,
}

/// Pull-mode event callback registered via `Ogmacam_StartPullModeWithCallback`.
///
/// SAFETY / lifetime proof: `ctx` is the pointer to the heap-allocated `TouptekEventState`
/// that `connect()` registered. The owning `Box` lives in `TouptekCamera::event_state` and
/// is only dropped AFTER `Ogmacam_Stop` + `Ogmacam_Close` have returned (see `disconnect()`
/// and the `Drop` impl). Stop/Close synchronize with and quiesce the SDK's internal
/// streaming thread, so once either returns no further callback can be dispatched. Therefore
/// while this function can run, the pointee is always live — it can never observe freed
/// memory. The `ctx.is_null()` guard defends against a spurious null context. This function
/// performs no SDK calls, only atomic stores, so it is reentrancy- and deadlock-safe.
pub(crate) unsafe extern "system" fn touptek_event_callback(n_event: c_uint, ctx: *mut c_void) {
    if ctx.is_null() {
        return;
    }
    // SAFETY: see the lifetime proof above — `ctx` points to a live `TouptekEventState`.
    let state = unsafe { &*(ctx as *const TouptekEventState) };
    match n_event {
        OGMACAM_EVENT_IMAGE => state.image_ready.store(true, Ordering::SeqCst),
        OGMACAM_EVENT_ERROR | OGMACAM_EVENT_DISCONNECTED | OGMACAM_EVENT_NOFRAMETIMEOUT => {
            state.error.store(true, Ordering::SeqCst);
        }
        _ => {}
    }
}
