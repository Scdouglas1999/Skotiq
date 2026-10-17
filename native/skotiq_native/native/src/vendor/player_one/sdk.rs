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
            &["libPlayerOneCamera.so", "libPlayerOneCamera.so.1"],
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

crate::load_vendor_sdk! {
    /// POA SDK library wrapper
    vendor_name: "Player One Camera",
    sdk_struct: PoaSdk,
    sdk_static: POA_SDK,
    candidate_paths_fn: poa_camera_candidate_paths,
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
        set_image_size: b"POASetImageSize\0" => unsafe extern "C" fn(c_int, c_int, c_int) -> c_int,
        set_image_start_pos: b"POASetImageStartPos\0" => unsafe extern "C" fn(c_int, c_int, c_int) -> c_int,
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
    }
}

crate::load_vendor_sdk! {
    /// Player One Phoenix filter-wheel SDK wrapper.
    vendor_name: "Player One Filter Wheel",
    sdk_struct: PoaPwSdk,
    sdk_static: POA_PW_SDK,
    candidate_paths_fn: poa_pw_candidate_paths,
    symbols: {
        get_pw_count: b"POAGetPWCount\0" => unsafe extern "C" fn() -> c_int,
        get_pw_properties: b"POAGetPWProperties\0" => unsafe extern "C" fn(c_int, *mut PWProperties) -> c_int,
        get_pw_properties_by_handle: b"POAGetPWPropertiesByHandle\0" => unsafe extern "C" fn(c_int, *mut PWProperties) -> c_int,
        open_pw: b"POAOpenPW\0" => unsafe extern "C" fn(c_int) -> c_int,
        close_pw: b"POAClosePW\0" => unsafe extern "C" fn(c_int) -> c_int,
        get_current_position: b"POAGetCurrentPosition\0" => unsafe extern "C" fn(c_int, *mut c_int) -> c_int,
        goto_position: b"POAGotoPosition\0" => unsafe extern "C" fn(c_int, c_int) -> c_int,
        get_pw_state: b"POAGetPWState\0" => unsafe extern "C" fn(c_int, *mut PWState) -> c_int,
        get_filter_alias: b"POAGetPWFilterAlias\0" => unsafe extern "C" fn(c_int, c_int, *mut c_char, c_int) -> c_int,
        set_filter_alias: b"POASetPWFilterAlias\0" => unsafe extern "C" fn(c_int, c_int, *const c_char) -> c_int,
        get_sdk_version: b"POAGetPWSDKVer\0" => unsafe extern "C" fn() -> *const c_char,
    }
}

/// Full-scale ADU of the delivered pixel container for a Player One sensor of
/// `bit_depth` bits read out as [`POAImgFormat::Raw16`].
///
/// `POACameraProperties.bit_depth` is the **ADC precision**, not the container:
/// PlayerOneCamera.h documents the field as `int bitDepth; ///< ADC depth of
/// CMOS sensor`. The delivered sample range is documented separately, on the
/// output format itself:
///
/// ```text
/// POA_RAW8 = 0,   ///< 8bit raw data, 1 pixel 1 byte, value range[0, 255]
/// POA_RAW16,      ///< 16bit raw data, 1 pixel 2 bytes, value range[0, 65535]
/// ```
///
/// — `SDKs/PlayerOne/PlayerOne_Camera_SDK_Linux_V3.7.1/.../include/PlayerOneCamera.h:50-51`,
/// repeated verbatim in Player One's own C# and Python bindings
/// (`include/PlayerOneCameraDLL.cs:29-30`, `python/pyPOACamera.py:21-22`). The
/// sibling entries in that enum (`POA_RGB24`/`POA_MONO8`, "value range[0, 255]")
/// state literal sample ranges, so `[0, 65535]` is the RAW16 sample range and
/// not merely the width of the word. Player One exposes no sub-16-bit two-byte
/// format at all — `POAImgFormat` is only RAW8/RAW16/RGB24/MONO8 — so a 12-bit
/// sensor's only 16-bit path is RAW16, and its samples fill the 16-bit range.
///
/// [`crate::vendor::zwo`] carries the same rule, confirmed against an ASI1600MM
/// on the bench. This one rests on Player One's SDK documentation rather than a
/// measured frame.
///
/// `bit_depth >= 16` needs no shift. `bit_depth == 0` (or a nonsensical value)
/// means the SDK never populated the property; fall back to the container's own
/// ceiling rather than underflowing to 0, which would report "this camera cannot
/// produce any signal".
pub(crate) fn raw16_container_max_adu(bit_depth: u32) -> u32 {
    const CONTAINER_BITS: u32 = 16;
    const CONTAINER_MAX: u32 = u16::MAX as u32;
    if bit_depth == 0 || bit_depth >= CONTAINER_BITS {
        return CONTAINER_MAX;
    }
    (((1u32 << bit_depth) - 1) << (CONTAINER_BITS - bit_depth)) & CONTAINER_MAX
}

/// Check POA error and convert to NativeError with detailed error messages
pub(crate) fn check_poa_error(code: c_int, operation: &str) -> Result<(), NativeError> {
    match code {
        0 => Ok(()), // POA_OK
        1 => Err(NativeError::InvalidDevice(format!(
            "{}: Invalid camera index - camera may not exist",
            operation
        ))),
        2 => Err(NativeError::InvalidDevice(format!(
            "{}: Invalid camera ID - camera may have been disconnected",
            operation
        ))),
        3 => Err(NativeError::InvalidParameter(format!(
            "{}: Invalid config - control type not available",
            operation
        ))),
        4 => Err(NativeError::InvalidParameter(format!(
            "{}: Invalid argument - value out of range",
            operation
        ))),
        5 => Err(NativeError::NotConnected),
        6 => Err(NativeError::Disconnected),
        7 => Err(NativeError::InvalidParameter(format!(
            "{}: Value out of limit",
            operation
        ))),
        8 => Err(NativeError::SdkError(format!(
            "{}: Exposure failed - check camera connection",
            operation
        ))),
        9 => Err(NativeError::Timeout(format!(
            "{}: Operation timed out",
            operation
        ))),
        10 => Err(NativeError::InvalidParameter(format!(
            "{}: Buffer size too small",
            operation
        ))),
        // Codes 11-17 per PlayerOneCamera.h (POAErrors enum).
        11 => Err(NativeError::SdkError(format!(
            "{}: Camera is exposing - stop the exposure first",
            operation
        ))),
        12 => Err(NativeError::SdkError(format!(
            "{}: Invalid pointer (internal SDK argument error)",
            operation
        ))),
        13 => Err(NativeError::InvalidParameter(format!(
            "{}: Config is not writable",
            operation
        ))),
        14 => Err(NativeError::InvalidParameter(format!(
            "{}: Config is not readable",
            operation
        ))),
        15 => Err(NativeError::SdkError(format!(
            "{}: Access denied",
            operation
        ))),
        // POA_ERROR_OPERATION_FAILED: "operation failed, maybe the camera is
        // disconnected suddenly" — surface as a disconnect so recovery fires.
        16 => Err(NativeError::Disconnected),
        17 => Err(NativeError::SdkError(format!(
            "{}: Memory allocation failed",
            operation
        ))),
        _ => Err(NativeError::SdkError(format!(
            "{}: Unknown POA error code {}",
            operation, code
        ))),
    }
}

pub(crate) fn check_poa_pw_error(code: c_int, operation: &str) -> Result<(), NativeError> {
    match code {
        0 => Ok(()),
        1 => Err(NativeError::InvalidDevice(format!(
            "{}: invalid filter-wheel index",
            operation
        ))),
        2 => Err(NativeError::InvalidDevice(format!(
            "{}: invalid filter-wheel handle",
            operation
        ))),
        3 => Err(NativeError::InvalidParameter(format!(
            "{}: invalid filter-wheel argument",
            operation
        ))),
        4 => Err(NativeError::NotConnected),
        5 => Err(NativeError::Disconnected),
        6 => Err(NativeError::SdkError(format!(
            "{}: filter wheel is moving",
            operation
        ))),
        7 => Err(NativeError::InvalidParameter(format!(
            "{}: null output pointer rejected by Player One PW SDK",
            operation
        ))),
        8 => Err(NativeError::SdkError(format!(
            "{}: Player One PW operation failed",
            operation
        ))),
        9 => Err(NativeError::SdkError(format!(
            "{}: Player One PW firmware error",
            operation
        ))),
        other => Err(NativeError::SdkError(format!(
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

pub fn pw_sdk_version() -> Option<String> {
    PoaPwSdk::get().and_then(pw_sdk_version_from_sdk)
}

pub(crate) fn camera_sdk_version_from_sdk(sdk: &PoaSdk) -> Option<String> {
    let get_sdk_version = sdk.get_sdk_version?;
    // SAFETY: POAGetSDKVersion takes no arguments and returns a static C string.
    player_one_static_cstr(unsafe { get_sdk_version() })
        .map(|version| format!("Player One SDK v{version}"))
}
