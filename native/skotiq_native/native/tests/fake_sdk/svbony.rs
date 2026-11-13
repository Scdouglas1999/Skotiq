// A software-only SVBCameraSDK for the SVBony driver's tests, compiled with
// `rustc --crate-type cdylib` (tests/svbony_fake_sdk.rs on Linux, the Windows
// contract in tests/native_driver_tests.rs, the camera sessions in
// tests/camera_session.rs).
//
// It answers like SVBCameraSDK.h describes and like the INDI and NINA drivers
// rely on: the camera list has to be read before a camera opens, a camera in
// soft-trigger mode delivers one frame per trigger, a frame that was triggered
// but not read is still handed out after capture stops and starts again, the
// readout region is refused while capturing or when it is not a multiple of
// 8 x 2, and control values outside a control's range are stored as the
// nearest limit.
//
// The model comes from the environment of the process that loads it:
//   FAKE_SVB_MODEL=mono        a monochrome uncooled camera offering Y8/Y16 only
//                              (default: an RGGB cooled camera offering RAW8/RAW16)
//   FAKE_SVB_START_MODE=<n>    the camera mode it was left in (default 1, soft trigger)
//   FAKE_SVB_NO_TRIGGER=1      the camera refuses soft-trigger mode
//   FAKE_SVB_FAIL_FRAME=<n>    reading frame n answers SVB_ERROR_GENERAL_ERROR
// Frame n's pixels are all 1000 + n (16-bit) or n (8-bit). FakeSvb* functions
// let a test read the camera's state.
#![allow(non_snake_case)]
use std::collections::VecDeque;
use std::ffi::{c_char, c_int, c_long};
use std::sync::Mutex;

#[repr(C)]
pub struct SvbCameraInfo {
    friendly_name: [c_char; 32],
    camera_sn: [c_char; 32],
    port_type: [c_char; 32],
    device_id: c_int,
    camera_id: c_int,
}
#[repr(C)]
pub struct SvbCameraProperty {
    max_height: c_long,
    max_width: c_long,
    is_color_cam: c_int,
    bayer_pattern: c_int,
    supported_bins: [c_int; 16],
    supported_video_format: [c_int; 8],
    max_bit_depth: c_int,
    is_trigger_cam: c_int,
}
#[repr(C)]
pub struct SvbCameraPropertyEx {
    b_support_pulse_guide: c_int,
    b_support_control_temp: c_int,
    unused: [c_int; 64],
}
#[repr(C)]
pub struct SvbControlCaps {
    name: [c_char; 64],
    description: [c_char; 128],
    max_value: c_long,
    min_value: c_long,
    default_value: c_long,
    is_auto_supported: c_int,
    is_writable: c_int,
    control_type: c_int,
    unused: [c_char; 32],
}

struct Control {
    control_type: c_int,
    name: &'static [u8],
    min: c_long,
    max: c_long,
    default: c_long,
    value: c_long,
    writable: bool,
}

struct Camera {
    color: bool,
    width: c_long,
    height: c_long,
    formats: Vec<c_int>,
    no_trigger: bool,
    fail_frame: Option<u32>,
    listed: bool,
    open: bool,
    capturing: bool,
    mode: c_int,
    img_type: c_int,
    roi: (c_int, c_int, c_int, c_int, c_int),
    controls: Vec<Control>,
    triggers: u32,
    next_frame: u32,
    triggered: VecDeque<u32>,
}

static CAMERA: Mutex<Option<Camera>> = Mutex::new(None);

fn env_number(name: &str) -> Option<i64> {
    std::env::var(name).ok().and_then(|v| v.parse().ok())
}

fn control(control_type: c_int, name: &'static [u8], min: c_long, max: c_long, default: c_long, value: c_long, writable: bool) -> Control {
    Control { control_type, name, min, max, default, value, writable }
}

fn new_camera() -> Camera {
    let mono = std::env::var("FAKE_SVB_MODEL").map_or(false, |m| m == "mono");
    let mut controls = vec![
        control(0, b"Gain", 0, 720, 120, 300, true),
        control(1, b"Exposure", 32, 1_000_000_000, 1_000_000, 1_000_000, true),
        // Left by another program: gamma 150, flip both axes, bad pixel correction on.
        control(2, b"Gamma", 0, 200, 100, 150, true),
        control(7, b"Flip", 0, 3, 0, 3, true),
        control(13, b"Offset", 0, 255, 10, 40, true),
        control(16, b"Temperature", -500, 1000, 0, 215, false),
        control(18, b"BadPixelCorrection", 0, 1, 0, 1, true),
    ];
    if !mono {
        controls.push(control(14, b"Cooler", 0, 1, 0, 0, true));
        controls.push(control(15, b"TargetTemperature", -400, 300, 0, 0, true));
        controls.push(control(17, b"CoolerPower", 0, 100, 0, 37, false));
        controls[5].value = -95;
    }
    Camera {
        color: !mono,
        width: if mono { 40 } else { 48 },
        height: 30,
        formats: if mono { vec![5, 9, -1] } else { vec![0, 4, -1] },
        no_trigger: std::env::var("FAKE_SVB_NO_TRIGGER").is_ok(),
        fail_frame: env_number("FAKE_SVB_FAIL_FRAME").map(|n| n as u32),
        listed: false,
        open: false,
        capturing: false,
        mode: env_number("FAKE_SVB_START_MODE").unwrap_or(1) as c_int,
        img_type: 0,
        roi: (0, 0, 0, 0, 1),
        controls,
        triggers: 0,
        next_frame: 1,
        triggered: VecDeque::new(),
    }
}

fn with<R>(f: impl FnOnce(&mut Camera) -> R) -> R {
    let mut guard = CAMERA.lock().unwrap();
    f(guard.get_or_insert_with(new_camera))
}

fn write_cstr(buf: &mut [c_char], text: &[u8]) {
    for b in buf.iter_mut() {
        *b = 0;
    }
    for i in 0..text.len().min(buf.len().saturating_sub(1)) {
        buf[i] = text[i] as c_char;
    }
}

#[no_mangle] pub extern "C" fn SVBGetNumOfConnectedCameras()->c_int {
    with(|c| c.listed = true);
    1
}
#[no_mangle] pub unsafe extern "C" fn SVBGetCameraInfo(info: *mut SvbCameraInfo, index: c_int)->c_int {
    if info.is_null() || index != 0 {
        return 1;
    }
    let mono = with(|c| !c.color);
    let mut v: SvbCameraInfo = std::mem::zeroed();
    write_cstr(&mut v.friendly_name, if mono { b"SVBONY SV305M PRO" } else { b"SVBONY SV405CC" });
    write_cstr(&mut v.camera_sn, if mono { b"SV305M-FAKE-01" } else { b"SV405CC-FAKE-01" });
    write_cstr(&mut v.port_type, b"USB3.0");
    v.device_id = 0x1234;
    v.camera_id = 0;
    *info = v;
    0
}
#[no_mangle] pub unsafe extern "C" fn SVBGetCameraProperty(id: c_int, prop: *mut SvbCameraProperty)->c_int {
    if prop.is_null() || id != 0 {
        return 2;
    }
    with(|c| {
        let mut v: SvbCameraProperty = std::mem::zeroed();
        v.max_width = c.width;
        v.max_height = c.height;
        v.is_color_cam = c.color as c_int;
        v.bayer_pattern = 0;
        v.supported_bins[0] = 1;
        v.supported_bins[1] = 2;
        v.supported_bins[2] = 4;
        v.supported_video_format = [-1; 8];
        v.supported_video_format[..c.formats.len()].copy_from_slice(&c.formats);
        v.max_bit_depth = if c.color { 14 } else { 12 };
        v.is_trigger_cam = 1;
        *prop = v;
    });
    0
}
#[no_mangle] pub unsafe extern "C" fn SVBGetCameraPropertyEx(id: c_int, prop: *mut SvbCameraPropertyEx)->c_int {
    if prop.is_null() || id != 0 {
        return 2;
    }
    let color = with(|c| c.color);
    let mut v: SvbCameraPropertyEx = std::mem::zeroed();
    v.b_support_pulse_guide = 1;
    v.b_support_control_temp = color as c_int;
    *prop = v;
    0
}
#[no_mangle] pub unsafe extern "C" fn SVBGetSensorPixelSize(_id: c_int, size: *mut f32)->c_int {
    if size.is_null() {
        return 16;
    }
    *size = if with(|c| c.color) { 4.63 } else { 2.9 };
    0
}
#[no_mangle] pub extern "C" fn SVBOpenCamera(id: c_int)->c_int {
    with(|c| {
        if !c.listed || id != 0 {
            return 2;
        }
        c.open = true;
        0
    })
}
#[no_mangle] pub extern "C" fn SVBCloseCamera(_id: c_int)->c_int {
    with(|c| {
        c.open = false;
        c.capturing = false;
    });
    0
}
#[no_mangle] pub unsafe extern "C" fn SVBGetNumOfControls(_id: c_int, num: *mut c_int)->c_int {
    if num.is_null() {
        return 16;
    }
    with(|c| {
        if !c.open {
            return 4;
        }
        *num = c.controls.len() as c_int;
        0
    })
}
#[no_mangle] pub unsafe extern "C" fn SVBGetControlCaps(_id: c_int, index: c_int, caps: *mut SvbControlCaps)->c_int {
    if caps.is_null() {
        return 16;
    }
    with(|c| {
        let Some(ctrl) = c.controls.get(index as usize) else { return 1 };
        let mut v: SvbControlCaps = std::mem::zeroed();
        write_cstr(&mut v.name, ctrl.name);
        write_cstr(&mut v.description, b"Skotiq fake SVBony control");
        v.min_value = ctrl.min;
        v.max_value = ctrl.max;
        v.default_value = ctrl.default;
        v.is_writable = ctrl.writable as c_int;
        v.control_type = ctrl.control_type;
        v.unused = [0x5a; 32];
        *caps = v;
        0
    })
}
#[no_mangle] pub unsafe extern "C" fn SVBGetControlValue(_id: c_int, ctrl: c_int, value: *mut c_long, is_auto: *mut c_int)->c_int {
    if value.is_null() || is_auto.is_null() {
        return 16;
    }
    with(|c| match c.controls.iter().find(|x| x.control_type == ctrl) {
        Some(x) => {
            *value = x.value;
            *is_auto = 0;
            0
        }
        None => 3,
    })
}
#[no_mangle] pub extern "C" fn SVBSetControlValue(_id: c_int, ctrl: c_int, value: c_long, _is_auto: c_int)->c_int {
    with(|c| match c.controls.iter_mut().find(|x| x.control_type == ctrl) {
        Some(x) if x.writable => {
            x.value = value.clamp(x.min, x.max);
            0
        }
        Some(_) => 16,
        None => 3,
    })
}
#[no_mangle] pub extern "C" fn SVBSetROIFormat(_id: c_int, x: c_int, y: c_int, width: c_int, height: c_int, bin: c_int)->c_int {
    with(|c| {
        if c.capturing {
            return 12;
        }
        if width <= 0 || height <= 0 || width % 8 != 0 || height % 2 != 0 || ![1, 2, 4].contains(&bin) {
            return 8;
        }
        if c_long::from((x + width) * bin) > c.width || c_long::from((y + height) * bin) > c.height {
            return 10;
        }
        c.roi = (x, y, width, height, bin);
        0
    })
}
#[no_mangle] pub unsafe extern "C" fn SVBGetROIFormat(_id: c_int, x: *mut c_int, y: *mut c_int, width: *mut c_int, height: *mut c_int, bin: *mut c_int)->c_int {
    let (rx, ry, rw, rh, rb) = with(|c| c.roi);
    for (out, value) in [(x, rx), (y, ry), (width, rw), (height, rh), (bin, rb)] {
        if !out.is_null() {
            *out = value;
        }
    }
    0
}
#[no_mangle] pub extern "C" fn SVBSetOutputImageType(_id: c_int, img_type: c_int)->c_int {
    with(|c| {
        if !c.formats.iter().take_while(|&&f| f != -1).any(|&f| f == img_type) {
            return 9;
        }
        c.img_type = img_type;
        0
    })
}
#[no_mangle] pub unsafe extern "C" fn SVBGetOutputImageType(_id: c_int, img_type: *mut c_int)->c_int {
    if !img_type.is_null() {
        *img_type = with(|c| c.img_type);
    }
    0
}
#[no_mangle] pub extern "C" fn SVBSetCameraMode(_id: c_int, mode: c_int)->c_int {
    with(|c| {
        if c.capturing {
            return 12;
        }
        if mode == 1 && c.no_trigger || !(0..=6).contains(&mode) {
            return 17;
        }
        c.mode = mode;
        0
    })
}
#[no_mangle] pub extern "C" fn SVBSendSoftTrigger(_id: c_int)->c_int {
    with(|c| {
        if c.mode != 1 || !c.capturing {
            return 17;
        }
        c.triggers += 1;
        let frame = c.next_frame;
        c.next_frame += 1;
        c.triggered.push_back(frame);
        0
    })
}
#[no_mangle] pub extern "C" fn SVBStartVideoCapture(_id: c_int)->c_int {
    with(|c| c.capturing = true);
    0
}
#[no_mangle] pub extern "C" fn SVBStopVideoCapture(_id: c_int)->c_int {
    with(|c| c.capturing = false);
    0
}
#[no_mangle] pub unsafe extern "C" fn SVBGetVideoData(_id: c_int, buf: *mut u8, buf_size: c_long, _wait_ms: c_int)->c_int {
    with(|c| {
        if !c.capturing {
            return 11;
        }
        let bytes = if c.img_type == 4 || c.img_type == 9 { 2 } else { 1 };
        let needed = (c.roi.2 * c.roi.3) as usize * bytes;
        if buf.is_null() || (buf_size as usize) < needed {
            return 13;
        }
        let frame = if c.mode == 1 {
            match c.triggered.pop_front() {
                Some(frame) => frame,
                None => return 11,
            }
        } else {
            let frame = c.next_frame;
            c.next_frame += 1;
            frame
        };
        if c.fail_frame == Some(frame) {
            return 16;
        }
        let out = std::slice::from_raw_parts_mut(buf, needed);
        if bytes == 2 {
            for px in out.chunks_exact_mut(2) {
                px.copy_from_slice(&(1000 + frame as u16).to_le_bytes());
            }
        } else {
            out.fill(frame as u8);
        }
        0
    })
}
#[no_mangle] pub extern "C" fn SVBGetSDKVersion()->*const c_char {
    b"fake-svbony-1.13\0".as_ptr() as *const c_char
}

#[no_mangle] pub extern "C" fn FakeSvbControl(ctrl: c_int)->c_long {
    with(|c| c.controls.iter().find(|x| x.control_type == ctrl).map_or(c_long::MIN, |x| x.value))
}
#[no_mangle] pub extern "C" fn FakeSvbMode()->c_int {
    with(|c| c.mode)
}
#[no_mangle] pub extern "C" fn FakeSvbTriggers()->c_int {
    with(|c| c.triggers as c_int)
}
