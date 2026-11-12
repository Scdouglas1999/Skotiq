//! SVBony camera discovery and SDK status.

use super::*;

#[derive(Debug, Clone)]
pub struct SvbonyDiscoveryInfo {
    pub camera_id: i32,
    pub name: String,
    pub serial_number: Option<String>,
    pub sdk_version: Option<String>,
    pub discovery_index: usize,
}

pub async fn discover_devices() -> Result<Vec<SvbonyDiscoveryInfo>, DriverError> {
    // If SDK is not available, return empty list (not error)
    let sdk = match SvbonySdk::lock().await {
        Ok(sdk) => sdk,
        Err(_) => return Ok(Vec::new()),
    };
    let sdk_version = sdk_version_from_sdk(&sdk);
    Ok(listed_cameras(&sdk)
        .into_iter()
        .map(|listed| SvbonyDiscoveryInfo {
            camera_id: listed.camera_id,
            name: listed.name,
            serial_number: listed.serial_number,
            sdk_version: sdk_version.clone(),
            discovery_index: listed.index,
        })
        .collect())
}

/// A camera as SVBGetCameraInfo lists it.
#[derive(Debug, Clone)]
pub(crate) struct ListedCamera {
    /// Position in the SDK's list.
    pub(crate) index: usize,
    pub(crate) camera_id: i32,
    pub(crate) name: String,
    pub(crate) serial_number: Option<String>,
}

/// The cameras the SDK sees now, under a lock the caller holds.
/// SVBGetNumOfConnectedCameras is "the first API to be called"
/// (SVBCameraSDK.h); it also refreshes the list a later SVBOpenCamera looks
/// the CameraID up in.
pub(crate) fn listed_cameras(sdk: &SvbonySdk) -> Vec<ListedCamera> {
    // SAFETY: SVBGetNumOfConnectedCameras takes no arguments and returns a plain c_int count.
    let count = unsafe { (sdk.get_num_of_connected_cameras)() };
    let mut cameras = Vec::new();
    for i in 0..count {
        // SAFETY: SvbCameraInfo is `#[repr(C)]` and contains only POD fields (c_char arrays, c_int) — all valid bit-patterns. Zero-initialization is the well-defined empty state before the SDK overwrites it.
        let mut info: SvbCameraInfo = unsafe { std::mem::zeroed() };
        // SAFETY: `&mut info` is a valid stack out-pointer to a `#[repr(C)]` SvbCameraInfo; `i` is in [0, count) per the loop bound, which is the contract for SVBGetCameraInfo's index parameter.
        let result = unsafe { (sdk.get_camera_info)(&mut info, i) };
        if SvbError::from_i32(result) != SvbError::Success {
            continue;
        }
        let text = |field: &[c_char; 32]| {
            // The SDK NUL-terminates inside the 32 bytes; a full field is read
            // to its end rather than past it.
            let bytes: Vec<u8> = field
                .iter()
                .take_while(|&&c| c != 0)
                .map(|&c| c as u8)
                .collect();
            String::from_utf8_lossy(&bytes).trim().to_string()
        };
        let serial = text(&info.camera_sn);
        cameras.push(ListedCamera {
            // `i` is in [0, count) and count is a non-negative c_int.
            index: i as usize,
            camera_id: info.camera_id,
            name: text(&info.friendly_name),
            serial_number: (!serial.is_empty()).then_some(serial),
        });
    }
    cameras
}

pub fn is_sdk_available() -> bool {
    SvbonySdk::is_available()
}

/// Get SDK status for diagnostics
pub fn get_sdk_status() -> (bool, String) {
    match SvbonySdk::installed() {
        Ok(sdk) => (
            true,
            // Unlocked on purpose: SVBGetSDKVersion takes no arguments, returns a
            // pointer to a string compiled into the library and touches no camera,
            // and this synchronous status helper cannot wait for the lock.
            sdk_version_from_sdk(sdk.unlocked())
                .unwrap_or_else(|| "SVBony SDK vunknown".to_string()),
        ),
        Err(e) => (false, format!("SDK not available: {}", e)),
    }
}

pub(crate) fn sdk_version_from_sdk(sdk: &SvbonySdk) -> Option<String> {
    // SAFETY: SVBGetSDKVersion returns a pointer to a static, NUL-terminated C string baked into the SDK shared library (per SVBCameraSDK.h); the SDK library is never unloaded, so the pointer is valid for the program's lifetime. We explicitly null-check before reading.
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
