//! X SDK library loading, error mapping and helpers.

use super::*;

/// The one path the loader tries: the first XAPI.dll that exists (application
/// directory, X Acquire install, current directory), else a bare `XAPI.dll`
/// for the system search path. To use native Fujifilm drivers, install
/// Fujifilm X Acquire or place XAPI.dll in the application directory.
pub(crate) fn fujifilm_candidate_paths() -> Vec<PathBuf> {
    vec![find_sdk_path().unwrap_or_else(|| PathBuf::from("XAPI.dll"))]
}

/// Find the SDK DLL path
pub(crate) fn find_sdk_path() -> Option<PathBuf> {
    // Try executable directory first
    if let Ok(exe_path) = std::env::current_exe() {
        if let Some(exe_dir) = exe_path.parent() {
            let xapi_path = exe_dir.join("XAPI.dll");
            if xapi_path.exists() {
                return Some(xapi_path);
            }
        }
    }

    // Try X Acquire installation
    let x_acquire_paths = [
        PathBuf::from(r"C:\Program Files\Fujifilm\X Acquire\XAPI.dll"),
        PathBuf::from(r"C:\Program Files (x86)\Fujifilm\X Acquire\XAPI.dll"),
    ];
    for path in &x_acquire_paths {
        if path.exists() {
            return Some(path.clone());
        }
    }

    // Try current directory
    let current_dir = PathBuf::from("XAPI.dll");
    if current_dir.exists() {
        return Some(current_dir);
    }

    None
}

crate::load_vendor_sdk! {
    /// Fujifilm X Acquire SDK function table (XAPI.dll).
    vendor_name: "Fujifilm",
    sdk_struct: FujifilmSdk,
    sdk_static: FUJIFILM_SDK,
    candidate_paths_fn: fujifilm_candidate_paths,
    symbols: {
        init: b"XSDK_Init\0"
            => unsafe extern "C" fn(h_lib: *mut c_void) -> c_long,
        exit: b"XSDK_Exit\0"
            => unsafe extern "C" fn() -> c_long,
        detect: b"XSDK_Detect\0"
            => unsafe extern "C" fn(
                l_interface: c_long,
                p_interface: *mut c_char,
                p_device_name: *mut c_char,
                pl_count: *mut c_long,
            ) -> c_long,
        append: b"XSDK_Append\0"
            => unsafe extern "C" fn(
                l_interface: c_long,
                p_interface: *mut c_char,
                p_device_name: *mut c_char,
                pl_count: *mut c_long,
                p_camera_list: *mut XsdkCameraList,
            ) -> c_long,
        open_ex: b"XSDK_OpenEx\0"
            => unsafe extern "C" fn(
                p_device: *const c_char,
                ph_camera: *mut XsdkHandle,
                pl_camera_mode: *mut c_long,
                p_option: *mut c_void,
            ) -> c_long,
        close: b"XSDK_Close\0"
            => unsafe extern "C" fn(h_camera: XsdkHandle) -> c_long,
        get_error_number: b"XSDK_GetErrorNumber\0"
            => unsafe extern "C" fn(
                h_camera: XsdkHandle,
                pl_api_code: *mut c_long,
                pl_err_code: *mut c_long,
            ) -> c_long,
        get_device_info: b"XSDK_GetDeviceInfo\0"
            => unsafe extern "C" fn(
                h_camera: XsdkHandle,
                p_dev_info: *mut XsdkDeviceInformation,
            ) -> c_long,
        set_priority_mode: b"XSDK_SetPriorityMode\0"
            => unsafe extern "C" fn(h_camera: XsdkHandle, l_priority_mode: c_long) -> c_long,
        release: b"XSDK_Release\0"
            => unsafe extern "C" fn(
                h_camera: XsdkHandle,
                l_release_mode: c_long,
                pl_shot_opt: *mut c_long,
                pl_af_status: *mut c_long,
            ) -> c_long,
        read_image_info: b"XSDK_ReadImageInfo\0"
            => unsafe extern "C" fn(h_camera: XsdkHandle, p_img_info: *mut XsdkImageInformation) -> c_long,
        read_image: b"XSDK_ReadImage\0"
            => unsafe extern "C" fn(h_camera: XsdkHandle, p_data: *mut u8, l_data_size: c_ulong) -> c_long,
        delete_image: b"XSDK_DeleteImage\0"
            => unsafe extern "C" fn(h_camera: XsdkHandle) -> c_long,
        cap_shutter_speed: b"XSDK_CapShutterSpeed\0"
            => unsafe extern "C" fn(
                h_camera: XsdkHandle,
                pl_num: *mut c_long,
                pl_shutter_speed: *mut c_long,
                pl_bulb_capable: *mut c_long,
            ) -> c_long,
        set_shutter_speed: b"XSDK_SetShutterSpeed\0"
            => unsafe extern "C" fn(
                h_camera: XsdkHandle,
                l_shutter_speed: c_long,
                l_bulb: c_long,
            ) -> c_long,
        cap_sensitivity: b"XSDK_CapSensitivity\0"
            => unsafe extern "C" fn(
                h_camera: XsdkHandle,
                pl_num: *mut c_long,
                pl_sensitivity: *mut c_long,
            ) -> c_long,
        set_sensitivity: b"XSDK_SetSensitivity\0"
            => unsafe extern "C" fn(h_camera: XsdkHandle, l_sensitivity: c_long) -> c_long,
        get_sensitivity: b"XSDK_GetSensitivity\0"
            => unsafe extern "C" fn(h_camera: XsdkHandle, pl_sensitivity: *mut c_long) -> c_long,
        set_dynamic_range: b"XSDK_SetDynamicRange\0"
            => unsafe extern "C" fn(h_camera: XsdkHandle, l_dynamic_range: c_long) -> c_long,
        set_prop: b"XSDK_SetProp\0"
            => unsafe extern "C" fn(
                h_camera: XsdkHandle,
                l_api_code: c_long,
                l_api_param: c_long,
                ...
            ) -> c_long,
        get_prop: b"XSDK_GetProp\0"
            => unsafe extern "C" fn(
                h_camera: XsdkHandle,
                l_api_code: c_long,
                l_api_param: c_long,
                ...
            ) -> c_long,
    }
}

// Error handling

/// Map XSDK error codes to NativeError
pub(crate) fn check_xapi_error(h_camera: XsdkHandle, sdk: &FujifilmSdk) -> Result<(), NativeError> {
    let mut api_code: c_long = 0;
    let mut err_code: c_long = 0;
    // SAFETY: the caller passes the table it just called through (this function is called only after a failed SDK call); `h_camera` is either a valid handle returned by XSDK_OpenEx or `std::ptr::null_mut()` (which XSDK_GetErrorNumber tolerates per XAPI.h for retrieving last init error); `&mut api_code` and `&mut err_code` are valid stack out-pointers to c_long.
    unsafe { (sdk.get_error_number)(h_camera, &mut api_code, &mut err_code) };

    match err_code {
        XSDK_ERRCODE_NOERR => Ok(()),

        // Sequence/parameter errors
        XSDK_ERRCODE_SEQUENCE => Err(NativeError::SdkError("API call sequence error".into())),
        XSDK_ERRCODE_PARAM => Err(NativeError::InvalidParameter("Invalid parameter".into())),
        XSDK_ERRCODE_INVALID_CAMERA => Err(NativeError::NotConnected),

        // SDK/hardware errors
        XSDK_ERRCODE_LOADLIB => Ok(()), // Already initialized, recoverable
        XSDK_ERRCODE_UNSUPPORTED => Err(NativeError::NotSupported),
        XSDK_ERRCODE_BUSY => Err(NativeError::SdkError("Camera is busy".into())),
        XSDK_ERRCODE_AF_TIMEOUT => Err(NativeError::Timeout("Autofocus timeout".into())),
        XSDK_ERRCODE_SHOOT_ERROR => Err(NativeError::SdkError("Shooting error".into())),
        XSDK_ERRCODE_FRAME_FULL => Err(NativeError::SdkError("Camera buffer full".into())),
        XSDK_ERRCODE_STANDBY => Err(NativeError::SdkError("Camera in standby".into())),

        // Driver/model errors
        XSDK_ERRCODE_NODRIVER => Err(NativeError::SdkNotLoaded),
        XSDK_ERRCODE_NO_MODEL_MODULE => {
            Err(NativeError::SdkError("Model-specific DLL not found".into()))
        }
        XSDK_ERRCODE_API_NOTFOUND => Err(NativeError::NotSupported),
        XSDK_ERRCODE_API_MISMATCH => Err(NativeError::SdkError("API version mismatch".into())),
        XSDK_ERRCODE_INVALID_USBMODE => Err(NativeError::SdkError(
            "Camera not in correct USB mode".into(),
        )),
        XSDK_ERRCODE_FORCEMODE_BUSY => Err(NativeError::SdkError(
            "Force mode operation in progress".into(),
        )),
        XSDK_ERRCODE_RUNNING_OTHER_FUNCTION => {
            Err(NativeError::SdkError("Another operation running".into()))
        }

        // Communication errors
        XSDK_ERRCODE_COMMUNICATION => {
            Err(NativeError::SdkError("USB/WiFi communication error".into()))
        }
        XSDK_ERRCODE_TIMEOUT => Err(NativeError::Timeout("Operation timeout".into())),
        XSDK_ERRCODE_COMBINATION => Err(NativeError::InvalidParameter(
            "Invalid parameter combination".into(),
        )),
        XSDK_ERRCODE_WRITEERROR => Err(NativeError::SdkError("Write error".into())),
        XSDK_ERRCODE_CARDFULL => Err(NativeError::SdkError("Memory card full".into())),

        // Hardware/internal errors
        XSDK_ERRCODE_HARDWARE => Err(NativeError::SdkError("Camera hardware error".into())),
        XSDK_ERRCODE_INTERNAL => Err(NativeError::SdkError("Internal SDK error".into())),
        XSDK_ERRCODE_MEMFULL => Err(NativeError::SdkError("SDK memory allocation failed".into())),
        XSDK_ERRCODE_UNKNOWN => Err(NativeError::SdkError("Unknown error".into())),

        _ => Err(NativeError::SdkError(format!(
            "XAPI error: API=0x{:04X}, ERR=0x{:08X}",
            api_code, err_code
        ))),
    }
}

// Helper functions

/// Safely convert C string array to Rust String
pub(crate) fn cstr_to_string(arr: &[c_char; 256]) -> String {
    let bytes: Vec<u8> = arr
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u8)
        .collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

pub(crate) fn cstr_to_string_32(arr: &[c_char; 32]) -> String {
    let bytes: Vec<u8> = arr
        .iter()
        .take_while(|&&c| c != 0)
        .map(|&c| c as u8)
        .collect();
    String::from_utf8_lossy(&bytes).into_owned()
}
