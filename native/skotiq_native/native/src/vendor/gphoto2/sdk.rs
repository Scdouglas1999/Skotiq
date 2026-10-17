//! libgphoto2 library loading and error mapping.

use super::*;

/// Candidate paths for libgphoto2, in search order.
pub(crate) fn gphoto2_candidate_paths() -> Vec<std::path::PathBuf> {
    let mut lib_paths: Vec<std::path::PathBuf> = Vec::new();

    if cfg!(target_os = "windows") {
        lib_paths.push(std::path::PathBuf::from("libgphoto2.dll"));
        lib_paths.push(std::path::PathBuf::from("gphoto2.dll"));
        // Common installation paths
        lib_paths.push(std::path::PathBuf::from(
            "C:\\Program Files\\libgphoto2\\bin\\libgphoto2.dll",
        ));
        lib_paths.push(std::path::PathBuf::from(
            "C:\\msys64\\mingw64\\bin\\libgphoto2.dll",
        ));

        if let Ok(exe_path) = std::env::current_exe() {
            if let Some(exe_dir) = exe_path.parent() {
                lib_paths.push(exe_dir.join("libgphoto2.dll"));
            }
        }
    } else if cfg!(target_os = "macos") {
        lib_paths = crate::vendor::sdk_loader::vendor_library_candidates(
            &["libgphoto2.dylib"],
            &[
                "/usr/local/lib/libgphoto2.dylib",
                "/opt/homebrew/lib/libgphoto2.dylib",
            ],
        );
        // Homebrew Cellar paths
        lib_paths.push(std::path::PathBuf::from(
            "/usr/local/opt/libgphoto2/lib/libgphoto2.dylib",
        ));
        lib_paths.push(std::path::PathBuf::from(
            "/opt/homebrew/opt/libgphoto2/lib/libgphoto2.dylib",
        ));
    } else {
        // Linux
        lib_paths = crate::vendor::sdk_loader::vendor_library_candidates(
            &["libgphoto2.so", "libgphoto2.so.6", "libgphoto2.so.2"],
            &[
                "/usr/lib/libgphoto2.so",
                "/usr/lib/x86_64-linux-gnu/libgphoto2.so",
                "/usr/lib/aarch64-linux-gnu/libgphoto2.so",
                "/usr/local/lib/libgphoto2.so",
                "/usr/lib64/libgphoto2.so",
            ],
        );
    }

    lib_paths
}

crate::load_vendor_sdk! {
    /// libgphoto2 SDK library wrapper
    vendor_name: "libgphoto2",
    sdk_struct: GPhoto2Sdk,
    sdk_static: GPHOTO2_SDK,
    candidate_paths_fn: gphoto2_candidate_paths,
    symbols: {
        context_new: b"gp_context_new\0" => unsafe extern "C" fn() -> *mut GPContext,
        context_unref: b"gp_context_unref\0" => unsafe extern "C" fn(*mut GPContext),
        camera_new: b"gp_camera_new\0" => unsafe extern "C" fn(*mut *mut GPCamera) -> c_int,
        camera_init: b"gp_camera_init\0" => unsafe extern "C" fn(*mut GPCamera, *mut GPContext) -> c_int,
        camera_exit: b"gp_camera_exit\0" => unsafe extern "C" fn(*mut GPCamera, *mut GPContext) -> c_int,
        camera_unref: b"gp_camera_unref\0" => unsafe extern "C" fn(*mut GPCamera) -> c_int,
        camera_free: b"gp_camera_free\0" => unsafe extern "C" fn(*mut GPCamera) -> c_int,
        camera_autodetect: b"gp_camera_autodetect\0" => unsafe extern "C" fn(*mut CameraList, *mut GPContext) -> c_int,
        camera_capture: b"gp_camera_capture\0" => unsafe extern "C" fn(*mut GPCamera, c_int, *mut CameraFilePath, *mut GPContext) -> c_int,
        camera_capture_preview: b"gp_camera_capture_preview\0" => unsafe extern "C" fn(*mut GPCamera, *mut CameraFile, *mut GPContext) -> c_int,
        camera_trigger_capture: b"gp_camera_trigger_capture\0" => unsafe extern "C" fn(*mut GPCamera, *mut GPContext) -> c_int,
        camera_wait_for_event: b"gp_camera_wait_for_event\0" => unsafe extern "C" fn( *mut GPCamera, c_int, *mut c_int, *mut *mut c_void, *mut GPContext, ) -> c_int,
        camera_file_get: b"gp_camera_file_get\0" => unsafe extern "C" fn( *mut GPCamera, *const c_char, *const c_char, c_int, *mut CameraFile, *mut GPContext, ) -> c_int,
        camera_file_delete: b"gp_camera_file_delete\0" => unsafe extern "C" fn(*mut GPCamera, *const c_char, *const c_char, *mut GPContext) -> c_int,
        file_new: b"gp_file_new\0" => unsafe extern "C" fn(*mut *mut CameraFile) -> c_int,
        file_unref: b"gp_file_unref\0" => unsafe extern "C" fn(*mut CameraFile) -> c_int,
        file_get_data_and_size: b"gp_file_get_data_and_size\0" => unsafe extern "C" fn(*mut CameraFile, *mut *const c_char, *mut u64) -> c_int,
        file_free: b"gp_file_free\0" => unsafe extern "C" fn(*mut CameraFile) -> c_int,
        list_new: b"gp_list_new\0" => unsafe extern "C" fn(*mut *mut CameraList) -> c_int,
        list_count: b"gp_list_count\0" => unsafe extern "C" fn(*mut CameraList) -> c_int,
        list_get_name: b"gp_list_get_name\0" => unsafe extern "C" fn(*mut CameraList, c_int, *mut *const c_char) -> c_int,
        list_get_value: b"gp_list_get_value\0" => unsafe extern "C" fn(*mut CameraList, c_int, *mut *const c_char) -> c_int,
        list_free: b"gp_list_free\0" => unsafe extern "C" fn(*mut CameraList) -> c_int,
        camera_get_config: b"gp_camera_get_config\0" => unsafe extern "C" fn(*mut GPCamera, *mut *mut CameraWidget, *mut GPContext) -> c_int,
        camera_set_config: b"gp_camera_set_config\0" => unsafe extern "C" fn(*mut GPCamera, *mut CameraWidget, *mut GPContext) -> c_int,
        widget_get_child_by_name: b"gp_widget_get_child_by_name\0" => unsafe extern "C" fn(*mut CameraWidget, *const c_char, *mut *mut CameraWidget) -> c_int,
        widget_get_type: b"gp_widget_get_type\0" => unsafe extern "C" fn(*mut CameraWidget, *mut c_int) -> c_int,
        widget_get_value: b"gp_widget_get_value\0" => unsafe extern "C" fn(*mut CameraWidget, *mut c_void) -> c_int,
        widget_set_value: b"gp_widget_set_value\0" => unsafe extern "C" fn(*mut CameraWidget, *const c_void) -> c_int,
        widget_count_choices: b"gp_widget_count_choices\0" => unsafe extern "C" fn(*mut CameraWidget) -> c_int,
        widget_get_choice: b"gp_widget_get_choice\0" => unsafe extern "C" fn(*mut CameraWidget, c_int, *mut *const c_char) -> c_int,
        widget_get_range: b"gp_widget_get_range\0" => unsafe extern "C" fn(*mut CameraWidget, *mut c_float, *mut c_float, *mut c_float) -> c_int,
        widget_free: b"gp_widget_free\0" => unsafe extern "C" fn(*mut CameraWidget) -> c_int,
        camera_get_abilities: b"gp_camera_get_abilities\0" => unsafe extern "C" fn(*mut GPCamera, *mut CameraAbilities) -> c_int,
        camera_get_summary: b"gp_camera_get_summary\0" => unsafe extern "C" fn(*mut GPCamera, *mut GPCameraText, *mut GPContext) -> c_int,
    },
    // Library metadata: absent from some distro builds, so never fatal.
    optional_symbols: {
        library_version: b"gp_library_version\0" => unsafe extern "C" fn(c_int) -> *const *const c_char,
    }
}

/// Camera text struct for summary
#[repr(C)]
#[derive(Clone)]
pub(crate) struct GPCameraText {
    pub(crate) text: [c_char; 32 * 1024],
}

impl Default for GPCameraText {
    fn default() -> Self {
        Self {
            text: [0; 32 * 1024],
        }
    }
}

/// Check gphoto2 error and convert to NativeError
pub(crate) fn check_gp_error(code: c_int, operation: &str) -> Result<(), NativeError> {
    if code >= GP_OK {
        return Ok(());
    }
    match code {
        GP_ERROR => Err(NativeError::SdkError(format!(
            "gPhoto2 {}: general error",
            operation
        ))),
        GP_ERROR_IO => Err(NativeError::SdkError(format!(
            "gPhoto2 {}: I/O error - camera may be disconnected or in use by another application",
            operation
        ))),
        GP_ERROR_NOT_SUPPORTED => Err(NativeError::NotSupported),
        GP_ERROR_CAMERA_BUSY => Err(NativeError::SdkError(format!(
            "gPhoto2 {}: camera busy - another operation is in progress",
            operation
        ))),
        GP_ERROR_MODEL_NOT_FOUND => Err(NativeError::DeviceNotFound(format!(
            "gPhoto2 {}: camera model not found",
            operation
        ))),
        _ => Err(NativeError::SdkError(format!(
            "gPhoto2 {}: error code {}",
            operation, code
        ))),
    }
}
