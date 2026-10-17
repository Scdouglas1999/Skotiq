//! Atik SDK function pointers and loading.

use super::*;

pub(crate) type ArtemisDeviceCount = unsafe extern "C" fn() -> c_int;
// Forces a fresh device re-enumeration and returns the count. Absent on older
// SDK builds, so it is loaded optionally.
pub(crate) type ArtemisRefreshDevicesCount = unsafe extern "C" fn() -> c_int;
pub(crate) type ArtemisDevicePresent = unsafe extern "C" fn(device: c_int) -> c_int;
pub(crate) type ArtemisDeviceName = unsafe extern "C" fn(device: c_int, name: *mut c_char) -> c_int;
pub(crate) type ArtemisDeviceSerial =
    unsafe extern "C" fn(device: c_int, serial: *mut c_char) -> c_int;
pub(crate) type ArtemisDeviceIsCamera = unsafe extern "C" fn(device: c_int) -> c_int;
pub(crate) type ArtemisDeviceHasFilterWheel = unsafe extern "C" fn(device: c_int) -> c_int;
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
pub(crate) type ArtemisSubframe =
    unsafe extern "C" fn(handle: ArtemisHandle, x: c_int, y: c_int, w: c_int, h: c_int) -> c_int;
pub(crate) type ArtemisStartExposure =
    unsafe extern "C" fn(handle: ArtemisHandle, seconds: c_float) -> c_int;
pub(crate) type ArtemisAbortExposure = unsafe extern "C" fn(handle: ArtemisHandle) -> c_int;
pub(crate) type ArtemisImageReady = unsafe extern "C" fn(handle: ArtemisHandle) -> c_int;
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
pub(crate) type ArtemisSetGain = unsafe extern "C" fn(
    handle: ArtemisHandle,
    preview: c_int,
    gain: c_int,
    offset: c_int,
) -> c_int;
pub(crate) type ArtemisGetGain = unsafe extern "C" fn(
    handle: ArtemisHandle,
    preview: c_int,
    gain: *mut c_int,
    offset: *mut c_int,
) -> c_int;
pub(crate) type ArtemisAPIVersion = unsafe extern "C" fn() -> c_int;
pub(crate) type ArtemisSetDarkMode =
    unsafe extern "C" fn(handle: ArtemisHandle, enable: c_int) -> c_int;
pub(crate) type ArtemisEightBitMode =
    unsafe extern "C" fn(handle: ArtemisHandle, eightbit: c_int) -> c_int;

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
    ///
    /// `device_has_filter_wheel` is resolved but never read — the filter-wheel
    /// path keys off `efw_is_present` instead. It is kept so the struct-level
    /// allow below documents one deliberately unused entry rather than hiding
    /// a whole class of them.
    #[allow(dead_code)]
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
    // Absent on older SDK builds: discovery falls back to the passive
    // ArtemisDeviceCount, and the EFW entry points gate the filter-wheel driver.
    optional_symbols: {
        refresh_devices_count: b"ArtemisRefreshDevicesCount\0" => ArtemisRefreshDevicesCount,
        device_has_filter_wheel: b"ArtemisDeviceHasFilterWheel\0" => ArtemisDeviceHasFilterWheel,
        efw_is_present: b"ArtemisEFWIsPresent\0" => ArtemisEFWIsPresent,
        efw_get_device_details: b"ArtemisEFWGetDeviceDetails\0" => ArtemisEFWGetDeviceDetails,
        efw_connect: b"ArtemisEFWConnect\0" => ArtemisEFWConnect,
        efw_is_connected: b"ArtemisEFWIsConnected\0" => ArtemisEFWIsConnected,
        efw_disconnect: b"ArtemisEFWDisconnect\0" => ArtemisEFWDisconnect,
        efw_nmr_position: b"ArtemisEFWNmrPosition\0" => ArtemisEFWNmrPosition,
        efw_set_position: b"ArtemisEFWSetPosition\0" => ArtemisEFWSetPosition,
        efw_get_position: b"ArtemisEFWGetPosition\0" => ArtemisEFWGetPosition,
    }
}

pub(crate) fn get_sdk() -> Result<&'static AtikSdk, NativeError> {
    AtikSdk::get_or_reason().map_err(|reason| NativeError::SdkError(reason.to_string()))
}

pub(crate) fn check_artemis_error(result: c_int, operation: &str) -> Result<(), NativeError> {
    let err = ArtemisError::from_i32(result);
    if err == ArtemisError::Ok {
        Ok(())
    } else {
        Err(err.to_native_error(operation))
    }
}

pub(crate) fn require_efw_api(sdk: &AtikSdk) -> Result<(), NativeError> {
    if sdk.efw_is_present.is_some()
        && sdk.efw_get_device_details.is_some()
        && sdk.efw_connect.is_some()
        && sdk.efw_is_connected.is_some()
        && sdk.efw_disconnect.is_some()
        && sdk.efw_nmr_position.is_some()
        && sdk.efw_set_position.is_some()
        && sdk.efw_get_position.is_some()
    {
        Ok(())
    } else {
        Err(NativeError::NotSupported)
    }
}

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

/// Resolve the live SDK enumeration index for a camera serial.
///
/// # Preconditions
///
/// The caller MUST already hold [`atik_mutex`]. The Artemis SDK keeps its device
/// table in process-global state and is not thread-safe, so both the enumeration
/// and the index-keyed queries below are only coherent (and the index only stays
/// meaningful between calls) while that lock is held. The sole caller,
/// `AtikCamera::connect`, takes the lock before calling.
pub(crate) fn camera_index_for_serial(
    sdk: &AtikSdk,
    serial_number: &str,
) -> Result<c_int, NativeError> {
    let count = match sdk.refresh_devices_count {
        // SAFETY: atik_mutex is held by the caller (see preconditions), so no other
        // task is inside the Artemis SDK. ArtemisRefreshDevicesCount takes no
        // arguments and returns a plain c_int, so there is no pointer to invalidate.
        // `sdk` is borrowed from the process-lifetime `SDK` OnceLock, whose library
        // is never unloaded, so the function pointer stays valid for the call.
        Some(refresh) => unsafe { refresh() },
        // SAFETY: identical to the refresh arm above — same held lock, same
        // never-unloaded library, and ArtemisDeviceCount likewise takes no arguments
        // and returns a c_int.
        None => unsafe { (sdk.device_count)() },
    };

    for index in 0..count {
        // SAFETY: atik_mutex is held by the caller; `index` comes from `0..count`
        // where `count` is the SDK's own device count read above under the same
        // lock, which is exactly the range ArtemisDevicePresent accepts. Only that
        // c_int is passed; no pointers are involved.
        if unsafe { (sdk.device_present)(index) } == 0 {
            continue;
        }
        // SAFETY: atik_mutex is held by the caller; `index` is in enumeration range
        // AND was just confirmed present, which is ArtemisDeviceIsCamera's
        // precondition. This is kept as a separate `if` rather than folded into the
        // presence check with `||` so the short-circuit survives: an absent slot must
        // never be asked whether it is a camera.
        if unsafe { (sdk.device_is_camera)(index) } == 0 {
            continue;
        }

        let mut serial_buf = [0 as c_char; 100];
        // SAFETY: caller holds atik_mutex; index is present and serial_buf is a valid
        // 100-byte output buffer.
        if unsafe { (sdk.device_serial)(index, serial_buf.as_mut_ptr()) } == 0 {
            continue;
        }
        // SAFETY: ArtemisDeviceSerial guarantees NUL-termination on success.
        let current_serial = unsafe { CStr::from_ptr(serial_buf.as_ptr()) }.to_string_lossy();
        if current_serial == serial_number {
            return Ok(index);
        }
    }

    Err(NativeError::DeviceNotFound(format!(
        "Atik camera serial {}",
        serial_number
    )))
}

pub(crate) fn efw_index_for_serial(
    sdk: &AtikSdk,
    serial_number: &str,
) -> Result<c_int, NativeError> {
    let efw_is_present = sdk.efw_is_present.unwrap();
    let efw_get_device_details = sdk.efw_get_device_details.unwrap();

    // SAFETY: caller holds atik_mutex; ArtemisDeviceCount takes no arguments.
    let count = unsafe { (sdk.device_count)() };
    for index in 0..count {
        // SAFETY: caller holds atik_mutex; index is inside the SDK enumeration range.
        if unsafe { efw_is_present(index) } == 0 {
            continue;
        }

        let mut efw_type: c_int = 0;
        let mut serial_buf = [0 as c_char; 100];
        // SAFETY: caller holds atik_mutex; index is present and both out-pointers are valid.
        if unsafe { efw_get_device_details(index, &mut efw_type, serial_buf.as_mut_ptr()) }
            != ArtemisError::Ok as c_int
        {
            continue;
        }
        // SAFETY: ArtemisEFWGetDeviceDetails documents a 100-byte, NUL-terminated serial.
        let current_serial = unsafe { CStr::from_ptr(serial_buf.as_ptr()) }.to_string_lossy();
        if current_serial == serial_number {
            return Ok(index);
        }
    }

    Err(NativeError::DeviceNotFound(format!(
        "Atik EFW serial {}",
        serial_number
    )))
}
