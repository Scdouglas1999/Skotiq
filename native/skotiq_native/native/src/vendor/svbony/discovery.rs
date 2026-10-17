//! SVBony camera discovery and SDK status.

use super::*;

/// Discovered SVBony camera info
#[derive(Debug, Clone)]
pub struct SvbonyDiscoveryInfo {
    pub camera_id: i32,
    pub name: String,
    pub serial_number: Option<String>,
    pub sdk_version: Option<String>,
    pub discovery_index: usize,
}

/// Discover connected SVBony cameras
pub async fn discover_devices() -> Result<Vec<SvbonyDiscoveryInfo>, NativeError> {
    // If SDK is not available, return empty list (not error)
    let sdk = match get_sdk() {
        Ok(sdk) => sdk,
        Err(_) => return Ok(Vec::new()),
    };

    // Acquire mutex for SDK discovery operations
    let _lock = svbony_mutex().lock().await;
    let sdk_version = sdk_version_from_sdk(sdk);

    // SAFETY: svbony_mutex held above (SVBony SDK is not thread-safe per module header); SVBGetNumOfConnectedCameras takes no arguments and returns a plain c_int count.
    let count = unsafe { (sdk.get_num_of_connected_cameras)() };

    let mut devices = Vec::new();
    for i in 0..count {
        // SAFETY: SvbCameraInfo is `#[repr(C)]` and contains only POD fields (c_char arrays, c_int) — all valid bit-patterns. Zero-initialization is the well-defined empty state before the SDK overwrites it.
        let mut info: SvbCameraInfo = unsafe { std::mem::zeroed() };
        // SAFETY: svbony_mutex held; `&mut info` is a valid stack out-pointer to a `#[repr(C)]` SvbCameraInfo; `i` is in [0, count) per the loop bound, which is the contract for SVBGetCameraInfo's index parameter.
        let result = unsafe { (sdk.get_camera_info)(&mut info, i) };
        if SvbError::from_i32(result) == SvbError::Success {
            // SAFETY: SVBGetCameraInfo populated `info.friendly_name` as a NUL-terminated C string inside a [c_char; 32] buffer per SVBCameraSDK.h; the pointer is valid for the duration of this `info` stack value and CStr::from_ptr reads up to the NUL.
            let name = unsafe { CStr::from_ptr(info.friendly_name.as_ptr()) }
                .to_string_lossy()
                .to_string();
            // SAFETY: SVBGetCameraInfo populated `info.camera_sn` as a NUL-terminated C string inside a [c_char; 32] buffer per SVBCameraSDK.h; the pointer is valid for the duration of this `info` stack value and CStr::from_ptr reads up to the NUL.
            let serial = unsafe { CStr::from_ptr(info.camera_sn.as_ptr()) }
                .to_string_lossy()
                .to_string();

            devices.push(SvbonyDiscoveryInfo {
                camera_id: info.camera_id,
                name,
                serial_number: if serial.is_empty() {
                    None
                } else {
                    Some(serial)
                },
                sdk_version: sdk_version.clone(),
                // Why: `i` ranges 0..count where count is c_int >= 0 (loop bound).
                // Negative would not enter the loop. `as usize` is widening with verified
                // non-negative value; total camera count tops out below double digits.
                discovery_index: i as usize,
            });
        }
    }
    Ok(devices)
}

/// Check if SDK is available
pub fn is_sdk_available() -> bool {
    get_sdk().is_ok()
}

/// Get SDK status for diagnostics
pub fn get_sdk_status() -> (bool, String) {
    match get_sdk() {
        Ok(sdk) => (
            true,
            sdk_version_from_sdk(sdk).unwrap_or_else(|| "SVBony SDK vunknown".to_string()),
        ),
        Err(e) => (false, format!("SDK not available: {}", e)),
    }
}

pub(crate) fn sdk_version_from_sdk(sdk: &SvbonySdk) -> Option<String> {
    // SAFETY: SVBGetSDKVersion returns a pointer to a static, NUL-terminated C string baked into the SDK shared library (per SVBCameraSDK.h); the SDK library is owned by SDK::OnceLock so the pointer is valid for the program's lifetime. We explicitly null-check before reading.
    let ptr = unsafe { (sdk.get_sdk_version)() };
    if ptr.is_null() {
        return None;
    }
    // SAFETY: ptr was just null-checked; the SDK returns a static NUL-terminated
    // version string that outlives this call.
    let version = unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .trim()
        .to_string();
    (!version.is_empty()).then_some(format!("SVBony SDK v{version}"))
}

pub fn sdk_version() -> Option<String> {
    get_sdk().ok().and_then(sdk_version_from_sdk)
}
