//! ASI camera SDK loading.

use super::*;

//
// Path search + library open + per-symbol resolution + OnceLock storage is
// delegated to the shared `vendor::sdk_loader` infrastructure via the
// `load_vendor_sdk!` macro. Adding a new ZWO SDK function pointer is now a
// single-line change in the `symbols: { ... }` block below.

use crate::load_vendor_sdk;
use crate::vendor::sdk_loader::vendor_library_candidates;
use std::path::PathBuf;

/// Build the ordered list of candidate paths for ASICamera2 (the ZWO camera SDK).
///
/// Windows has a richer search list because the SDK ships as a loose DLL that
/// users typically drop next to the executable or leave in the SDK installer's
/// default path. macOS/Linux rely on system library paths or the binary's
/// install prefix.
pub(crate) fn asi_candidate_paths() -> Vec<PathBuf> {
    let mut paths: Vec<PathBuf> = Vec::new();

    if cfg!(target_os = "windows") {
        paths.push(PathBuf::from("ASICamera2.dll"));
        paths.push(PathBuf::from(
            "C:\\Program Files\\ZWO\\ASI SDK\\lib\\x64\\ASICamera2.dll",
        ));
        paths.push(PathBuf::from(
            "C:\\Program Files (x86)\\ZWO\\ASI SDK\\lib\\x64\\ASICamera2.dll",
        ));

        if let Ok(exe_path) = std::env::current_exe() {
            if let Some(exe_dir) = exe_path.parent() {
                paths.push(exe_dir.join("ASICamera2.dll"));

                if let Some(parent) = exe_dir.parent() {
                    paths.push(parent.join("ASICamera2.dll"));
                    paths.push(
                        parent
                            .join("SDKs")
                            .join("ZWO")
                            .join("ASI_Camera_SDK")
                            .join("ASI_Windows_SDK_V1.40")
                            .join("ASI SDK")
                            .join("lib")
                            .join("x64")
                            .join("ASICamera2.dll"),
                    );
                }

                if let Some(grandparent) = exe_dir.parent().and_then(|p| p.parent()) {
                    paths.push(grandparent.join("ASICamera2.dll"));
                    paths.push(
                        grandparent
                            .join("SDKs")
                            .join("ZWO")
                            .join("ASI_Camera_SDK")
                            .join("ASI_Windows_SDK_V1.40")
                            .join("ASI SDK")
                            .join("lib")
                            .join("x64")
                            .join("ASICamera2.dll"),
                    );
                }
            }
        }
    } else if cfg!(target_os = "macos") {
        paths.push(PathBuf::from("libASICamera2.dylib"));
        paths.push(PathBuf::from("/usr/local/lib/libASICamera2.dylib"));
    } else {
        paths.extend(vendor_library_candidates(
            &["libASICamera2.so", "libASICamera2.so.1"],
            &[
                "/usr/lib/libASICamera2.so",
                "/usr/local/lib/libASICamera2.so",
            ],
        ));
    }

    paths
}

load_vendor_sdk! {
    /// ZWO ASI Camera SDK function-pointer table (ASICamera2.dll / libASICamera2.{so,dylib}).
    vendor_name: "ZWO ASI Camera",
    sdk_struct: AsiSdk,
    sdk_static: ASI_SDK,
    candidate_paths_fn: asi_candidate_paths,
    symbols: {
        get_num_cameras: b"ASIGetNumOfConnectedCameras\0"
            => unsafe extern "C" fn() -> c_int,
        // ASIGetCameraProperty(ASI_CAMERA_INFO *pASICameraInfo, int iCameraIndex)
        get_camera_property: b"ASIGetCameraProperty\0"
            => unsafe extern "C" fn(*mut ASICameraInfo, c_int) -> c_int,
        get_sdk_version: b"ASIGetSDKVersion\0"
            => unsafe extern "C" fn() -> *const c_char,
        open_camera: b"ASIOpenCamera\0"
            => unsafe extern "C" fn(c_int) -> c_int,
        init_camera: b"ASIInitCamera\0"
            => unsafe extern "C" fn(c_int) -> c_int,
        close_camera: b"ASICloseCamera\0"
            => unsafe extern "C" fn(c_int) -> c_int,
        get_control_value: b"ASIGetControlValue\0"
            => unsafe extern "C" fn(c_int, c_int, *mut c_long, *mut ASIBool) -> c_int,
        set_control_value: b"ASISetControlValue\0"
            => unsafe extern "C" fn(c_int, c_int, c_long, ASIBool) -> c_int,
        set_roi_format: b"ASISetROIFormat\0"
            => unsafe extern "C" fn(c_int, c_int, c_int, c_int, c_int) -> c_int,
        set_start_pos: b"ASISetStartPos\0"
            => unsafe extern "C" fn(c_int, c_int, c_int) -> c_int,
        get_roi_format: b"ASIGetROIFormat\0"
            => unsafe extern "C" fn(c_int, *mut c_int, *mut c_int, *mut c_int, *mut c_int) -> c_int,
        start_exposure: b"ASIStartExposure\0"
            => unsafe extern "C" fn(c_int, ASIBool) -> c_int,
        stop_exposure: b"ASIStopExposure\0"
            => unsafe extern "C" fn(c_int) -> c_int,
        get_exp_status: b"ASIGetExpStatus\0"
            => unsafe extern "C" fn(c_int, *mut c_int) -> c_int,
        get_data_after_exp: b"ASIGetDataAfterExp\0"
            => unsafe extern "C" fn(c_int, *mut c_uchar, c_long) -> c_int,
        get_num_controls: b"ASIGetNumOfControls\0"
            => unsafe extern "C" fn(c_int, *mut c_int) -> c_int,
        get_control_caps: b"ASIGetControlCaps\0"
            => unsafe extern "C" fn(c_int, c_int, *mut ASIControlCaps) -> c_int,
    }
}

/// Resolve `ASIGetSerialNumber` lazily and **optionally**.
///
/// Why this is not in the `load_vendor_sdk!` table above: every symbol declared
/// there is mandatory, and one unresolved entry makes the entire SDK fail to
/// load. `ASIGetSerialNumber` only appeared in ASI SDK v1.15, so listing it
/// would turn "your ASI SDK is a few years old" into "Skotiq cannot see any
/// ZWO camera at all". An absent symbol yields `None`, and callers fall back to
/// the model/geometry fingerprint.
pub(crate) fn asi_get_serial_number_fn() -> Option<AsiGetSerialNumberFn> {
    static RESOLVED: OnceLock<Option<AsiGetSerialNumberFn>> = OnceLock::new();
    *RESOLVED.get_or_init(|| {
        let sdk = AsiSdk::get()?;
        // SAFETY: the signature is hand-derived from ASICamera2.h
        // (`ASICAMERA_API ASI_ERROR_CODE ASIGetSerialNumber(int iCameraID, ASI_SN* pSN)`),
        // matching the policy the `load_vendor_sdk!` call site already applies
        // to every other ASI symbol. The returned pointer outlives this call
        // because `_library` is owned by the `AsiSdk` singleton, which lives in
        // a process-lifetime `OnceLock`.
        let symbol: libloading::Symbol<AsiGetSerialNumberFn> =
            unsafe { sdk._library.get(b"ASIGetSerialNumber\0").ok()? };
        Some(*symbol)
    })
}

/// Check ASI error and convert to NativeError with detailed messages
pub(crate) fn check_asi_error(code: c_int) -> Result<(), NativeError> {
    match code {
        0 => Ok(()),
        1 => Err(NativeError::InvalidDevice("ASI_ERROR_INVALID_INDEX: No camera connected or camera index out of bounds".to_string())),
        2 => Err(NativeError::InvalidDevice("ASI_ERROR_INVALID_ID: Invalid camera ID - camera may have been disconnected".to_string())),
        3 => Err(NativeError::SdkError("ASI_ERROR_INVALID_CONTROL_TYPE: Invalid control type".to_string())),
        4 => Err(NativeError::NotConnected),
        5 => Err(NativeError::Disconnected),
        6 => Err(NativeError::SdkError("ASI_ERROR_INVALID_PATH: Cannot find file path".to_string())),
        7 => Err(NativeError::SdkError("ASI_ERROR_INVALID_FILEFORMAT: Invalid file format".to_string())),
        8 => Err(NativeError::SdkError("ASI_ERROR_INVALID_SIZE: Invalid video format size".to_string())),
        9 => Err(NativeError::SdkError("ASI_ERROR_INVALID_IMGTYPE: Unsupported image format".to_string())),
        10 => Err(NativeError::SdkError("ASI_ERROR_OUTOF_BOUNDARY: Start position out of boundary".to_string())),
        11 => Err(NativeError::Timeout("ASI_ERROR_TIMEOUT: Operation timed out".to_string())),
        12 => Err(NativeError::SdkError("ASI_ERROR_INVALID_SEQUENCE: Invalid operation sequence - stop capture first".to_string())),
        13 => Err(NativeError::SdkError("ASI_ERROR_BUFFER_TOO_SMALL: Buffer size is too small".to_string())),
        14 => Err(NativeError::SdkError("ASI_ERROR_VIDEO_MODE_ACTIVE: Camera is in video mode - may be in use by another application".to_string())),
        15 => Err(NativeError::SdkError("ASI_ERROR_EXPOSURE_IN_PROGRESS: Exposure in progress".to_string())),
        16 => Err(NativeError::SdkError("ASI_ERROR_GENERAL_ERROR: General error - camera may be in use by another application (NINA, SharpCap, etc.)".to_string())),
        17 => Err(NativeError::SdkError("ASI_ERROR_INVALID_MODE: Invalid mode".to_string())),
        _ => Err(NativeError::SdkError(format!("Unknown ASI error code: {}", code))),
    }
}
