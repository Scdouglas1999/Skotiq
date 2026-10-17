//! Atik camera and filter-wheel discovery.

use super::*;

/// Discovered Atik camera info
#[derive(Debug, Clone)]
pub struct AtikDiscoveryInfo {
    pub device_index: i32,
    pub name: String,
    pub serial_number: Option<String>,
    pub sdk_version: Option<String>,
}

/// Discovered Atik standalone filter wheel info.
#[derive(Debug, Clone)]
pub struct AtikFilterWheelDiscoveryInfo {
    pub device_index: i32,
    pub name: String,
    pub serial_number: Option<String>,
    pub sdk_version: Option<String>,
    pub efw_type: i32,
}

/// Discover connected Atik cameras
pub async fn discover_devices() -> Result<Vec<AtikDiscoveryInfo>, NativeError> {
    let sdk = match get_sdk() {
        Ok(sdk) => sdk,
        Err(_) => return Ok(Vec::new()),
    };

    // Acquire global SDK mutex for thread safety
    let _lock = atik_mutex().lock().await;

    // Prefer ArtemisRefreshDevicesCount: it forces a synchronous re-enumeration,
    // so a camera that hasn't finished USB enumeration on a cold scan (the Atik
    // SDK can report 0 for a brief window right after the library loads) is picked
    // up on the FIRST scan instead of needing a manual rescan. Falls back to the
    // passive ArtemisDeviceCount on older SDKs. This is the correct fix over a
    // blanket retry-sleep, which would slow discovery for the common no-Atik case.
    let count = match sdk.refresh_devices_count {
        // SAFETY: atik_mutex is held (acquired above), so no other task is inside the
        // Artemis SDK for the duration of this call. ArtemisRefreshDevicesCount takes
        // no arguments and returns a c_int, so there is no pointer to invalidate, and
        // `sdk` is borrowed from the process-lifetime `SDK` OnceLock whose library is
        // never unloaded, keeping the function pointer valid.
        Some(refresh) => unsafe { refresh() },
        // SAFETY: identical to the refresh arm above — same held lock, same
        // never-unloaded library, and ArtemisDeviceCount takes no arguments either.
        None => unsafe { (sdk.device_count)() },
    };
    let sdk_version = sdk_version_from_sdk(sdk);
    let mut devices = Vec::new();
    let mut serials_by_index = HashMap::new();

    for i in 0..count {
        // SAFETY: atik_mutex held; `i` is in `0..count` returned by the SDK above, so it is a
        // valid device index per ArtemisDevicePresent's contract.
        let present = unsafe { (sdk.device_present)(i) };
        if present == 0 {
            continue;
        }

        // SAFETY: atik_mutex held; `i` is a valid device index (present == 1 verified above).
        let is_camera = unsafe { (sdk.device_is_camera)(i) };
        if is_camera == 0 {
            continue;
        }

        let mut name_buf = [0 as c_char; 100];
        // SAFETY: atik_mutex held; `i` is a valid device index; name_buf is a 100-byte stack
        // array and the SDK writes a NUL-terminated name into it (Atik SDK guarantees the
        // buffer is bounded by the name field width in ARTEMISPROPERTIES, 40 bytes).
        let name = if unsafe { (sdk.device_name)(i, name_buf.as_mut_ptr()) } != 0 {
            // SAFETY: name_buf is 100 bytes; ArtemisDeviceName guaranteed NUL-termination by
            // returning non-zero above.
            unsafe { CStr::from_ptr(name_buf.as_ptr()) }
                .to_string_lossy()
                .to_string()
        } else {
            format!("Atik Camera {}", i)
        };

        let mut serial_buf = [0 as c_char; 100];
        // SAFETY: atik_mutex held; `i` is a valid device index; serial_buf is a 100-byte stack
        // array — ArtemisDeviceSerial returns a NUL-terminated serial that fits in the buffer.
        let serial = if unsafe { (sdk.device_serial)(i, serial_buf.as_mut_ptr()) } != 0 {
            // SAFETY: serial_buf is 100 bytes; ArtemisDeviceSerial guaranteed NUL-termination
            // by returning non-zero above.
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

        if let Some(ref serial_number) = serial {
            serials_by_index.insert(i, serial_number.clone());
        }
        devices.push(AtikDiscoveryInfo {
            device_index: i,
            name,
            serial_number: serial,
            sdk_version: sdk_version.clone(),
        });
    }

    *discovered_camera_serials()
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = serials_by_index;

    Ok(devices)
}

/// Discover connected Atik EFW filter wheels.
pub async fn discover_filter_wheels() -> Result<Vec<AtikFilterWheelDiscoveryInfo>, NativeError> {
    let sdk = match get_sdk() {
        Ok(sdk) => sdk,
        Err(_) => return Ok(Vec::new()),
    };

    if require_efw_api(sdk).is_err() {
        tracing::debug!("Atik EFW discovery skipped: SDK lacks EFW API exports");
        return Ok(Vec::new());
    }

    let efw_is_present = sdk.efw_is_present.unwrap();
    let efw_get_device_details = sdk.efw_get_device_details.unwrap();
    let sdk_version = sdk_version_from_sdk(sdk);

    let _lock = atik_mutex().lock().await;

    // The Atik SDK exposes standalone EFW devices by index through
    // ArtemisEFWIsPresent/ArtemisEFWGetDeviceDetails; there is no separate
    // EFW count call, so use ArtemisDeviceCount as the bounded index space.
    // SAFETY: atik_mutex held; ArtemisDeviceCount takes no arguments and is
    // safe to call whenever the SDK library is loaded.
    let count = unsafe { (sdk.device_count)() };
    let mut devices = Vec::new();
    let mut serials_by_index = HashMap::new();

    for i in 0..count {
        // SAFETY: atik_mutex held; `i` is in the bounded SDK enumeration range.
        if unsafe { efw_is_present(i) } == 0 {
            continue;
        }

        let mut efw_type: c_int = 0;
        let mut serial_buf = [0 as c_char; 100];
        // SAFETY: atik_mutex held; `i` was reported present by ArtemisEFWIsPresent;
        // `efw_type` and `serial_buf` are valid out-pointers per AtikCameras.h.
        let result = unsafe { efw_get_device_details(i, &mut efw_type, serial_buf.as_mut_ptr()) };
        if result != ArtemisError::Ok as c_int {
            tracing::warn!(
                "Atik EFWGetDeviceDetails failed for index {}: {:?}",
                i,
                ArtemisError::from_i32(result)
            );
            continue;
        }

        let serial = {
            // SAFETY: Atik documents serialNumber as a char array of length 100 populated by
            // ArtemisEFWGetDeviceDetails on success.
            let s = unsafe { CStr::from_ptr(serial_buf.as_ptr()) }
                .to_string_lossy()
                .to_string();
            if s.is_empty() {
                None
            } else {
                Some(s)
            }
        };

        if let Some(ref serial_number) = serial {
            serials_by_index.insert(i, serial_number.clone());
        }
        devices.push(AtikFilterWheelDiscoveryInfo {
            device_index: i,
            name: atik_efw_type_name(efw_type),
            serial_number: serial,
            sdk_version: sdk_version.clone(),
            efw_type,
        });
    }

    *discovered_efw_serials()
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = serials_by_index;

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
            sdk_version_from_sdk(sdk).unwrap_or_else(|| "Atik SDK vunknown".to_string()),
        ),
        Err(e) => (false, format!("SDK not available: {}", e)),
    }
}

pub(crate) fn sdk_version_from_sdk(sdk: &AtikSdk) -> Option<String> {
    // SAFETY: ArtemisAPIVersion takes no arguments and returns a c_int; it is safe to
    // call without a device handle or the SDK mutex (the call is read-only and the SDK
    // documents it as version-query, not state-modifying).
    let version = unsafe { (sdk.api_version)() };
    (version > 0).then_some(format!("Atik SDK v{version}"))
}

pub fn sdk_version() -> Option<String> {
    get_sdk().ok().and_then(sdk_version_from_sdk)
}
