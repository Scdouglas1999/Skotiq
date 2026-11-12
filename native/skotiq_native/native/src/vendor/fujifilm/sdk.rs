//! X SDK library loading, error mapping and helpers.

use super::*;

/// The one path the loader tries: the first XAPI.dll that exists (application
/// directory, X Acquire install, current directory), else a bare `XAPI.dll`
/// for the system search path. To use native Fujifilm drivers, install
/// Fujifilm X Acquire or place XAPI.dll in the application directory.
pub(crate) fn fujifilm_candidate_paths() -> Vec<PathBuf> {
    vec![find_sdk_path().unwrap_or_else(|| PathBuf::from("XAPI.dll"))]
}

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
        get_buffer_capacity: b"XSDK_GetBufferCapacity\0"
            => unsafe extern "C" fn(
                h_camera: XsdkHandle,
                pl_shoot_frame_num: *mut c_long,
                pl_total_frame_num: *mut c_long,
            ) -> c_long,
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

/// The error for an SDK call on `h_camera` that did not return
/// `XSDK_COMPLETE`, from the SDK's last error number. `action` says what the
/// driver was doing, in the words the user sees.
pub(crate) fn sdk_error(h_camera: XsdkHandle, sdk: &FujifilmSdk, action: &str) -> DriverError {
    let (api_code, err_code) = last_error(h_camera, sdk);
    sdk_failure(action, api_code, err_code)
}

/// The SDK's last (API code, error number) for `h_camera`.
pub(crate) fn last_error(h_camera: XsdkHandle, sdk: &FujifilmSdk) -> (c_long, c_long) {
    let mut api_code: c_long = 0;
    let mut err_code: c_long = 0;
    // SAFETY: the caller passes the table it just called through (this function is called only after a failed SDK call); `h_camera` is either a valid handle returned by XSDK_OpenEx or `std::ptr::null_mut()` (which XSDK_GetErrorNumber tolerates per XAPI.h for retrieving last init error); `&mut api_code` and `&mut err_code` are valid stack out-pointers to c_long.
    unsafe { (sdk.get_error_number)(h_camera, &mut api_code, &mut err_code) };
    (api_code, err_code)
}

/// When `XSDK_Close` last returned. The Programming Reference (4.1.3.2,
/// IMPORTANT NOTICE) requires 600 ms after a close before the SDK is used
/// again; it is honored just before the next open, so a disconnect stays quick.
static LAST_CLOSE: std::sync::Mutex<Option<Instant>> = std::sync::Mutex::new(None);
const CLOSE_SETTLE: Duration = Duration::from_millis(600);

pub(crate) fn close_camera(h_camera: XsdkHandle, sdk: &FujifilmSdk) {
    // SAFETY: `h_camera` is a handle XSDK_OpenEx returned and nothing uses it after this call; XSDK_Close is the contractual release for XSDK_OpenEx per XAPI.h.
    unsafe { (sdk.close)(h_camera) };
    *LAST_CLOSE.lock().unwrap_or_else(|e| e.into_inner()) = Some(Instant::now());
}

pub(crate) fn wait_for_close_settle() {
    let closed = *LAST_CLOSE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(remaining) = closed.and_then(|at| CLOSE_SETTLE.checked_sub(at.elapsed())) {
        std::thread::sleep(remaining);
    }
}

/// Frames waiting in the camera's buffer, per `XSDK_GetBufferCapacity`.
pub(crate) fn frames_in_buffer(
    h_camera: XsdkHandle,
    sdk: &FujifilmSdk,
) -> Result<c_long, DriverError> {
    let mut shot: c_long = 0;
    let mut total: c_long = 0;
    // SAFETY: `h_camera` is the connected XSDK handle; both out-pointers are valid stack c_long locals.
    let result = unsafe { (sdk.get_buffer_capacity)(h_camera, &mut shot, &mut total) };
    if result != XSDK_COMPLETE {
        return Err(sdk_error(
            h_camera,
            sdk,
            "reading the camera's image buffer",
        ));
    }
    Ok(shot)
}

/// Delete every frame waiting in the camera's buffer (at most eight), so the
/// next download cannot return a frame from an earlier exposure. Returns how
/// many were deleted.
pub(crate) fn discard_buffered_frames(h_camera: XsdkHandle, sdk: &FujifilmSdk) -> usize {
    let mut discarded = 0;
    while discarded < 8 && frames_in_buffer(h_camera, sdk).is_ok_and(|n| n > 0) {
        // SAFETY: `h_camera` is the connected XSDK handle; XSDK_DeleteImage takes only the handle.
        if unsafe { (sdk.delete_image)(h_camera) } != XSDK_COMPLETE {
            break;
        }
        discarded += 1;
    }
    discarded
}

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
