//! Player One SDK loading and error mapping.

use super::*;

/// Candidate paths for the Player One camera SDK, in search order.
pub(crate) fn poa_camera_candidate_paths() -> Vec<std::path::PathBuf> {
    if cfg!(target_os = "windows") {
        vec![
            std::path::PathBuf::from("PlayerOneCamera.dll"),
            std::path::PathBuf::from(
                "C:\\Program Files\\PlayerOne\\SDK\\lib\\x64\\PlayerOneCamera.dll",
            ),
        ]
    } else if cfg!(target_os = "macos") {
        vec![
            std::path::PathBuf::from("libPlayerOneCamera.dylib"),
            std::path::PathBuf::from("/usr/local/lib/libPlayerOneCamera.dylib"),
        ]
    } else {
        crate::vendor::sdk_loader::vendor_library_candidates(
            &["libPlayerOneCamera.so", "libPlayerOneCamera.so.3"],
            &[
                "/usr/lib/libPlayerOneCamera.so",
                "/usr/local/lib/libPlayerOneCamera.so",
            ],
        )
    }
}

/// Candidate paths for the Player One Phoenix filter-wheel SDK, in search order.
pub(crate) fn poa_pw_candidate_paths() -> Vec<std::path::PathBuf> {
    if cfg!(target_os = "windows") {
        vec![
            std::path::PathBuf::from("PlayerOnePW.dll"),
            std::path::PathBuf::from(
                "C:\\Program Files\\PlayerOne\\SDK\\lib\\x64\\PlayerOnePW.dll",
            ),
        ]
    } else if cfg!(target_os = "macos") {
        vec![
            std::path::PathBuf::from("libPlayerOnePW.dylib"),
            std::path::PathBuf::from("/usr/local/lib/libPlayerOnePW.dylib"),
        ]
    } else {
        crate::vendor::sdk_loader::vendor_library_candidates(
            &["libPlayerOnePW.so", "libPlayerOnePW.so.1"],
            &[
                "/usr/lib/libPlayerOnePW.so",
                "/usr/local/lib/libPlayerOnePW.so",
            ],
        )
    }
}

/// The one lock for both Player One libraries: a camera call and a
/// filter-wheel call never run at the same time.
pub(crate) static PLAYER_ONE_SDK_LOCK: crate::vendor::sdk_loader::SdkLock =
    crate::vendor::sdk_loader::SdkLock::new();

crate::load_vendor_sdk! {
    /// POA SDK library wrapper
    vendor_name: "Player One Camera",
    sdk_struct: PoaSdk,
    sdk_static: POA_SDK,
    candidate_paths_fn: poa_camera_candidate_paths,
    shared_lock: PLAYER_ONE_SDK_LOCK,
    symbols: {
        get_camera_count: b"POAGetCameraCount\0" => unsafe extern "C" fn() -> c_int,
        get_camera_properties: b"POAGetCameraProperties\0" => unsafe extern "C" fn(c_int, *mut POACameraProperties) -> c_int,
        get_camera_properties_by_id: b"POAGetCameraPropertiesByID\0" => unsafe extern "C" fn(c_int, *mut POACameraProperties) -> c_int,
        open_camera: b"POAOpenCamera\0" => unsafe extern "C" fn(c_int) -> c_int,
        init_camera: b"POAInitCamera\0" => unsafe extern "C" fn(c_int) -> c_int,
        close_camera: b"POACloseCamera\0" => unsafe extern "C" fn(c_int) -> c_int,
        get_config: b"POAGetConfig\0" => unsafe extern "C" fn(c_int, c_int, *mut POAConfigValue, *mut POABool) -> c_int,
        set_config: b"POASetConfig\0" => unsafe extern "C" fn(c_int, c_int, POAConfigValue, POABool) -> c_int,
        set_image_bin: b"POASetImageBin\0" => unsafe extern "C" fn(c_int, c_int) -> c_int,
        get_image_bin: b"POAGetImageBin\0" => unsafe extern "C" fn(c_int, *mut c_int) -> c_int,
        set_image_size: b"POASetImageSize\0" => unsafe extern "C" fn(c_int, c_int, c_int) -> c_int,
        set_image_start_pos: b"POASetImageStartPos\0" => unsafe extern "C" fn(c_int, c_int, c_int) -> c_int,
        get_image_start_pos: b"POAGetImageStartPos\0" => unsafe extern "C" fn(c_int, *mut c_int, *mut c_int) -> c_int,
        set_image_format: b"POASetImageFormat\0" => unsafe extern "C" fn(c_int, c_int) -> c_int,
        start_exposure: b"POAStartExposure\0" => unsafe extern "C" fn(c_int, POABool) -> c_int,
        stop_exposure: b"POAStopExposure\0" => unsafe extern "C" fn(c_int) -> c_int,
        get_camera_state: b"POAGetCameraState\0" => unsafe extern "C" fn(c_int, *mut c_int) -> c_int,
        get_image_data: b"POAGetImageData\0" => unsafe extern "C" fn(c_int, *mut u8, c_long, c_int) -> c_int,
        get_image_size: b"POAGetImageSize\0" => unsafe extern "C" fn(c_int, *mut c_int, *mut c_int) -> c_int,
        image_ready: b"POAImageReady\0" => unsafe extern "C" fn(c_int, *mut POABool) -> c_int,
    },
    // SDK metadata. Older camera SDK builds may not export this.
    optional_symbols: {
        get_sdk_version: b"POAGetSDKVersion\0" => unsafe extern "C" fn() -> *const c_char,
        // Per-control min/max/default. Optional so an SDK build that predates it
        // still loads and drives cameras; callers report unknown bounds instead.
        get_config_attributes_by_config_id: b"POAGetConfigAttributesByConfigID\0" => unsafe extern "C" fn(c_int, c_int, *mut POAConfigAttributes) -> c_int,
        // Sensor modes (such as a low-noise mode). Optional for SDK builds before them.
        get_sensor_mode_count: b"POAGetSensorModeCount\0" => unsafe extern "C" fn(c_int, *mut c_int) -> c_int,
        get_sensor_mode_info: b"POAGetSensorModeInfo\0" => unsafe extern "C" fn(c_int, c_int, *mut POASensorModeInfo) -> c_int,
        get_sensor_mode: b"POAGetSensorMode\0" => unsafe extern "C" fn(c_int, *mut c_int) -> c_int,
        set_sensor_mode: b"POASetSensorMode\0" => unsafe extern "C" fn(c_int, c_int) -> c_int,
    }
}

crate::load_vendor_sdk! {
    /// Player One Phoenix filter-wheel SDK wrapper.
    vendor_name: "Player One Filter Wheel",
    sdk_struct: PoaPwSdk,
    sdk_static: POA_PW_SDK,
    candidate_paths_fn: poa_pw_candidate_paths,
    shared_lock: PLAYER_ONE_SDK_LOCK,
    symbols: {
        get_pw_count: b"POAGetPWCount\0" => unsafe extern "C" fn() -> c_int,
        get_pw_properties: b"POAGetPWProperties\0" => unsafe extern "C" fn(c_int, *mut PWProperties) -> c_int,
        get_pw_properties_by_handle: b"POAGetPWPropertiesByHandle\0" => unsafe extern "C" fn(c_int, *mut PWProperties) -> c_int,
        open_pw: b"POAOpenPW\0" => unsafe extern "C" fn(c_int) -> c_int,
        close_pw: b"POAClosePW\0" => unsafe extern "C" fn(c_int) -> c_int,
        get_current_position: b"POAGetCurrentPosition\0" => unsafe extern "C" fn(c_int, *mut c_int) -> c_int,
        goto_position: b"POAGotoPosition\0" => unsafe extern "C" fn(c_int, c_int) -> c_int,
        get_pw_state: b"POAGetPWState\0" => unsafe extern "C" fn(c_int, *mut c_int) -> c_int,
        get_filter_alias: b"POAGetPWFilterAlias\0" => unsafe extern "C" fn(c_int, c_int, *mut c_char, c_int) -> c_int,
        set_filter_alias: b"POASetPWFilterAlias\0" => unsafe extern "C" fn(c_int, c_int, *const c_char, c_int) -> c_int,
        get_sdk_version: b"POAGetPWSDKVer\0" => unsafe extern "C" fn() -> *const c_char,
    }
}

/// Check POA error and convert to DriverError with detailed error messages
pub(crate) fn check_poa_error(code: c_int, operation: &str) -> Result<(), DriverError> {
    match code {
        0 => Ok(()), // POA_OK
        1 => Err(DriverError::InvalidDevice(format!(
            "{}: Invalid camera index - camera may not exist",
            operation
        ))),
        2 => Err(DriverError::InvalidDevice(format!(
            "{}: Invalid camera ID - camera may have been disconnected",
            operation
        ))),
        3 => Err(DriverError::InvalidParameter(format!(
            "{}: Invalid config - control type not available",
            operation
        ))),
        4 => Err(DriverError::InvalidParameter(format!(
            "{}: Invalid argument - value out of range",
            operation
        ))),
        5 => Err(DriverError::NotConnected),
        6 => Err(DriverError::Disconnected),
        7 => Err(DriverError::InvalidParameter(format!(
            "{}: Value out of limit",
            operation
        ))),
        8 => Err(DriverError::SdkError(format!(
            "{}: Exposure failed - check camera connection",
            operation
        ))),
        9 => Err(DriverError::Timeout(format!(
            "{}: Operation timed out",
            operation
        ))),
        10 => Err(DriverError::InvalidParameter(format!(
            "{}: Buffer size too small",
            operation
        ))),
        // Codes 11-17 per PlayerOneCamera.h (POAErrors enum).
        11 => Err(DriverError::SdkError(format!(
            "{}: Camera is exposing - stop the exposure first",
            operation
        ))),
        12 => Err(DriverError::SdkError(format!(
            "{}: Invalid pointer (internal SDK argument error)",
            operation
        ))),
        13 => Err(DriverError::InvalidParameter(format!(
            "{}: Config is not writable",
            operation
        ))),
        14 => Err(DriverError::InvalidParameter(format!(
            "{}: Config is not readable",
            operation
        ))),
        15 => Err(DriverError::SdkError(format!(
            "{}: Access denied",
            operation
        ))),
        // POA_ERROR_OPERATION_FAILED: "operation failed, maybe the camera is
        // disconnected suddenly" — surface as a disconnect so recovery fires.
        16 => Err(DriverError::Disconnected),
        17 => Err(DriverError::SdkError(format!(
            "{}: Memory allocation failed",
            operation
        ))),
        _ => Err(DriverError::SdkError(format!(
            "{}: Unknown POA error code {}",
            operation, code
        ))),
    }
}

/// [`check_poa_error`] for a call on a camera that `connect` opened. The SDK
/// drops a camera that leaves the bus from its list, and every later call on
/// its ID answers POA_ERROR_INVALID_INDEX or POA_ERROR_INVALID_ID, so on an
/// open camera those two mean it was lost.
pub(crate) fn check_open_poa_error(code: c_int, operation: &str) -> Result<(), DriverError> {
    match code {
        1 | 2 => Err(DriverError::Disconnected),
        _ => check_poa_error(code, operation),
    }
}

/// [`check_poa_pw_error`] for a call on a wheel that `connect` opened; see
/// [`check_open_poa_error`].
pub(crate) fn check_open_poa_pw_error(code: c_int, operation: &str) -> Result<(), DriverError> {
    match code {
        1 | 2 => Err(DriverError::Disconnected),
        _ => check_poa_pw_error(code, operation),
    }
}

pub(crate) fn check_poa_pw_error(code: c_int, operation: &str) -> Result<(), DriverError> {
    match code {
        0 => Ok(()),
        1 => Err(DriverError::InvalidDevice(format!(
            "{}: invalid filter-wheel index",
            operation
        ))),
        2 => Err(DriverError::InvalidDevice(format!(
            "{}: invalid filter-wheel handle",
            operation
        ))),
        3 => Err(DriverError::InvalidParameter(format!(
            "{}: invalid filter-wheel argument",
            operation
        ))),
        4 => Err(DriverError::NotConnected),
        5 => Err(DriverError::Disconnected),
        6 => Err(DriverError::SdkError(format!(
            "{}: filter wheel is moving",
            operation
        ))),
        7 => Err(DriverError::InvalidParameter(format!(
            "{}: null output pointer rejected by Player One PW SDK",
            operation
        ))),
        8 => Err(DriverError::SdkError(format!(
            "{}: Player One filter wheel operation failed (sent commands too often, or unplugged)",
            operation
        ))),
        9 => Err(DriverError::SdkError(format!(
            "{}: Player One filter wheel firmware error (a filter may not line up with its slot); \
             power-cycle the wheel",
            operation
        ))),
        other => Err(DriverError::SdkError(format!(
            "{}: unknown Player One PW error code {}",
            operation, other
        ))),
    }
}

pub(crate) fn pw_cstr<const N: usize>(value: &[c_char; N]) -> String {
    safe_cstr_to_string(value.as_ptr(), N)
}

pub(crate) fn player_one_static_cstr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }

    // SAFETY: Player One version functions return static, NUL-terminated C strings
    // owned by the loaded SDK library.
    let value = unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .trim()
        .to_string();
    (!value.is_empty()).then_some(value)
}

pub(crate) fn pw_sdk_version_from_sdk(sdk: &PoaPwSdk) -> Option<String> {
    // SAFETY: POAGetPWSDKVer takes no arguments and returns a static C string.
    player_one_static_cstr(unsafe { (sdk.get_sdk_version)() })
        .map(|version| format!("Player One PW SDK v{version}"))
}

pub fn is_pw_sdk_available() -> bool {
    PoaPwSdk::is_available()
}

pub(crate) fn camera_sdk_version_from_sdk(sdk: &PoaSdk) -> Option<String> {
    let get_sdk_version = sdk.get_sdk_version?;
    // SAFETY: POAGetSDKVersion takes no arguments and returns a static C string.
    player_one_static_cstr(unsafe { get_sdk_version() })
        .map(|version| format!("Player One SDK v{version}"))
}
