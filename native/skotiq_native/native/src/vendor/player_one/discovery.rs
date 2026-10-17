//! Player One camera discovery.

use super::*;

/// Player One camera discovery info
pub struct PlayerOneCameraInfo {
    pub camera_id: i32,
    pub name: String,
    /// Serial number from POACameraProperties.sn
    pub serial_number: Option<String>,
    /// User custom ID (if set)
    pub user_custom_id: Option<String>,
    /// Player One camera SDK version reported by the loaded native library, when available
    pub sdk_version: Option<String>,
}

/// Check if Player One SDK is available
pub fn is_sdk_available() -> bool {
    PoaSdk::get().is_some()
}

/// Discover Player One cameras
pub async fn discover_devices() -> Result<Vec<PlayerOneCameraInfo>, NativeError> {
    let sdk = match PoaSdk::get() {
        Some(sdk) => sdk,
        None => return Ok(Vec::new()), // SDK not available, return empty
    };

    // Acquire mutex for SDK discovery operations
    let _lock = player_one_mutex().lock().await;
    let sdk_version = camera_sdk_version_from_sdk(sdk);

    // SAFETY: player_one_mutex held above (single-threaded SDK access); POAGetCameraCount takes no arguments.
    let num_cameras = unsafe { (sdk.get_camera_count)() };

    let mut cameras = Vec::new();
    for i in 0..num_cameras {
        // SAFETY: POACameraProperties is `#[repr(C)]` and contains only POD fields — zero-initialization is well-defined before the SDK overwrites it.
        let mut info: POACameraProperties = unsafe { std::mem::zeroed() };
        // SAFETY: player_one_mutex held; `i` is in the range [0, num_cameras) returned by POAGetCameraCount; `&mut info` is a valid stack out-pointer.
        let result = unsafe { (sdk.get_camera_properties)(i, &mut info) };

        if result == 0 {
            // SAFETY: result == 0 (POA_OK) means SDK populated `info`; camera_model_name is a 256-byte `[c_char; 256]` and POA SDK guarantees NUL-termination within the buffer per PlayerOneCamera.h.
            let name = unsafe {
                CStr::from_ptr(info.camera_model_name.as_ptr())
                    .to_string_lossy()
                    .to_string()
            };

            // Extract serial number
            // SAFETY: SDK populated `info` on success; `sn` is a 64-byte `[c_char; 64]` field with NUL-termination guarantee from POA SDK.
            let serial_number = unsafe {
                let sn = CStr::from_ptr(info.sn.as_ptr())
                    .to_string_lossy()
                    .to_string();
                if sn.is_empty() {
                    None
                } else {
                    Some(sn)
                }
            };

            // Extract user custom ID (if set by user)
            // SAFETY: SDK populated `info` on success; `user_custom_id` is a 16-byte `[c_char; 16]` field with NUL-termination guarantee from POA SDK.
            let user_custom_id = unsafe {
                let custom_id = CStr::from_ptr(info.user_custom_id.as_ptr())
                    .to_string_lossy()
                    .to_string();
                if custom_id.is_empty() {
                    None
                } else {
                    Some(custom_id)
                }
            };

            cameras.push(PlayerOneCameraInfo {
                camera_id: info.camera_id,
                name,
                serial_number,
                user_custom_id,
                sdk_version: sdk_version.clone(),
            });
        }
    }

    Ok(cameras)
}
