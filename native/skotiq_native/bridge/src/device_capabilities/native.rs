use super::*;

/// Get capabilities for a native SDK camera or mount
///
/// Native SDK devices (ZWO, QHY, PlayerOne, etc.) typically have well-defined
/// capabilities that can be queried from their SDK functions. This function
/// returns capability information based on the vendor and device type.
///
/// # Silent-fallback contract
///
/// Native vendor SDKs use their own `Result` types: failures here usually mean
/// "the SDK rejected the call because the camera/mount is mid-state-transition"
/// (e.g. querying `is_moving` while a homing routine is firing). The capability
/// struct is a SNAPSHOT — defaulting transient-state booleans to `false` and
/// missing-list queries to empty is acceptable because the equipment view
/// re-polls these values on a timer once the connection is established.
pub(crate) async fn get_native_capabilities(
    device_id: &str,
) -> Result<DeviceCapabilities, SkotiqError> {
    let mgr = crate::api::get_device_manager();

    // Look up the device in the device registry to determine its type
    let device_type = {
        let devices = mgr.devices.read().await;
        devices.get(device_id).map(|d| d.info.device_type.clone())
    };

    let device_type = device_type
        .ok_or_else(|| SkotiqError::hardware_error(device_id, "Device not found in registry"))?;

    match device_type {
        // A connected camera or mount answers through its handle
        // (`read_capabilities`); one that reaches here is not connected.
        crate::device::DeviceType::Camera => Err(SkotiqError::hardware_error(
            device_id,
            "Native camera not connected",
        )),
        crate::device::DeviceType::Mount => Err(SkotiqError::hardware_error(
            device_id,
            "Native mount not connected",
        )),
        _ => Err(SkotiqError::not_supported(
            device_id,
            &format!(
                "Native capabilities are unavailable for device type {:?}",
                device_type
            ),
        )),
    }
}
