//! A software-only stand-in for the QHYCCD SDK (`libqhyccd.so`), built by
//! `tests/qhy_sdk_contract.rs` and loaded by the real QHY driver in place of
//! the vendor library.
//!
//! It answers the way the vendor SDK does where that is known: from the SDK
//! headers (`qhyccd.h`, `qhyccdstruct.h`, `qhyccderr.h`), from the INDI and
//! NINA drivers, and from the x86-64 Linux `libqhyccd` the INDI tree ships
//! (read with gdb, see notes/a-qhy.md):
//! - `OpenQHYCCD` on a camera that is already open returns the same handle;
//!   `CloseQHYCCD` cancels a running exposure and closes the handle for
//!   everyone holding it.
//! - `IsQHYCCDControlAvailable(CAM_COLOR)` answers with the BAYER_ID (1 GB,
//!   2 GR, 3 BG, 4 RG); `GetQHYCCDParam(CAM_COLOR)` has no handler and returns
//!   QHYCCD_ERROR.
//! - `SetQHYCCDParam(CONTROL_CURPWM)` has no handler and returns QHYCCD_ERROR.
//! - `SetQHYCCDParam(CONTROL_CFWPORT, c)` sends the one-character order `c`
//!   to the wheel; `GetQHYCCDParam(CONTROL_CFWPORT)` returns the first
//!   character of the wheel's status reply.
//! - `GetQHYCCDSingleFrame` blocks until the exposure has ended and read out.
//! - `InitQHYCCD` puts the camera back to its power-on settings.
//!
//! Test hooks (`FakeQhy*`) reset the fake, unplug cameras and read back what
//! the driver did.

#![allow(non_snake_case, clippy::missing_safety_doc)]
use std::ffi::{c_char, c_double, c_int, c_uint, c_void, CStr};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

const SUCCESS: c_uint = 0;
const ERROR: c_uint = 0xFFFF_FFFF;
const READ_DIRECTLY: c_uint = 0x2001;
const DELAY_200MS: c_uint = 0x2000;
const ERROR_F64: f64 = 4294967295.0;

#[derive(Clone)]
struct Model {
    id: &'static str,
    bayer: Option<c_uint>,
    cooled: bool,
    thermometer: bool,
    shutter: bool,
    bins: &'static [u32],
    chip: (u32, u32),
    effective: (u32, u32, u32, u32),
    pixel_um: f64,
    cfw_slots: Option<f64>,
    exposure_us: (f64, f64),
    bin_answer: c_uint,
    expose_answer: c_uint,
}

fn models() -> Vec<Model> {
    vec![
        // A cooled one-shot-color CMOS camera with an overscan border and a
        // seven-slot CFW on its 4-pin port.
        Model {
            id: "QHY268C-FAKE0001",
            bayer: Some(1),
            cooled: true,
            thermometer: true,
            shutter: false,
            bins: &[1, 2, 3, 4],
            chip: (80, 60),
            effective: (4, 2, 72, 56),
            pixel_um: 3.76,
            cfw_slots: Some(7.0),
            exposure_us: (1.0, 3_600_000_000.0),
            bin_answer: SUCCESS,
            expose_answer: SUCCESS,
        },
        // A legacy cooled CCD with a mechanical shutter. It wants a 200 ms
        // pause after a bin change and is read out directly after the start.
        // Its CFW port answers but no wheel is attached (slot count 255).
        Model {
            id: "QHY9S-FAKE0002",
            bayer: None,
            cooled: true,
            thermometer: true,
            shutter: true,
            bins: &[1, 2],
            chip: (40, 30),
            effective: (0, 0, 40, 30),
            pixel_um: 5.4,
            cfw_slots: Some(255.0),
            exposure_us: (1_000.0, 3_600_000_000.0),
            bin_answer: DELAY_200MS,
            expose_answer: READ_DIRECTLY,
        },
        // An uncooled planetary/guide camera without a thermometer or CFW port.
        Model {
            id: "QHY5III462C-FAKE0003",
            bayer: Some(4),
            cooled: false,
            thermometer: false,
            shutter: false,
            bins: &[1, 2],
            chip: (48, 32),
            effective: (0, 0, 48, 32),
            pixel_um: 2.9,
            cfw_slots: None,
            exposure_us: (1.0, 600_000_000.0),
            bin_answer: SUCCESS,
            expose_answer: SUCCESS,
        },
    ]
}

struct Cam {
    model: Model,
    plugged: bool,
    open: bool,
    opens: u32,
    inits: u32,
    closes: u32,
    cancels: u32,
    bits: u32,
    bin: u32,
    roi: (u32, u32, u32, u32),
    gain: f64,
    offset: f64,
    exposure_us: f64,
    exposing: Option<(Instant, Duration)>,
    shutter: f64,
    shutter_at_start: f64,
    started: Option<(f64, f64, f64, f64, f64, f64, f64, f64)>,
    cooler_writes: u32,
    cooler_target: f64,
    manual_pwm: f64,
    pwm_reading: f64,
    debayer: f64,
    read_mode: u32,
    ulvo: f64,
    wheel_position: u8,
    wheel_target: u8,
    wheel_arrives: Option<Instant>,
}

impl Cam {
    fn new(model: Model) -> Self {
        let mut cam = Cam {
            model,
            plugged: true,
            open: false,
            opens: 0,
            inits: 0,
            closes: 0,
            cancels: 0,
            bits: 8,
            bin: 1,
            roi: (0, 0, 0, 0),
            gain: 0.0,
            offset: 0.0,
            exposure_us: 0.0,
            exposing: None,
            shutter: -1.0,
            shutter_at_start: -1.0,
            started: None,
            cooler_writes: 0,
            cooler_target: 0.0,
            manual_pwm: 0.0,
            pwm_reading: 0.0,
            debayer: -1.0,
            read_mode: 0,
            ulvo: 1.0,
            wheel_position: b'0',
            wheel_target: b'0',
            wheel_arrives: None,
        };
        cam.power_on_settings();
        cam
    }

    fn power_on_settings(&mut self) {
        self.bits = 8;
        self.bin = 1;
        self.roi = (0, 0, self.model.chip.0, self.model.chip.1);
        self.gain = 10.0;
        self.offset = 30.0;
    }

    fn available(&self, control: c_int) -> bool {
        match control {
            6 | 7 | 8 | 9 | 10 | 12 | 34 | 35 | 37 => true,
            14 => self.model.thermometer,
            15 | 16 | 18 => self.model.cooled,
            21 => self.model.bins.contains(&1),
            22 => self.model.bins.contains(&2),
            23 => self.model.bins.contains(&3),
            24 => self.model.bins.contains(&4),
            25 => self.model.shutter,
            59 => self.model.bayer.is_some(),
            67 => true,
            _ => false,
        }
    }

    fn wheel_status(&mut self) -> u8 {
        match self.wheel_arrives {
            Some(at) if Instant::now() < at => b'N',
            Some(_) => {
                self.wheel_position = self.wheel_target;
                self.wheel_arrives = None;
                self.wheel_position
            }
            None => self.wheel_position,
        }
    }
}

struct State {
    cams: Vec<Cam>,
    scanned: Vec<usize>,
}

fn state() -> MutexGuard<'static, State> {
    static STATE: OnceLock<Mutex<State>> = OnceLock::new();
    STATE
        .get_or_init(|| Mutex::new(fresh_state()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn fresh_state() -> State {
    State {
        cams: models().into_iter().map(Cam::new).collect(),
        scanned: Vec::new(),
    }
}

fn handle_of(index: usize) -> *mut c_void {
    (0x1000 + index) as *mut c_void
}

fn index_of(handle: *mut c_void) -> Option<usize> {
    (handle as usize).checked_sub(0x1000)
}

fn with_open<R>(handle: *mut c_void, missing: R, f: impl FnOnce(&mut Cam) -> R) -> R {
    let mut state = state();
    match index_of(handle).and_then(|i| state.cams.get_mut(i)) {
        Some(cam) if cam.open && cam.plugged => f(cam),
        _ => missing,
    }
}

unsafe fn write_cstr(buf: *mut c_char, text: &str) {
    for (i, byte) in text.bytes().enumerate() {
        *buf.add(i) = byte as c_char;
    }
    *buf.add(text.len()) = 0;
}

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
    year: *mut c_uint,
    month: *mut c_uint,
    day: *mut c_uint,
    subday: *mut c_uint,
) -> c_uint {
    *year = 2025;
    *month = 4;
    *day = 10;
    *subday = 0;
    SUCCESS
}

#[no_mangle]
pub extern "C" fn ScanQHYCCD() -> c_uint {
    let mut state = state();
    let plugged: Vec<usize> = (0..state.cams.len())
        .filter(|&i| state.cams[i].plugged)
        .collect();
    state.scanned = plugged;
    state.scanned.len() as c_uint
}

#[no_mangle]
pub unsafe extern "C" fn GetQHYCCDId(index: c_uint, id: *mut c_char) -> c_uint {
    let state = state();
    match state.scanned.get(index as usize) {
        Some(&cam) => {
            write_cstr(id, state.cams[cam].model.id);
            SUCCESS
        }
        None => ERROR,
    }
}

#[no_mangle]
pub unsafe extern "C" fn OpenQHYCCD(id: *const c_char) -> *mut c_void {
    let id = CStr::from_ptr(id).to_string_lossy().into_owned();
    let mut state = state();
    let found = state
        .scanned
        .iter()
        .copied()
        .find(|&i| state.cams[i].model.id == id && state.cams[i].plugged);
    let Some(index) = found else {
        return std::ptr::null_mut();
    };
    let cam = &mut state.cams[index];
    if !cam.open {
        cam.open = true;
        cam.opens += 1;
    }
    handle_of(index)
}

#[no_mangle]
pub extern "C" fn CloseQHYCCD(handle: *mut c_void) -> c_uint {
    let mut state = state();
    match index_of(handle).and_then(|i| state.cams.get_mut(i)) {
        Some(cam) if cam.open => {
            if cam.exposing.take().is_some() {
                cam.cancels += 1;
            }
            cam.open = false;
            cam.closes += 1;
            SUCCESS
        }
        _ => ERROR,
    }
}

#[no_mangle]
pub extern "C" fn SetQHYCCDStreamMode(handle: *mut c_void, mode: c_uint) -> c_uint {
    with_open(handle, ERROR, |_| if mode <= 1 { SUCCESS } else { ERROR })
}

#[no_mangle]
pub extern "C" fn InitQHYCCD(handle: *mut c_void) -> c_uint {
    with_open(handle, ERROR, |cam| {
        cam.inits += 1;
        cam.power_on_settings();
        SUCCESS
    })
}

#[no_mangle]
pub unsafe extern "C" fn GetQHYCCDChipInfo(
    handle: *mut c_void,
    chip_w: *mut c_double,
    chip_h: *mut c_double,
    image_w: *mut c_uint,
    image_h: *mut c_uint,
    pixel_w: *mut c_double,
    pixel_h: *mut c_double,
    bpp: *mut c_uint,
) -> c_uint {
    with_open(handle, ERROR, |cam| {
        let m = &cam.model;
        *chip_w = f64::from(m.chip.0) * m.pixel_um / 1000.0;
        *chip_h = f64::from(m.chip.1) * m.pixel_um / 1000.0;
        *image_w = m.chip.0;
        *image_h = m.chip.1;
        *pixel_w = m.pixel_um;
        *pixel_h = m.pixel_um;
        *bpp = cam.bits;
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
    with_open(handle, ERROR, |cam| {
        let (ex, ey, ew, eh) = cam.model.effective;
        *x = ex;
        *y = ey;
        *w = ew;
        *h = eh;
        SUCCESS
    })
}

#[no_mangle]
pub extern "C" fn IsQHYCCDControlAvailable(handle: *mut c_void, control: c_int) -> c_uint {
    with_open(handle, ERROR, |cam| {
        if control == 20 {
            return cam.model.bayer.unwrap_or(ERROR);
        }
        if cam.available(control) {
            SUCCESS
        } else {
            ERROR
        }
    })
}

#[no_mangle]
pub extern "C" fn SetQHYCCDParam(handle: *mut c_void, control: c_int, value: c_double) -> c_uint {
    with_open(handle, ERROR, |cam| {
        match control {
            6 => cam.gain = value,
            7 => cam.offset = value,
            8 => cam.exposure_us = value,
            9 | 12 => {}
            16 if cam.model.cooled => {
                cam.manual_pwm = value;
                cam.pwm_reading = value;
            }
            17 if cam.model.cfw_slots.is_some() => {
                cam.wheel_target = value as u8;
                cam.wheel_arrives = Some(Instant::now() + Duration::from_millis(300));
            }
            18 if cam.model.cooled => {
                cam.cooler_writes += 1;
                cam.cooler_target = value;
            }
            _ => return ERROR,
        }
        SUCCESS
    })
}

#[no_mangle]
pub extern "C" fn GetQHYCCDParam(handle: *mut c_void, control: c_int) -> c_double {
    with_open(handle, ERROR_F64, |cam| match control {
        6 => cam.gain,
        7 => cam.offset,
        8 => cam.exposure_us,
        9 => 1.0,
        12 => 30.0,
        14 if cam.model.thermometer => -9.25,
        15 if cam.model.cooled => cam.pwm_reading,
        17 if cam.model.cfw_slots.is_some() => f64::from(cam.wheel_status()),
        18 if cam.model.cooled => cam.cooler_target,
        44 => cam.model.cfw_slots.unwrap_or(ERROR_F64),
        67 => cam.ulvo,
        _ => ERROR_F64,
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
    with_open(handle, ERROR, |cam| {
        let range = match control {
            6 => (0.0, 100.0, 1.0),
            7 => (0.0, 255.0, 1.0),
            8 => (cam.model.exposure_us.0, cam.model.exposure_us.1, 1.0),
            9 => (0.0, 2.0, 1.0),
            12 => (0.0, 60.0, 1.0),
            16 if cam.model.cooled => (0.0, 255.0, 1.0),
            18 if cam.model.cooled => (-50.0, 50.0, 0.5),
            _ => return ERROR,
        };
        *min = range.0;
        *max = range.1;
        *step = range.2;
        SUCCESS
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
    with_open(handle, ERROR, |cam| {
        let (cw, ch) = (cam.model.chip.0 / cam.bin, cam.model.chip.1 / cam.bin);
        if w == 0 || h == 0 || x + w > cw || y + h > ch {
            return ERROR;
        }
        cam.roi = (x, y, w, h);
        SUCCESS
    })
}

#[no_mangle]
pub extern "C" fn SetQHYCCDBinMode(handle: *mut c_void, bin_x: c_uint, bin_y: c_uint) -> c_uint {
    with_open(handle, ERROR, |cam| {
        if bin_x != bin_y || !cam.model.bins.contains(&bin_x) {
            return ERROR;
        }
        cam.bin = bin_x;
        cam.model.bin_answer
    })
}

#[no_mangle]
pub extern "C" fn SetQHYCCDBitsMode(handle: *mut c_void, bits: c_uint) -> c_uint {
    with_open(handle, ERROR, |cam| {
        if bits == 8 || bits == 16 {
            cam.bits = bits;
            SUCCESS
        } else {
            ERROR
        }
    })
}

#[no_mangle]
pub extern "C" fn SetQHYCCDDebayerOnOff(handle: *mut c_void, on: bool) -> c_uint {
    with_open(handle, ERROR, |cam| {
        cam.debayer = if on { 1.0 } else { 0.0 };
        SUCCESS
    })
}

#[no_mangle]
pub extern "C" fn ControlQHYCCDShutter(handle: *mut c_void, status: u8) -> c_uint {
    with_open(handle, ERROR, |cam| {
        if !cam.model.shutter {
            return ERROR;
        }
        cam.shutter = f64::from(status);
        SUCCESS
    })
}

#[no_mangle]
pub extern "C" fn ExpQHYCCDSingleFrame(handle: *mut c_void) -> c_uint {
    with_open(handle, ERROR, |cam| {
        if cam.exposing.is_some() {
            return ERROR;
        }
        let length = Duration::from_secs_f64(cam.exposure_us.max(0.0) / 1e6);
        cam.exposing = Some((Instant::now(), length));
        cam.shutter_at_start = cam.shutter;
        cam.started = Some((
            cam.exposure_us,
            f64::from(cam.bin),
            f64::from(cam.roi.0),
            f64::from(cam.roi.1),
            f64::from(cam.roi.2),
            f64::from(cam.roi.3),
            cam.gain,
            cam.offset,
        ));
        cam.model.expose_answer
    })
}

#[no_mangle]
pub extern "C" fn GetQHYCCDExposureRemaining(handle: *mut c_void) -> c_uint {
    with_open(handle, 0, |cam| match cam.exposing {
        Some((started, length)) => length.saturating_sub(started.elapsed()).as_millis() as c_uint,
        None => 0,
    })
}

#[no_mangle]
pub extern "C" fn CancelQHYCCDExposingAndReadout(handle: *mut c_void) -> c_uint {
    with_open(handle, ERROR, |cam| {
        cam.exposing = None;
        cam.cancels += 1;
        SUCCESS
    })
}

#[no_mangle]
pub extern "C" fn GetQHYCCDMemLength(handle: *mut c_void) -> c_uint {
    with_open(handle, 0, |cam| cam.model.chip.0 * cam.model.chip.1 * 2)
}

#[no_mangle]
pub unsafe extern "C" fn GetQHYCCDSingleFrame(
    handle: *mut c_void,
    w: *mut c_uint,
    h: *mut c_uint,
    bpp: *mut c_uint,
    channels: *mut c_uint,
    data: *mut u8,
) -> c_uint {
    loop {
        let wait = with_open(handle, None, |cam| match cam.exposing {
            Some((started, length)) => Some(length.saturating_sub(started.elapsed())),
            None => None,
        });
        match wait {
            Some(left) if !left.is_zero() => std::thread::sleep(left.min(Duration::from_millis(20))),
            Some(_) => break,
            None => return ERROR,
        }
    }
    with_open(handle, ERROR, |cam| {
        cam.exposing = None;
        let (_, _, rw, rh) = cam.roi;
        let planes = if cam.debayer == 1.0 { 3 } else { 1 };
        *w = rw;
        *h = rh;
        *bpp = cam.bits;
        *channels = planes;
        let bytes = (cam.bits / 8) as usize;
        for i in 0..(rw * rh * planes) as usize {
            let value = (1000 + i) as u16;
            if bytes == 2 {
                *data.add(2 * i) = (value & 0xff) as u8;
                *data.add(2 * i + 1) = (value >> 8) as u8;
            } else {
                *data.add(i) = (value & 0xff) as u8;
            }
        }
        SUCCESS
    })
}

#[no_mangle]
pub unsafe extern "C" fn GetQHYCCDNumberOfReadModes(handle: *mut c_void, count: *mut c_uint) -> c_uint {
    with_open(handle, ERROR, |_| {
        *count = 2;
        SUCCESS
    })
}

#[no_mangle]
pub unsafe extern "C" fn GetQHYCCDReadModeName(
    handle: *mut c_void,
    mode: c_uint,
    name: *mut c_char,
) -> c_uint {
    with_open(handle, ERROR, |_| match mode {
        0 => {
            write_cstr(name, "Photographic DSO");
            SUCCESS
        }
        1 => {
            write_cstr(name, "High Gain Mode");
            SUCCESS
        }
        _ => ERROR,
    })
}

#[no_mangle]
pub extern "C" fn SetQHYCCDReadMode(handle: *mut c_void, mode: c_uint) -> c_uint {
    with_open(handle, ERROR, |cam| {
        if mode > 1 {
            return ERROR;
        }
        cam.read_mode = mode;
        SUCCESS
    })
}

#[no_mangle]
pub unsafe extern "C" fn GetQHYCCDReadMode(handle: *mut c_void, mode: *mut c_uint) -> c_uint {
    with_open(handle, ERROR, |cam| {
        *mode = cam.read_mode;
        SUCCESS
    })
}

#[no_mangle]
pub extern "C" fn IsQHYCCDCFWPlugged(handle: *mut c_void) -> c_uint {
    with_open(handle, ERROR, |cam| {
        if cam.model.cfw_slots.is_some() {
            SUCCESS
        } else {
            ERROR
        }
    })
}

/// Back to a fresh SDK: every camera plugged in, closed and at power-on settings.
#[no_mangle]
pub extern "C" fn FakeQhyReset() {
    *state() = fresh_state();
}

#[no_mangle]
pub extern "C" fn FakeQhyPlug(index: c_uint, plugged: bool) {
    let mut state = state();
    let cam = &mut state.cams[index as usize];
    cam.plugged = plugged;
    if !plugged {
        // The SDK's camera list holds the USB device that went away; only a
        // new scan finds the camera again.
        cam.open = false;
        cam.exposing = None;
        state.scanned.retain(|&i| i != index as usize);
    }
}

#[no_mangle]
pub extern "C" fn FakeQhySet(index: c_uint, key: c_uint, value: f64) {
    let mut state = state();
    let cam = &mut state.cams[index as usize];
    match key {
        0 => cam.ulvo = value,
        1 => cam.pwm_reading = value,
        _ => {}
    }
}

/// What the driver did to camera `index`, by key; NaN for an unknown key.
#[no_mangle]
pub extern "C" fn FakeQhyGet(index: c_uint, key: c_uint) -> f64 {
    let state = state();
    let cam = &state.cams[index as usize];
    let started = cam.started.unwrap_or((-1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0));
    match key {
        0 => f64::from(cam.opens),
        1 => f64::from(cam.inits),
        2 => f64::from(cam.closes),
        3 => f64::from(cam.cancels),
        4 => f64::from(u8::from(cam.open)),
        5 => f64::from(cam.bits),
        6 => f64::from(cam.bin),
        7 => f64::from(cam.cooler_writes),
        8 => cam.cooler_target,
        9 => cam.manual_pwm,
        10 => cam.debayer,
        11 => cam.shutter_at_start,
        12 => started.0,
        13 => started.1,
        14 => started.2,
        15 => started.3,
        16 => started.4,
        17 => started.5,
        18 => started.6,
        19 => started.7,
        20 => f64::from(u8::from(cam.exposing.is_some())),
        21 => f64::from(cam.read_mode),
        22 => f64::from(cam.wheel_target),
        23 => cam.gain,
        24 => cam.offset,
        _ => f64::NAN,
    }
}
