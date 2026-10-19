use super::*;

/// Get capabilities for a native SDK device
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
        crate::device::DeviceType::Camera => {
            let native_cameras = mgr.native_cameras.read().await;
            if let Some(camera) = native_cameras.get(device_id) {
                let native_caps = camera.capabilities();
                let sensor_info = camera.get_sensor_info();
                let gain_range = camera.get_gain_range().await.ok();
                let offset_range = camera.get_offset_range().await.ok();
                // Why: vendor SDK readout-mode enumeration is optional (only ZWO
                // and QHY expose multi-mode sensors). Empty vec → UI hides the
                // readout-mode selector, matching cameras that have a single
                // hard-coded mode.
                let readout_modes = camera.get_readout_modes().await.unwrap_or_default();
                let status = camera.get_status().await.ok();
                let cooler_power = status.as_ref().and_then(|s| s.cooler_power);
                // Why: the NativeCamera trait's get_cooler_temp_range default
                // returns Ok(None); only drivers that publish the achievable
                // regulated-cooling range (currently ZWO, via C2) override it.
                // `.ok().flatten()` collapses a transient SDK error to None
                // ("range unknown") — the equipment view re-probes on a timer,
                // and an unknown range simply leaves the setpoint field unclamped
                // rather than fabricating limits.
                let (cooler_min_temp_c, cooler_max_temp_c) = camera
                    .get_cooler_temp_range()
                    .await
                    .ok()
                    .flatten()
                    .map_or((None, None), |(min, max)| (Some(min), Some(max)));

                // Same contract as the cooler range: `None` means "this driver
                // does not publish the limits", never a guessed clamp. Without
                // these, `exposureMin`/`exposureMax` were always null, so no
                // client could validate an exposure before submitting it and an
                // out-of-range request failed deep in the SDK instead of being
                // refused up front. ZWO publishes them via ASIGetControlCaps.
                let (exposure_min, exposure_max) = camera
                    .get_exposure_range()
                    .await
                    .ok()
                    .flatten()
                    .map_or((None, None), |(min, max)| (Some(min), Some(max)));

                Ok(DeviceCapabilities::Camera(CameraCapabilities {
                    max_width: sensor_info.width,
                    max_height: sensor_info.height,
                    bit_depth: sensor_info.bit_depth,
                    has_shutter: native_caps.has_shutter,
                    can_set_ccd_temperature: native_caps.can_cool,
                    can_set_cooler: native_caps.can_cool,
                    can_get_cooler_power: cooler_power.is_some(),
                    can_bin: native_caps.can_set_binning,
                    max_bin_x: native_caps.max_bin_x,
                    max_bin_y: native_caps.max_bin_y,
                    can_set_gain: native_caps.can_set_gain,
                    gain_min: gain_range.map(|(min, _)| min),
                    gain_max: gain_range.map(|(_, max)| max),
                    can_set_offset: native_caps.can_set_offset,
                    offset_min: offset_range.map(|(min, _)| min),
                    offset_max: offset_range.map(|(_, max)| max),
                    can_abort_exposure: true,
                    can_subframe: native_caps.can_subframe,
                    pixel_size_x: Some(sensor_info.pixel_size_x),
                    pixel_size_y: Some(sensor_info.pixel_size_y),
                    is_color: sensor_info.color,
                    bayer_pattern: sensor_info.bayer_pattern.map(|bp| format!("{:?}", bp)),
                    readout_modes: readout_modes.into_iter().map(|m| m.name).collect(),
                    ccd_temperature: status.as_ref().and_then(|s| s.sensor_temp),
                    set_ccd_temperature: status.as_ref().and_then(|s| s.target_temp),
                    cooler_power,
                    cooler_on: status.as_ref().map(|s| s.cooler_on),
                    cooler_min_temp_c,
                    cooler_max_temp_c,
                    exposure_min,
                    exposure_max,
                    ..Default::default()
                }))
            } else {
                Err(SkotiqError::hardware_error(
                    device_id,
                    "Native camera not connected",
                ))
            }
        }
        crate::device::DeviceType::Mount => {
            let native_mounts = mgr.native_mounts.read().await;
            if let Some(mount) = native_mounts.get(device_id) {
                let tracking = mount.get_tracking().await.ok();
                let can_set_tracking = tracking.is_some();
                let can_park = mount.is_parked().await.is_ok();
                let can_abort_slew = mount.is_slewing().await.is_ok();
                Ok(DeviceCapabilities::Mount(MountCapabilities {
                    can_slew: true,
                    can_slew_async: true,
                    can_sync: true,
                    can_park,
                    can_unpark: can_park,
                    can_pulse_guide: true,
                    can_set_tracking,
                    can_abort_slew,
                    can_find_home: mount.can_find_home(),
                    can_set_park: mount.can_set_park(),
                    is_equatorial: true,
                    tracking,
                    axis_count: 2,
                    ..Default::default()
                }))
            } else {
                Err(SkotiqError::hardware_error(
                    device_id,
                    "Native mount not connected",
                ))
            }
        }
        crate::device::DeviceType::Focuser => {
            let native_focusers = mgr.native_focusers.read().await;
            if let Some(focuser) = native_focusers.get(device_id) {
                let position = focuser.get_position().await.ok();
                let temperature = focuser.get_temperature().await.ok().flatten();
                // Why: transient-state probe — if the focuser SDK is busy with
                // another command we treat the focuser as stationary in this
                // snapshot. The equipment poller re-reads on a 500 ms cadence,
                // so a false "stationary" reading self-corrects within a frame.
                let is_moving = focuser.is_moving().await.unwrap_or(false);
                Ok(DeviceCapabilities::Focuser(FocuserCapabilities {
                    max_position: focuser.get_max_position(),
                    step_size: Some(focuser.get_step_size()),
                    absolute: true,
                    position,
                    temperature,
                    is_moving,
                    can_halt: true,
                    ..Default::default()
                }))
            } else {
                Err(SkotiqError::hardware_error(
                    device_id,
                    "Native focuser not connected",
                ))
            }
        }
        crate::device::DeviceType::FilterWheel => {
            let native_fws = mgr.native_filter_wheels.read().await;
            if let Some(fw) = native_fws.get(device_id) {
                // Why: vendor SDKs that don't persist filter labels (e.g. ZWO
                // EFW) return an error here on first connect. Empty vec → UI
                // renders generic "Filter 1, Filter 2..." labels indexed off
                // `get_filter_count()`, which is sufficient for slot selection.
                let names = fw.get_filter_names().await.unwrap_or_default();
                let position = fw.get_position().await.ok().map(|p| p as i32);
                // Why: same transient-state contract as focuser is_moving above.
                let is_moving = fw.is_moving().await.unwrap_or(false);
                Ok(DeviceCapabilities::FilterWheel(FilterWheelCapabilities {
                    position_count: fw.get_filter_count(),
                    current_position: position,
                    filter_names: names,
                    is_moving,
                    // The `NativeFilterWheel` trait requires `set_filter_name`,
                    // so every native wheel can be renamed. Leaving this at the
                    // `Default::default()` `false` under-reported a working
                    // feature: on the live rig a real ZWO EFW advertised
                    // `canSetFilterNames: false`, yet
                    // `POST /api/filter-wheel/names` with
                    // ["L","R","G","B","Ha","OIII","SII","Dark"] returned 200 and
                    // both `/api/filter-wheel/names` and
                    // `/api/equipment/filter-wheel/status` served the new labels
                    // back. Any UI that gates its rename control on this flag
                    // hides a feature the hardware supports.
                    can_set_filter_names: true,
                    ..Default::default()
                }))
            } else {
                Err(SkotiqError::hardware_error(
                    device_id,
                    "Native filter wheel not connected",
                ))
            }
        }
        _ => Err(SkotiqError::not_supported(
            device_id,
            &format!(
                "Native capabilities are unavailable for device type {:?}",
                device_type
            ),
        )),
    }
}
