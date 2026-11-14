//! Player One camera discovery.

use super::*;

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

pub fn is_sdk_available() -> bool {
    PoaSdk::is_available()
}

pub async fn discover_devices() -> Result<Vec<PlayerOneCameraInfo>, DriverError> {
    // An unavailable SDK means no cameras; otherwise hold the lock for the scan.
    let sdk = match PoaSdk::lock().await {
        Ok(sdk) => sdk,
        Err(_) => return Ok(Vec::new()),
    };
    let sdk_version = camera_sdk_version_from_sdk(&sdk);

    // SAFETY: POAGetCameraCount takes no arguments.
    let num_cameras = unsafe { (sdk.get_camera_count)() };

    let mut cameras = Vec::new();
    for i in 0..num_cameras {
        // SAFETY: POACameraProperties is `#[repr(C)]` and contains only POD fields — zero-initialization is well-defined before the SDK overwrites it.
        let mut info: POACameraProperties = unsafe { std::mem::zeroed() };
        // SAFETY: `i` is in the range [0, num_cameras) returned by POAGetCameraCount; `&mut info` is a valid stack out-pointer.
        let result = unsafe { (sdk.get_camera_properties)(i, &mut info) };

        if result == 0 {
            // Fixed-size fields; userCustomID holds up to 16 bytes with no room for a NUL.
            let text = |field: &[c_char]| safe_cstr_to_string(field.as_ptr(), field.len());
            let present = |value: String| (!value.trim().is_empty()).then_some(value);
            let name = text(&info.camera_model_name);
            let serial_number = present(text(&info.sn));
            let user_custom_id = present(text(&info.user_custom_id));

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
