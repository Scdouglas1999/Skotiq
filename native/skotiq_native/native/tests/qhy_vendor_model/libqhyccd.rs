//! A software QHY camera written from the vendor's documents only: the SDK
//! headers of libqhy 26.07.21 (qhyccd.h, qhyccdstruct.h, qhyccderr.h), the
//! x64 libqhyccd.bin they ship with (CONTROL_CFWPORT and CONTROL_COOLER cases
//! of SetQHYCCDParam/GetQHYCCDParam), and what INDI's indi-qhy and NINA's
//! QHYCamera rely on. It is independent of tests/qhy_fake_sdk.
//!
//! Built as `libqhyccd.so`; `tests/qhy_vendor_model.rs` drives Skotiq's driver
//! against it and inspects it through the `model_*` functions.
//!
//! What it holds the driver to:
//! - InitQHYCCD needs SetQHYCCDStreamMode first and resets the read mode's
//!   gain and offset, the binning (1x1), the window (whole chip) and the bit
//!   depth; it also ends an exposure in progress (logged as a fault).
//! - GetQHYCCDEffectiveArea answers in pixels of the current binning, so only
//!   a 1x1 answer is the unbinned imaging area (NINA SetImageResolution).
//! - SetQHYCCDResolution takes binned pixels inside the binned chip.
//! - IsQHYCCDControlAvailable(CAM_COLOR) answers the BAYER_ID (INDI, NINA);
//!   GetQHYCCDParam answers QHYCCD_ERROR for anything it cannot read.
//! - The cooler regulates only while the set-point keeps arriving at least
//!   every 2 s ("old firmware", NINA); CONTROL_MANULPWM switches to manual.
//! - GetQHYCCDSingleFrame blocks until the exposure is over and fails after
//!   CancelQHYCCDExposingAndReadout. A camera that answered
//!   QHYCCD_READ_DIRECTLY must be read right after the start (qhyccderr.h).
//! - The CFW reports 'N' while it turns, then its slot as '0'..'F'.
//! - OpenQHYCCD on an open camera returns its handle; CloseQHYCCD closes it
//!   for every holder and ends its exposure.

#![allow(non_snake_case, clippy::missing_safety_doc)]

use std::ffi::{c_char, c_double, c_int, c_uint, c_void, CStr};
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

const SUCCESS: c_uint = 0;
const ERROR: c_uint = 0xFFFF_FFFF;
const READ_DIRECTLY: c_uint = 0x2001;
const DELAY_200MS: c_uint = 0x2000;
const ERROR_VALUE: f64 = ERROR as f64;

const CONTROL_GAIN: c_int = 6;
const CONTROL_OFFSET: c_int = 7;
const CONTROL_EXPOSURE: c_int = 8;
const CONTROL_USBTRAFFIC: c_int = 12;
const CONTROL_CURTEMP: c_int = 14;
const CONTROL_CURPWM: c_int = 15;
const CONTROL_MANULPWM: c_int = 16;
const CONTROL_CFWPORT: c_int = 17;
const CONTROL_COOLER: c_int = 18;
const CONTROL_ST4PORT: c_int = 19;
const CAM_COLOR: c_int = 20;
const CAM_BIN1X1MODE: c_int = 21;
const CAM_BIN4X4MODE: c_int = 24;
const CAM_MECHANICALSHUTTER: c_int = 25;
const CAM_16BITS: c_int = 35;
const CONTROL_CFWSLOTSNUM: c_int = 44;
const CAM_SENSOR_ULVO_STATUS: c_int = 67;

#[derive(Clone, Copy, PartialEq)]
enum Cooler {
    Off,
    Auto { target: f64, last: Instant },
    Manual(f64),
}

#[derive(Clone, Copy)]
struct Frame {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
}

#[derive(Clone, Copy)]
struct Exposure {
    started: Instant,
    us: f64,
    bin: u32,
    window: Frame,
    bits: u32,
    gain: f64,
    offset: f64,
    shutter: Option<u8>,
    canceled: bool,
}

struct Model {
    id: &'static str,
    chip: (u32, u32),
    effective: Frame,
    bins: u32,
    bayer: Option<c_uint>,
    cooled: bool,
    thermometer: bool,
    shutter: bool,
    wheel_slots: Option<f64>,
    read_modes: &'static [(&'static str, f64, f64)],
    power_on_bits: u32,
    read_directly: bool,
    bin_delay: bool,
}

const MODELS: [Model; 3] = [
    Model {
        id: "QHY268C-1a2b3c",
        chip: (640, 480),
        effective: Frame {
            x: 16,
            y: 8,
            w: 600,
            h: 460,
        },
        bins: 4,
        bayer: Some(4), // BAYER_RG
        cooled: true,
        thermometer: true,
        shutter: false,
        wheel_slots: Some(7.0),
        read_modes: &[
            ("Photographic DSO", 0.0, 30.0),
            ("High Gain Mode", 56.0, 20.0),
        ],
        power_on_bits: 16,
        read_directly: false,
        bin_delay: false,
    },
    Model {
        id: "QHY9S-M-0077",
        chip: (400, 300),
        effective: Frame {
            x: 4,
            y: 2,
            w: 390,
            h: 296,
        },
        bins: 4,
        bayer: None,
        cooled: true,
        thermometer: true,
        shutter: true,
        wheel_slots: None,
        read_modes: &[("STANDARD MODE", 10.0, 120.0)],
        power_on_bits: 16,
        read_directly: true,
        bin_delay: true,
    },
    Model {
        id: "QHY5III462C-9a",
        chip: (320, 240),
        effective: Frame {
            x: 0,
            y: 0,
            w: 320,
            h: 240,
        },
        bins: 2,
        bayer: Some(1), // BAYER_GB
        cooled: false,
        thermometer: false,
        shutter: false,
        wheel_slots: Some(255.0),
        read_modes: &[("Normal", 0.0, 0.0)],
        power_on_bits: 8,
        read_directly: false,
        bin_delay: false,
    },
];

struct Camera {
    model: usize,
    open: bool,
    opens: u32,
    closes: u32,
    stream_mode_set: bool,
    initialized: bool,
    read_mode: u32,
    pending_read_mode: u32,
    gain: f64,
    offset: f64,
    exposure_us: f64,
    bin: u32,
    window: Frame,
    bits: u32,
    debayer: Option<bool>,
    shutter: Option<u8>,
    exposure: Option<Exposure>,
    reading: bool,
    cooler: Cooler,
    longest_setpoint_gap: f64,
    lapsed: bool,
    wheel_slot: u32,
    wheel_turning_until: Instant,
    events: Vec<String>,
    faults: Vec<String>,
}

impl Camera {
    fn new(model: usize) -> Self {
        let m = &MODELS[model];
        Camera {
            model,
            open: false,
            opens: 0,
            closes: 0,
            stream_mode_set: false,
            initialized: false,
            read_mode: 0,
            pending_read_mode: 0,
            gain: m.read_modes[0].1,
            offset: m.read_modes[0].2,
            exposure_us: 20_000.0,
            bin: 1,
            window: Frame {
                x: 0,
                y: 0,
                w: m.chip.0,
                h: m.chip.1,
            },
            bits: m.power_on_bits,
            debayer: None,
            shutter: None,
            exposure: None,
            reading: false,
            cooler: Cooler::Off,
            longest_setpoint_gap: 0.0,
            lapsed: false,
            wheel_slot: 0,
            wheel_turning_until: Instant::now() + Duration::from_millis(300),
            events: Vec::new(),
            faults: Vec::new(),
        }
    }
    fn m(&self) -> &'static Model {
        &MODELS[self.model]
    }
    fn event(&mut self, e: String) {
        self.events.push(e);
    }
    fn fault(&mut self, e: String) {
        self.faults.push(e);
    }
    fn regulating_power(&mut self) -> f64 {
        match self.cooler {
            Cooler::Off => 0.0,
            Cooler::Manual(pwm) => pwm,
            Cooler::Auto { last, .. } => {
                if last.elapsed().as_secs_f64() > 2.0 {
                    self.lapsed = true;
                    0.0
                } else {
                    127.5
                }
            }
        }
    }
}

struct State {
    camera: Option<Camera>,
}

static STATE: Mutex<State> = Mutex::new(State { camera: None });
static FRAME_DONE: Condvar = Condvar::new();

fn state() -> MutexGuard<'static, State> {
    STATE.lock().unwrap_or_else(|p| p.into_inner())
}

/// The camera behind `handle`, if it is open; a closed or foreign handle is a fault.
fn with_open<R>(
    handle: *mut c_void,
    what: &str,
    fallback: R,
    f: impl FnOnce(&mut Camera) -> R,
) -> R {
    let mut st = state();
    let Some(cam) = st.camera.as_mut() else {
        return fallback;
    };
    if handle != handle_value() || !cam.open {
        cam.fault(format!("{what} on a closed handle"));
        return fallback;
    }
    f(cam)
}

fn handle_value() -> *mut c_void {
    0x5148_5900usize as *mut c_void
}

// ---- inspection for the test ----

#[no_mangle]
pub extern "C" fn model_reset(model: c_uint) {
    state().camera = Some(Camera::new(model as usize));
}

/// The log as one '\n'-joined string; `faults` selects the fault log.
#[no_mangle]
pub unsafe extern "C" fn model_log(faults: bool, buf: *mut c_char, len: usize) -> usize {
    let st = state();
    let text = st
        .camera
        .as_ref()
        .map(|c| {
            if faults {
                c.faults.join("\n")
            } else {
                c.events.join("\n")
            }
        })
        .unwrap_or_default();
    let bytes = text.as_bytes();
    let n = bytes.len().min(len.saturating_sub(1));
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, n);
    *buf.add(n) = 0;
    bytes.len()
}

#[no_mangle]
pub extern "C" fn model_clear_log() {
    if let Some(c) = state().camera.as_mut() {
        c.events.clear();
    }
}

/// [opens, closes, open, initialized, gain, offset, bits, read_mode,
///  longest set-point gap (ms), regulation lapsed, cooler mode (0 off, 1 auto, 2 manual), auto target]
#[no_mangle]
pub unsafe extern "C" fn model_status(out: *mut f64) {
    let st = state();
    let Some(c) = st.camera.as_ref() else { return };
    let (mode, target) = match c.cooler {
        Cooler::Off => (0.0, 0.0),
        Cooler::Auto { target, .. } => (1.0, target),
        Cooler::Manual(_) => (2.0, 0.0),
    };
    let values = [
        c.opens as f64,
        c.closes as f64,
        c.open as u8 as f64,
        c.initialized as u8 as f64,
        c.gain,
        c.offset,
        c.bits as f64,
        c.read_mode as f64,
        c.longest_setpoint_gap * 1000.0,
        c.lapsed as u8 as f64,
        mode,
        target,
    ];
    std::ptr::copy_nonoverlapping(values.as_ptr(), out, values.len());
}

// ---- SDK ----

#[no_mangle]
pub extern "C" fn InitQHYCCDResource() -> c_uint {
    SUCCESS
}

#[no_mangle]
pub extern "C" fn ReleaseQHYCCDResource() -> c_uint {
    SUCCESS
}

#[no_mangle]
pub unsafe extern "C" fn GetQHYCCDSDKVersion(
    y: *mut c_uint,
    m: *mut c_uint,
    d: *mut c_uint,
    s: *mut c_uint,
) -> c_uint {
    *y = 26;
    *m = 7;
    *d = 21;
    *s = 0;
    SUCCESS
}

#[no_mangle]
pub extern "C" fn ScanQHYCCD() -> c_uint {
    if let Some(c) = state().camera.as_mut() {
        c.event("ScanQHYCCD".into());
        1
    } else {
        0
    }
}

#[no_mangle]
pub unsafe extern "C" fn GetQHYCCDId(index: c_uint, id: *mut c_char) -> c_uint {
    let st = state();
    let Some(c) = st.camera.as_ref() else {
        return ERROR;
    };
    if index != 0 {
        return ERROR;
    }
    let bytes = c.m().id.as_bytes();
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), id as *mut u8, bytes.len());
    *id.add(bytes.len()) = 0;
    SUCCESS
}

#[no_mangle]
pub unsafe extern "C" fn OpenQHYCCD(id: *const c_char) -> *mut c_void {
    let id = CStr::from_ptr(id).to_string_lossy().into_owned();
    let mut st = state();
    let Some(c) = st.camera.as_mut() else {
        return std::ptr::null_mut();
    };
    if id != c.m().id {
        return std::ptr::null_mut();
    }
    c.event(format!("OpenQHYCCD(already open: {})", c.open));
    if !c.open {
        c.open = true;
        c.opens += 1;
        c.initialized = false;
        c.stream_mode_set = false;
    }
    handle_value()
}

#[no_mangle]
pub extern "C" fn CloseQHYCCD(handle: *mut c_void) -> c_uint {
    with_open(handle, "CloseQHYCCD", ERROR, |c| {
        c.event("CloseQHYCCD".into());
        if let Some(e) = c.exposure.as_mut() {
            e.canceled = true;
        }
        c.open = false;
        c.initialized = false;
        c.closes += 1;
        c.cooler = Cooler::Off;
        FRAME_DONE.notify_all();
        SUCCESS
    })
}

#[no_mangle]
pub extern "C" fn SetQHYCCDStreamMode(handle: *mut c_void, mode: u8) -> c_uint {
    with_open(handle, "SetQHYCCDStreamMode", ERROR, |c| {
        c.event(format!("SetQHYCCDStreamMode({mode})"));
        c.stream_mode_set = mode == 0;
        SUCCESS
    })
}

#[no_mangle]
pub extern "C" fn InitQHYCCD(handle: *mut c_void) -> c_uint {
    with_open(handle, "InitQHYCCD", ERROR, |c| {
        c.event("InitQHYCCD".into());
        if !c.stream_mode_set {
            c.fault("InitQHYCCD before SetQHYCCDStreamMode".into());
        }
        if c.exposure.is_some_and(|e| !e.canceled) {
            c.fault("InitQHYCCD during an exposure".into());
            if let Some(e) = c.exposure.as_mut() {
                e.canceled = true;
            }
            FRAME_DONE.notify_all();
        }
        c.read_mode = c.pending_read_mode;
        let (_, gain, offset) = c.m().read_modes[c.read_mode as usize];
        c.gain = gain;
        c.offset = offset;
        c.bin = 1;
        c.window = Frame {
            x: 0,
            y: 0,
            w: c.m().chip.0,
            h: c.m().chip.1,
        };
        c.bits = c.m().power_on_bits;
        c.debayer = None;
        c.initialized = true;
        SUCCESS
    })
}

fn require_init(c: &mut Camera, what: &str) -> bool {
    if !c.initialized {
        c.fault(format!("{what} before InitQHYCCD"));
    }
    c.initialized
}

#[no_mangle]
pub unsafe extern "C" fn GetQHYCCDChipInfo(
    handle: *mut c_void,
    chipw: *mut c_double,
    chiph: *mut c_double,
    imagew: *mut c_uint,
    imageh: *mut c_uint,
    pixelw: *mut c_double,
    pixelh: *mut c_double,
    bpp: *mut c_uint,
) -> c_uint {
    with_open(handle, "GetQHYCCDChipInfo", ERROR, |c| {
        if !require_init(c, "GetQHYCCDChipInfo") {
            return ERROR;
        }
        let (w, h) = c.m().chip;
        *chipw = w as f64 * 0.00376;
        *chiph = h as f64 * 0.00376;
        *imagew = w;
        *imageh = h;
        *pixelw = 3.76;
        *pixelh = 3.76;
        *bpp = c.bits;
        SUCCESS
    })
}

#[no_mangle]
pub unsafe extern "C" fn GetQHYCCDEffectiveArea(
    handle: *mut c_void,
    x: *mut c_uint,
    y: *mut c_uint,
    w: *mut c_uint,
    h: *mut c_uint,
) -> c_uint {
    with_open(handle, "GetQHYCCDEffectiveArea", ERROR, |c| {
        let e = c.m().effective;
        let b = c.bin;
        *x = e.x / b;
        *y = e.y / b;
        *w = e.w / b;
        *h = e.h / b;
        SUCCESS
    })
}

#[no_mangle]
pub extern "C" fn IsQHYCCDControlAvailable(handle: *mut c_void, control: c_int) -> c_uint {
    with_open(handle, "IsQHYCCDControlAvailable", ERROR, |c| {
        let m = c.m();
        let yes = |b: bool| if b { SUCCESS } else { ERROR };
        match control {
            CAM_COLOR => m.bayer.unwrap_or(ERROR),
            CONTROL_GAIN | CONTROL_OFFSET | CONTROL_EXPOSURE | CONTROL_USBTRAFFIC | CAM_16BITS => {
                SUCCESS
            }
            CONTROL_COOLER | CONTROL_MANULPWM | CONTROL_CURPWM => yes(m.cooled),
            CONTROL_CURTEMP => yes(m.thermometer),
            CONTROL_ST4PORT => yes(m.model_has_st4()),
            CAM_MECHANICALSHUTTER => yes(m.shutter),
            CAM_BIN1X1MODE..=CAM_BIN4X4MODE => yes((control - CAM_BIN1X1MODE + 1) as u32 <= m.bins),
            CONTROL_CFWPORT | CONTROL_CFWSLOTSNUM => yes(m.wheel_slots.is_some()),
            CAM_SENSOR_ULVO_STATUS => yes(c.model == 0),
            _ => ERROR,
        }
    })
}

impl Model {
    fn model_has_st4(&self) -> bool {
        self.cooled
    }
}

#[no_mangle]
pub extern "C" fn SetQHYCCDParam(handle: *mut c_void, control: c_int, value: c_double) -> c_uint {
    with_open(handle, "SetQHYCCDParam", ERROR, |c| {
        if !require_init(c, "SetQHYCCDParam") {
            return ERROR;
        }
        let m = c.m();
        c.event(format!("SetQHYCCDParam({control}, {value})"));
        match control {
            CONTROL_GAIN => c.gain = value,
            CONTROL_OFFSET => c.offset = value,
            CONTROL_EXPOSURE => c.exposure_us = value,
            CONTROL_USBTRAFFIC => {}
            CONTROL_COOLER if m.cooled => {
                if let Cooler::Auto { last, .. } = c.cooler {
                    let gap = last.elapsed().as_secs_f64();
                    c.longest_setpoint_gap = c.longest_setpoint_gap.max(gap);
                    if gap > 2.0 {
                        c.lapsed = true;
                    }
                }
                c.cooler = Cooler::Auto {
                    target: value,
                    last: Instant::now(),
                };
            }
            CONTROL_MANULPWM if m.cooled => {
                if !(0.0..=255.0).contains(&value) {
                    return ERROR;
                }
                c.cooler = if value == 0.0 {
                    Cooler::Off
                } else {
                    Cooler::Manual(value)
                };
            }
            CONTROL_CFWPORT if m.wheel_slots == Some(7.0) => return order_wheel(c, value as u8),
            _ => return ERROR,
        }
        SUCCESS
    })
}

fn order_wheel(c: &mut Camera, order: u8) -> c_uint {
    let slot = match order {
        b'0'..=b'9' => order - b'0',
        b'A'..=b'F' => order - b'A' + 10,
        _ => return ERROR,
    } as u32;
    if slot >= 7 {
        return ERROR;
    }
    c.event(format!("CFW order {}", order as char));
    c.wheel_slot = slot;
    c.wheel_turning_until = Instant::now() + Duration::from_millis(800);
    SUCCESS
}

fn wheel_status(c: &Camera) -> u8 {
    if Instant::now() < c.wheel_turning_until {
        b'N'
    } else {
        b'0' + c.wheel_slot as u8
    }
}

#[no_mangle]
pub extern "C" fn GetQHYCCDParam(handle: *mut c_void, control: c_int) -> c_double {
    with_open(handle, "GetQHYCCDParam", ERROR_VALUE, |c| {
        if !require_init(c, "GetQHYCCDParam") {
            return ERROR_VALUE;
        }
        let m = c.m();
        match control {
            CONTROL_GAIN => c.gain,
            CONTROL_OFFSET => c.offset,
            CONTROL_EXPOSURE => c.exposure_us,
            CONTROL_USBTRAFFIC => 30.0,
            CONTROL_CURPWM if m.cooled => c.regulating_power(),
            CONTROL_CURTEMP if m.thermometer => 20.0 - c.regulating_power() / 255.0 * 30.0,
            CONTROL_CFWSLOTSNUM => m.wheel_slots.unwrap_or(ERROR_VALUE),
            CONTROL_CFWPORT if m.wheel_slots == Some(7.0) => wheel_status(c) as f64,
            CAM_SENSOR_ULVO_STATUS if c.model == 0 => 1.0,
            _ => ERROR_VALUE,
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn GetQHYCCDParamMinMaxStep(
    handle: *mut c_void,
    control: c_int,
    min: *mut c_double,
    max: *mut c_double,
    step: *mut c_double,
) -> c_uint {
    with_open(handle, "GetQHYCCDParamMinMaxStep", ERROR, |c| {
        let range = match control {
            CONTROL_GAIN => (0.0, 100.0, 1.0),
            CONTROL_OFFSET => (0.0, 255.0, 1.0),
            CONTROL_EXPOSURE => (1.0, 3_600_000_000.0, 1.0),
            CONTROL_MANULPWM if c.m().cooled => (0.0, 255.0, 1.0),
            CONTROL_COOLER if c.m().cooled => (-50.0, 50.0, 0.5),
            _ => return ERROR,
        };
        *min = range.0;
        *max = range.1;
        *step = range.2;
        SUCCESS
    })
}

#[no_mangle]
pub extern "C" fn SetQHYCCDBinMode(handle: *mut c_void, wbin: c_uint, hbin: c_uint) -> c_uint {
    with_open(handle, "SetQHYCCDBinMode", ERROR, |c| {
        c.event(format!("SetQHYCCDBinMode({wbin}, {hbin})"));
        if wbin != hbin || wbin == 0 || wbin > c.m().bins {
            return ERROR;
        }
        let changed = c.bin != wbin;
        c.bin = wbin;
        if changed && c.m().bin_delay {
            DELAY_200MS
        } else {
            SUCCESS
        }
    })
}

#[no_mangle]
pub extern "C" fn SetQHYCCDResolution(
    handle: *mut c_void,
    x: c_uint,
    y: c_uint,
    w: c_uint,
    h: c_uint,
) -> c_uint {
    with_open(handle, "SetQHYCCDResolution", ERROR, |c| {
        c.event(format!(
            "SetQHYCCDResolution({x}, {y}, {w}, {h}) at bin {}",
            c.bin
        ));
        let (cw, ch) = (c.m().chip.0 / c.bin, c.m().chip.1 / c.bin);
        if w == 0 || h == 0 || x + w > cw || y + h > ch {
            c.fault(format!(
                "window {x},{y} {w}x{h} outside the {cw}x{ch} binned chip"
            ));
            return ERROR;
        }
        c.window = Frame { x, y, w, h };
        SUCCESS
    })
}

#[no_mangle]
pub extern "C" fn SetQHYCCDBitsMode(handle: *mut c_void, bits: c_uint) -> c_uint {
    with_open(handle, "SetQHYCCDBitsMode", ERROR, |c| {
        c.event(format!("SetQHYCCDBitsMode({bits})"));
        if bits != 8 && bits != 16 {
            return ERROR;
        }
        c.bits = bits;
        SUCCESS
    })
}

#[no_mangle]
pub extern "C" fn SetQHYCCDDebayerOnOff(handle: *mut c_void, on: bool) -> c_uint {
    with_open(handle, "SetQHYCCDDebayerOnOff", ERROR, |c| {
        c.event(format!("SetQHYCCDDebayerOnOff({on})"));
        c.debayer = Some(on);
        SUCCESS
    })
}

#[no_mangle]
pub extern "C" fn ControlQHYCCDShutter(handle: *mut c_void, status: u8) -> c_uint {
    with_open(handle, "ControlQHYCCDShutter", ERROR, |c| {
        c.event(format!("ControlQHYCCDShutter({status})"));
        if !c.m().shutter || status > 2 {
            return ERROR;
        }
        c.shutter = Some(status);
        SUCCESS
    })
}

#[no_mangle]
pub extern "C" fn ExpQHYCCDSingleFrame(handle: *mut c_void) -> c_uint {
    with_open(handle, "ExpQHYCCDSingleFrame", ERROR, |c| {
        if !require_init(c, "ExpQHYCCDSingleFrame") {
            return ERROR;
        }
        if c.exposure.is_some_and(|e| !e.canceled) {
            c.fault("ExpQHYCCDSingleFrame while a frame is pending".into());
            return ERROR;
        }
        if c.m().bayer.is_some() && c.debayer != Some(false) {
            c.fault("color frame started with the SDK's debayering not switched off".into());
        }
        let e = Exposure {
            started: Instant::now(),
            us: c.exposure_us,
            bin: c.bin,
            window: c.window,
            bits: c.bits,
            gain: c.gain,
            offset: c.offset,
            shutter: c.shutter,
            canceled: false,
        };
        c.event(format!(
            "ExpQHYCCDSingleFrame {}us bin {} window {},{} {}x{} gain {} offset {} shutter {:?} bits {}",
            e.us, e.bin, e.window.x, e.window.y, e.window.w, e.window.h, e.gain, e.offset, e.shutter, e.bits
        ));
        c.exposure = Some(e);
        if c.m().read_directly {
            READ_DIRECTLY
        } else {
            SUCCESS
        }
    })
}

#[no_mangle]
pub extern "C" fn GetQHYCCDExposureRemaining(handle: *mut c_void) -> c_uint {
    with_open(handle, "GetQHYCCDExposureRemaining", 0, |c| {
        c.exposure.map_or(0, |e| {
            let left = e.us / 1_000_000.0 - e.started.elapsed().as_secs_f64();
            (left.max(0.0) * 1_000_000.0) as c_uint
        })
    })
}

#[no_mangle]
pub extern "C" fn CancelQHYCCDExposingAndReadout(handle: *mut c_void) -> c_uint {
    with_open(handle, "CancelQHYCCDExposingAndReadout", ERROR, |c| {
        c.event("CancelQHYCCDExposingAndReadout".into());
        if let Some(e) = c.exposure.as_mut() {
            e.canceled = true;
        }
        FRAME_DONE.notify_all();
        SUCCESS
    })
}

#[no_mangle]
pub extern "C" fn GetQHYCCDMemLength(handle: *mut c_void) -> c_uint {
    with_open(handle, "GetQHYCCDMemLength", ERROR, |c| {
        c.m().chip.0 * c.m().chip.1 * 2
    })
}

/// Pixel value: the unbinned sensor column of the pixel in the low byte and
/// its row in the high byte (each modulo 256), so a test can tell which
/// sensor pixels a frame covers. 8-bit frames carry the column only.
#[no_mangle]
pub unsafe extern "C" fn GetQHYCCDSingleFrame(
    handle: *mut c_void,
    w: *mut c_uint,
    h: *mut c_uint,
    bpp: *mut c_uint,
    channels: *mut c_uint,
    data: *mut u8,
) -> c_uint {
    let entered = Instant::now();
    let mut st = state();
    loop {
        let Some(c) = st.camera.as_mut() else {
            return ERROR;
        };
        if handle != handle_value() || !c.open {
            c.fault("GetQHYCCDSingleFrame on a closed handle".into());
            return ERROR;
        }
        if c.reading {
            c.fault("two GetQHYCCDSingleFrame calls at once".into());
            return ERROR;
        }
        let Some(e) = c.exposure else {
            c.fault("GetQHYCCDSingleFrame without an exposure".into());
            return ERROR;
        };
        if e.canceled {
            c.event("GetQHYCCDSingleFrame after cancel".into());
            c.exposure = None;
            return ERROR;
        }
        if c.m().read_directly && entered.duration_since(e.started) > Duration::from_millis(250) {
            c.fault("a READ_DIRECTLY frame was read late".into());
        }
        let end = e.started + Duration::from_secs_f64(e.us / 1_000_000.0);
        let now = Instant::now();
        if now >= end {
            break;
        }
        c.reading = true;
        let (guard, _) = FRAME_DONE
            .wait_timeout(st, end - now)
            .unwrap_or_else(|p| p.into_inner());
        st = guard;
        if let Some(c) = st.camera.as_mut() {
            c.reading = false;
        }
    }
    let c = st.camera.as_mut().unwrap();
    let e = c.exposure.take().unwrap();
    std::thread::sleep(Duration::from_millis(30));
    let bytes = if e.bits > 8 { 2 } else { 1 };
    for j in 0..e.window.h {
        for i in 0..e.window.w {
            let sx = (e.window.x + i) * e.bin;
            let sy = (e.window.y + j) * e.bin;
            let k = (j * e.window.w + i) as usize;
            if bytes == 2 {
                *data.add(2 * k) = (sx & 0xFF) as u8;
                *data.add(2 * k + 1) = (sy & 0xFF) as u8;
            } else {
                *data.add(k) = (sx & 0xFF) as u8;
            }
        }
    }
    *w = e.window.w;
    *h = e.window.h;
    *bpp = e.bits;
    *channels = 1;
    c.event(format!(
        "GetQHYCCDSingleFrame {}x{} {} bits",
        e.window.w, e.window.h, e.bits
    ));
    SUCCESS
}

#[no_mangle]
pub unsafe extern "C" fn GetQHYCCDNumberOfReadModes(handle: *mut c_void, n: *mut c_uint) -> c_uint {
    with_open(handle, "GetQHYCCDNumberOfReadModes", ERROR, |c| {
        *n = c.m().read_modes.len() as c_uint;
        SUCCESS
    })
}

#[no_mangle]
pub unsafe extern "C" fn GetQHYCCDReadModeName(
    handle: *mut c_void,
    mode: c_uint,
    name: *mut c_char,
) -> c_uint {
    with_open(handle, "GetQHYCCDReadModeName", ERROR, |c| {
        let Some((text, _, _)) = c.m().read_modes.get(mode as usize) else {
            return ERROR;
        };
        std::ptr::copy_nonoverlapping(text.as_ptr(), name as *mut u8, text.len());
        *name.add(text.len()) = 0;
        SUCCESS
    })
}

#[no_mangle]
pub extern "C" fn SetQHYCCDReadMode(handle: *mut c_void, mode: c_uint) -> c_uint {
    with_open(handle, "SetQHYCCDReadMode", ERROR, |c| {
        c.event(format!("SetQHYCCDReadMode({mode})"));
        if mode as usize >= c.m().read_modes.len() {
            return ERROR;
        }
        c.pending_read_mode = mode;
        SUCCESS
    })
}

#[no_mangle]
pub unsafe extern "C" fn GetQHYCCDReadMode(handle: *mut c_void, mode: *mut c_uint) -> c_uint {
    with_open(handle, "GetQHYCCDReadMode", ERROR, |c| {
        *mode = c.read_mode;
        SUCCESS
    })
}

#[no_mangle]
pub extern "C" fn IsQHYCCDCFWPlugged(handle: *mut c_void) -> c_uint {
    with_open(handle, "IsQHYCCDCFWPlugged", ERROR, |c| {
        if c.m().wheel_slots.is_some() {
            SUCCESS
        } else {
            ERROR
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn SendOrder2QHYCCDCFW(
    handle: *mut c_void,
    order: *mut c_char,
    length: c_uint,
) -> c_uint {
    with_open(handle, "SendOrder2QHYCCDCFW", ERROR, |c| {
        if length < 1 || c.m().wheel_slots != Some(7.0) {
            return ERROR;
        }
        order_wheel(c, *order as u8)
    })
}

#[no_mangle]
pub unsafe extern "C" fn GetQHYCCDCFWStatus(handle: *mut c_void, status: *mut c_char) -> c_uint {
    with_open(handle, "GetQHYCCDCFWStatus", ERROR, |c| {
        if c.m().wheel_slots != Some(7.0) {
            return ERROR;
        }
        *status = wheel_status(c) as c_char;
        *status.add(1) = 0;
        SUCCESS
    })
}
