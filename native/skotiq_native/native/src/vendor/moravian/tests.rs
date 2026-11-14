//! The driver against in-process stand-ins for the three Moravian libraries.
//!
//! One stand-in camera model answers through a `libgxccd` table (0 / -1
//! results, rows delivered bottom row first, gxccd.h), a `cXusb.dll` table and
//! a `gXusb.dll` table (one-byte TRUE / FALSE results, `String_HIGH` buffer
//! lengths, begin / end / get-image exposures; cxusb.h, gxusb.h,
//! MoravianCameraDriver.pdf). Every call the driver makes is logged.

use super::*;
use skotiq_device::FrameType;
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

#[derive(Clone)]
struct FakeCamera {
    id: u32,
    name: &'static str,
    serial: &'static str,
    width: i32,
    height: i32,
    rgb: bool,
    x_odd: bool,
    y_odd: bool,
    /// GBP_GAIN: the camera reports its e-/ADU, which says nothing about setting gain.
    reports_adc_gain: bool,
    max_gain: i32,
    min_exposure_us: i32,
    default_read_mode: i32,
    /// GIP_MAX_PIXEL_VALUE at 1x1 and at larger binning.
    max_pixel: (i32, i32),
    power_fraction: f32,
}

impl FakeCamera {
    fn cmos() -> Self {
        Self {
            id: 1,
            name: "C3-61000 Pro",
            serial: "3061-0042",
            width: 72,
            height: 54,
            rgb: false,
            x_odd: false,
            y_odd: false,
            reports_adc_gain: false,
            max_gain: 100,
            min_exposure_us: 125,
            default_read_mode: 1,
            max_pixel: (4095, 16383),
            power_fraction: 0.41,
        }
    }

    fn ccd() -> Self {
        Self {
            id: 2,
            name: "G2-8300",
            serial: "G2-0007",
            width: 48,
            height: 32,
            reports_adc_gain: true,
            max_gain: 0,
            min_exposure_us: 0,
            default_read_mode: 0,
            max_pixel: (65535, 65535),
            ..Self::cmos()
        }
    }
}

struct Fake {
    cameras: Vec<FakeCamera>,
    calls: Vec<String>,
    connected: bool,
    ready: bool,
    bin: (u32, u32),
}

impl Fake {
    fn with(cameras: Vec<FakeCamera>) -> Self {
        Self {
            cameras,
            calls: Vec::new(),
            connected: true,
            ready: true,
            bin: (1, 1),
        }
    }
}

static FAKE: Mutex<Option<Fake>> = Mutex::new(None);

struct Installed(#[allow(dead_code)] MutexGuard<'static, ()>);

fn install(fake: Fake) -> Installed {
    let turn = discovery::REGISTRY_TEST_TURN
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    *FAKE.lock().unwrap_or_else(|e| e.into_inner()) = Some(fake);
    discovery::forget_every_open_camera();
    Installed(turn)
}

fn with<R>(f: impl FnOnce(&mut Fake) -> R) -> R {
    f(FAKE
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_mut()
        .expect("a stand-in is installed"))
}

fn log(call: String) {
    with(|f| f.calls.push(call));
}

fn calls() -> Vec<String> {
    with(|f| std::mem::take(&mut f.calls))
}

fn handle_of(index: usize) -> PCCamera {
    ((index + 1) << 8) as PCCamera
}

fn camera_at(handle: PCCamera) -> FakeCamera {
    let index = (handle as usize >> 8) - 1;
    with(|f| f.cameras[index].clone())
}

fn initialize_id(id: u32) -> Option<PCCamera> {
    log(format!("initialize({})", id));
    with(|f| f.cameras.iter().position(|c| c.id == id)).map(handle_of)
}

fn boolean(handle: PCCamera, index: c_int) -> Option<bool> {
    let camera = camera_at(handle);
    Some(match index {
        0 => with(|f| f.connected),
        1 | 3 | 4 | 7 => true,
        10 => false,
        13 => camera.reports_adc_gain,
        128 => camera.rgb,
        129 | 130 => false,
        131 => camera.x_odd,
        132 => camera.y_odd,
        _ => return None,
    })
}

fn integer(handle: PCCamera, index: c_int) -> Option<i32> {
    let camera = camera_at(handle);
    Some(match index {
        1 => camera.width,
        2 => camera.height,
        3 | 4 => 3760,
        5 | 6 => 4,
        9 => camera.min_exposure_us,
        12 => camera.default_read_mode,
        16 => camera.max_gain,
        17 => {
            if with(|f| f.bin) == (1, 1) {
                camera.max_pixel.0
            } else {
                camera.max_pixel.1
            }
        }
        _ => return None,
    })
}

fn text(handle: PCCamera, index: c_int) -> Option<&'static str> {
    let camera = camera_at(handle);
    match index {
        0 => Some(camera.name),
        2 => Some(camera.serial),
        _ => None,
    }
}

fn value(handle: PCCamera, index: c_int) -> Option<f32> {
    let camera = camera_at(handle);
    match index {
        0 => Some(-9.5),
        11 => Some(camera.power_fraction),
        _ => None,
    }
}

const READ_MODES: [&str; 2] = ["Normal", "Low noise"];

fn write_text(buffer: *mut c_char, size: usize, text: &str) {
    for (i, byte) in text
        .bytes()
        .chain(std::iter::once(0))
        .take(size)
        .enumerate()
    {
        // SAFETY: the driver passes a buffer of `size` bytes.
        unsafe { *buffer.add(i) = byte as c_char };
    }
}

fn put<T>(out: *mut T, value: T) {
    // SAFETY: the driver passes valid out-pointers.
    unsafe { *out = value };
}

/// A delivered frame whose pixel at buffer row `r`, column `c` is `r * 100 + c`.
fn fill(buffer: *mut c_void, bytes: usize, width: usize) {
    let pixels = buffer.cast::<u16>();
    for i in 0..bytes / 2 {
        // SAFETY: the driver passes a buffer of `bytes` bytes.
        unsafe { *pixels.add(i) = ((i / width) * 100 + i % width) as u16 };
    }
}

static LAST_ROI_WIDTH: Mutex<usize> = Mutex::new(1);

fn started(seconds: f64, shutter: u8, x: c_int, y: c_int, w: c_int, h: c_int) {
    *LAST_ROI_WIDTH.lock().unwrap() = w as usize;
    log(format!(
        "start({},shutter={},{},{},{},{})",
        seconds, shutter, x, y, w, h
    ));
}

// --- libgxccd stand-in -----------------------------------------------------

unsafe extern "C" fn gx_enumerate(callback: GxccdEnumCallback) {
    for id in with(|f| f.cameras.iter().map(|c| c.id).collect::<Vec<_>>()) {
        callback(id as c_int);
    }
}
extern "C" fn gx_initialize(id: c_int) -> PCCamera {
    initialize_id(id as u32).unwrap_or(std::ptr::null_mut())
}
extern "C" fn gx_release(_: PCCamera) {
    log("release".into());
}
extern "C" fn gx_boolean(h: PCCamera, i: c_int, v: *mut GxBool) -> c_int {
    boolean(h, i).map_or(-1, |b| {
        put(v, b as GxBool);
        0
    })
}
extern "C" fn gx_integer(h: PCCamera, i: c_int, v: *mut c_int) -> c_int {
    integer(h, i).map_or(-1, |n| {
        put(v, n);
        0
    })
}
extern "C" fn gx_string(h: PCCamera, i: c_int, buf: *mut c_char, size: usize) -> c_int {
    text(h, i).map_or(-1, |t| {
        write_text(buf, size, t);
        0
    })
}
extern "C" fn gx_value(h: PCCamera, i: c_int, v: *mut c_float) -> c_int {
    value(h, i).map_or(-1, |x| {
        put(v, x);
        0
    })
}
extern "C" fn gx_set_temperature(_: PCCamera, t: c_float) -> c_int {
    log(format!("set_temperature({})", t));
    0
}
extern "C" fn gx_set_binning(_: PCCamera, x: c_int, y: c_int) -> c_int {
    log(format!("set_binning({},{})", x, y));
    with(|f| f.bin = (x as u32, y as u32));
    0
}
extern "C" fn gx_set_gain(_: PCCamera, gain: u16) -> c_int {
    log(format!("set_gain({})", gain));
    0
}
extern "C" fn gx_set_read_mode(_: PCCamera, mode: c_int) -> c_int {
    log(format!("set_read_mode({})", mode));
    0
}
extern "C" fn gx_read_modes(_: PCCamera, i: c_int, buf: *mut c_char, size: usize) -> c_int {
    READ_MODES.get(i as usize).map_or(-1, |name| {
        write_text(buf, size, name);
        0
    })
}
extern "C" fn gx_start(
    _: PCCamera,
    s: c_double,
    sh: GxBool,
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
) -> c_int {
    started(s, sh, x, y, w, h);
    0
}
extern "C" fn gx_abort(_: PCCamera, keep: GxBool) -> c_int {
    log(format!("abort(keep={})", keep));
    0
}
extern "C" fn gx_ready(_: PCCamera, ready: *mut GxBool) -> c_int {
    if !with(|f| f.connected) {
        return -1;
    }
    put(ready, with(|f| f.ready) as GxBool);
    0
}
extern "C" fn gx_read(_: PCCamera, buf: *mut c_void, size: usize) -> c_int {
    log(format!("read_image({})", size));
    fill(buf, size, *LAST_ROI_WIDTH.lock().unwrap());
    0
}
extern "C" fn gx_last_error(_: PCCamera, buf: *mut c_char, size: usize) {
    write_text(buf, size, "stand-in error");
}

#[cfg(unix)]
fn this_process() -> libloading::Library {
    libloading::os::unix::Library::this().into()
}

#[cfg(windows)]
fn this_process() -> libloading::Library {
    libloading::os::windows::Library::this()
        .expect("a handle to the test executable")
        .into()
}

fn gxccd() -> GxccdSdk {
    GxccdSdk {
        enumerate_usb: gx_enumerate,
        initialize_usb: gx_initialize,
        release: gx_release,
        get_boolean_parameter: gx_boolean,
        get_integer_parameter: gx_integer,
        get_string_parameter: gx_string,
        get_value: gx_value,
        set_temperature: gx_set_temperature,
        set_binning: gx_set_binning,
        set_gain: gx_set_gain,
        set_read_mode: gx_set_read_mode,
        enumerate_read_modes: gx_read_modes,
        start_exposure: gx_start,
        abort_exposure: gx_abort,
        image_ready: gx_ready,
        read_image: gx_read,
        get_last_error: gx_last_error,
        _library: this_process(),
    }
}

// --- Windows driver stand-ins (cXusb, gXusb) -------------------------------

unsafe extern "C" fn win_enumerate(callback: SipsEnumCallback) {
    for id in with(|f| f.cameras.iter().map(|c| c.id).collect::<Vec<_>>()) {
        callback(id);
    }
}
extern "C" fn win_initialize(id: u32) -> PCCamera {
    initialize_id(id).unwrap_or(usize::MAX as PCCamera)
}
extern "C" fn win_boolean(h: PCCamera, i: u32, v: *mut GxBool) -> GxBool {
    boolean(h, i as c_int).is_some_and(|b| {
        put(v, b as GxBool);
        true
    }) as GxBool
}
extern "C" fn win_integer(h: PCCamera, i: u32, v: *mut c_int) -> GxBool {
    integer(h, i as c_int).is_some_and(|n| {
        put(v, n);
        true
    }) as GxBool
}
/// `high` is the highest index the buffer has.
extern "C" fn win_string(h: PCCamera, i: u32, high: u32, buf: *mut c_char) -> GxBool {
    text(h, i as c_int).is_some_and(|t| {
        write_text(buf, high as usize + 1, t);
        true
    }) as GxBool
}
extern "C" fn win_value(h: PCCamera, i: u32, v: *mut c_float) -> GxBool {
    value(h, i as c_int).is_some_and(|x| {
        put(v, x);
        true
    }) as GxBool
}
extern "C" fn win_last_error(_: PCCamera, high: u32, buf: *mut c_char) {
    write_text(buf, high as usize + 1, "stand-in error");
}
extern "C" fn win_set_temperature(h: PCCamera, t: c_float) -> GxBool {
    (gx_set_temperature(h, t) == 0) as GxBool
}
extern "C" fn win_set_binning(h: PCCamera, x: u32, y: u32) -> GxBool {
    (gx_set_binning(h, x as c_int, y as c_int) == 0) as GxBool
}
extern "C" fn win_read_modes(h: PCCamera, i: u32, high: u32, buf: *mut c_char) -> GxBool {
    (gx_read_modes(h, i as c_int, buf, high as usize + 1) == 0) as GxBool
}
extern "C" fn win_set_read_mode(h: PCCamera, mode: u32) -> GxBool {
    (gx_set_read_mode(h, mode as c_int) == 0) as GxBool
}
extern "C" fn win_set_gain(h: PCCamera, gain: u32) -> GxBool {
    (gx_set_gain(h, gain as u16) == 0) as GxBool
}
extern "C" fn win_start(
    h: PCCamera,
    s: c_double,
    sh: GxBool,
    x: c_int,
    y: c_int,
    w: c_int,
    d: c_int,
) -> GxBool {
    (gx_start(h, s, sh, x, y, w, d) == 0) as GxBool
}
extern "C" fn win_abort(h: PCCamera, keep: GxBool) -> GxBool {
    (gx_abort(h, keep) == 0) as GxBool
}
extern "C" fn win_ready(h: PCCamera, ready: *mut GxBool) -> GxBool {
    (gx_ready(h, ready) == 0) as GxBool
}
extern "C" fn win_read(h: PCCamera, len: u32, buf: *mut c_void) -> GxBool {
    (gx_read(h, buf, len as usize) == 0) as GxBool
}
extern "C" fn win_begin(_: PCCamera, shutter: GxBool) -> GxBool {
    log(format!("begin(shutter={})", shutter));
    1
}
extern "C" fn win_end(_: PCCamera, shutter: GxBool, discard: GxBool) -> GxBool {
    log(format!("end(shutter={},discard={})", shutter, discard));
    1
}
extern "C" fn win_get_image(
    _: PCCamera,
    x: c_int,
    y: c_int,
    w: c_int,
    d: c_int,
    len: u32,
    buf: *mut c_void,
) -> GxBool {
    log(format!("get_image({},{},{},{},{})", x, y, w, d, len));
    fill(buf, len as usize, w as usize);
    1
}

fn cxusb() -> CxUsbSdk {
    CxUsbSdk {
        enumerate: win_enumerate,
        initialize: win_initialize,
        release: gx_release,
        get_boolean_parameter: win_boolean,
        get_integer_parameter: win_integer,
        get_string_parameter: win_string,
        get_value: win_value,
        get_last_error_string: win_last_error,
        set_temperature: win_set_temperature,
        set_binning: win_set_binning,
        enumerate_read_modes: win_read_modes,
        set_read_mode: win_set_read_mode,
        start_exposure: win_start,
        abort_exposure: win_abort,
        image_ready: win_ready,
        read_image: win_read,
        set_gain: Some(win_set_gain),
        _library: this_process(),
    }
}

fn gxusb() -> GxUsbSdk {
    GxUsbSdk {
        enumerate: win_enumerate,
        initialize: win_initialize,
        release: gx_release,
        get_boolean_parameter: win_boolean,
        get_integer_parameter: win_integer,
        get_string_parameter: win_string,
        get_value: win_value,
        get_last_error_string: win_last_error,
        set_temperature: win_set_temperature,
        set_binning: win_set_binning,
        enumerate_read_modes: win_read_modes,
        set_read_mode: win_set_read_mode,
        begin_exposure: win_begin,
        end_exposure: win_end,
        get_image: win_get_image,
        set_gain: Some(win_set_gain),
        _library: this_process(),
    }
}

// --- helpers -----------------------------------------------------------------

fn connected(api: &dyn Api, id: u32) -> MoravianCamera {
    let mut camera = MoravianCamera::new(api.library(), id);
    camera.open(api).expect("the camera connects");
    calls();
    camera
}

fn exposure(
    seconds: f64,
    bin: i32,
    subframe: Option<SubFrame>,
    frame_type: FrameType,
) -> ExposureParams {
    ExposureParams {
        duration_secs: seconds,
        gain: None,
        offset: None,
        bin_x: bin,
        bin_y: bin,
        subframe,
        readout_mode: None,
        frame_type,
    }
}

fn region(x: u32, y: u32, w: u32, h: u32) -> SubFrame {
    SubFrame {
        start_x: x,
        start_y: y,
        width: w,
        height: h,
    }
}

// --- tests -------------------------------------------------------------------

#[test]
fn starting_an_exposure_returns_at_once_and_abort_reaches_the_camera() {
    let _fake = install(Fake::with(vec![FakeCamera::cmos()]));
    let sdk = gxccd();
    let mut camera = connected(&sdk, 1);

    let begun = Instant::now();
    camera
        .begin(&sdk, &exposure(300.0, 1, None, FrameType::Light))
        .unwrap();
    assert!(
        begun.elapsed() < Duration::from_secs(1),
        "start_exposure must not hold the camera for the exposure"
    );
    assert!(
        !camera.poll_complete(&sdk).unwrap(),
        "300 s have not passed"
    );
    camera.abort(&sdk);
    assert_eq!(
        calls(),
        [
            "set_binning(1,1)",
            "start(300,shutter=1,0,0,72,54)",
            "abort(keep=0)"
        ]
    );
    assert!(camera.exposure.is_none());
}

#[test]
fn each_frame_uses_its_own_binning_and_binned_region() {
    let _fake = install(Fake::with(vec![FakeCamera::cmos()]));
    let sdk = gxccd();
    let mut camera = connected(&sdk, 1);

    camera
        .begin(&sdk, &exposure(0.0, 2, None, FrameType::Light))
        .unwrap();
    assert_eq!(
        calls(),
        ["set_binning(2,2)", "start(0.000125,shutter=1,0,0,36,27)"]
    );
    let frame = camera.read_frame(&sdk).unwrap();
    assert_eq!((frame.width, frame.height), (36, 27));
    assert_eq!((frame.metadata.bin_x, frame.metadata.bin_y), (2, 2));
    assert_eq!(calls(), ["read_image(1944)"]);

    // Binned pixels, as the sequencer sends them; libgxccd counts rows from
    // the bottom: 27 - 4 - 8 = 15.
    camera
        .begin(
            &sdk,
            &exposure(0.0, 2, Some(region(8, 4, 16, 8)), FrameType::Dark),
        )
        .unwrap();
    assert_eq!(
        calls(),
        ["set_binning(2,2)", "start(0.000125,shutter=0,8,15,16,8)"]
    );
    let frame = camera.read_frame(&sdk).unwrap();
    assert_eq!((frame.width, frame.height), (16, 8));
    assert_eq!(
        frame.metadata.subframe.map(|s| (s.start_x, s.start_y)),
        Some((8, 4))
    );
    assert_eq!(calls(), ["read_image(256)"]);

    let refused = camera.begin(&sdk, &exposure(1.0, 99, None, FrameType::Light));
    assert!(matches!(refused, Err(DriverError::InvalidParameter(_))));
    let refused = camera.begin(
        &sdk,
        &exposure(1.0, 2, Some(region(30, 0, 16, 8)), FrameType::Light),
    );
    assert!(matches!(refused, Err(DriverError::InvalidParameter(_))));
    assert!(
        calls().is_empty(),
        "nothing reaches the camera for a refused frame"
    );
}

#[test]
fn a_frame_shorter_than_the_camera_allows_records_what_the_camera_exposed() {
    let _fake = install(Fake::with(vec![FakeCamera::cmos()]));
    let sdk = gxccd();
    let mut camera = connected(&sdk, 1);
    camera
        .begin(&sdk, &exposure(0.0, 1, None, FrameType::Bias))
        .unwrap();
    let frame = camera.read_frame(&sdk).unwrap();
    assert_eq!(frame.metadata.exposure_time, 0.000125);
}

#[test]
fn gain_is_settable_when_the_camera_has_a_gain_range() {
    let _fake = install(Fake::with(vec![FakeCamera::cmos(), FakeCamera::ccd()]));
    let sdk = gxccd();

    let mut cmos = connected(&sdk, 1);
    assert!(cmos.core.capabilities.can_set_gain);
    assert_eq!(cmos.limits.max_gain, Some(100));
    let mut params = exposure(1.0, 1, None, FrameType::Light);
    params.gain = Some(42);
    cmos.begin(&sdk, &params).unwrap();
    assert!(calls().contains(&"set_gain(42)".to_string()));
    let frame = cmos.read_frame(&sdk).unwrap();
    assert_eq!(frame.metadata.gain, 42);
    params.gain = Some(101);
    assert!(matches!(
        cmos.begin(&sdk, &params),
        Err(DriverError::InvalidParameter(_))
    ));

    // GBP_GAIN only means "reports e-/ADU"; a CCD with no gain range cannot set it.
    let mut ccd = connected(&sdk, 2);
    assert!(!ccd.core.capabilities.can_set_gain);
    params.gain = Some(42);
    ccd.begin(&sdk, &params).unwrap();
    assert!(!calls().iter().any(|c| c.starts_with("set_gain")));
    assert_eq!(ccd.read_frame(&sdk).unwrap().metadata.gain, 0);
}

#[test]
fn the_default_read_mode_is_selected_and_named_in_each_frame() {
    let _fake = install(Fake::with(vec![FakeCamera::cmos()]));
    let sdk = gxccd();
    let mut camera = MoravianCamera::new(Library::Gxccd, 1);
    camera.open(&sdk).unwrap();
    assert!(calls().contains(&"set_read_mode(1)".to_string()));
    camera
        .begin(&sdk, &exposure(1.0, 1, None, FrameType::Light))
        .unwrap();
    let frame = camera.read_frame(&sdk).unwrap();
    assert_eq!(frame.metadata.readout_mode.as_deref(), Some("Low noise"));
}

#[test]
fn full_scale_follows_the_binning_the_frame_used() {
    let _fake = install(Fake::with(vec![FakeCamera::cmos()]));
    let sdk = gxccd();
    let mut camera = connected(&sdk, 1);
    assert_eq!(camera.core.sensor_info.max_adu, 4095);
    assert_eq!(camera.core.sensor_info.bit_depth, 12);
    camera
        .begin(&sdk, &exposure(1.0, 2, None, FrameType::Light))
        .unwrap();
    assert_eq!(camera.core.sensor_info.max_adu, 16383);
    assert_eq!(camera.read_frame(&sdk).unwrap().bits_per_pixel, 14);
}

#[test]
fn cooler_power_is_reported_in_percent() {
    let _fake = install(Fake::with(vec![FakeCamera::cmos()]));
    let sdk = gxccd();
    let camera = connected(&sdk, 1);
    let status = camera.status(&sdk).unwrap();
    assert!((status.cooler_power.unwrap() - 41.0).abs() < 1e-3);
}

#[test]
fn an_unplugged_camera_reports_disconnected() {
    let _fake = install(Fake::with(vec![FakeCamera::cmos()]));
    let sdk = gxccd();
    let mut camera = connected(&sdk, 1);
    with(|f| f.connected = false);
    assert!(matches!(
        camera.status(&sdk),
        Err(DriverError::Disconnected)
    ));
    with(|f| f.connected = true);
    camera
        .begin(&sdk, &exposure(0.0, 1, None, FrameType::Light))
        .unwrap();
    with(|f| f.connected = false);
    std::thread::sleep(Duration::from_millis(1));
    assert!(matches!(
        camera.poll_complete(&sdk),
        Err(DriverError::Disconnected)
    ));
}

#[test]
fn a_search_does_not_reopen_a_camera_this_process_has_open() {
    let _fake = install(Fake::with(vec![FakeCamera::cmos(), FakeCamera::ccd()]));
    let sdk = gxccd();
    let mut camera = connected(&sdk, 1);

    let listed = list_cameras(&sdk);
    let names: Vec<_> = listed.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, ["C3-61000 Pro", "G2-8300"]);
    assert_eq!(listed[0].serial_number.as_deref(), Some("3061-0042"));
    assert_eq!(calls(), ["initialize(2)", "release"]);

    camera.close(&sdk);
    calls();
    list_cameras(&sdk);
    assert_eq!(
        calls(),
        ["initialize(1)", "release", "initialize(2)", "release"]
    );
}

#[test]
fn a_color_frame_names_the_cell_at_its_own_first_pixel() {
    let mut color = FakeCamera::cmos();
    color.rgb = true;
    let _fake = install(Fake::with(vec![color]));
    let sdk = gxccd();
    let mut camera = connected(&sdk, 1);
    // RGGB from the delivered bottom row; 54 rows, mirrored: the top row is
    // delivered row 53, an odd row.
    assert_eq!(
        camera.core.sensor_info.bayer_pattern,
        Some(BayerPattern::Gbrg.into())
    );

    camera
        .begin(
            &sdk,
            &exposure(1.0, 1, Some(region(1, 2, 8, 4)), FrameType::Light),
        )
        .unwrap();
    let frame = camera.read_frame(&sdk).unwrap();
    // Column 1 and sensor row 53 - 2 = 51 of the delivered frame.
    assert_eq!(frame.bayer_pattern, Some(BayerPattern::Bggr.into()));
    // Mirrored: the first row handed on is the last row delivered.
    assert_eq!(&frame.data[..3], &[300, 301, 302]);

    camera
        .begin(&sdk, &exposure(1.0, 2, None, FrameType::Light))
        .unwrap();
    assert_eq!(camera.read_frame(&sdk).unwrap().bayer_pattern, None);
}

#[test]
fn the_cxusb_driver_reads_top_row_first_with_its_own_result_codes() {
    let mut color = FakeCamera::cmos();
    color.rgb = true;
    let _fake = install(Fake::with(vec![color]));
    let sdk = cxusb();
    let mut camera = connected(&sdk, 1);
    assert_eq!(camera.core.name, "C3-61000 Pro");
    assert_eq!(camera.serial_number().as_deref(), Some("3061-0042"));
    assert_eq!(
        camera.core.sensor_info.bayer_pattern,
        Some(BayerPattern::Rggb.into())
    );

    camera
        .begin(
            &sdk,
            &exposure(1.0, 1, Some(region(1, 2, 8, 4)), FrameType::Light),
        )
        .unwrap();
    assert_eq!(calls(), ["set_binning(1,1)", "start(1,shutter=1,1,2,8,4)"]);
    let frame = camera.read_frame(&sdk).unwrap();
    assert_eq!(frame.bayer_pattern, Some(BayerPattern::Grbg.into()));
    assert_eq!(&frame.data[..3], &[0, 1, 2]);
    assert_eq!(calls(), ["read_image(64)"]);
}

#[test]
fn the_gxusb_driver_times_the_exposure_on_the_computer() {
    let _fake = install(Fake::with(vec![FakeCamera::ccd()]));
    let sdk = gxusb();
    let mut camera = connected(&sdk, 2);

    camera
        .begin(
            &sdk,
            &exposure(0.05, 2, Some(region(2, 3, 8, 4)), FrameType::Dark),
        )
        .unwrap();
    assert_eq!(calls(), ["set_binning(2,2)", "begin(shutter=0)"]);
    assert!(!camera.poll_complete(&sdk).unwrap());
    std::thread::sleep(Duration::from_millis(60));
    assert!(camera.poll_complete(&sdk).unwrap());
    assert!(camera.poll_complete(&sdk).unwrap());
    assert_eq!(
        calls(),
        ["end(shutter=0,discard=0)"],
        "the exposure ends once"
    );

    let frame = camera.read_frame(&sdk).unwrap();
    assert_eq!(calls(), ["get_image(2,3,8,4,64)"]);
    assert_eq!((frame.width, frame.height), (8, 4));
    assert!(frame.metadata.exposure_time >= 0.05 && frame.metadata.exposure_time < 1.0);

    camera
        .begin(&sdk, &exposure(60.0, 1, None, FrameType::Light))
        .unwrap();
    camera.abort(&sdk);
    assert_eq!(
        calls(),
        [
            "set_binning(1,1)",
            "begin(shutter=1)",
            "end(shutter=1,discard=1)"
        ]
    );
}

#[test]
fn an_address_names_the_library_and_the_camera() {
    let gxccd = MoravianCamera::from_address("1234").unwrap();
    assert_eq!((gxccd.library, gxccd.camera_id), (Library::Gxccd, 1234));
    let cx = MoravianCamera::from_address("cx:77").unwrap();
    assert_eq!((cx.library, cx.camera_id), (Library::CxUsb, 77));
    let gx = MoravianCamera::from_address("gx:5").unwrap();
    assert_eq!((gx.library, gx.camera_id), (Library::GxUsb, 5));
    assert!(MoravianCamera::from_address("eth:5").is_err());
    let info = MoravianCameraInfo {
        library: Library::CxUsb,
        camera_id: 77,
        name: String::new(),
        serial_number: None,
        discovery_index: 0,
    };
    assert_eq!(info.address(), "cx:77");
}

#[tokio::test]
async fn offset_is_not_supported() {
    let mut camera = MoravianCamera::new(Library::Gxccd, 0);
    camera.core.offset = 7;
    assert!(matches!(
        camera.set_offset(22).await,
        Err(DriverError::NotSupported)
    ));
    assert_eq!(camera.core.offset, 7);
}

#[test]
fn region_rules() {
    let full = sdk_roi(4032, 2688, 2, 2, None, true).unwrap();
    assert_eq!(
        full,
        SdkRoi {
            x: 0,
            y: 0,
            w: 2016,
            h: 1344
        }
    );
    // Binned 100x100 at bin 1: a 30x40 region at (10, 20) starts at row 40 from the bottom.
    let flipped = sdk_roi(100, 100, 1, 1, Some(&region(10, 20, 30, 40)), true).unwrap();
    assert_eq!(
        flipped,
        SdkRoi {
            x: 10,
            y: 40,
            w: 30,
            h: 40
        }
    );
    let top_down = sdk_roi(100, 100, 1, 1, Some(&region(10, 20, 30, 40)), false).unwrap();
    assert_eq!(top_down.y, 20);
    assert!(sdk_roi(100, 100, 1, 1, Some(&region(0, 0, 0, 5)), true).is_err());
    assert!(sdk_roi(100, 100, 1, 1, Some(&region(u32::MAX, 0, 2, 5)), true).is_err());
    assert!(sdk_roi(100, 100, 0, 1, None, true).is_err());
}

#[test]
fn bayer_cells_shift_by_column_and_row() {
    use BayerPattern::*;
    assert_eq!(delivered_bayer(false, false), Rggb);
    assert_eq!(delivered_bayer(true, false), Grbg);
    assert_eq!(delivered_bayer(false, true), Gbrg);
    assert_eq!(delivered_bayer(true, true), Bggr);
    for cell in [Rggb, Grbg, Gbrg, Bggr] {
        assert_eq!(shift_bayer(shift_bayer(cell, 1, 1), 1, 1), cell);
        assert_eq!(shift_bayer(cell, 2, 4), cell);
    }
    // Full frame, bottom row delivered first: even height swaps the rows.
    assert_eq!(frame_bayer(Rggb, true, 2688, 0, 0), Gbrg);
    assert_eq!(frame_bayer(Rggb, true, 2689, 0, 0), Rggb);
    assert_eq!(frame_bayer(Rggb, false, 2688, 0, 0), Rggb);
}

#[test]
fn mirror_reverses_rows() {
    let mut buf = vec![1u16, 2, 3, 4, 5, 6];
    mirror_vertical_u16(&mut buf, 2, 3);
    assert_eq!(buf, vec![5, 6, 3, 4, 1, 2]);
    let mut short = vec![1u16, 2, 3];
    mirror_vertical_u16(&mut short, 2, 3);
    assert_eq!(short, vec![1, 2, 3], "a short buffer is left alone");
}

#[test]
fn bits_for_full_scale() {
    assert_eq!(bits_for(4095), 12);
    assert_eq!(bits_for(16383), 14);
    assert_eq!(bits_for(65535), 16);
    assert_eq!(bits_for(65520), 16);
}
