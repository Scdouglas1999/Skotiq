//! Atik SDK function pointers and loading.

use super::*;

pub(crate) type ArtemisDeviceCount = unsafe extern "C" fn() -> c_int;
/// Makes the SDK look for devices plugged in or removed since the last look.
/// It returns how many times the device lists have changed, not how many
/// devices there are (the SDK guide says otherwise; the shipped library and
/// NINA's notes agree on the counter).
pub(crate) type ArtemisRefreshDevicesCount = unsafe extern "C" fn() -> c_int;
pub(crate) type ArtemisDevicePresent = unsafe extern "C" fn(device: c_int) -> c_int;
pub(crate) type ArtemisDeviceName = unsafe extern "C" fn(device: c_int, name: *mut c_char) -> c_int;
pub(crate) type ArtemisDeviceSerial =
    unsafe extern "C" fn(device: c_int, serial: *mut c_char) -> c_int;
pub(crate) type ArtemisDeviceIsCamera = unsafe extern "C" fn(device: c_int) -> c_int;
pub(crate) type ArtemisEFWIsPresent = unsafe extern "C" fn(device: c_int) -> c_int;
pub(crate) type ArtemisEFWGetDeviceDetails =
    unsafe extern "C" fn(device: c_int, efw_type: *mut c_int, serial: *mut c_char) -> c_int;
pub(crate) type ArtemisEFWConnect = unsafe extern "C" fn(device: c_int) -> ArtemisHandle;
pub(crate) type ArtemisEFWIsConnected = unsafe extern "C" fn(handle: ArtemisHandle) -> bool;
pub(crate) type ArtemisEFWDisconnect = unsafe extern "C" fn(handle: ArtemisHandle) -> c_int;
pub(crate) type ArtemisEFWNmrPosition =
    unsafe extern "C" fn(handle: ArtemisHandle, positions: *mut c_int) -> c_int;
pub(crate) type ArtemisEFWSetPosition =
    unsafe extern "C" fn(handle: ArtemisHandle, position: c_int) -> c_int;
pub(crate) type ArtemisEFWGetPosition = unsafe extern "C" fn(
    handle: ArtemisHandle,
    position: *mut c_int,
    is_moving: *mut bool,
) -> c_int;
pub(crate) type ArtemisConnect = unsafe extern "C" fn(device: c_int) -> ArtemisHandle;
pub(crate) type ArtemisDisconnect = unsafe extern "C" fn(handle: ArtemisHandle) -> c_int;
pub(crate) type ArtemisIsConnected = unsafe extern "C" fn(handle: ArtemisHandle) -> c_int;
pub(crate) type ArtemisProperties_ =
    unsafe extern "C" fn(handle: ArtemisHandle, prop: *mut ArtemisProperties) -> c_int;
pub(crate) type ArtemisColourProperties = unsafe extern "C" fn(
    handle: ArtemisHandle,
    colour_type: *mut c_int,
    normal_offset_x: *mut c_int,
    normal_offset_y: *mut c_int,
    preview_offset_x: *mut c_int,
    preview_offset_y: *mut c_int,
) -> c_int;
pub(crate) type ArtemisBin =
    unsafe extern "C" fn(handle: ArtemisHandle, x: c_int, y: c_int) -> c_int;
pub(crate) type ArtemisGetMaxBin =
    unsafe extern "C" fn(handle: ArtemisHandle, x: *mut c_int, y: *mut c_int) -> c_int;
/// Position and size in unbinned sensor pixels, whatever the binning.
pub(crate) type ArtemisSubframe =
    unsafe extern "C" fn(handle: ArtemisHandle, x: c_int, y: c_int, w: c_int, h: c_int) -> c_int;
pub(crate) type ArtemisStartExposure =
    unsafe extern "C" fn(handle: ArtemisHandle, seconds: c_float) -> c_int;
pub(crate) type ArtemisAbortExposure = unsafe extern "C" fn(handle: ArtemisHandle) -> c_int;
pub(crate) type ArtemisImageReady = unsafe extern "C" fn(handle: ArtemisHandle) -> c_int;
pub(crate) type ArtemisImageFailed = unsafe extern "C" fn(handle: ArtemisHandle) -> c_int;
pub(crate) type ArtemisCameraState = unsafe extern "C" fn(handle: ArtemisHandle) -> c_int;
pub(crate) type ArtemisExposureTimeRemaining =
    unsafe extern "C" fn(handle: ArtemisHandle) -> c_float;
pub(crate) type ArtemisGetImageData = unsafe extern "C" fn(
    handle: ArtemisHandle,
    x: *mut c_int,
    y: *mut c_int,
    w: *mut c_int,
    h: *mut c_int,
    binx: *mut c_int,
    biny: *mut c_int,
) -> c_int;
pub(crate) type ArtemisImageBuffer = unsafe extern "C" fn(handle: ArtemisHandle) -> *mut c_void;
pub(crate) type ArtemisSetCooling =
    unsafe extern "C" fn(handle: ArtemisHandle, setpoint: c_int) -> c_int;
pub(crate) type ArtemisCoolingInfo = unsafe extern "C" fn(
    handle: ArtemisHandle,
    flags: *mut c_int,
    level: *mut c_int,
    minlvl: *mut c_int,
    maxlvl: *mut c_int,
    setpoint: *mut c_int,
) -> c_int;
pub(crate) type ArtemisCoolerWarmUp = unsafe extern "C" fn(handle: ArtemisHandle) -> c_int;
pub(crate) type ArtemisTemperatureSensorInfo =
    unsafe extern "C" fn(handle: ArtemisHandle, sensor: c_int, temperature: *mut c_int) -> c_int;
/// Only the Sony scientific cameras implement these; every other Atik camera
/// answers ARTEMIS_INVALID_FUNCTION and takes gain through camera specific
/// options, or has none.
pub(crate) type ArtemisSetGain =
    unsafe extern "C" fn(handle: ArtemisHandle, preview: bool, gain: c_int, offset: c_int) -> c_int;
pub(crate) type ArtemisGetGain = unsafe extern "C" fn(
    handle: ArtemisHandle,
    preview: bool,
    gain: *mut c_int,
    offset: *mut c_int,
) -> c_int;
pub(crate) type ArtemisAPIVersion = unsafe extern "C" fn() -> c_int;
/// ARTEMIS_INVALID_FUNCTION on a camera without a mechanical shutter.
pub(crate) type ArtemisSetDarkMode =
    unsafe extern "C" fn(handle: ArtemisHandle, enable: bool) -> c_int;
/// ARTEMIS_INVALID_PARAMETER on a camera without an 8-bit mode.
pub(crate) type ArtemisEightBitMode =
    unsafe extern "C" fn(handle: ArtemisHandle, eightbit: bool) -> c_int;
pub(crate) type ArtemisHasCameraSpecificOption =
    unsafe extern "C" fn(handle: ArtemisHandle, id: u16) -> bool;
pub(crate) type ArtemisCameraSpecificOptionGetData = unsafe extern "C" fn(
    handle: ArtemisHandle,
    id: u16,
    data: *mut u8,
    data_length: c_int,
    actual_length: *mut c_int,
) -> c_int;
pub(crate) type ArtemisCameraSpecificOptionSetData = unsafe extern "C" fn(
    handle: ArtemisHandle,
    id: u16,
    data: *mut u8,
    data_length: c_int,
) -> c_int;

/// Candidate paths for the Atik camera SDK, in search order.
pub(crate) fn atik_candidate_paths() -> Vec<std::path::PathBuf> {
    let lib_name = if cfg!(target_os = "windows") {
        "AtikCameras.dll"
    } else if cfg!(target_os = "macos") {
        "libatikcameras.dylib"
    } else {
        "libatikcameras.so"
    };
    let system_paths = if cfg!(target_os = "linux") {
        vec![
            format!("/usr/lib/{lib_name}"),
            format!("/usr/local/lib/{lib_name}"),
        ]
    } else if cfg!(target_os = "macos") {
        vec![
            format!("/usr/local/lib/{lib_name}"),
            format!("/opt/homebrew/lib/{lib_name}"),
        ]
    } else {
        Vec::new()
    };
    let system_path_refs = system_paths.iter().map(String::as_str).collect::<Vec<_>>();
    crate::vendor::sdk_loader::vendor_library_candidates(&[lib_name], &system_path_refs)
}

crate::load_vendor_sdk! {
    /// Atik SDK wrapper with dynamically loaded functions.
    vendor_name: "Atik",
    sdk_struct: AtikSdk,
    sdk_static: SDK,
    candidate_paths_fn: atik_candidate_paths,
    symbols: {
        device_count: b"ArtemisDeviceCount\0" => ArtemisDeviceCount,
        device_present: b"ArtemisDevicePresent\0" => ArtemisDevicePresent,
        device_name: b"ArtemisDeviceName\0" => ArtemisDeviceName,
        device_serial: b"ArtemisDeviceSerial\0" => ArtemisDeviceSerial,
        device_is_camera: b"ArtemisDeviceIsCamera\0" => ArtemisDeviceIsCamera,
        connect: b"ArtemisConnect\0" => ArtemisConnect,
        disconnect: b"ArtemisDisconnect\0" => ArtemisDisconnect,
        is_connected: b"ArtemisIsConnected\0" => ArtemisIsConnected,
        properties: b"ArtemisProperties\0" => ArtemisProperties_,
        colour_properties: b"ArtemisColourProperties\0" => ArtemisColourProperties,
        bin: b"ArtemisBin\0" => ArtemisBin,
        get_max_bin: b"ArtemisGetMaxBin\0" => ArtemisGetMaxBin,
        subframe: b"ArtemisSubframe\0" => ArtemisSubframe,
        start_exposure: b"ArtemisStartExposure\0" => ArtemisStartExposure,
        abort_exposure: b"ArtemisAbortExposure\0" => ArtemisAbortExposure,
        image_ready: b"ArtemisImageReady\0" => ArtemisImageReady,
        exposure_time_remaining: b"ArtemisExposureTimeRemaining\0" => ArtemisExposureTimeRemaining,
        get_image_data: b"ArtemisGetImageData\0" => ArtemisGetImageData,
        image_buffer: b"ArtemisImageBuffer\0" => ArtemisImageBuffer,
        set_cooling: b"ArtemisSetCooling\0" => ArtemisSetCooling,
        cooling_info: b"ArtemisCoolingInfo\0" => ArtemisCoolingInfo,
        cooler_warm_up: b"ArtemisCoolerWarmUp\0" => ArtemisCoolerWarmUp,
        temperature_sensor_info: b"ArtemisTemperatureSensorInfo\0" => ArtemisTemperatureSensorInfo,
        set_gain: b"ArtemisSetGain\0" => ArtemisSetGain,
        get_gain: b"ArtemisGetGain\0" => ArtemisGetGain,
        api_version: b"ArtemisAPIVersion\0" => ArtemisAPIVersion,
        set_dark_mode: b"ArtemisSetDarkMode\0" => ArtemisSetDarkMode,
        eight_bit_mode: b"ArtemisEightBitMode\0" => ArtemisEightBitMode,
    },
    // Absent on older SDK builds. Without them discovery uses the device
    // count as it stands, the EFW driver is unavailable, the CMOS gain
    // controls are unavailable, and exposures start without waiting for the
    // camera to report idle.
    optional_symbols: {
        refresh_devices_count: b"ArtemisRefreshDevicesCount\0" => ArtemisRefreshDevicesCount,
        efw_is_present: b"ArtemisEFWIsPresent\0" => ArtemisEFWIsPresent,
        efw_get_device_details: b"ArtemisEFWGetDeviceDetails\0" => ArtemisEFWGetDeviceDetails,
        efw_connect: b"ArtemisEFWConnect\0" => ArtemisEFWConnect,
        efw_is_connected: b"ArtemisEFWIsConnected\0" => ArtemisEFWIsConnected,
        efw_disconnect: b"ArtemisEFWDisconnect\0" => ArtemisEFWDisconnect,
        efw_nmr_position: b"ArtemisEFWNmrPosition\0" => ArtemisEFWNmrPosition,
        efw_set_position: b"ArtemisEFWSetPosition\0" => ArtemisEFWSetPosition,
        efw_get_position: b"ArtemisEFWGetPosition\0" => ArtemisEFWGetPosition,
        camera_state: b"ArtemisCameraState\0" => ArtemisCameraState,
        image_failed: b"ArtemisImageFailed\0" => ArtemisImageFailed,
        has_camera_specific_option: b"ArtemisHasCameraSpecificOption\0" => ArtemisHasCameraSpecificOption,
        camera_specific_option_get_data: b"ArtemisCameraSpecificOptionGetData\0" => ArtemisCameraSpecificOptionGetData,
        camera_specific_option_set_data: b"ArtemisCameraSpecificOptionSetData\0" => ArtemisCameraSpecificOptionSetData,
    }
}

pub(crate) fn check_artemis_error(result: c_int, operation: &str) -> Result<(), DriverError> {
    match ArtemisError::from_i32(result) {
        ArtemisError::Ok => Ok(()),
        error => Err(error.to_native_error(operation)),
    }
}

/// The external filter wheel entry points, all present or none.
pub(crate) struct EfwApi {
    pub(crate) is_present: ArtemisEFWIsPresent,
    pub(crate) get_device_details: ArtemisEFWGetDeviceDetails,
    pub(crate) connect: ArtemisEFWConnect,
    pub(crate) is_connected: ArtemisEFWIsConnected,
    pub(crate) disconnect: ArtemisEFWDisconnect,
    pub(crate) nmr_position: ArtemisEFWNmrPosition,
    pub(crate) set_position: ArtemisEFWSetPosition,
    pub(crate) get_position: ArtemisEFWGetPosition,
}

impl AtikSdk {
    pub(crate) fn efw(&self) -> Result<EfwApi, DriverError> {
        Ok(EfwApi {
            is_present: self.efw_is_present.ok_or(DriverError::NotSupported)?,
            get_device_details: self
                .efw_get_device_details
                .ok_or(DriverError::NotSupported)?,
            connect: self.efw_connect.ok_or(DriverError::NotSupported)?,
            is_connected: self.efw_is_connected.ok_or(DriverError::NotSupported)?,
            disconnect: self.efw_disconnect.ok_or(DriverError::NotSupported)?,
            nmr_position: self.efw_nmr_position.ok_or(DriverError::NotSupported)?,
            set_position: self.efw_set_position.ok_or(DriverError::NotSupported)?,
            get_position: self.efw_get_position.ok_or(DriverError::NotSupported)?,
        })
    }

    /// How many entries the camera device list has now.
    pub(crate) fn device_count_now(&self) -> c_int {
        if let Some(refresh) = self.refresh_devices_count {
            // SAFETY: takes no arguments; the caller holds the SDK lock and the
            // library is never unloaded. The return value is a change counter.
            unsafe { refresh() };
        }
        // SAFETY: takes no arguments; same lock and library as above.
        unsafe { (self.device_count)() }
    }
}

/// External filter wheels have an index list of their own, with no count
/// call (INDI probes the first four). A list only grows by plugging wheels in.
pub(crate) const EFW_INDEX_LIMIT: c_int = 8;

pub(crate) fn atik_efw_type_name(efw_type: c_int) -> String {
    match efw_type {
        1 => "Atik EFW1".to_string(),
        // The Atik SDK documents EFW3 devices as reporting the EFW2 firmware type.
        2 => "Atik EFW2/EFW3".to_string(),
        other => format!("Atik EFW type {}", other),
    }
}

pub(crate) static DISCOVERED_CAMERA_SERIALS: OnceLock<Mutex<HashMap<c_int, String>>> =
    OnceLock::new();
pub(crate) static DISCOVERED_EFW_SERIALS: OnceLock<Mutex<HashMap<c_int, String>>> = OnceLock::new();

pub(crate) fn discovered_camera_serials() -> &'static Mutex<HashMap<c_int, String>> {
    DISCOVERED_CAMERA_SERIALS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(crate) fn discovered_efw_serials() -> &'static Mutex<HashMap<c_int, String>> {
    DISCOVERED_EFW_SERIALS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// A NUL-terminated string the SDK wrote into a buffer or struct field. An
/// empty string is no answer.
pub(crate) fn c_text(buffer: &[c_char]) -> Option<String> {
    let bytes: Vec<u8> = buffer
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u8)
        .collect();
    let text = String::from_utf8_lossy(&bytes).trim().to_string();
    (!text.is_empty()).then_some(text)
}

/// The camera at a device index: its name and USB serial, or `None` when the
/// index holds no camera now.
///
/// The caller holds the SDK lock; indices are only meaningful under it.
pub(crate) fn camera_at(sdk: &AtikSdk, index: c_int) -> Option<(String, Option<String>)> {
    // SAFETY: plain int argument; the SDK checks the index itself.
    if unsafe { (sdk.device_present)(index) } == 0 {
        return None;
    }
    // SAFETY: plain int argument, asked only of a present index.
    if unsafe { (sdk.device_is_camera)(index) } == 0 {
        return None;
    }
    let mut name_buf = [0 as c_char; 100];
    // SAFETY: the SDK writes at most 100 bytes into the buffer (AtikCameras.h).
    let name = if unsafe { (sdk.device_name)(index, name_buf.as_mut_ptr()) } != 0 {
        c_text(&name_buf)
    } else {
        None
    };
    let mut serial_buf = [0 as c_char; 100];
    // SAFETY: as for the name.
    let serial = if unsafe { (sdk.device_serial)(index, serial_buf.as_mut_ptr()) } != 0 {
        c_text(&serial_buf)
    } else {
        None
    };
    Some((
        name.unwrap_or_else(|| format!("Atik Camera {index}")),
        serial,
    ))
}

/// The device index a camera has now. A camera seen with a serial is found by
/// it, since indices move when devices are plugged or unplugged; one without
/// (some USB bodies report none) can only be taken at its index.
///
/// The caller holds the SDK lock.
pub(crate) fn camera_index_now(
    sdk: &AtikSdk,
    seen_index: c_int,
    serial_number: Option<&str>,
) -> Result<(c_int, Option<String>), DriverError> {
    let count = sdk.device_count_now();
    match serial_number {
        Some(serial) => (0..count)
            .find(|&index| {
                camera_at(sdk, index).is_some_and(|(_, found)| found.as_deref() == Some(serial))
            })
            .map(|index| (index, Some(serial.to_string())))
            .ok_or_else(|| {
                DriverError::DeviceNotFound(format!(
                    "the Atik camera with serial {serial} is not plugged in (the SDK lists {count} device(s))"
                ))
            }),
        None => match camera_at(sdk, seen_index) {
            Some((_, serial)) if seen_index < count => Ok((seen_index, serial)),
            _ => Err(DriverError::DeviceNotFound(format!(
                "no Atik camera at device index {seen_index}; search for devices again"
            ))),
        },
    }
}

/// The details of the external filter wheel at an index, or `None`.
///
/// The caller holds the SDK lock.
pub(crate) fn efw_at(efw: &EfwApi, index: c_int) -> Option<(c_int, Option<String>)> {
    // SAFETY: plain int argument; the SDK checks the index itself.
    if unsafe { (efw.is_present)(index) } == 0 {
        return None;
    }
    let mut efw_type: c_int = 0;
    let mut serial_buf = [0 as c_char; 100];
    // SAFETY: both out-pointers are valid; the serial buffer has the 100 bytes
    // the SDK documents.
    let result = unsafe { (efw.get_device_details)(index, &mut efw_type, serial_buf.as_mut_ptr()) };
    if result != ArtemisError::Ok as c_int {
        tracing::warn!(
            "Atik EFW at index {index}: ArtemisEFWGetDeviceDetails answered {:?}",
            ArtemisError::from_i32(result)
        );
        return None;
    }
    Some((efw_type, c_text(&serial_buf)))
}

/// The index an external filter wheel has now, found by serial when it has one.
///
/// The caller holds the SDK lock.
pub(crate) fn efw_index_now(
    efw: &EfwApi,
    seen_index: c_int,
    serial_number: Option<&str>,
) -> Result<c_int, DriverError> {
    match serial_number {
        Some(serial) => (0..EFW_INDEX_LIMIT)
            .find(|&index| {
                efw_at(efw, index).is_some_and(|(_, found)| found.as_deref() == Some(serial))
            })
            .ok_or_else(|| {
                DriverError::DeviceNotFound(format!(
                    "the Atik filter wheel with serial {serial} is not plugged in"
                ))
            }),
        None => efw_at(efw, seen_index).map(|_| seen_index).ok_or_else(|| {
            DriverError::DeviceNotFound(format!(
                "no Atik filter wheel at index {seen_index}; search for devices again"
            ))
        }),
    }
}

// A child of this module, so the tests can build an `AtikSdk` table of their own.
#[cfg(test)]
#[path = "tests.rs"]
mod driver_tests;

// The driver against a model of the SDK written from Atik's documents.
#[cfg(test)]
#[path = "verify_tests.rs"]
mod verify_tests;
