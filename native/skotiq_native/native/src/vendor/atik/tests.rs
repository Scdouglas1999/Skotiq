//! The driver against an in-process stand-in for the Atik SDK.
//!
//! The stand-in answers the way the shipped library does where the driver
//! once assumed otherwise; each such answer names where in libatikcameras
//! (SDK 2024.11.26, the same build INDI ships as libatik 2.2.22) it was read.

use super::*;
use skotiq_device::FrameType;
use std::collections::VecDeque;
use std::sync::MutexGuard;

#[derive(Clone)]
struct FakeDevice {
    name: &'static str,
    serial: Option<&'static str>,
}

struct Fake {
    devices: Vec<FakeDevice>,
    /// What ArtemisRefreshDevicesCount answers: a count of list changes
    /// (ArtemisDLL::RefreshDeviceCount sums the device managers'
    /// DeviceUpdateCount, which LibUSBDeviceManager::Cycle increments).
    refresh_counter: c_int,
    present: bool,
    width: c_int,
    height: c_int,
    camera_flags: c_int,
    colour: c_int,
    colour_offset: (c_int, c_int),
    cooling_flags: c_int,
    setpoint: c_int,
    /// `Some` only for the cameras whose gain control implements
    /// ArtemisSetGain; GainControlEmpty answers 5 to both calls.
    sdk_gain: Option<(c_int, c_int)>,
    options: HashMap<u16, Vec<u8>>,
    states: VecDeque<c_int>,
    image_ready: bool,
    image_failed: bool,
    efws: Vec<(c_int, Option<&'static str>)>,
    efw_position: c_int,

    opened_index: Option<c_int>,
    bin: (c_int, c_int),
    subframe: (c_int, c_int, c_int, c_int),
    dark_mode_calls: Vec<bool>,
    eight_bit_calls: Vec<bool>,
    started: Vec<f32>,
    aborts: u32,
    warm_ups: u32,
    buffer: Vec<u8>,
}

impl Default for Fake {
    fn default() -> Self {
        Self {
            devices: vec![FakeDevice {
                name: "Atik 414EX",
                serial: Some("ATIK-1"),
            }],
            refresh_counter: 1,
            present: true,
            width: 32,
            height: 24,
            camera_flags: 0,
            colour: ARTEMIS_COLOUR_NONE,
            colour_offset: (0, 0),
            cooling_flags: 0,
            setpoint: 0,
            sdk_gain: None,
            options: HashMap::new(),
            states: VecDeque::new(),
            image_ready: true,
            image_failed: false,
            efws: Vec::new(),
            efw_position: 0,
            opened_index: None,
            bin: (1, 1),
            subframe: (0, 0, 32, 24),
            dark_mode_calls: Vec::new(),
            eight_bit_calls: Vec::new(),
            started: Vec::new(),
            aborts: 0,
            warm_ups: 0,
            buffer: Vec::new(),
        }
    }
}

static FAKE: Mutex<Option<Fake>> = Mutex::new(None);
static ONE_AT_A_TIME: Mutex<()> = Mutex::new(());

struct Installed(#[allow(dead_code)] MutexGuard<'static, ()>);

fn install(fake: Fake) -> Installed {
    let turn = ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner());
    *FAKE.lock().unwrap_or_else(|e| e.into_inner()) = Some(fake);
    Installed(turn)
}

fn with<R>(f: impl FnOnce(&mut Fake) -> R) -> R {
    f(FAKE
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_mut()
        .expect("a fake SDK is installed"))
}

const CAMERA: ArtemisHandle = 0x1000 as ArtemisHandle;
const WHEEL: ArtemisHandle = 0x2000 as ArtemisHandle;

fn write_text(buffer: *mut c_char, text: &str) {
    for (i, byte) in text.bytes().chain(std::iter::once(0)).enumerate() {
        // SAFETY: the driver passes 100-byte buffers and every text here is shorter.
        unsafe { *buffer.add(i) = byte as c_char };
    }
}

fn put<T>(out: *mut T, value: T) {
    if !out.is_null() {
        // SAFETY: the driver passes valid out-pointers or null.
        unsafe { *out = value };
    }
}

extern "C" fn device_count() -> c_int {
    with(|f| f.devices.len() as c_int)
}
extern "C" fn refresh_devices_count() -> c_int {
    with(|f| f.refresh_counter)
}
extern "C" fn device_present(index: c_int) -> c_int {
    with(|f| (index >= 0 && (index as usize) < f.devices.len()) as c_int)
}
extern "C" fn device_is_camera(index: c_int) -> c_int {
    device_present(index)
}
extern "C" fn device_name(index: c_int, name: *mut c_char) -> c_int {
    match with(|f| f.devices.get(index as usize).cloned()) {
        Some(device) => {
            write_text(name, device.name);
            1
        }
        None => 0,
    }
}
extern "C" fn device_serial(index: c_int, serial: *mut c_char) -> c_int {
    match with(|f| f.devices.get(index as usize).and_then(|d| d.serial)) {
        Some(text) => {
            write_text(serial, text);
            1
        }
        None => 0,
    }
}
extern "C" fn connect(index: c_int) -> ArtemisHandle {
    with(|f| {
        if (index as usize) < f.devices.len() {
            f.opened_index = Some(index);
            CAMERA
        } else {
            std::ptr::null_mut()
        }
    })
}
extern "C" fn disconnect(_handle: ArtemisHandle) -> c_int {
    1
}
extern "C" fn is_connected(_handle: ArtemisHandle) -> c_int {
    with(|f| f.present as c_int)
}
extern "C" fn properties(_handle: ArtemisHandle, props: *mut ArtemisProperties) -> c_int {
    with(|f| {
        // SAFETY: all zeroes is a valid ArtemisProperties.
        let mut p: ArtemisProperties = unsafe { std::mem::zeroed() };
        p.protocol = 0x0102;
        p.pixels_x = f.width;
        p.pixels_y = f.height;
        p.pixel_microns_x = 3.76;
        p.pixel_microns_y = 3.76;
        p.camera_flags = f.camera_flags;
        for (slot, byte) in p.description.iter_mut().zip(b"Atik Test".iter()) {
            *slot = *byte as c_char;
        }
        put(props, p);
    });
    0
}
extern "C" fn colour_properties(
    _handle: ArtemisHandle,
    colour: *mut c_int,
    offset_x: *mut c_int,
    offset_y: *mut c_int,
    preview_x: *mut c_int,
    preview_y: *mut c_int,
) -> c_int {
    with(|f| {
        put(colour, f.colour);
        put(offset_x, f.colour_offset.0);
        put(offset_y, f.colour_offset.1);
        put(preview_x, 0);
        put(preview_y, 0);
    });
    0
}
extern "C" fn bin(_handle: ArtemisHandle, x: c_int, y: c_int) -> c_int {
    with(|f| f.bin = (x, y));
    0
}
extern "C" fn get_max_bin(_handle: ArtemisHandle, x: *mut c_int, y: *mut c_int) -> c_int {
    put(x, 4);
    put(y, 4);
    0
}
/// ExposureSettings::SetSubFrame: unbinned sensor pixels, 1 when the region
/// leaves the sensor.
extern "C" fn subframe(_handle: ArtemisHandle, x: c_int, y: c_int, w: c_int, h: c_int) -> c_int {
    with(|f| {
        if x < 0 || y < 0 || w <= 0 || h <= 0 || x + w > f.width || y + h > f.height {
            return 1;
        }
        f.subframe = (x, y, w, h);
        0
    })
}
extern "C" fn start_exposure(_handle: ArtemisHandle, seconds: c_float) -> c_int {
    with(|f| f.started.push(seconds));
    0
}
extern "C" fn abort_exposure(_handle: ArtemisHandle) -> c_int {
    with(|f| f.aborts += 1);
    0
}
extern "C" fn image_ready(_handle: ArtemisHandle) -> c_int {
    with(|f| f.image_ready as c_int)
}
extern "C" fn image_failed(_handle: ArtemisHandle) -> c_int {
    with(|f| f.image_failed as c_int)
}
extern "C" fn camera_state(_handle: ArtemisHandle) -> c_int {
    with(|f| f.states.pop_front().unwrap_or(CAMERA_IDLE))
}
extern "C" fn exposure_time_remaining(_handle: ArtemisHandle) -> c_float {
    0.0
}
extern "C" fn get_image_data(
    _handle: ArtemisHandle,
    x: *mut c_int,
    y: *mut c_int,
    w: *mut c_int,
    h: *mut c_int,
    bin_x: *mut c_int,
    bin_y: *mut c_int,
) -> c_int {
    with(|f| {
        let (sx, sy, sw, sh) = f.subframe;
        put(x, sx);
        put(y, sy);
        put(w, sw / f.bin.0);
        put(h, sh / f.bin.1);
        put(bin_x, f.bin.0);
        put(bin_y, f.bin.1);
    });
    0
}
extern "C" fn image_buffer(_handle: ArtemisHandle) -> *mut c_void {
    with(|f| {
        let (_, _, sw, sh) = f.subframe;
        let pixels = (sw / f.bin.0 * (sh / f.bin.1)) as usize;
        f.buffer = (0..pixels)
            .flat_map(|i| (1000 + i as u16).to_le_bytes())
            .collect();
        f.buffer.as_mut_ptr() as *mut c_void
    })
}
extern "C" fn set_cooling(_handle: ArtemisHandle, setpoint: c_int) -> c_int {
    with(|f| {
        f.setpoint = setpoint;
        f.cooling_flags |= ARTEMIS_COOLING_INFO_COOLINGON;
        f.cooling_flags &= !ARTEMIS_COOLING_INFO_WARMINGUP;
    });
    0
}
extern "C" fn cooling_info(
    _handle: ArtemisHandle,
    flags: *mut c_int,
    level: *mut c_int,
    min_level: *mut c_int,
    max_level: *mut c_int,
    setpoint: *mut c_int,
) -> c_int {
    with(|f| {
        put(flags, f.cooling_flags);
        put(level, 51);
        put(min_level, 0);
        put(max_level, 255);
        put(setpoint, f.setpoint);
    });
    0
}
extern "C" fn cooler_warm_up(_handle: ArtemisHandle) -> c_int {
    with(|f| {
        f.warm_ups += 1;
        f.cooling_flags |= ARTEMIS_COOLING_INFO_WARMINGUP;
    });
    0
}
extern "C" fn temperature_sensor_info(
    _handle: ArtemisHandle,
    sensor: c_int,
    temp: *mut c_int,
) -> c_int {
    put(temp, if sensor == 0 { 1 } else { -950 });
    0
}
extern "C" fn set_gain(
    _handle: ArtemisHandle,
    _preview: bool,
    gain: c_int,
    offset: c_int,
) -> c_int {
    with(|f| match &mut f.sdk_gain {
        Some(values) => {
            *values = (gain, offset);
            0
        }
        None => ArtemisError::InvalidFunction as c_int,
    })
}
extern "C" fn get_gain(
    _handle: ArtemisHandle,
    _preview: bool,
    gain: *mut c_int,
    offset: *mut c_int,
) -> c_int {
    with(|f| match f.sdk_gain {
        Some((g, o)) => {
            put(gain, g);
            put(offset, o);
            0
        }
        None => ArtemisError::InvalidFunction as c_int,
    })
}
extern "C" fn api_version() -> c_int {
    20241126
}
/// ExposureSettings::SetInDarkMode answers 5 when HasShutter() is false,
/// whatever it is asked.
extern "C" fn set_dark_mode(_handle: ArtemisHandle, enable: bool) -> c_int {
    with(|f| {
        if f.camera_flags & ARTEMIS_CAMERA_HAS_SHUTTER == 0 {
            return ArtemisError::InvalidFunction as c_int;
        }
        f.dark_mode_calls.push(enable);
        0
    })
}
/// ExposureSettings::SetIn8BitMode answers 1 when Has8BitMode() is false.
extern "C" fn eight_bit_mode(_handle: ArtemisHandle, eight_bit: bool) -> c_int {
    with(|f| {
        if f.camera_flags & ARTEMIS_CAMERA_HAS_EIGHT_BIT_MODE == 0 {
            return ArtemisError::InvalidParameter as c_int;
        }
        f.eight_bit_calls.push(eight_bit);
        0
    })
}
extern "C" fn has_option(_handle: ArtemisHandle, id: u16) -> bool {
    with(|f| f.options.contains_key(&id))
}
extern "C" fn option_get(
    _handle: ArtemisHandle,
    id: u16,
    data: *mut u8,
    length: c_int,
    actual: *mut c_int,
) -> c_int {
    with(|f| match f.options.get(&id) {
        Some(value) if value.len() <= length as usize => {
            for (i, byte) in value.iter().enumerate() {
                // SAFETY: `length` bytes are writable and value.len() <= length.
                unsafe { *data.add(i) = *byte };
            }
            put(actual, value.len() as c_int);
            0
        }
        _ => ArtemisError::InvalidParameter as c_int,
    })
}
/// Custom gain and offset are clamped into their range, as the Apx60 guide says.
extern "C" fn option_set(_handle: ArtemisHandle, id: u16, data: *mut u8, length: c_int) -> c_int {
    // SAFETY: the driver passes `length` readable bytes.
    let bytes = unsafe { std::slice::from_raw_parts(data, length as usize) }.to_vec();
    with(|f| {
        let Some(value) = f.options.get_mut(&id) else {
            return ArtemisError::InvalidParameter as c_int;
        };
        if id == ID_GO_CUSTOM_GAIN || id == ID_GO_CUSTOM_OFFSET {
            let min = u16::from_le_bytes([value[0], value[1]]);
            let max = u16::from_le_bytes([value[2], value[3]]);
            let wanted = u16::from_le_bytes([bytes[0], bytes[1]]).clamp(min, max);
            value[4..6].copy_from_slice(&wanted.to_le_bytes());
        } else {
            *value = bytes;
        }
        0
    })
}
extern "C" fn efw_is_present(index: c_int) -> c_int {
    with(|f| (index >= 0 && (index as usize) < f.efws.len()) as c_int)
}
extern "C" fn efw_get_device_details(
    index: c_int,
    efw_type: *mut c_int,
    serial: *mut c_char,
) -> c_int {
    match with(|f| f.efws.get(index as usize).copied()) {
        Some((kind, text)) => {
            put(efw_type, kind);
            write_text(serial, text.unwrap_or(""));
            0
        }
        None => 1,
    }
}
extern "C" fn efw_connect(index: c_int) -> ArtemisHandle {
    if efw_is_present(index) != 0 {
        WHEEL
    } else {
        std::ptr::null_mut()
    }
}
extern "C" fn efw_is_connected(_handle: ArtemisHandle) -> bool {
    true
}
extern "C" fn efw_disconnect(_handle: ArtemisHandle) -> c_int {
    0
}
extern "C" fn efw_nmr_position(_handle: ArtemisHandle, positions: *mut c_int) -> c_int {
    put(positions, 7);
    0
}
extern "C" fn efw_set_position(_handle: ArtemisHandle, position: c_int) -> c_int {
    with(|f| f.efw_position = position);
    0
}
extern "C" fn efw_get_position(
    _handle: ArtemisHandle,
    position: *mut c_int,
    moving: *mut bool,
) -> c_int {
    put(position, with(|f| f.efw_position));
    put(moving, false);
    0
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

fn fake_sdk() -> AtikSdk {
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
        has_camera_specific_option: Some(has_option),
        camera_specific_option_get_data: Some(option_get),
        camera_specific_option_set_data: Some(option_set),
        _library: this_process(),
    }
}

fn camera(serial: Option<&str>, index: c_int) -> AtikCamera {
    AtikCamera {
        serial_number: serial.map(str::to_string),
        device_index: index,
        ..AtikCamera::new(index)
    }
}

fn connected(sdk: &AtikSdk) -> AtikCamera {
    let mut camera = camera(Some("ATIK-1"), 0);
    camera.open(sdk).expect("the camera connects");
    camera
}

fn exposure(frame_type: FrameType, bin: i32, subframe: Option<SubFrame>) -> ExposureParams {
    ExposureParams {
        duration_secs: 2.0,
        gain: None,
        offset: None,
        bin_x: bin,
        bin_y: bin,
        subframe,
        readout_mode: None,
        frame_type,
    }
}

fn custom_range(min: u16, max: u16, current: u16) -> Vec<u8> {
    [min, max, current]
        .iter()
        .flat_map(|v| v.to_le_bytes())
        .collect()
}

fn preset(gain: u16, offset: u16) -> Vec<u8> {
    let mut data = vec![1];
    data.extend(gain.to_le_bytes());
    data.extend(offset.to_le_bytes());
    data
}

/// A Horizon-like camera: custom gain 0..60 and offset 0..511, factory presets.
fn cmos_options(preset_mode: u16) -> HashMap<u16, Vec<u8>> {
    HashMap::from([
        (ID_GO_PRESET_MODE, preset_mode.to_le_bytes().to_vec()),
        (ID_GO_PRESET_LOW, preset(0, 30)),
        (ID_GO_PRESET_LOW + 1, preset(20, 35)),
        (ID_GO_PRESET_LOW + 2, preset(40, 40)),
        (ID_GO_CUSTOM_GAIN, custom_range(0, 60, 30)),
        (ID_GO_CUSTOM_OFFSET, custom_range(0, 511, 10)),
    ])
}

#[test]
fn every_camera_is_listed_whatever_the_refresh_counter_says() {
    let _fake = install(Fake {
        devices: vec![
            FakeDevice {
                name: "Atik Horizon",
                serial: Some("A"),
            },
            FakeDevice {
                name: "Atik 383L+",
                serial: Some("B"),
            },
        ],
        refresh_counter: 1,
        ..Fake::default()
    });
    let sdk = fake_sdk();
    let names: Vec<_> = list_cameras(&sdk).into_iter().map(|d| d.name).collect();
    assert_eq!(names, ["Atik Horizon", "Atik 383L+"]);

    with(|f| f.refresh_counter = 0);
    assert_eq!(
        list_cameras(&sdk).len(),
        2,
        "no change since the last look still lists both"
    );
}

#[test]
fn a_camera_is_opened_by_its_serial_after_the_list_reorders() {
    let _fake = install(Fake {
        devices: vec![
            FakeDevice {
                name: "Atik 383L+",
                serial: Some("B"),
            },
            FakeDevice {
                name: "Atik Horizon",
                serial: Some("A"),
            },
        ],
        ..Fake::default()
    });
    let sdk = fake_sdk();
    let mut camera = camera(Some("A"), 0);
    camera.open(&sdk).expect("connects");
    assert_eq!(with(|f| f.opened_index), Some(1));
    assert_eq!(camera.serial_number(), Some("A".to_string()));
}

#[test]
fn a_camera_without_a_usb_serial_connects_at_its_index() {
    let _fake = install(Fake {
        devices: vec![FakeDevice {
            name: "Atik 16HR",
            serial: None,
        }],
        ..Fake::default()
    });
    let sdk = fake_sdk();
    let mut camera = camera(None, 0);
    camera
        .open(&sdk)
        .expect("a camera with no serial still connects");
    assert_eq!(with(|f| f.opened_index), Some(0));
}

#[test]
fn a_camera_without_an_eight_bit_mode_connects_and_one_with_it_is_set_to_16_bit() {
    let _fake = install(Fake::default());
    let sdk = fake_sdk();
    let camera = connected(&sdk);
    assert_eq!(camera.get_sensor_info().bit_depth, 16);
    assert!(with(|f| f.eight_bit_calls.is_empty()));

    with(|f| f.camera_flags = ARTEMIS_CAMERA_HAS_EIGHT_BIT_MODE);
    connected(&sdk);
    assert_eq!(with(|f| f.eight_bit_calls.clone()), [false]);
}

#[test]
fn a_camera_without_a_shutter_takes_lights_and_darks() {
    let _fake = install(Fake::default());
    let sdk = fake_sdk();
    let mut camera = connected(&sdk);
    for frame_type in [FrameType::Light, FrameType::Dark, FrameType::Bias] {
        camera
            .begin_exposure(&sdk, &exposure(frame_type, 1, None))
            .expect("a shutterless camera exposes every frame type");
    }
    assert_eq!(with(|f| f.started.len()), 3);
    assert!(with(|f| f.dark_mode_calls.is_empty()));
}

#[test]
fn a_camera_with_a_shutter_keeps_it_closed_for_darks() {
    let _fake = install(Fake {
        camera_flags: ARTEMIS_CAMERA_HAS_SHUTTER,
        ..Fake::default()
    });
    let sdk = fake_sdk();
    let mut camera = connected(&sdk);
    camera
        .begin_exposure(&sdk, &exposure(FrameType::Dark, 1, None))
        .unwrap();
    camera
        .begin_exposure(&sdk, &exposure(FrameType::Light, 1, None))
        .unwrap();
    assert_eq!(with(|f| f.dark_mode_calls.clone()), [true, false]);
}

#[test]
fn a_binned_frame_covers_the_whole_sensor() {
    let _fake = install(Fake::default());
    let sdk = fake_sdk();
    let mut camera = connected(&sdk);
    camera
        .begin_exposure(&sdk, &exposure(FrameType::Light, 2, None))
        .unwrap();
    assert_eq!(with(|f| f.subframe), (0, 0, 32, 24));
    let image = camera.take_frame(&sdk).unwrap();
    assert_eq!((image.width, image.height), (16, 12));
    assert_eq!((image.metadata.bin_x, image.metadata.bin_y), (2, 2));
}

#[test]
fn a_subframe_in_binned_pixels_is_sent_in_sensor_pixels() {
    let _fake = install(Fake::default());
    let sdk = fake_sdk();
    let mut camera = connected(&sdk);
    let roi = SubFrame {
        start_x: 2,
        start_y: 3,
        width: 5,
        height: 4,
    };
    camera
        .begin_exposure(&sdk, &exposure(FrameType::Light, 2, Some(roi)))
        .unwrap();
    assert_eq!(with(|f| f.subframe), (4, 6, 10, 8));
    let image = camera.take_frame(&sdk).unwrap();
    assert_eq!((image.width, image.height), (5, 4));

    let too_wide = SubFrame {
        start_x: 10,
        start_y: 0,
        width: 8,
        height: 4,
    };
    assert!(matches!(
        camera.begin_exposure(&sdk, &exposure(FrameType::Light, 2, Some(too_wide))),
        Err(DriverError::InvalidParameter(_))
    ));
}

#[test]
fn cmos_gain_goes_through_camera_options_and_the_frame_records_what_the_camera_took() {
    let _fake = install(Fake {
        options: cmos_options(2),
        ..Fake::default()
    });
    let sdk = fake_sdk();
    let mut camera = connected(&sdk);
    let caps = camera.capabilities();
    assert!(caps.can_set_gain && caps.can_set_offset);
    assert_eq!(camera.facts.gain.gain_range(), Some((0, 60)));
    assert_eq!(camera.facts.gain.offset_range(), Some((0, 511)));
    assert_eq!(
        (camera.core.gain, camera.core.offset),
        (20, 35),
        "the medium preset is in force at connect"
    );

    let params = ExposureParams {
        gain: Some(45),
        ..exposure(FrameType::Light, 1, None)
    };
    camera.begin_exposure(&sdk, &params).unwrap();
    assert_eq!(
        with(|f| f.options[&ID_GO_PRESET_MODE].clone()),
        0u16.to_le_bytes(),
        "the preset gave way to the custom setting"
    );
    let image = camera.take_frame(&sdk).unwrap();
    assert_eq!(image.metadata.gain, 45);
    assert_eq!(
        image.metadata.offset, 10,
        "the custom offset applies with the custom gain"
    );

    let out_of_range = ExposureParams {
        gain: Some(61),
        ..exposure(FrameType::Light, 1, None)
    };
    assert!(matches!(
        camera.begin_exposure(&sdk, &out_of_range),
        Err(DriverError::InvalidParameter(_))
    ));
}

#[test]
fn a_ccd_without_gain_exposes_when_a_gain_is_asked_for() {
    let _fake = install(Fake::default());
    let sdk = fake_sdk();
    let mut camera = connected(&sdk);
    assert!(!camera.capabilities().can_set_gain);
    assert_eq!(camera.facts.gain.gain_range(), None);
    let params = ExposureParams {
        gain: Some(100),
        offset: Some(10),
        ..exposure(FrameType::Light, 1, None)
    };
    camera
        .begin_exposure(&sdk, &params)
        .expect("the exposure starts");
    assert_eq!(camera.take_frame(&sdk).unwrap().metadata.gain, 0);
}

#[test]
fn a_camera_whose_driver_implements_artemis_set_gain_uses_it() {
    let _fake = install(Fake {
        sdk_gain: Some((3, 100)),
        ..Fake::default()
    });
    let sdk = fake_sdk();
    let mut camera = connected(&sdk);
    assert_eq!(camera.facts.gain, GainControl::Sdk);
    assert_eq!((camera.core.gain, camera.core.offset), (3, 100));
    let params = ExposureParams {
        gain: Some(7),
        ..exposure(FrameType::Light, 1, None)
    };
    camera.begin_exposure(&sdk, &params).unwrap();
    assert_eq!(with(|f| f.sdk_gain), Some((7, 100)));
}

#[test]
fn the_sdk_mosaic_offset_and_an_odd_subframe_origin_move_the_bayer_cell() {
    let _fake = install(Fake {
        colour: ARTEMIS_COLOUR_RGGB,
        colour_offset: (1, 0),
        ..Fake::default()
    });
    let sdk = fake_sdk();
    let mut camera = connected(&sdk);
    assert_eq!(
        camera.get_sensor_info().bayer_pattern,
        Some(BayerPattern::Grbg.into())
    );

    camera
        .begin_exposure(&sdk, &exposure(FrameType::Light, 1, None))
        .unwrap();
    assert_eq!(
        camera.take_frame(&sdk).unwrap().bayer_pattern,
        Some(BayerPattern::Grbg.into())
    );

    let roi = SubFrame {
        start_x: 1,
        start_y: 1,
        width: 8,
        height: 8,
    };
    camera
        .begin_exposure(&sdk, &exposure(FrameType::Light, 1, Some(roi)))
        .unwrap();
    assert_eq!(
        camera.take_frame(&sdk).unwrap().bayer_pattern,
        Some(BayerPattern::Gbrg.into())
    );
}

#[test]
fn a_12_bit_cmos_camera_reports_the_full_scale_its_frames_have() {
    let _fake = install(Fake {
        options: HashMap::from([(ID_PAD_DATA, vec![0])]),
        ..Fake::default()
    });
    let sdk = fake_sdk();
    let info = connected(&sdk).get_sensor_info();
    assert_eq!((info.bit_depth, info.max_adu), (12, 4095));

    with(|f| f.options.insert(ID_PAD_DATA, vec![1]));
    let info = connected(&sdk).get_sensor_info();
    assert_eq!((info.bit_depth, info.max_adu), (12, 65520));
}

#[test]
fn a_camera_left_in_fast_exposure_speed_is_switched_to_single_frames() {
    let _fake = install(Fake {
        options: HashMap::from([(
            ID_EXPOSURE_SPEED,
            EXPOSURE_SPEED_FAST.to_le_bytes().to_vec(),
        )]),
        ..Fake::default()
    });
    let sdk = fake_sdk();
    connected(&sdk);
    assert_eq!(
        with(|f| f.options[&ID_EXPOSURE_SPEED].clone()),
        EXPOSURE_SPEED_POWER_SAVE.to_le_bytes()
    );
}

#[test]
fn an_unplugged_camera_fails_its_status_read_and_its_exposure() {
    let _fake = install(Fake::default());
    let sdk = fake_sdk();
    let camera = connected(&sdk);
    assert!(camera.status(&sdk).is_ok());
    with(|f| f.present = false);
    assert!(matches!(
        camera.status(&sdk),
        Err(DriverError::Disconnected)
    ));
    assert!(matches!(
        camera.exposure_done(&sdk),
        Err(DriverError::Disconnected)
    ));
}

#[test]
fn an_exposure_starts_only_once_the_camera_is_idle() {
    let _fake = install(Fake {
        states: VecDeque::from([5, CAMERA_ERROR, CAMERA_IDLE]),
        ..Fake::default()
    });
    let sdk = fake_sdk();
    let camera = connected(&sdk);
    assert!(!camera.ready_to_expose(&sdk).unwrap(), "flushing");
    assert!(!camera.ready_to_expose(&sdk).unwrap(), "error");
    assert_eq!(
        with(|f| f.aborts),
        1,
        "an error state is stopped so it can clear"
    );
    assert!(camera.ready_to_expose(&sdk).unwrap());
}

#[test]
fn a_camera_error_during_the_exposure_and_a_failed_download_are_reported() {
    let _fake = install(Fake {
        image_ready: false,
        ..Fake::default()
    });
    let sdk = fake_sdk();
    let mut camera = connected(&sdk);
    assert!(!camera.exposure_done(&sdk).unwrap());
    with(|f| f.states = VecDeque::from([CAMERA_ERROR]));
    assert!(camera.exposure_done(&sdk).is_err());

    with(|f| {
        f.image_ready = true;
        f.image_failed = true;
    });
    assert!(camera.exposure_done(&sdk).unwrap());
    assert!(camera.take_frame(&sdk).is_err());
}

#[test]
fn a_camera_still_cooling_from_before_is_warmed_up_on_disconnect() {
    let _fake = install(Fake {
        cooling_flags: ARTEMIS_COOLING_INFO_HASCOOLING
            | ARTEMIS_COOLING_INFO_SETPOINTCONTROL
            | ARTEMIS_COOLING_INFO_COOLINGON,
        setpoint: -1500,
        ..Fake::default()
    });
    let sdk = fake_sdk();
    let mut camera = connected(&sdk);
    assert!(camera.capabilities().can_cool);
    let status = camera.status(&sdk).unwrap();
    assert_eq!(status.cooler_on, Some(true));
    assert_eq!(status.target_temp, Some(-15.0));
    assert_eq!(status.cooler_power, Some(20.0));
    assert_eq!(status.sensor_temp, Some(-9.5));
    camera.close(&sdk).unwrap();
    assert_eq!(with(|f| f.warm_ups), 1);
}

#[test]
fn a_cooler_without_set_point_control_is_not_offered_as_settable() {
    let _fake = install(Fake {
        cooling_flags: ARTEMIS_COOLING_INFO_HASCOOLING | ARTEMIS_COOLING_INFO_COOLINGON,
        ..Fake::default()
    });
    let sdk = fake_sdk();
    let camera = connected(&sdk);
    assert!(!camera.capabilities().can_cool);
    assert_eq!(camera.status(&sdk).unwrap().cooler_power, Some(20.0));
}

#[tokio::test]
async fn filter_wheels_are_listed_in_their_own_index_space() {
    let _fake = install(Fake {
        devices: Vec::new(),
        efws: vec![(2, Some("EFW-A")), (1, Some("EFW-B"))],
        ..Fake::default()
    });
    let sdk = fake_sdk();
    let wheels = list_filter_wheels(&sdk).unwrap();
    let names: Vec<_> = wheels.iter().map(|w| w.name.as_str()).collect();
    assert_eq!(
        names,
        ["Atik EFW2/EFW3", "Atik EFW1"],
        "found with no camera plugged in"
    );

    let mut wheel = AtikFilterWheel {
        serial_number: Some("EFW-B".to_string()),
        ..AtikFilterWheel::new(0)
    };
    wheel.open(&sdk).expect("the wheel connects");
    assert_eq!(wheel.device_index, 1);
    assert_eq!(wheel.get_filter_count().await, 7);
    with(|f| f.efw_position = 4);
    assert_eq!(wheel.read_position(&sdk).unwrap(), (4, false));
}

#[test]
fn sdk_errors_read_as_what_they_mean() {
    assert!(matches!(
        ArtemisError::NotConnected.to_native_error("start the exposure"),
        DriverError::Disconnected
    ));
    assert!(matches!(
        ArtemisError::NoResponse.to_native_error("start the exposure"),
        DriverError::Timeout(_)
    ));
    let DriverError::SdkError(text) =
        ArtemisError::InvalidFunction.to_native_error("warm up the cooler")
    else {
        panic!("an SDK error");
    };
    assert!(text.contains("does not have that feature"), "{text}");
}
