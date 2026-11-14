//! Atik camera and filter-wheel discovery.

use super::*;

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

pub async fn discover_devices() -> Result<Vec<AtikDiscoveryInfo>, DriverError> {
    let sdk = match AtikSdk::installed() {
        Ok(sdk) => sdk,
        Err(_) => return Ok(Vec::new()),
    };
    let sdk = sdk.lock().await;
    let devices = list_cameras(&sdk);
    *discovered_camera_serials()
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = devices
        .iter()
        .filter_map(|d| Some((d.device_index, d.serial_number.clone()?)))
        .collect();
    Ok(devices)
}

/// Every camera in the SDK's device list. Never opens a camera, so a camera
/// another program holds is listed and left alone.
///
/// The caller holds the SDK lock.
pub(crate) fn list_cameras(sdk: &AtikSdk) -> Vec<AtikDiscoveryInfo> {
    let sdk_version = sdk_version_from_sdk(sdk);
    (0..sdk.device_count_now())
        .filter_map(|index| {
            let (name, serial_number) = camera_at(sdk, index)?;
            Some(AtikDiscoveryInfo {
                device_index: index,
                name,
                serial_number,
                sdk_version: sdk_version.clone(),
            })
        })
        .collect()
}

/// Discover connected Atik EFW filter wheels.
pub async fn discover_filter_wheels() -> Result<Vec<AtikFilterWheelDiscoveryInfo>, DriverError> {
    let loaded = match AtikSdk::installed() {
        Ok(sdk) => sdk,
        Err(_) => return Ok(Vec::new()),
    };
    // Unlocked on purpose: this only reads which optional entry points the
    // library exports. An SDK without the EFW API answers "no wheels" without
    // waiting behind a camera operation.
    if loaded.unlocked().efw().is_err() {
        tracing::debug!("Atik EFW discovery skipped: SDK lacks EFW API exports");
        return Ok(Vec::new());
    }
    let sdk = loaded.lock().await;
    let wheels = list_filter_wheels(&sdk)?;
    *discovered_efw_serials()
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = wheels
        .iter()
        .filter_map(|w| Some((w.device_index, w.serial_number.clone()?)))
        .collect();
    Ok(wheels)
}

/// Every external filter wheel the SDK lists.
///
/// The caller holds the SDK lock.
pub(crate) fn list_filter_wheels(
    sdk: &AtikSdk,
) -> Result<Vec<AtikFilterWheelDiscoveryInfo>, DriverError> {
    let efw = sdk.efw()?;
    let sdk_version = sdk_version_from_sdk(sdk);
    Ok((0..EFW_INDEX_LIMIT)
        .filter_map(|index| {
            let (efw_type, serial_number) = efw_at(&efw, index)?;
            Some(AtikFilterWheelDiscoveryInfo {
                device_index: index,
                name: atik_efw_type_name(efw_type),
                serial_number,
                sdk_version: sdk_version.clone(),
                efw_type,
            })
        })
        .collect())
}

pub fn is_sdk_available() -> bool {
    AtikSdk::is_available()
}

pub(crate) fn sdk_version_from_sdk(sdk: &AtikSdk) -> Option<String> {
    // SAFETY: ArtemisAPIVersion takes no arguments and returns a c_int; it is safe to
    // call without a device handle or the SDK mutex (the call is read-only and the SDK
    // documents it as version-query, not state-modifying).
    let version = unsafe { (sdk.api_version)() };
    (version > 0).then_some(format!("Atik SDK v{version}"))
}
