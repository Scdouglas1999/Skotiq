//! X SDK library loading, error mapping and helpers.

use super::*;

/// Fujifilm SDK library wrapper
pub(crate) struct FujifilmSdk {
    #[allow(dead_code)]
    pub(crate) lib: libloading::Library,

    // Initialize/Finalize
    pub(crate) init: unsafe extern "C" fn(h_lib: *mut c_void) -> c_long,
    pub(crate) exit: unsafe extern "C" fn() -> c_long,

    // Enumeration
    pub(crate) detect: unsafe extern "C" fn(
        l_interface: c_long,
        p_interface: *mut c_char,
        p_device_name: *mut c_char,
        pl_count: *mut c_long,
    ) -> c_long,
    pub(crate) append: unsafe extern "C" fn(
        l_interface: c_long,
        p_interface: *mut c_char,
        p_device_name: *mut c_char,
        pl_count: *mut c_long,
        p_camera_list: *mut XsdkCameraList,
    ) -> c_long,

    // Session management
    pub(crate) open_ex: unsafe extern "C" fn(
        p_device: *const c_char,
        ph_camera: *mut XsdkHandle,
        pl_camera_mode: *mut c_long,
        p_option: *mut c_void,
    ) -> c_long,
    pub(crate) close: unsafe extern "C" fn(h_camera: XsdkHandle) -> c_long,

    // Basic functions
    pub(crate) get_error_number: unsafe extern "C" fn(
        h_camera: XsdkHandle,
        pl_api_code: *mut c_long,
        pl_err_code: *mut c_long,
    ) -> c_long,

    // Device Information
    pub(crate) get_device_info: unsafe extern "C" fn(
        h_camera: XsdkHandle,
        p_dev_info: *mut XsdkDeviceInformation,
    ) -> c_long,

    // Priority Mode
    pub(crate) set_priority_mode:
        unsafe extern "C" fn(h_camera: XsdkHandle, l_priority_mode: c_long) -> c_long,

    // Release Control
    pub(crate) release: unsafe extern "C" fn(
        h_camera: XsdkHandle,
        l_release_mode: c_long,
        pl_shot_opt: *mut c_long,
        pl_af_status: *mut c_long,
    ) -> c_long,

    // Image acquisition
    pub(crate) read_image_info:
        unsafe extern "C" fn(h_camera: XsdkHandle, p_img_info: *mut XsdkImageInformation) -> c_long,
    pub(crate) read_image:
        unsafe extern "C" fn(h_camera: XsdkHandle, p_data: *mut u8, l_data_size: c_ulong) -> c_long,
    pub(crate) delete_image: unsafe extern "C" fn(h_camera: XsdkHandle) -> c_long,

    // Exposure control
    pub(crate) cap_shutter_speed: unsafe extern "C" fn(
        h_camera: XsdkHandle,
        pl_num: *mut c_long,
        pl_shutter_speed: *mut c_long,
        pl_bulb_capable: *mut c_long,
    ) -> c_long,
    pub(crate) set_shutter_speed: unsafe extern "C" fn(
        h_camera: XsdkHandle,
        l_shutter_speed: c_long,
        l_bulb: c_long,
    ) -> c_long,
    pub(crate) cap_sensitivity: unsafe extern "C" fn(
        h_camera: XsdkHandle,
        pl_num: *mut c_long,
        pl_sensitivity: *mut c_long,
    ) -> c_long,
    pub(crate) set_sensitivity:
        unsafe extern "C" fn(h_camera: XsdkHandle, l_sensitivity: c_long) -> c_long,
    pub(crate) get_sensitivity:
        unsafe extern "C" fn(h_camera: XsdkHandle, pl_sensitivity: *mut c_long) -> c_long,
    pub(crate) set_dynamic_range:
        unsafe extern "C" fn(h_camera: XsdkHandle, l_dynamic_range: c_long) -> c_long,

    // Optional functions via XSDK_SetProp/XSDK_GetProp (lines 2390-2392)
    // These are varargs functions for live view, focus control, and other optional features
    pub(crate) set_prop: unsafe extern "C" fn(
        h_camera: XsdkHandle,
        l_api_code: c_long,
        l_api_param: c_long,
        ...
    ) -> c_long,
    pub(crate) get_prop: unsafe extern "C" fn(
        h_camera: XsdkHandle,
        l_api_code: c_long,
        l_api_param: c_long,
        ...
    ) -> c_long,
}

pub(crate) static FUJIFILM_SDK: OnceLock<Option<FujifilmSdk>> = OnceLock::new();

impl FujifilmSdk {
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

    /// Load the Fujifilm SDK library
    pub(crate) fn load() -> Option<Self> {
        let lib_path = Self::find_sdk_path().or_else(|| {
            // Last resort: try loading from system PATH
            Some(PathBuf::from("XAPI.dll"))
        })?;

        tracing::debug!("Trying to load Fujifilm SDK from: {:?}", lib_path);

        // SAFETY: libloading::Library::new performs platform dynamic loading; `lib_path` was resolved via find_sdk_path() or fell back to a constant "XAPI.dll" name. The loaded library is moved into the FujifilmSdk struct stored in a `static OnceLock` so its symbols remain valid for the program's lifetime.
        unsafe {
            match libloading::Library::new(&lib_path) {
                Ok(lib) => {
                    tracing::info!("Found Fujifilm SDK at: {:?}", lib_path);

                    // Helper to load and log function pointer failures
                    fn load_symbol<T: Copy>(
                        lib: &libloading::Library,
                        name: &[u8],
                        name_str: &str,
                    ) -> Option<T> {
                        // SAFETY: `name` is always a `b"...\0"` byte string literal (verified at call sites below) terminated with a NUL byte, satisfying libloading's contract; `T` is constrained to the C-ABI function-pointer type the caller declared at the call site — those types are defined in this module to match XAPI.h signatures (XSDK_Init, XSDK_OpenEx, ...). The returned `Symbol` is immediately deref-copied while the `&lib` borrow is live.
                        match unsafe { lib.get::<T>(name) } {
                            Ok(sym) => Some(*sym),
                            Err(e) => {
                                tracing::error!(
                                    "Failed to load Fujifilm function '{}': {}",
                                    name_str,
                                    e
                                );
                                None
                            }
                        }
                    }

                    let init = load_symbol(&lib, b"XSDK_Init\0", "XSDK_Init")?;
                    let exit = load_symbol(&lib, b"XSDK_Exit\0", "XSDK_Exit")?;
                    let detect = load_symbol(&lib, b"XSDK_Detect\0", "XSDK_Detect")?;
                    let append = load_symbol(&lib, b"XSDK_Append\0", "XSDK_Append")?;
                    let open_ex = load_symbol(&lib, b"XSDK_OpenEx\0", "XSDK_OpenEx")?;
                    let close = load_symbol(&lib, b"XSDK_Close\0", "XSDK_Close")?;
                    let get_error_number =
                        load_symbol(&lib, b"XSDK_GetErrorNumber\0", "XSDK_GetErrorNumber")?;
                    let get_device_info =
                        load_symbol(&lib, b"XSDK_GetDeviceInfo\0", "XSDK_GetDeviceInfo")?;
                    let set_priority_mode =
                        load_symbol(&lib, b"XSDK_SetPriorityMode\0", "XSDK_SetPriorityMode")?;
                    let release = load_symbol(&lib, b"XSDK_Release\0", "XSDK_Release")?;
                    let read_image_info =
                        load_symbol(&lib, b"XSDK_ReadImageInfo\0", "XSDK_ReadImageInfo")?;
                    let read_image = load_symbol(&lib, b"XSDK_ReadImage\0", "XSDK_ReadImage")?;
                    let delete_image =
                        load_symbol(&lib, b"XSDK_DeleteImage\0", "XSDK_DeleteImage")?;
                    let cap_shutter_speed =
                        load_symbol(&lib, b"XSDK_CapShutterSpeed\0", "XSDK_CapShutterSpeed")?;
                    let set_shutter_speed =
                        load_symbol(&lib, b"XSDK_SetShutterSpeed\0", "XSDK_SetShutterSpeed")?;
                    let cap_sensitivity =
                        load_symbol(&lib, b"XSDK_CapSensitivity\0", "XSDK_CapSensitivity")?;
                    let set_sensitivity =
                        load_symbol(&lib, b"XSDK_SetSensitivity\0", "XSDK_SetSensitivity")?;
                    let get_sensitivity =
                        load_symbol(&lib, b"XSDK_GetSensitivity\0", "XSDK_GetSensitivity")?;
                    let set_dynamic_range =
                        load_symbol(&lib, b"XSDK_SetDynamicRange\0", "XSDK_SetDynamicRange")?;
                    let set_prop = load_symbol(&lib, b"XSDK_SetProp\0", "XSDK_SetProp")?;
                    let get_prop = load_symbol(&lib, b"XSDK_GetProp\0", "XSDK_GetProp")?;

                    let sdk = Self {
                        lib,
                        init,
                        exit,
                        detect,
                        append,
                        open_ex,
                        close,
                        get_error_number,
                        get_device_info,
                        set_priority_mode,
                        release,
                        read_image_info,
                        read_image,
                        delete_image,
                        cap_shutter_speed,
                        set_shutter_speed,
                        cap_sensitivity,
                        set_sensitivity,
                        get_sensitivity,
                        set_dynamic_range,
                        set_prop,
                        get_prop,
                    };

                    tracing::info!("Successfully loaded all Fujifilm SDK functions");
                    return Some(sdk);
                }
                Err(e) => {
                    tracing::debug!("Fujifilm SDK not found at {:?}: {}", lib_path, e);
                }
            }
        }

        tracing::debug!("Fujifilm X Acquire SDK (XAPI.dll) not found. Native Fujifilm camera support unavailable.");
        tracing::debug!("To use native Fujifilm drivers, install the Fujifilm X Acquire SDK or place XAPI.dll in the application directory.");
        None
    }

    /// Get the global SDK instance
    pub(crate) fn get() -> Option<&'static FujifilmSdk> {
        FUJIFILM_SDK.get_or_init(Self::load).as_ref()
    }
}

// Error handling

/// Map XSDK error codes to NativeError
pub(crate) fn check_xapi_error(h_camera: XsdkHandle, sdk: &FujifilmSdk) -> Result<(), NativeError> {
    let mut api_code: c_long = 0;
    let mut err_code: c_long = 0;
    // SAFETY: caller already holds `fujifilm_mutex` (this function is called only after a failed SDK call inside a mutex-guarded section); `h_camera` is either a valid handle returned by XSDK_OpenEx or `std::ptr::null_mut()` (which XSDK_GetErrorNumber tolerates per XAPI.h for retrieving last init error); `&mut api_code` and `&mut err_code` are valid stack out-pointers to c_long.
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
