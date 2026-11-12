//! The Atik driver against a model of the SDK written from Atik's own
//! documents (AtikCameras.h, AtikDefs.h, the SDK Developer's Guide, "CMOS
//! Camera Specific Options", the Apx60 and TE Series programmers guides) and
//! from what the shipped libatikcameras.so does where the documents are silent
//! or wrong. Each rule of the model names its source.

use super::*;
use skotiq_device::camera::FrameType;
use std::cell::RefCell;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Family {
    /// A CCD: no gain or offset at all.
    Ccd,
    /// The Sony scientific bodies, the ones ArtemisSetGain works on.
    SonySci,
    Horizon,
    Acis,
    Apx,
    Te,
}

#[derive(Clone, Debug)]
struct Cam {
    name: &'static str,
    serial: Option<&'static str>,
    is_camera: bool,
    plugged: bool,
    family: Family,
    width: i32,
    height: i32,
    camera_flags: c_int,
    colour_type: c_int,
    colour_offset: (c_int, c_int),
    max_bin: (c_int, c_int),
    cooling_flags: c_int,
    cooling_level: (c_int, c_int, c_int),
    setpoint: c_int,
    temperature: c_int,
    // Camera specific options (CMOS Camera Specific Options; Apx60 and TE guides).
    preset_mode: u16,
    presets: [(u16, u16); 3],
    custom_gain: (u16, u16, u16),
    custom_offset: (u16, u16, u16),
    pad_data: bool,
    exposure_speed: u16,
    te_readout: u16,
    te_adc1_offset: (u16, u16, u16),
    sdk_gain: (c_int, c_int),
    // State the SDK keeps for an open camera.
    open: bool,
    eight_bit: bool,
    bin: (c_int, c_int),
    subframe: (c_int, c_int, c_int, c_int),
    dark_mode: Option<bool>,
    dark_mode_calls: u32,
    eight_bit_calls: u32,
    exposing: bool,
    exposed_with: Option<Exposure>,
    warm_up_calls: u32,
    image: Vec<u16>,
}

/// What the camera actually did for the last exposure.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Exposure {
    seconds: f32,
    gain: Option<u16>,
    offset: Option<u16>,
    dark: bool,
    bin: (c_int, c_int),
    subframe: (c_int, c_int, c_int, c_int),
}

const SHUTTER: c_int = 16;
const EIGHT_BIT: c_int = 256;

fn cam(family: Family) -> Cam {
    let cmos = !matches!(family, Family::Ccd | Family::SonySci);
    let (gain_range, offset_range) = match family {
        Family::Horizon => ((0, 60), (0, 511)),
        Family::Acis => ((0, 24), (0, 4095)),
        Family::Te => ((0, 63), (0, 255)),
        _ => ((0, 100), (0, 1000)),
    };
    Cam {
        name: "Atik Test",
        serial: Some("S1"),
        is_camera: true,
        plugged: true,
        family,
        width: 1000,
        height: 800,
        camera_flags: if cmos { 0 } else { SHUTTER | EIGHT_BIT },
        colour_type: ARTEMIS_COLOUR_NONE,
        colour_offset: (0, 0),
        max_bin: (4, 4),
        // HASCOOLING | CONTROLLABLE | SETPOINTCONTROL
        cooling_flags: 1 | 2 | 16,
        cooling_level: (0, 0, 255),
        setpoint: 0,
        temperature: 2150,
        preset_mode: 0,
        presets: [(0, 10), (20, 30), (40, 50)],
        custom_gain: (gain_range.0, gain_range.1, 5),
        custom_offset: (offset_range.0, offset_range.1, 100),
        pad_data: false,
        exposure_speed: 0,
        te_readout: 0,
        te_adc1_offset: (0, 4095, 1000),
        sdk_gain: (3, 7),
        open: false,
        eight_bit: false,
        bin: (1, 1),
        subframe: (0, 0, 1000, 800),
        dark_mode: None,
        dark_mode_calls: 0,
        eight_bit_calls: 0,
        exposing: false,
        exposed_with: None,
        warm_up_calls: 0,
        image: Vec::new(),
    }
}

#[derive(Clone, Debug)]
struct Wheel {
    serial: &'static str,
    efw_type: c_int,
    positions: c_int,
    position: c_int,
    open: bool,
}

#[derive(Default)]
struct World {
    devices: Vec<Cam>,
    wheels: Vec<Wheel>,
    refreshes: c_int,
    highest_index_asked: c_int,
}

thread_local! {
    static WORLD: RefCell<World> = RefCell::new(World::default());
}

fn world<R>(f: impl FnOnce(&mut World) -> R) -> R {
    WORLD.with(|w| f(&mut w.borrow_mut()))
}

fn camera<R>(handle: ArtemisHandle, f: impl FnOnce(&mut Cam) -> R) -> Option<R> {
    let index = (handle as usize).checked_sub(1)?;
    world(|w| {
        w.devices
            .get_mut(index)
            .filter(|c| c.open && c.plugged)
            .map(f)
    })
}

fn with_camera(handle: ArtemisHandle, f: impl FnOnce(&mut Cam) -> c_int) -> c_int {
    camera(handle, f).unwrap_or(ArtemisError::InvalidParameter as c_int)
}

fn wheel<R>(handle: ArtemisHandle, f: impl FnOnce(&mut Wheel) -> R) -> Option<R> {
    let index = (handle as usize).checked_sub(0x1000)?;
    world(|w| w.wheels.get_mut(index).filter(|wh| wh.open).map(f))
}

fn write_text(dest: *mut c_char, text: &str) {
    // SAFETY: the caller passes a 100-byte buffer (AtikCameras.h).
    unsafe {
        for (i, b) in text.bytes().enumerate() {
            *dest.add(i) = b as c_char;
        }
        *dest.add(text.len()) = 0;
    }
}

const OK: c_int = 0;
const INVALID_PARAMETER: c_int = 1;
const INVALID_FUNCTION: c_int = 5;

// ---- device list -----------------------------------------------------------

extern "C" fn device_count() -> c_int {
    world(|w| w.devices.iter().filter(|d| d.plugged).count() as c_int)
}
/// The shipped library returns the sum of its device-update counters
/// (AtikCore::ArtemisDLL::RefreshDeviceCount), not a device count.
extern "C" fn refresh_devices_count() -> c_int {
    world(|w| {
        w.refreshes += 1;
        1000 + w.refreshes
    })
}
fn plugged_at(index: c_int) -> Option<usize> {
    world(|w| {
        w.highest_index_asked = w.highest_index_asked.max(index);
        w.devices
            .iter()
            .enumerate()
            .filter(|(_, d)| d.plugged)
            .nth(usize::try_from(index).ok()?)
            .map(|(i, _)| i)
    })
}
extern "C" fn device_present(index: c_int) -> c_int {
    plugged_at(index).is_some() as c_int
}
extern "C" fn device_is_camera(index: c_int) -> c_int {
    plugged_at(index).is_some_and(|i| world(|w| w.devices[i].is_camera)) as c_int
}
extern "C" fn device_name(index: c_int, name: *mut c_char) -> c_int {
    match plugged_at(index) {
        Some(i) => {
            write_text(name, world(|w| w.devices[i].name));
            1
        }
        None => 0,
    }
}
extern "C" fn device_serial(index: c_int, serial: *mut c_char) -> c_int {
    match plugged_at(index).and_then(|i| world(|w| w.devices[i].serial)) {
        Some(s) => {
            write_text(serial, s);
            1
        }
        None => 0,
    }
}
extern "C" fn connect(index: c_int) -> ArtemisHandle {
    match plugged_at(index) {
        Some(i) if world(|w| w.devices[i].is_camera && !w.devices[i].open) => {
            world(|w| w.devices[i].open = true);
            (i + 1) as ArtemisHandle
        }
        _ => std::ptr::null_mut(),
    }
}
extern "C" fn disconnect(handle: ArtemisHandle) -> c_int {
    camera(handle, |c| c.open = false).is_some() as c_int
}
extern "C" fn is_connected(handle: ArtemisHandle) -> c_int {
    camera(handle, |_| ()).is_some() as c_int
}

// ---- camera info -----------------------------------------------------------

extern "C" fn properties(handle: ArtemisHandle, prop: *mut ArtemisProperties) -> c_int {
    with_camera(handle, |c| {
        // SAFETY: the driver passes a valid struct.
        let p = unsafe { &mut *prop };
        p.protocol = 0x0102;
        p.pixels_x = c.width;
        p.pixels_y = c.height;
        p.pixel_microns_x = 3.76;
        p.pixel_microns_y = 3.76;
        p.camera_flags = c.camera_flags;
        for (i, b) in c.name.bytes().enumerate() {
            p.description[i] = b as c_char;
        }
        OK
    })
}
extern "C" fn colour_properties(
    handle: ArtemisHandle,
    colour_type: *mut c_int,
    ox: *mut c_int,
    oy: *mut c_int,
    px: *mut c_int,
    py: *mut c_int,
) -> c_int {
    with_camera(handle, |c| {
        // SAFETY: valid out-pointers.
        unsafe {
            *colour_type = c.colour_type;
            *ox = c.colour_offset.0;
            *oy = c.colour_offset.1;
            *px = 0;
            *py = 0;
        }
        OK
    })
}
extern "C" fn get_max_bin(handle: ArtemisHandle, x: *mut c_int, y: *mut c_int) -> c_int {
    with_camera(handle, |c| {
        // SAFETY: valid out-pointers.
        unsafe {
            *x = c.max_bin.0;
            *y = c.max_bin.1;
        }
        OK
    })
}
/// ExposureSettings::SetIn8BitMode answers 1 (INVALID_PARAMETER) when
/// AtikCameraDetails::Has8BitMode is false.
extern "C" fn eight_bit_mode(handle: ArtemisHandle, on: bool) -> c_int {
    with_camera(handle, |c| {
        c.eight_bit_calls += 1;
        if c.camera_flags & EIGHT_BIT == 0 {
            return INVALID_PARAMETER;
        }
        c.eight_bit = on;
        OK
    })
}

// ---- exposure settings -----------------------------------------------------

extern "C" fn bin(handle: ArtemisHandle, x: c_int, y: c_int) -> c_int {
    with_camera(handle, |c| {
        if x < 1 || y < 1 || x > c.max_bin.0 || y > c.max_bin.1 {
            return INVALID_PARAMETER;
        }
        c.bin = (x, y);
        OK
    })
}
/// In unbinned sensor pixels (INDI passes its unbinned frame; NINA passes the
/// full sensor size whatever the binning).
extern "C" fn subframe(handle: ArtemisHandle, x: c_int, y: c_int, w: c_int, h: c_int) -> c_int {
    with_camera(handle, |c| {
        if x < 0 || y < 0 || w <= 0 || h <= 0 || x + w > c.width || y + h > c.height {
            return INVALID_PARAMETER;
        }
        c.subframe = (x, y, w, h);
        OK
    })
}
/// ExposureSettings::SetInDarkMode answers 5 (INVALID_FUNCTION) when
/// AtikCameraDetails::HasShutter is false.
extern "C" fn set_dark_mode(handle: ArtemisHandle, on: bool) -> c_int {
    with_camera(handle, |c| {
        c.dark_mode_calls += 1;
        if c.camera_flags & SHUTTER == 0 {
            return INVALID_FUNCTION;
        }
        c.dark_mode = Some(on);
        OK
    })
}

/// The gain and offset the sensor is read with now.
fn effective_gain(c: &Cam) -> (Option<u16>, Option<u16>) {
    match c.family {
        Family::Ccd => (None, None),
        Family::SonySci => (Some(c.sdk_gain.0 as u16), Some(c.sdk_gain.1 as u16)),
        // Custom values take effect only in the Custom preset (Apx60 guide).
        Family::Horizon | Family::Acis | Family::Apx => match c.preset_mode {
            0 => (Some(c.custom_gain.2), Some(c.custom_offset.2)),
            p => {
                let (g, o) = c.presets[usize::from(p) - 1];
                (Some(g), Some(o))
            }
        },
        // TE guide: readout 0 and 1 use ADC1 and its offset (ID 88), with no
        // gain; readout 2 uses ADC2 with the custom gain and offset.
        Family::Te => match c.te_readout {
            2 => (Some(c.custom_gain.2), Some(c.custom_offset.2)),
            _ => (None, Some(c.te_adc1_offset.2)),
        },
    }
}

extern "C" fn start_exposure(handle: ArtemisHandle, seconds: c_float) -> c_int {
    with_camera(handle, |c| {
        let (gain, offset) = effective_gain(c);
        let dark = c.dark_mode.unwrap_or(false);
        c.exposed_with = Some(Exposure {
            seconds,
            gain,
            offset,
            dark,
            bin: c.bin,
            subframe: c.subframe,
        });
        c.exposing = true;
        let (w, h) = (c.subframe.2 / c.bin.0, c.subframe.3 / c.bin.1);
        // Pad data on puts the 12-bit samples in the high bits (CMOS options).
        let full = if c.pad_data { 0xFFF0 } else { 0x0FFF };
        let full = if matches!(c.family, Family::Horizon | Family::Acis) {
            full
        } else {
            0xFFFF
        };
        c.image = vec![1; (w * h) as usize];
        c.image[0] = full;
        OK
    })
}
extern "C" fn abort_exposure(handle: ArtemisHandle) -> c_int {
    with_camera(handle, |c| {
        c.exposing = false;
        OK
    })
}
/// Fast exposure speed delivers frames only through the fast callback, never
/// through ArtemisImageReady/ArtemisImageBuffer (CMOS options, Apx60 guide).
extern "C" fn image_ready(handle: ArtemisHandle) -> c_int {
    camera(handle, |c| (c.exposing && c.exposure_speed != 2) as c_int).unwrap_or(0)
}
extern "C" fn image_failed(handle: ArtemisHandle) -> c_int {
    camera(handle, |_| 0).unwrap_or(1)
}
extern "C" fn camera_state(handle: ArtemisHandle) -> c_int {
    camera(handle, |_| CAMERA_IDLE).unwrap_or(CAMERA_ERROR)
}
extern "C" fn exposure_time_remaining(_handle: ArtemisHandle) -> c_float {
    0.0
}
/// w and h are the binned image (the SDK example allocates w * h samples).
extern "C" fn get_image_data(
    handle: ArtemisHandle,
    x: *mut c_int,
    y: *mut c_int,
    w: *mut c_int,
    h: *mut c_int,
    bx: *mut c_int,
    by: *mut c_int,
) -> c_int {
    with_camera(handle, |c| {
        // SAFETY: valid out-pointers.
        unsafe {
            *x = c.subframe.0;
            *y = c.subframe.1;
            *w = c.subframe.2 / c.bin.0;
            *h = c.subframe.3 / c.bin.1;
            *bx = c.bin.0;
            *by = c.bin.1;
        }
        OK
    })
}
extern "C" fn image_buffer(handle: ArtemisHandle) -> *mut c_void {
    camera(handle, |c| c.image.as_mut_ptr() as *mut c_void).unwrap_or(std::ptr::null_mut())
}

// ---- cooling ---------------------------------------------------------------

/// Hundredths of a degree (guide 5.6: -10 C is -1000).
extern "C" fn set_cooling(handle: ArtemisHandle, setpoint: c_int) -> c_int {
    with_camera(handle, |c| {
        c.setpoint = setpoint;
        // COOLINGON | SETPOINTCONTROLON, not WARMINGUP
        c.cooling_flags = (c.cooling_flags | 64 | 128) & !32;
        OK
    })
}
extern "C" fn cooling_info(
    handle: ArtemisHandle,
    flags: *mut c_int,
    level: *mut c_int,
    min: *mut c_int,
    max: *mut c_int,
    setpoint: *mut c_int,
) -> c_int {
    with_camera(handle, |c| {
        // SAFETY: valid out-pointers.
        unsafe {
            *flags = c.cooling_flags;
            *level = c.cooling_level.0;
            *min = c.cooling_level.1;
            *max = c.cooling_level.2;
            *setpoint = c.setpoint;
        }
        OK
    })
}
extern "C" fn cooler_warm_up(handle: ArtemisHandle) -> c_int {
    with_camera(handle, |c| {
        c.warm_up_calls += 1;
        c.cooling_flags |= 32;
        OK
    })
}
/// Sensor 0 answers the number of sensors; sensor 1 is hundredths of a degree
/// (SDK example prints 0.01 * temp).
extern "C" fn temperature_sensor_info(
    handle: ArtemisHandle,
    sensor: c_int,
    t: *mut c_int,
) -> c_int {
    with_camera(handle, |c| {
        // SAFETY: valid out-pointer.
        unsafe {
            *t = match sensor {
                0 => 1,
                1 => c.temperature,
                _ => return INVALID_PARAMETER,
            }
        };
        OK
    })
}

// ---- gain ------------------------------------------------------------------

/// "Artemis{Get/Set}Gain will not work" on the CMOS bodies (CMOS options,
/// Apx60 and TE guides).
extern "C" fn set_gain(handle: ArtemisHandle, _preview: bool, gain: c_int, offset: c_int) -> c_int {
    with_camera(handle, |c| {
        if c.family != Family::SonySci {
            return INVALID_FUNCTION;
        }
        c.sdk_gain = (gain, offset);
        OK
    })
}
extern "C" fn get_gain(
    handle: ArtemisHandle,
    _preview: bool,
    g: *mut c_int,
    o: *mut c_int,
) -> c_int {
    with_camera(handle, |c| {
        if c.family != Family::SonySci {
            return INVALID_FUNCTION;
        }
        // SAFETY: valid out-pointers.
        unsafe {
            *g = c.sdk_gain.0;
            *o = c.sdk_gain.1;
        }
        OK
    })
}
extern "C" fn api_version() -> c_int {
    20250630
}

fn has_option(c: &Cam, id: u16) -> bool {
    match c.family {
        Family::Ccd | Family::SonySci => false,
        Family::Horizon => matches!(id, 1..=6 | 12 | 13 | 14 | 200 | 201),
        Family::Acis => matches!(id, 1..=6 | 13 | 14 | 15 | 200 | 201),
        Family::Apx => matches!(id, 1..=6 | 14 | 200 | 201),
        Family::Te => matches!(id, 5 | 6 | 20 | 88 | 200 | 201),
    }
}
extern "C" fn has_camera_specific_option(handle: ArtemisHandle, id: u16) -> bool {
    camera(handle, |c| has_option(c, id)).unwrap_or(false)
}
fn range_bytes((min, max, cur): (u16, u16, u16)) -> Vec<u8> {
    [min, max, cur]
        .iter()
        .flat_map(|v| v.to_le_bytes())
        .collect()
}
extern "C" fn option_get(
    handle: ArtemisHandle,
    id: u16,
    data: *mut u8,
    length: c_int,
    actual: *mut c_int,
) -> c_int {
    with_camera(handle, |c| {
        if !has_option(c, id) {
            return INVALID_PARAMETER;
        }
        let bytes: Vec<u8> = match (c.family, id) {
            (Family::Te, 20) => range_bytes((0, 2, c.te_readout)),
            (_, 1) => c.preset_mode.to_le_bytes().to_vec(),
            (_, 2..=4) => {
                let (g, o) = c.presets[usize::from(id - 2)];
                let mut b = vec![1];
                b.extend(g.to_le_bytes());
                b.extend(o.to_le_bytes());
                b
            }
            (_, 5) => range_bytes(c.custom_gain),
            (_, 6) => range_bytes(c.custom_offset),
            (_, 88) => range_bytes(c.te_adc1_offset),
            (_, 12) | (_, 13) => vec![c.pad_data as u8],
            (_, 14) => c.exposure_speed.to_le_bytes().to_vec(),
            (_, 15) => 0u16.to_le_bytes().to_vec(),
            _ => vec![0; 6],
        };
        // "ARTEMIS_INVALID_PARAM ... or the dataLength provided is too small"
        // (Apx60 and TE guides).
        if (length as usize) < bytes.len() {
            return INVALID_PARAMETER;
        }
        // SAFETY: the driver passes `length` writable bytes.
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), data, bytes.len());
            *actual = bytes.len() as c_int;
        }
        OK
    })
}
extern "C" fn option_set(handle: ArtemisHandle, id: u16, data: *mut u8, length: c_int) -> c_int {
    with_camera(handle, |c| {
        if !has_option(c, id) {
            return INVALID_PARAMETER;
        }
        // SAFETY: the driver passes `length` readable bytes.
        let bytes = unsafe { std::slice::from_raw_parts(data, length as usize) };
        let u16_value = || (bytes.len() >= 2).then(|| u16::from_le_bytes([bytes[0], bytes[1]]));
        // Out-of-range custom values are clamped (Apx60 and TE guides).
        let clamp = |(min, max, _): (u16, u16, u16), v: u16| (min, max, v.clamp(min, max));
        match (c.family, id) {
            (Family::Te, 20) => match u16_value() {
                Some(v) if v <= 2 => c.te_readout = v,
                _ => return INVALID_PARAMETER,
            },
            (_, 1) => match u16_value() {
                Some(v) if v <= 3 => c.preset_mode = v,
                _ => return INVALID_PARAMETER,
            },
            (_, 5) => c.custom_gain = clamp(c.custom_gain, u16_value().unwrap_or(0)),
            (_, 6) => c.custom_offset = clamp(c.custom_offset, u16_value().unwrap_or(0)),
            (_, 88) => c.te_adc1_offset = clamp(c.te_adc1_offset, u16_value().unwrap_or(0)),
            (_, 13) => c.pad_data = bytes.first().is_some_and(|b| *b != 0),
            (_, 14) => match u16_value() {
                Some(v) if v <= 2 => c.exposure_speed = v,
                _ => return INVALID_PARAMETER,
            },
            _ => {}
        }
        OK
    })
}

// ---- external filter wheels ------------------------------------------------

extern "C" fn efw_is_present(index: c_int) -> c_int {
    world(|w| usize::try_from(index).is_ok_and(|i| i < w.wheels.len())) as c_int
}
extern "C" fn efw_get_device_details(index: c_int, t: *mut c_int, serial: *mut c_char) -> c_int {
    match world(|w| w.wheels.get(index as usize).cloned()) {
        Some(wh) => {
            // SAFETY: valid out-pointer.
            unsafe { *t = wh.efw_type };
            write_text(serial, wh.serial);
            OK
        }
        None => INVALID_PARAMETER,
    }
}
extern "C" fn efw_connect(index: c_int) -> ArtemisHandle {
    world(|w| match w.wheels.get_mut(index as usize) {
        Some(wh) => {
            wh.open = true;
            (0x1000 + index as usize) as ArtemisHandle
        }
        None => std::ptr::null_mut(),
    })
}
extern "C" fn efw_is_connected(handle: ArtemisHandle) -> bool {
    wheel(handle, |_| ()).is_some()
}
extern "C" fn efw_disconnect(handle: ArtemisHandle) -> c_int {
    wheel(handle, |wh| wh.open = false).map_or(INVALID_PARAMETER, |_| OK)
}
extern "C" fn efw_nmr_position(handle: ArtemisHandle, n: *mut c_int) -> c_int {
    wheel(handle, |wh| {
        // SAFETY: valid out-pointer.
        unsafe { *n = wh.positions };
        OK
    })
    .unwrap_or(INVALID_PARAMETER)
}
/// Positions are 0-based (INDI sends targetFilter - 1, reads iPosition + 1).
extern "C" fn efw_set_position(handle: ArtemisHandle, position: c_int) -> c_int {
    wheel(handle, |wh| {
        if !(0..wh.positions).contains(&position) {
            return INVALID_PARAMETER;
        }
        wh.position = position;
        OK
    })
    .unwrap_or(INVALID_PARAMETER)
}
extern "C" fn efw_get_position(handle: ArtemisHandle, p: *mut c_int, moving: *mut bool) -> c_int {
    wheel(handle, |wh| {
        // SAFETY: valid out-pointers.
        unsafe {
            *p = wh.position;
            *moving = false;
        }
        OK
    })
    .unwrap_or(INVALID_PARAMETER)
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

fn sdk() -> AtikSdk {
    AtikSdk {
        device_count,
        device_present,
        device_name,
        device_serial,
        device_is_camera,
        connect,
        disconnect,
        is_connected,
        properties,
        colour_properties,
        bin,
        get_max_bin,
        subframe,
        start_exposure,
        abort_exposure,
        image_ready,
        exposure_time_remaining,
        get_image_data,
        image_buffer,
        set_cooling,
        cooling_info,
        cooler_warm_up,
        temperature_sensor_info,
        set_gain,
        get_gain,
        api_version,
        set_dark_mode,
        eight_bit_mode,
        refresh_devices_count: Some(refresh_devices_count),
        efw_is_present: Some(efw_is_present),
        efw_get_device_details: Some(efw_get_device_details),
        efw_connect: Some(efw_connect),
        efw_is_connected: Some(efw_is_connected),
        efw_disconnect: Some(efw_disconnect),
        efw_nmr_position: Some(efw_nmr_position),
        efw_set_position: Some(efw_set_position),
        efw_get_position: Some(efw_get_position),
        camera_state: Some(camera_state),
        image_failed: Some(image_failed),
        has_camera_specific_option: Some(has_camera_specific_option),
        camera_specific_option_get_data: Some(option_get),
        camera_specific_option_set_data: Some(option_set),
        _library: this_process(),
    }
}

fn install(devices: Vec<Cam>) -> AtikSdk {
    world(|w| {
        *w = World {
            devices,
            ..World::default()
        }
    });
    sdk()
}

fn opened(sdk: &AtikSdk, serial: Option<&str>) -> AtikCamera {
    let mut camera = AtikCamera::new(0);
    camera.serial_number = serial.map(str::to_string);
    camera.open(sdk).expect("connect");
    camera
}

fn exposure(frame_type: FrameType) -> ExposureParams {
    ExposureParams {
        duration_secs: 2.0,
        gain: None,
        offset: None,
        bin_x: 1,
        bin_y: 1,
        subframe: None,
        readout_mode: None,
        frame_type,
    }
}

fn expose(sdk: &AtikSdk, camera: &mut AtikCamera, params: ExposureParams) -> ImageData {
    assert!(camera.ready_to_expose(sdk).expect("ready"));
    camera.begin_exposure(sdk, &params).expect("start");
    assert!(camera.exposure_done(sdk).expect("done"));
    camera.take_frame(sdk).expect("download")
}

fn last_exposure() -> Exposure {
    world(|w| w.devices[0].exposed_with.expect("an exposure was started"))
}

fn device(index: usize) -> Cam {
    world(|w| w.devices[index].clone())
}

#[test]
fn the_device_list_is_bounded_by_the_device_count_not_the_refresh_counter() {
    let mut wheel_device = cam(Family::Ccd);
    wheel_device.is_camera = false;
    let mut second = cam(Family::Acis);
    second.serial = Some("S3");
    let sdk = install(vec![cam(Family::Ccd), wheel_device, second]);

    let found = list_cameras(&sdk);

    let indices: Vec<_> = found.iter().map(|d| d.device_index).collect();
    assert_eq!(indices, vec![0, 2]);
    assert_eq!(found[1].serial_number.as_deref(), Some("S3"));
    assert!(world(|w| w.highest_index_asked) < 3);
}

#[test]
fn a_camera_is_found_by_its_serial_after_the_indices_move() {
    let mut first = cam(Family::Ccd);
    first.serial = Some("S1");
    let mut second = cam(Family::Ccd);
    second.serial = Some("S2");
    let sdk = install(vec![first, second]);
    world(|w| w.devices[0].plugged = false);

    let camera = opened(&sdk, Some("S2"));

    assert_eq!(camera.device_index, 0);
    assert!(device(1).open);
}

#[test]
fn a_shutterless_camera_takes_a_dark_without_dark_mode() {
    let sdk = install(vec![cam(Family::Acis)]);
    let mut camera = opened(&sdk, Some("S1"));

    expose(&sdk, &mut camera, exposure(FrameType::Dark));

    assert_eq!(device(0).dark_mode_calls, 0);
    assert!(device(0).exposing);
}

#[test]
fn a_shuttered_camera_keeps_its_shutter_closed_for_darks_and_bias_only() {
    let sdk = install(vec![cam(Family::Ccd)]);
    let mut camera = opened(&sdk, Some("S1"));

    for (frame_type, dark) in [
        (FrameType::Dark, true),
        (FrameType::Bias, true),
        (FrameType::DarkFlat, true),
        (FrameType::Light, false),
        (FrameType::Flat, false),
    ] {
        expose(&sdk, &mut camera, exposure(frame_type));
        assert_eq!(last_exposure().dark, dark, "{frame_type:?}");
    }
}

#[test]
fn eight_bit_mode_is_left_only_on_cameras_that_have_it() {
    let sdk = install(vec![cam(Family::Horizon)]);
    let _camera = opened(&sdk, Some("S1"));
    assert_eq!(device(0).eight_bit_calls, 0);

    let mut ccd = cam(Family::Ccd);
    ccd.eight_bit = true;
    let sdk = install(vec![ccd]);
    let mut camera = opened(&sdk, Some("S1"));
    assert!(!device(0).eight_bit);
    let image = expose(&sdk, &mut camera, exposure(FrameType::Light));
    assert_eq!(image.data.len(), 1000 * 800);
}

#[test]
fn a_binned_subframe_is_sent_in_sensor_pixels_and_comes_back_binned() {
    let sdk = install(vec![cam(Family::Ccd)]);
    let mut camera = opened(&sdk, Some("S1"));

    let mut params = exposure(FrameType::Light);
    params.bin_x = 2;
    params.bin_y = 2;
    params.subframe = Some(SubFrame {
        start_x: 10,
        start_y: 20,
        width: 100,
        height: 50,
    });
    let image = expose(&sdk, &mut camera, params.clone());
    assert_eq!(last_exposure().subframe, (20, 40, 200, 100));
    assert_eq!(last_exposure().bin, (2, 2));
    assert_eq!((image.width, image.height), (100, 50));

    params.subframe = None;
    let image = expose(&sdk, &mut camera, params);
    assert_eq!(last_exposure().subframe, (0, 0, 1000, 800));
    assert_eq!((image.width, image.height), (500, 400));
}

#[test]
fn a_subframe_outside_the_sensor_is_refused_before_the_sdk_sees_it() {
    let sdk = install(vec![cam(Family::Ccd)]);
    let mut camera = opened(&sdk, Some("S1"));
    let mut params = exposure(FrameType::Light);
    params.bin_x = 2;
    params.bin_y = 2;
    params.subframe = Some(SubFrame {
        start_x: 400,
        start_y: 0,
        width: 101,
        height: 10,
    });
    assert!(matches!(
        camera.begin_exposure(&sdk, &params),
        Err(DriverError::InvalidParameter(_))
    ));
}

#[test]
fn a_horizon_in_a_preset_reports_the_preset_and_a_set_gain_switches_to_custom() {
    let mut horizon = cam(Family::Horizon);
    horizon.preset_mode = 2;
    let sdk = install(vec![horizon]);
    let mut camera = opened(&sdk, Some("S1"));

    assert_eq!((camera.core.gain, camera.core.offset), (20, 30));
    assert_eq!(camera.facts.gain.gain_range(), Some((0, 60)));
    assert_eq!(camera.facts.gain.offset_range(), Some((0, 511)));

    let mut params = exposure(FrameType::Light);
    params.gain = Some(25);
    let image = expose(&sdk, &mut camera, params);
    assert_eq!(device(0).preset_mode, 0);
    assert_eq!(last_exposure().gain, Some(25));
    assert_eq!(last_exposure().offset, Some(100));
    assert_eq!((image.metadata.gain, image.metadata.offset), (25, 100));

    let mut params = exposure(FrameType::Light);
    params.gain = Some(61);
    assert!(camera.begin_exposure(&sdk, &params).is_err());
}

#[test]
fn acis_and_apx_ranges_come_from_the_camera() {
    let sdk = install(vec![cam(Family::Acis)]);
    let camera = opened(&sdk, Some("S1"));
    assert_eq!(camera.facts.gain.gain_range(), Some((0, 24)));
    assert_eq!(camera.facts.gain.offset_range(), Some((0, 4095)));

    let sdk = install(vec![cam(Family::Apx)]);
    let mut camera = opened(&sdk, Some("S1"));
    let mut params = exposure(FrameType::Light);
    params.offset = Some(42);
    expose(&sdk, &mut camera, params);
    assert_eq!(last_exposure().offset, Some(42));
}

#[test]
fn a_ccd_has_no_gain_and_a_sony_scientific_body_takes_it_through_set_gain() {
    let sdk = install(vec![cam(Family::Ccd)]);
    let camera = opened(&sdk, Some("S1"));
    assert!(!camera.core.capabilities.can_set_gain);

    let sdk = install(vec![cam(Family::SonySci)]);
    let mut camera = opened(&sdk, Some("S1"));
    assert_eq!((camera.core.gain, camera.core.offset), (3, 7));
    let mut params = exposure(FrameType::Light);
    params.gain = Some(9);
    expose(&sdk, &mut camera, params);
    assert_eq!(last_exposure().gain, Some(9));
    assert_eq!(last_exposure().offset, Some(7));
}

#[test]
fn pad_data_sets_the_full_scale_of_the_12_bit_cameras() {
    for (pad, max_adu) in [(true, 0xFFF0), (false, 0x0FFF)] {
        let mut horizon = cam(Family::Horizon);
        horizon.pad_data = pad;
        let sdk = install(vec![horizon]);
        let mut camera = opened(&sdk, Some("S1"));
        assert_eq!(camera.core.sensor_info.bit_depth, 12);
        assert_eq!(camera.core.sensor_info.max_adu, max_adu);
        let image = expose(&sdk, &mut camera, exposure(FrameType::Light));
        assert_eq!(u32::from(image.data[0]), max_adu);
    }
    let sdk = install(vec![cam(Family::Apx)]);
    let camera = opened(&sdk, Some("S1"));
    assert_eq!(camera.core.sensor_info.max_adu, 0xFFFF);
}

#[test]
fn the_bayer_cell_follows_the_sdk_offset_and_the_subframe_origin() {
    let mut colour = cam(Family::Acis);
    colour.colour_type = ARTEMIS_COLOUR_RGGB;
    colour.colour_offset = (1, 0);
    let sdk = install(vec![colour]);
    let mut camera = opened(&sdk, Some("S1"));
    assert_eq!(
        camera.core.sensor_info.bayer_pattern,
        Some(BayerPattern::Grbg)
    );

    let image = expose(&sdk, &mut camera, exposure(FrameType::Light));
    assert_eq!(image.bayer_pattern, Some(BayerPattern::Grbg));

    let mut params = exposure(FrameType::Light);
    params.subframe = Some(SubFrame {
        start_x: 1,
        start_y: 1,
        width: 100,
        height: 100,
    });
    let image = expose(&sdk, &mut camera, params);
    assert_eq!(image.bayer_pattern, Some(BayerPattern::Gbrg));
}

#[test]
fn a_camera_left_in_fast_mode_still_delivers_single_frames() {
    let mut horizon = cam(Family::Horizon);
    horizon.exposure_speed = 2;
    let sdk = install(vec![horizon]);
    let mut camera = opened(&sdk, Some("S1"));
    assert_ne!(device(0).exposure_speed, 2);
    expose(&sdk, &mut camera, exposure(FrameType::Light));
}

#[test]
fn the_cooler_state_comes_from_the_camera_and_disconnect_warms_it_up() {
    let mut cooled = cam(Family::Ccd);
    cooled.cooling_flags |= 64 | 128;
    cooled.setpoint = -1500;
    cooled.cooling_level = (128, 0, 255);
    let sdk = install(vec![cooled]);
    let mut camera = opened(&sdk, Some("S1"));
    assert!(camera.core.capabilities.can_cool);
    assert!(camera.core.cooler().enabled);
    assert_eq!(camera.core.cooler().target_c, -15.0);

    let status = camera.status(&sdk).expect("status");
    assert!(status.cooler_on);
    assert_eq!(status.target_temp, Some(-15.0));
    assert_eq!(status.sensor_temp, Some(21.5));
    let power = status.cooler_power.expect("power");
    assert!((power - 128.0 / 255.0 * 100.0).abs() < 1e-9);

    world(|w| w.devices[0].cooling_flags |= 32);
    assert!(!camera.status(&sdk).expect("status").cooler_on);
    world(|w| w.devices[0].cooling_flags &= !32);

    camera.close(&sdk).expect("disconnect");
    assert_eq!(device(0).warm_up_calls, 1);
    assert!(!device(0).open);
}

#[test]
fn an_unplugged_camera_reads_as_disconnected() {
    let sdk = install(vec![cam(Family::Ccd)]);
    let camera = opened(&sdk, Some("S1"));
    world(|w| w.devices[0].plugged = false);
    assert!(matches!(
        camera.status(&sdk),
        Err(DriverError::Disconnected)
    ));
    assert!(matches!(
        camera.ready_to_expose(&sdk),
        Err(DriverError::Disconnected)
    ));
}

#[test]
fn filter_wheels_have_their_own_index_list_and_zero_based_positions() {
    let sdk = install(Vec::new());
    world(|w| {
        w.wheels = vec![
            Wheel {
                serial: "W1",
                efw_type: 1,
                positions: 5,
                position: 0,
                open: false,
            },
            Wheel {
                serial: "W2",
                efw_type: 2,
                positions: 7,
                position: 3,
                open: false,
            },
        ]
    });
    let wheels = list_filter_wheels(&sdk).expect("list");
    assert_eq!(wheels.len(), 2);
    assert_eq!(wheels[1].serial_number.as_deref(), Some("W2"));

    let mut efw = AtikFilterWheel::new(1);
    efw.serial_number = Some("W2".into());
    efw.open(&sdk).expect("connect");
    assert_eq!(efw.filter_count, 7);
    assert_eq!(efw.read_position(&sdk).expect("position"), (3, false));
}
