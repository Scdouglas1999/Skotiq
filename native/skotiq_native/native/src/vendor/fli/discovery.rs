//! FLI device discovery and SDK status.

use super::*;

/// Discovered FLI device info
#[derive(Debug, Clone)]
pub struct FliDiscoveryInfo {
    pub device_path: String,
    pub name: String,
    pub serial_number: Option<String>,
    pub sdk_version: Option<String>,
    pub device_type: FliDeviceType,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FliDeviceType {
    Camera,
    Focuser,
    FilterWheel,
}

/// Discover connected FLI cameras
pub async fn discover_cameras() -> Result<Vec<FliDiscoveryInfo>, NativeError> {
    discover_devices_by_type(FLIDEVICE_CAMERA, FliDeviceType::Camera).await
}

/// Discover connected FLI focusers
pub async fn discover_focusers() -> Result<Vec<FliDiscoveryInfo>, NativeError> {
    discover_devices_by_type(FLIDEVICE_FOCUSER, FliDeviceType::Focuser).await
}

/// Discover connected FLI filter wheels
pub async fn discover_filter_wheels() -> Result<Vec<FliDiscoveryInfo>, NativeError> {
    discover_devices_by_type(FLIDEVICE_FILTERWHEEL, FliDeviceType::FilterWheel).await
}

async fn discover_devices_by_type(
    device_flag: c_long,
    device_type: FliDeviceType,
) -> Result<Vec<FliDiscoveryInfo>, NativeError> {
    let sdk = match get_sdk() {
        Ok(sdk) => sdk,
        Err(_) => return Ok(Vec::new()),
    };

    // Acquire global SDK mutex for thread safety
    let _lock = fli_mutex().lock().await;

    let domain = FLIDOMAIN_USB | device_flag;
    let sdk_version = sdk_version_from_sdk(sdk);
    let mut devices = Vec::new();

    // Create device list
    // SAFETY: fli_mutex held above ensuring single-threaded SDK access; FLICreateList takes a pass-by-value c_long with no pointer arguments.
    let result = unsafe { (sdk.create_list)(domain) };
    if result != 0 {
        return Ok(Vec::new());
    }

    // Iterate through devices
    let mut dev_domain: c_long = 0;
    let mut filename = [0 as c_char; 256];
    let mut name_buf = [0 as c_char; 256];

    // Get first device
    // SAFETY: fli_mutex held; all four out-pointers point to stack buffers (dev_domain c_long and 256-byte arrays); lengths are passed correctly so SDK can't overrun.
    let mut result = unsafe {
        (sdk.list_first)(
            &mut dev_domain,
            filename.as_mut_ptr(),
            filename.len(),
            name_buf.as_mut_ptr(),
            name_buf.len(),
        )
    };

    while result == 0 {
        // SAFETY: filename buffer is 256 bytes and FLI SDK guarantees NUL-termination within that buffer after a successful FLIListFirst/Next call (result == 0).
        let path = unsafe { CStr::from_ptr(filename.as_ptr()) }
            .to_string_lossy()
            .to_string();
        // SAFETY: name_buf is 256 bytes and FLI SDK guarantees NUL-termination within after a successful list call.
        let name = unsafe { CStr::from_ptr(name_buf.as_ptr()) }
            .to_string_lossy()
            .to_string();

        // Try to get serial number by opening device temporarily
        let serial = if !path.is_empty() {
            let path_cstr = CString::new(path.clone()).unwrap();
            let mut dev: FliDev = FLI_INVALID_DEVICE;

            // SAFETY: fli_mutex held; `dev` is a valid stack pointer; path_cstr is a valid NUL-terminated CString that outlives the call.
            if unsafe { (sdk.open)(&mut dev, path_cstr.as_ptr(), domain) } == 0 {
                let mut serial_buf = [0 as c_char; 64];
                // SAFETY: fli_mutex held; `dev` was successfully opened; serial_buf is a 64-byte stack buffer and the length is passed truthfully so the SDK can't overrun.
                let serial = if unsafe {
                    (sdk.get_serial_string)(dev, serial_buf.as_mut_ptr(), serial_buf.len())
                } == 0
                {
                    // SAFETY: serial_buf is 64 bytes and SDK guarantees NUL-termination on success.
                    let s = unsafe { CStr::from_ptr(serial_buf.as_ptr()) }
                        .to_string_lossy()
                        .to_string();
                    if s.is_empty() {
                        None
                    } else {
                        Some(s)
                    }
                } else {
                    None
                };
                // SAFETY: fli_mutex held; `dev` was just successfully opened. FLIClose pairs with FLIOpen.
                let _ = unsafe { (sdk.close)(dev) };
                serial
            } else {
                None
            }
        } else {
            None
        };

        devices.push(FliDiscoveryInfo {
            device_path: path,
            name,
            serial_number: serial,
            sdk_version: sdk_version.clone(),
            device_type,
        });

        // Get next device
        // SAFETY: fli_mutex held; same buffer-pointer invariants as FLIListFirst above.
        result = unsafe {
            (sdk.list_next)(
                &mut dev_domain,
                filename.as_mut_ptr(),
                filename.len(),
                name_buf.as_mut_ptr(),
                name_buf.len(),
            )
        };
    }

    // Clean up
    // SAFETY: fli_mutex held; FLIDeleteList takes no arguments and releases the SDK-internal list created by FLICreateList above.
    let _ = unsafe { (sdk.delete_list)() };

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
            sdk_version_from_sdk(sdk).unwrap_or_else(|| "FLI libfli (version unknown)".to_string()),
        ),
        Err(e) => (false, format!("SDK not available: {}", e)),
    }
}

pub(crate) fn sdk_version_from_sdk(sdk: &FliSdk) -> Option<String> {
    let mut version_buf = [0 as c_char; 64];
    // SAFETY: version_buf is a 64-byte stack array; the length is passed truthfully so the SDK can't overrun. FLIGetLibVersion has no device handle to validate.
    if unsafe { (sdk.get_lib_version)(version_buf.as_mut_ptr(), version_buf.len()) } != 0 {
        return None;
    }
    // SAFETY: version_buf is 64 bytes; FLI SDK guarantees NUL-termination on success.
    let version = unsafe { CStr::from_ptr(version_buf.as_ptr()) }
        .to_string_lossy()
        .trim()
        .to_string();
    (!version.is_empty()).then_some(format!("FLI libfli v{version}"))
}

pub fn sdk_version() -> Option<String> {
    get_sdk().ok().and_then(sdk_version_from_sdk)
}
