// A software-only libgphoto2 for the gPhoto2 driver's tests, compiled with
// `rustc --crate-type cdylib` into `libgphoto2.so` (tests/gphoto2_fake_sdk.rs,
// tests/fake_sdk_linux/build_fakes.py).
//
// It answers the calls the driver makes the way libgphoto2 2.5 does
// (gphoto2-camera.h, gphoto2-widget.h, gphoto2-abilities-list.h,
// gphoto2-port-info-list.h): `gp_camera_init` opens the first attached camera
// unless the camera was given abilities and a port, a configuration tree is a
// copy the caller frees and writes back with `gp_camera_set_config`, a timed
// capture blocks until the frame is written and names one file, a RAW+JPEG
// body reports its second file as a FILE_ADDED event, a bulb exposure ends
// when the bulb control is released and its files arrive as events, event
// data is `malloc`ed for the caller to `free`, and an unplugged camera answers
// GP_ERROR_IO.
//
// The bodies' trees follow libgphoto2 2.5.34's widget names (strings of its
// ptp2 camlib) and the INDI driver: Canon EOS (`eosremoterelease`, decimal and
// fractional speeds, `bulb` among them only in M or B), Nikon (`shutterspeed`
// in "0.0040s" form beside `shutterspeed2`, `bulb` toggle, `longexpnr`), Sony
// (ILCE, `bulb` toggle) and Fujifilm X (no trigger capture, "2m" speeds).
// A test drives it through the `fake_gp_*` functions.
#![allow(non_snake_case, non_camel_case_types, clippy::missing_safety_doc)]
use std::collections::{HashMap, VecDeque};
use std::ffi::{c_char, c_float, c_int, c_ulong, c_void, CStr, CString};
use std::sync::Mutex;
use std::time::{Duration, Instant};

extern "C" {
    fn malloc(size: usize) -> *mut c_void;
}

const GP_OK: c_int = 0;
const GP_ERROR: c_int = -1;
const GP_ERROR_BAD_PARAMETERS: c_int = -2;
const GP_ERROR_UNKNOWN_PORT: c_int = -5;
const GP_ERROR_NOT_SUPPORTED: c_int = -6;
const GP_ERROR_IO: c_int = -7;
const GP_ERROR_MODEL_NOT_FOUND: c_int = -105;
const GP_ERROR_FILE_NOT_FOUND: c_int = -108;
const GP_ERROR_CAMERA_BUSY: c_int = -110;
const EVENT_TIMEOUT: c_int = 1;
const EVENT_FILE_ADDED: c_int = 2;
const EVENT_CAPTURE_COMPLETE: c_int = 4;
const OP_CAPTURE: c_int = 1;
const OP_PREVIEW: c_int = 8;
const OP_CONFIG: c_int = 16;
const OP_TRIGGER: c_int = 32;
const TEXT: c_int = 2;
const TOGGLE: c_int = 4;
const RADIO: c_int = 5;
const SECTION: c_int = 1;
const WINDOW: c_int = 0;

#[repr(C)]
pub struct CameraFilePath {
    name: [c_char; 128],
    folder: [c_char; 1024],
}

#[repr(C)]
pub struct CameraAbilities {
    model: [c_char; 128],
    status: c_int,
    port: c_int,
    speed: [c_int; 64],
    operations: c_int,
    file_operations: c_int,
    folder_operations: c_int,
    usb_vendor: c_int,
    usb_product: c_int,
    usb_class: c_int,
    usb_subclass: c_int,
    usb_protocol: c_int,
    library: [c_char; 1024],
    id: [c_char; 1024],
    device_type: c_int,
    reserved: [c_int; 7],
}

#[derive(Clone, Copy, PartialEq)]
enum Maker {
    Canon,
    Nikon,
    Sony,
    Fuji,
}

const MODELS: &[(&str, Maker)] = &[
    ("Canon EOS 6d Mark II", Maker::Canon),
    ("Nikon Z6_2", Maker::Nikon),
    ("Sony Alpha-A7 III (PC Control)", Maker::Sony),
    ("Fuji Fujifilm X-T5", Maker::Fuji),
];

const CANON_SPEEDS: &[&str] = &[
    "bulb", "30", "25", "20", "15", "13", "10", "8", "6", "5", "4", "3.2", "2.5", "2", "1.6", "1.3", "1",
    "0.8", "0.6", "0.5", "0.4", "0.3", "1/4", "1/8", "1/15", "1/30", "1/60", "1/125", "1/250", "1/4000",
];
const NIKON_SPEEDS: &[&str] = &[
    "0.0002s", "0.0040s", "0.0080s", "0.5000s", "1.0000s", "2.0000s", "15.0000s", "30.0000s", "Bulb", "Time",
];
const NIKON_SPEEDS2: &[&str] = &["1/4000", "1/250", "1/125", "1/2", "1", "2", "15", "30", "Bulb", "Time", "x 200"];
const SONY_SPEEDS: &[&str] = &["Bulb", "30", "15", "8", "4", "2", "1", "1/2", "1/125", "1/250", "1/8000"];
const FUJI_SPEEDS: &[&str] = &["bulb", "4m", "2m", "1m", "30", "15", "8", "4", "2", "1", "1/2", "1/250", "1/8000"];
const ISO: &[&str] = &["100", "200", "400", "800", "1600", "3200", "6400", "12800"];

struct Spec {
    section: &'static str,
    name: &'static str,
    label: &'static str,
    kind: c_int,
    value: &'static str,
    choices: Vec<&'static str>,
}

fn w(section: &'static str, name: &'static str, label: &'static str, kind: c_int, value: &'static str, choices: &[&'static str]) -> Spec {
    Spec { section, name, label, kind, value, choices: choices.to_vec() }
}

fn with_auto(first: &'static str) -> Vec<&'static str> {
    let mut v = vec![first];
    v.extend_from_slice(ISO);
    v
}

fn specs(maker: Maker) -> Vec<Spec> {
    let target = &["Internal RAM", "Memory card"];
    match maker {
        Maker::Canon => vec![
            w("actions", "eosremoterelease", "Canon EOS Remote Release", RADIO, "None",
              &["None", "Press Half", "Press Full", "Release Half", "Release Full", "Immediate"]),
            w("actions", "bulb", "Bulb Mode", TOGGLE, "0", &[]),
            w("settings", "capturetarget", "Capture Target", RADIO, "Internal RAM", target),
            w("status", "serialnumber", "Serial Number", TEXT, "072022001234", &[]),
            w("status", "manufacturer", "Camera Manufacturer", TEXT, "Canon Inc.", &[]),
            w("status", "cameramodel", "Camera Model", TEXT, "Canon EOS 6D Mark II", &[]),
            w("status", "batterylevel", "Battery Level", TEXT, "100%", &[]),
            w("imgsettings", "iso", "ISO Speed", RADIO, "Auto", &with_auto("Auto")),
            w("imgsettings", "imageformat", "Image Format", RADIO, "Large Fine JPEG",
              &["Large Fine JPEG", "Large Normal JPEG", "RAW + Large Fine JPEG", "RAW"]),
            w("capturesettings", "autoexposuremode", "Auto Exposure Mode", RADIO, "Manual",
              &["P", "TV", "AV", "Manual", "Bulb"]),
            w("capturesettings", "shutterspeed", "Shutter Speed", RADIO, "1/125", CANON_SPEEDS),
        ],
        Maker::Nikon => vec![
            w("actions", "bulb", "Bulb Mode", TOGGLE, "0", &[]),
            w("settings", "capturetarget", "Capture Target", RADIO, "Memory card", target),
            w("status", "serialnumber", "Serial Number", TEXT, "6012345", &[]),
            w("status", "manufacturer", "Camera Manufacturer", TEXT, "Nikon Corporation", &[]),
            w("status", "cameramodel", "Camera Model", TEXT, "Z 6_2", &[]),
            w("status", "batterylevel", "Battery Level", TEXT, "84", &[]),
            w("imgsettings", "iso", "ISO Speed", RADIO, "800", ISO),
            w("capturesettings", "imagequality", "Image Quality", RADIO, "NEF+Fine",
              &["JPEG Basic", "JPEG Fine", "NEF (Raw)", "NEF+Basic", "NEF+Fine"]),
            w("capturesettings", "longexpnr", "Long Exp Noise Reduction", RADIO, "On", &["Off", "On"]),
            w("capturesettings", "shutterspeed", "Shutter Speed", RADIO, "1.0000s", NIKON_SPEEDS),
            w("capturesettings", "shutterspeed2", "Shutter Speed 2", RADIO, "1", NIKON_SPEEDS2),
        ],
        Maker::Sony => vec![
            w("actions", "bulb", "Bulb Mode", TOGGLE, "0", &[]),
            w("status", "serialnumber", "Serial Number", TEXT, "00000000000000003282933003521371", &[]),
            w("status", "manufacturer", "Camera Manufacturer", TEXT, "Sony Corporation", &[]),
            w("status", "cameramodel", "Camera Model", TEXT, "ILCE-7M3", &[]),
            w("status", "batterylevel", "Battery Level", TEXT, "50%", &[]),
            w("imgsettings", "iso", "ISO Speed", RADIO, "Auto ISO", &with_auto("Auto ISO")),
            w("imgsettings", "imageformat", "Image Format", RADIO, "RAW", &["RAW", "RAW+JPEG", "Fine", "Standard"]),
            w("capturesettings", "shutterspeed", "Shutter Speed", RADIO, "1/125", SONY_SPEEDS),
        ],
        Maker::Fuji => vec![
            w("actions", "bulb", "Bulb Mode", TOGGLE, "0", &[]),
            w("status", "serialnumber", "Serial Number", TEXT, "93A12345", &[]),
            w("status", "manufacturer", "Camera Manufacturer", TEXT, "FUJIFILM", &[]),
            w("status", "cameramodel", "Camera Model", TEXT, "X-T5", &[]),
            w("imgsettings", "iso", "ISO Speed", RADIO, "800", ISO),
            w("imgsettings", "imagequality", "Image Quality", RADIO, "Fine + RAW", &["Fine", "Normal", "Fine + RAW", "RAW"]),
            w("capturesettings", "shutterspeed", "Shutter Speed", RADIO, "1/250", FUJI_SPEEDS),
        ],
    }
}

fn speed_seconds(s: &str) -> Option<f64> {
    let s = s.trim().trim_end_matches('s');
    if let Some(m) = s.strip_suffix('m') {
        return m.parse::<f64>().ok().map(|v| v * 60.0);
    }
    if let Some((n, d)) = s.split_once('/') {
        return Some(n.parse::<f64>().ok()? / d.parse::<f64>().ok()?);
    }
    s.parse().ok()
}

struct File {
    folder: String,
    name: String,
    data: Vec<u8>,
}

struct Body {
    model: String,
    maker: Maker,
    port: String,
    attached: bool,
    raw: Vec<u8>,
    values: HashMap<String, String>,
    /// Widgets that refuse every write.
    locked: Vec<String>,
    busy: u32,
    realtime: bool,
    jpeg_first: bool,
    shutter_widget: String,
    open_since: Option<Instant>,
    events: VecDeque<(c_int, Option<(String, String)>)>,
    files: Vec<File>,
    counter: u32,
    made: Vec<String>,
}

impl Body {
    fn value(&self, name: &str) -> String {
        self.values.get(name).cloned().unwrap_or_default()
    }
    fn speeds(&self, widget: &str) -> Vec<&'static str> {
        let spec = specs(self.maker).into_iter().find(|s| s.name == widget).map(|s| s.choices).unwrap_or_default();
        // A Canon body lists bulb only in M or B.
        if self.maker == Maker::Canon && widget == "shutterspeed" {
            let mode = self.value("autoexposuremode");
            if mode != "Manual" && mode != "Bulb" {
                return spec.into_iter().filter(|c| *c != "bulb").collect();
            }
        }
        spec
    }
    fn shutter(&self) -> String {
        self.value(&self.shutter_widget)
    }
    fn on_bulb(&self) -> bool {
        self.shutter().to_ascii_lowercase().starts_with("bulb")
    }
    fn ram(&self) -> bool {
        self.value("capturetarget") != "Memory card"
    }
    /// Write the frame's files; answer the one a capture names first.
    fn write_files(&mut self) -> Vec<(String, String)> {
        self.counter += 1;
        let format = self.value("imageformat") + &self.value("imagequality");
        let ext = match self.maker {
            Maker::Canon => "CR2",
            Maker::Nikon => "NEF",
            Maker::Sony => "ARW",
            Maker::Fuji => "RAF",
        };
        let folder = if self.ram() { "/".to_string() } else { "/store_00010001/DCIM/100CAMRA".to_string() };
        let raw = format.contains("RAW") || format.contains("NEF");
        let jpeg = !raw || format.contains('+');
        let mut names = Vec::new();
        if raw {
            let name = format!("IMG_{:04}.{ext}", self.counter);
            self.files.push(File { folder: folder.clone(), name: name.clone(), data: self.raw.clone() });
            names.push((folder.clone(), name));
        }
        if jpeg {
            let name = format!("IMG_{:04}.JPG", self.counter);
            self.files.push(File { folder: folder.clone(), name: name.clone(), data: vec![0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10] });
            names.push((folder, name));
        }
        if self.jpeg_first {
            names.reverse();
        }
        names
    }
}

struct State {
    bodies: Vec<Body>,
    trace: Vec<String>,
}

static STATE: Mutex<State> = Mutex::new(State { bodies: Vec::new(), trace: Vec::new() });

fn state() -> std::sync::MutexGuard<'static, State> {
    STATE.lock().unwrap_or_else(|e| e.into_inner())
}

fn trace(s: String) {
    state().trace.push(s);
}

unsafe fn text(p: *const c_char) -> String {
    if p.is_null() { String::new() } else { CStr::from_ptr(p).to_string_lossy().into_owned() }
}

fn put(dst: &mut [c_char], s: &str) {
    for (d, b) in dst.iter_mut().zip(s.bytes().chain(std::iter::once(0))) {
        *d = b as c_char;
    }
}

pub struct FakeCamera {
    model: Option<String>,
    port: Option<String>,
    open: Option<String>,
}

fn body_of<'a>(st: &'a mut State, cam: *mut FakeCamera) -> Result<&'a mut Body, c_int> {
    // SAFETY: test-only; `cam` is a FakeCamera made by gp_camera_new.
    let port = unsafe { (*cam).open.clone() }.ok_or(GP_ERROR)?;
    let body = st.bodies.iter_mut().find(|b| b.port == port).ok_or(GP_ERROR_IO)?;
    if body.attached { Ok(body) } else { Err(GP_ERROR_IO) }
}

// ---- test control -------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn fake_gp_reset() {
    let mut st = state();
    st.bodies.clear();
    st.trace.clear();
}

/// Attach a body of `model` on `port`, its captures holding the raw file at `raw_path`.
#[no_mangle]
pub unsafe extern "C" fn fake_gp_attach(model: *const c_char, port: *const c_char, raw_path: *const c_char) -> c_int {
    let model = text(model);
    let Some(&(_, maker)) = MODELS.iter().find(|(m, _)| *m == model) else { return GP_ERROR_MODEL_NOT_FOUND };
    let raw = std::fs::read(text(raw_path)).unwrap_or_default();
    let values = specs(maker).iter().map(|s| (s.name.to_string(), s.value.to_string())).collect();
    let shutter_widget = if maker == Maker::Nikon { "shutterspeed2" } else { "shutterspeed" }.to_string();
    state().bodies.push(Body {
        model, maker, port: text(port), attached: true, raw, values, locked: Vec::new(), busy: 0,
        realtime: false, jpeg_first: false, shutter_widget, open_since: None, events: VecDeque::new(),
        files: Vec::new(), counter: 0, made: Vec::new(),
    });
    GP_OK
}

/// Unplug the body on `port` (`new_port` null), or plug it back in on `new_port`.
#[no_mangle]
pub unsafe extern "C" fn fake_gp_replug(port: *const c_char, new_port: *const c_char) {
    let (port, new_port) = (text(port), text(new_port));
    let mut st = state();
    if let Some(b) = st.bodies.iter_mut().find(|b| b.port == port) {
        b.attached = !new_port.is_empty();
        if b.attached {
            b.port = new_port;
        }
    }
}

/// Body settings for a test: `busy` = n, `realtime` = 1, `jpeg_first` = 1,
/// `lock` = widget name, `stray` = 1 (a file and its event from an earlier
/// capture), or any widget name = value.
#[no_mangle]
pub unsafe extern "C" fn fake_gp_set(port: *const c_char, key: *const c_char, value: *const c_char) {
    let (port, key, value) = (text(port), text(key), text(value));
    let mut st = state();
    let Some(b) = st.bodies.iter_mut().find(|b| b.port == port) else { return };
    match key.as_str() {
        "busy" => b.busy = value.parse().unwrap_or(0),
        "realtime" => b.realtime = value == "1",
        "jpeg_first" => b.jpeg_first = value == "1",
        "lock" => b.locked.push(value),
        "stray" => {
            for (folder, name) in b.write_files() {
                b.events.push_back((EVENT_FILE_ADDED, Some((folder, name))));
            }
        }
        _ => {
            b.values.insert(key, value);
        }
    }
}

fn leak(s: String) -> *const c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

/// A widget's value on the body on `port`.
#[no_mangle]
pub unsafe extern "C" fn fake_gp_value(port: *const c_char, name: *const c_char) -> *const c_char {
    let (port, name) = (text(port), text(name));
    let st = state();
    leak(st.bodies.iter().find(|b| b.port == port).map(|b| b.value(&name)).unwrap_or_default())
}

/// The exposures the body on `port` made ("timed 30", "bulb 7.012"), one per line.
#[no_mangle]
pub unsafe extern "C" fn fake_gp_made(port: *const c_char) -> *const c_char {
    let port = text(port);
    let st = state();
    leak(st.bodies.iter().find(|b| b.port == port).map(|b| b.made.join("\n")).unwrap_or_default())
}

/// The files left on the body on `port`.
#[no_mangle]
pub unsafe extern "C" fn fake_gp_files(port: *const c_char) -> c_int {
    let port = text(port);
    let st = state();
    st.bodies.iter().find(|b| b.port == port).map_or(-1, |b| b.files.len() as c_int)
}

/// Every call the fake answered of note, one per line.
#[no_mangle]
pub unsafe extern "C" fn fake_gp_trace() -> *const c_char {
    leak(state().trace.join("\n"))
}

// ---- library ------------------------------------------------------------

#[no_mangle]
pub extern "C" fn gp_library_version(_verbose: c_int) -> *const *const c_char {
    static VERSION: &[u8] = b"2.5.34-fake\0";
    struct Table([*const c_char; 2]);
    unsafe impl Sync for Table {}
    static TABLE: Table = Table([VERSION.as_ptr() as *const c_char, std::ptr::null()]);
    TABLE.0.as_ptr()
}

#[no_mangle]
pub extern "C" fn gp_context_new() -> *mut c_void {
    Box::into_raw(Box::new(0u8)) as *mut c_void
}
#[no_mangle]
pub unsafe extern "C" fn gp_context_unref(c: *mut c_void) {
    if !c.is_null() {
        drop(Box::from_raw(c as *mut u8));
    }
}

#[no_mangle]
pub unsafe extern "C" fn gp_camera_new(out: *mut *mut FakeCamera) -> c_int {
    *out = Box::into_raw(Box::new(FakeCamera { model: None, port: None, open: None }));
    GP_OK
}
#[no_mangle]
pub unsafe extern "C" fn gp_camera_set_abilities(cam: *mut FakeCamera, a: CameraAbilities) -> c_int {
    (*cam).model = Some(text(a.model.as_ptr()));
    GP_OK
}
#[no_mangle]
pub unsafe extern "C" fn gp_camera_set_port_info(cam: *mut FakeCamera, info: *mut c_void) -> c_int {
    (*cam).port = Some(text(info as *const c_char));
    GP_OK
}
#[no_mangle]
pub unsafe extern "C" fn gp_camera_init(cam: *mut FakeCamera, _ctx: *mut c_void) -> c_int {
    let mut st = state();
    let wanted = (*cam).port.clone();
    let found = st.bodies.iter().find(|b| b.attached && wanted.as_ref().map_or(true, |p| *p == b.port)).map(|b| b.port.clone());
    match found {
        Some(port) => {
            st.trace.push(format!("init {port} as {:?}", (*cam).model));
            (*cam).open = Some(port);
            GP_OK
        }
        None => GP_ERROR_IO,
    }
}
#[no_mangle]
pub unsafe extern "C" fn gp_camera_exit(cam: *mut FakeCamera, _ctx: *mut c_void) -> c_int {
    if let Some(port) = &(*cam).open {
        trace(format!("exit {port}"));
    }
    GP_OK
}
#[no_mangle]
pub unsafe extern "C" fn gp_camera_unref(cam: *mut FakeCamera) -> c_int {
    gp_camera_free(cam)
}
#[no_mangle]
pub unsafe extern "C" fn gp_camera_free(cam: *mut FakeCamera) -> c_int {
    if !cam.is_null() {
        drop(Box::from_raw(cam));
    }
    GP_OK
}

#[no_mangle]
pub unsafe extern "C" fn gp_camera_get_abilities(cam: *mut FakeCamera, out: *mut CameraAbilities) -> c_int {
    let mut st = state();
    let body = match body_of(&mut st, cam) { Ok(b) => b, Err(e) => return e };
    put(&mut (*out).model, &body.model);
    (*out).operations = OP_CAPTURE | OP_PREVIEW | OP_CONFIG | if body.maker == Maker::Fuji { 0 } else { OP_TRIGGER };
    GP_OK
}

#[no_mangle]
pub unsafe extern "C" fn gp_camera_get_summary(_cam: *mut FakeCamera, out: *mut c_char, _ctx: *mut c_void) -> c_int {
    *out = 0;
    GP_OK
}

// ---- lists --------------------------------------------------------------

pub struct List(Vec<(CString, CString)>);

#[no_mangle]
pub unsafe extern "C" fn gp_list_new(out: *mut *mut List) -> c_int {
    *out = Box::into_raw(Box::new(List(Vec::new())));
    GP_OK
}
#[no_mangle]
pub unsafe extern "C" fn gp_list_count(l: *mut List) -> c_int {
    (*l).0.len() as c_int
}
#[no_mangle]
pub unsafe extern "C" fn gp_list_get_name(l: *mut List, i: c_int, out: *mut *const c_char) -> c_int {
    match (&(*l).0).get(i as usize) { Some((n, _)) => { *out = n.as_ptr(); GP_OK } None => GP_ERROR_BAD_PARAMETERS }
}
#[no_mangle]
pub unsafe extern "C" fn gp_list_get_value(l: *mut List, i: c_int, out: *mut *const c_char) -> c_int {
    match (&(*l).0).get(i as usize) { Some((_, v)) => { *out = v.as_ptr(); GP_OK } None => GP_ERROR_BAD_PARAMETERS }
}
#[no_mangle]
pub unsafe extern "C" fn gp_list_free(l: *mut List) -> c_int {
    drop(Box::from_raw(l));
    GP_OK
}
#[no_mangle]
pub unsafe extern "C" fn gp_camera_autodetect(l: *mut List, _ctx: *mut c_void) -> c_int {
    let st = state();
    for b in st.bodies.iter().filter(|b| b.attached) {
        (*l).0.push((CString::new(b.model.clone()).unwrap(), CString::new(b.port.clone()).unwrap()));
    }
    GP_OK
}

pub struct Names(Vec<CString>);

#[no_mangle]
pub unsafe extern "C" fn gp_abilities_list_new(out: *mut *mut Names) -> c_int {
    *out = Box::into_raw(Box::new(Names(Vec::new())));
    GP_OK
}
#[no_mangle]
pub unsafe extern "C" fn gp_abilities_list_load(l: *mut Names, _ctx: *mut c_void) -> c_int {
    (*l).0 = MODELS.iter().map(|(m, _)| CString::new(*m).unwrap()).collect();
    GP_OK
}
#[no_mangle]
pub unsafe extern "C" fn gp_abilities_list_lookup_model(l: *mut Names, model: *const c_char) -> c_int {
    let model = text(model);
    (*l).0.iter().position(|m| m.to_str() == Ok(model.as_str())).map_or(GP_ERROR_MODEL_NOT_FOUND, |i| i as c_int)
}
#[no_mangle]
pub unsafe extern "C" fn gp_abilities_list_get_abilities(l: *mut Names, i: c_int, out: *mut CameraAbilities) -> c_int {
    match (&(*l).0).get(i as usize) {
        Some(m) => { put(&mut (*out).model, m.to_str().unwrap_or_default()); GP_OK }
        None => GP_ERROR_BAD_PARAMETERS,
    }
}
#[no_mangle]
pub unsafe extern "C" fn gp_abilities_list_free(l: *mut Names) -> c_int {
    drop(Box::from_raw(l));
    GP_OK
}
#[no_mangle]
pub unsafe extern "C" fn gp_port_info_list_new(out: *mut *mut Names) -> c_int {
    *out = Box::into_raw(Box::new(Names(Vec::new())));
    GP_OK
}
#[no_mangle]
pub unsafe extern "C" fn gp_port_info_list_load(l: *mut Names) -> c_int {
    let st = state();
    (*l).0 = st.bodies.iter().filter(|b| b.attached).map(|b| CString::new(b.port.clone()).unwrap()).collect();
    (*l).0.push(CString::new("usb:").unwrap());
    GP_OK
}
#[no_mangle]
pub unsafe extern "C" fn gp_port_info_list_lookup_path(l: *mut Names, path: *const c_char) -> c_int {
    let path = text(path);
    (*l).0.iter().position(|p| p.to_str() == Ok(path.as_str())).map_or(GP_ERROR_UNKNOWN_PORT, |i| i as c_int)
}
#[no_mangle]
pub unsafe extern "C" fn gp_port_info_list_get_info(l: *mut Names, i: c_int, out: *mut *mut c_void) -> c_int {
    match (&(*l).0).get(i as usize) { Some(p) => { *out = p.as_ptr() as *mut c_void; GP_OK } None => GP_ERROR_BAD_PARAMETERS }
}
#[no_mangle]
pub unsafe extern "C" fn gp_port_info_list_free(l: *mut Names) -> c_int {
    drop(Box::from_raw(l));
    GP_OK
}

// ---- configuration ------------------------------------------------------

pub struct Widget {
    name: CString,
    label: CString,
    kind: c_int,
    value: CString,
    toggle: c_int,
    choices: Vec<CString>,
    children: Vec<Box<Widget>>,
}

fn node(name: &str, kind: c_int) -> Box<Widget> {
    Box::new(Widget {
        name: CString::new(name).unwrap(), label: CString::new(name).unwrap(), kind,
        value: CString::default(), toggle: 0, choices: Vec::new(), children: Vec::new(),
    })
}

#[no_mangle]
pub unsafe extern "C" fn gp_camera_get_config(cam: *mut FakeCamera, out: *mut *mut Widget, _ctx: *mut c_void) -> c_int {
    let mut st = state();
    let body = match body_of(&mut st, cam) { Ok(b) => b, Err(e) => return e };
    let mut root = node("main", WINDOW);
    for spec in specs(body.maker) {
        let section = match root.children.iter().position(|s| s.name.to_str() == Ok(spec.section)) {
            Some(i) => i,
            None => { root.children.push(node(spec.section, SECTION)); root.children.len() - 1 }
        };
        let value = body.value(spec.name);
        let choices = if spec.name.starts_with("shutterspeed") { body.speeds(spec.name) } else { spec.choices };
        root.children[section].children.push(Box::new(Widget {
            name: CString::new(spec.name).unwrap(), label: CString::new(spec.label).unwrap(), kind: spec.kind,
            toggle: value.parse().unwrap_or(0), value: CString::new(value).unwrap(),
            choices: choices.iter().map(|c| CString::new(*c).unwrap()).collect(), children: Vec::new(),
        }));
    }
    *out = Box::into_raw(root);
    GP_OK
}

fn changes(w: &Widget, out: &mut Vec<(String, String)>) {
    if w.kind == TOGGLE {
        out.push((w.name.to_string_lossy().into_owned(), w.toggle.to_string()));
    } else if w.kind == RADIO || w.kind == TEXT {
        out.push((w.name.to_string_lossy().into_owned(), w.value.to_string_lossy().into_owned()));
    }
    for c in &w.children {
        changes(c, out);
    }
}

fn press(body: &mut Body, st_trace: &mut Vec<String>) -> c_int {
    if !body.on_bulb() {
        // The camera takes a timed frame of its current speed.
        let shutter = body.shutter();
        body.made.push(format!("timed {}", speed_seconds(&shutter).unwrap_or(0.0)));
        for (folder, name) in body.write_files() {
            body.events.push_back((EVENT_FILE_ADDED, Some((folder, name))));
        }
        st_trace.push(format!("press while shutter {shutter}"));
        return GP_OK;
    }
    body.open_since = Some(Instant::now());
    GP_OK
}

fn release(body: &mut Body) {
    if let Some(opened) = body.open_since.take() {
        body.made.push(format!("bulb {:.3}", opened.elapsed().as_secs_f64()));
        for (folder, name) in body.write_files() {
            body.events.push_back((EVENT_FILE_ADDED, Some((folder, name))));
        }
        body.events.push_back((EVENT_CAPTURE_COMPLETE, None));
    }
}

#[no_mangle]
pub unsafe extern "C" fn gp_camera_set_config(cam: *mut FakeCamera, root: *mut Widget, _ctx: *mut c_void) -> c_int {
    let mut guard = state();
    let st = &mut *guard;
    let mut trace_lines = Vec::new();
    let result = (|| {
        let body = body_of(st, cam)?;
        if body.busy > 0 {
            body.busy -= 1;
            return Err(GP_ERROR_CAMERA_BUSY);
        }
        let mut all = Vec::new();
        changes(&*root, &mut all);
        for (name, value) in all {
            if body.value(&name) == value {
                continue;
            }
            if body.locked.contains(&name) {
                return Err(GP_ERROR_NOT_SUPPORTED);
            }
            let spec = specs(body.maker).into_iter().find(|s| s.name == name);
            if let Some(spec) = spec.filter(|s| s.kind == RADIO) {
                let choices = if name.starts_with("shutterspeed") { body.speeds(&name) } else { spec.choices };
                if !choices.contains(&value.as_str()) {
                    return Err(GP_ERROR_BAD_PARAMETERS);
                }
            }
            trace_lines.push(format!("set {name}={value}"));
            match name.as_str() {
                "eosremoterelease" if value.starts_with("Press Full") => { press(body, &mut trace_lines); }
                "eosremoterelease" if value.starts_with("Release") => release(body),
                "bulb" if value == "1" => {
                    if !body.on_bulb() {
                        return Err(GP_ERROR);
                    }
                    body.open_since = Some(Instant::now());
                }
                "bulb" => release(body),
                n if n.starts_with("shutterspeed") => body.shutter_widget = n.to_string(),
                _ => {}
            }
            body.values.insert(name, value);
        }
        Ok(())
    })();
    st.trace.extend(trace_lines);
    result.err().unwrap_or(GP_OK)
}

#[no_mangle]
pub unsafe extern "C" fn gp_widget_get_child_by_name(w: *mut Widget, name: *const c_char, out: *mut *mut Widget) -> c_int {
    unsafe fn find(w: *mut Widget, name: &CStr) -> *mut Widget {
        if (*w).name.as_c_str() == name {
            return w;
        }
        for c in (*w).children.iter_mut() {
            let found = find(&mut **c, name);
            if !found.is_null() {
                return found;
            }
        }
        std::ptr::null_mut()
    }
    let found = find(w, CStr::from_ptr(name));
    if found.is_null() { GP_ERROR_BAD_PARAMETERS } else { *out = found; GP_OK }
}
#[no_mangle]
pub unsafe extern "C" fn gp_widget_get_type(w: *mut Widget, out: *mut c_int) -> c_int {
    *out = (*w).kind;
    GP_OK
}
#[no_mangle]
pub unsafe extern "C" fn gp_widget_get_name(w: *mut Widget, out: *mut *const c_char) -> c_int {
    *out = (*w).name.as_ptr();
    GP_OK
}
#[no_mangle]
pub unsafe extern "C" fn gp_widget_get_label(w: *mut Widget, out: *mut *const c_char) -> c_int {
    *out = (*w).label.as_ptr();
    GP_OK
}
#[no_mangle]
pub unsafe extern "C" fn gp_widget_count_children(w: *mut Widget) -> c_int {
    (*w).children.len() as c_int
}
#[no_mangle]
pub unsafe extern "C" fn gp_widget_get_child(w: *mut Widget, i: c_int, out: *mut *mut Widget) -> c_int {
    match (&mut (*w).children).get_mut(i as usize) { Some(c) => { *out = &mut **c; GP_OK } None => GP_ERROR_BAD_PARAMETERS }
}
#[no_mangle]
pub unsafe extern "C" fn gp_widget_get_value(w: *mut Widget, out: *mut c_void) -> c_int {
    match (*w).kind {
        TOGGLE => *(out as *mut c_int) = (*w).toggle,
        RADIO | TEXT => *(out as *mut *const c_char) = (*w).value.as_ptr(),
        _ => return GP_ERROR_BAD_PARAMETERS,
    }
    GP_OK
}
#[no_mangle]
pub unsafe extern "C" fn gp_widget_set_value(w: *mut Widget, value: *const c_void) -> c_int {
    match (*w).kind {
        TOGGLE => (*w).toggle = *(value as *const c_int),
        RADIO | TEXT => (*w).value = CStr::from_ptr(value as *const c_char).to_owned(),
        _ => return GP_ERROR_BAD_PARAMETERS,
    }
    GP_OK
}
#[no_mangle]
pub unsafe extern "C" fn gp_widget_count_choices(w: *mut Widget) -> c_int {
    (*w).choices.len() as c_int
}
#[no_mangle]
pub unsafe extern "C" fn gp_widget_get_choice(w: *mut Widget, i: c_int, out: *mut *const c_char) -> c_int {
    match (&(*w).choices).get(i as usize) { Some(c) => { *out = c.as_ptr(); GP_OK } None => GP_ERROR_BAD_PARAMETERS }
}
#[no_mangle]
pub unsafe extern "C" fn gp_widget_get_range(_w: *mut Widget, _min: *mut c_float, _max: *mut c_float, _inc: *mut c_float) -> c_int {
    GP_ERROR_BAD_PARAMETERS
}
#[no_mangle]
pub unsafe extern "C" fn gp_widget_free(w: *mut Widget) -> c_int {
    drop(Box::from_raw(w));
    GP_OK
}

// ---- capture, events, files ---------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn gp_camera_capture(cam: *mut FakeCamera, _kind: c_int, path: *mut CameraFilePath, _ctx: *mut c_void) -> c_int {
    let (seconds, realtime) = {
        let mut st = state();
        let body = match body_of(&mut st, cam) { Ok(b) => b, Err(e) => return e };
        if body.on_bulb() {
            return GP_ERROR;
        }
        (speed_seconds(&body.shutter()).unwrap_or(0.0), body.realtime)
    };
    std::thread::sleep(Duration::from_secs_f64(if realtime { seconds } else { seconds.min(0.05) }));
    let mut st = state();
    let body = match body_of(&mut st, cam) { Ok(b) => b, Err(e) => return e };
    body.made.push(format!("timed {seconds}"));
    let mut names = body.write_files().into_iter();
    let (folder, name) = names.next().unwrap();
    for (f, n) in names {
        body.events.push_back((EVENT_FILE_ADDED, Some((f, n))));
    }
    put(&mut (*path).folder, &folder);
    put(&mut (*path).name, &name);
    st.trace.push(format!("capture {folder}/{name}"));
    GP_OK
}

#[no_mangle]
pub unsafe extern "C" fn gp_camera_trigger_capture(cam: *mut FakeCamera, _ctx: *mut c_void) -> c_int {
    let mut st = state();
    let body = match body_of(&mut st, cam) { Ok(b) => b, Err(e) => return e };
    if body.maker == Maker::Fuji {
        return GP_ERROR_NOT_SUPPORTED;
    }
    let mut trace_lines = Vec::new();
    press(body, &mut trace_lines);
    GP_OK
}

#[no_mangle]
pub unsafe extern "C" fn gp_camera_wait_for_event(cam: *mut FakeCamera, timeout_ms: c_int, kind: *mut c_int, data: *mut *mut c_void, _ctx: *mut c_void) -> c_int {
    *data = std::ptr::null_mut();
    let event = {
        let mut st = state();
        let body = match body_of(&mut st, cam) { Ok(b) => b, Err(e) => return e };
        body.events.pop_front()
    };
    match event {
        Some((k, file)) => {
            *kind = k;
            if let Some((folder, name)) = file {
                let p = malloc(std::mem::size_of::<CameraFilePath>()) as *mut CameraFilePath;
                put(&mut (*p).folder, &folder);
                put(&mut (*p).name, &name);
                *data = p as *mut c_void;
            }
        }
        None => {
            std::thread::sleep(Duration::from_millis((timeout_ms.max(0) as u64).min(20)));
            *kind = EVENT_TIMEOUT;
        }
    }
    GP_OK
}

pub struct FakeFile(Vec<u8>);

#[no_mangle]
pub unsafe extern "C" fn gp_file_new(out: *mut *mut FakeFile) -> c_int {
    *out = Box::into_raw(Box::new(FakeFile(Vec::new())));
    GP_OK
}
#[no_mangle]
pub unsafe extern "C" fn gp_file_unref(f: *mut FakeFile) -> c_int {
    gp_file_free(f)
}
#[no_mangle]
pub unsafe extern "C" fn gp_file_free(f: *mut FakeFile) -> c_int {
    if !f.is_null() {
        drop(Box::from_raw(f));
    }
    GP_OK
}
#[no_mangle]
pub unsafe extern "C" fn gp_file_get_data_and_size(f: *mut FakeFile, data: *mut *const c_char, size: *mut c_ulong) -> c_int {
    *data = (*f).0.as_ptr() as *const c_char;
    *size = (*f).0.len() as c_ulong;
    GP_OK
}

#[no_mangle]
pub unsafe extern "C" fn gp_camera_file_get(cam: *mut FakeCamera, folder: *const c_char, name: *const c_char, _kind: c_int, file: *mut FakeFile, _ctx: *mut c_void) -> c_int {
    let (folder, name) = (text(folder), text(name));
    let mut st = state();
    let body = match body_of(&mut st, cam) { Ok(b) => b, Err(e) => return e };
    match body.files.iter().find(|f| f.folder == folder && f.name == name) {
        Some(f) => { (*file).0 = f.data.clone(); GP_OK }
        None => GP_ERROR_FILE_NOT_FOUND,
    }
}

#[no_mangle]
pub unsafe extern "C" fn gp_camera_file_delete(cam: *mut FakeCamera, folder: *const c_char, name: *const c_char, _ctx: *mut c_void) -> c_int {
    let (folder, name) = (text(folder), text(name));
    let mut st = state();
    let body = match body_of(&mut st, cam) { Ok(b) => b, Err(e) => return e };
    let before = body.files.len();
    body.files.retain(|f| !(f.folder == folder && f.name == name));
    let removed = before != body.files.len();
    st.trace.push(format!("delete {folder}/{name}"));
    if removed { GP_OK } else { GP_ERROR_FILE_NOT_FOUND }
}

#[no_mangle]
pub unsafe extern "C" fn gp_camera_capture_preview(cam: *mut FakeCamera, file: *mut FakeFile, _ctx: *mut c_void) -> c_int {
    let mut st = state();
    if let Err(e) = body_of(&mut st, cam) {
        return e;
    }
    (*file).0 = vec![0xFF, 0xD8, 0xFF, 0xD9];
    GP_OK
}
