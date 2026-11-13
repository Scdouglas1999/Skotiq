use super::*;
#[cfg(windows)]
use crate::device::DeviceType;
#[cfg(windows)]
use skotiq_device::ascom::AscomDeviceType;

#[cfg(windows)]
pub(crate) fn normalize_ascom_capability_device_type(value: &str) -> Option<DeviceType> {
    let normalized = value
        .trim()
        .to_ascii_lowercase()
        .replace([' ', '-', '_'], "");
    // A driver may answer with the interface name (`ICameraV3`) or with
    // Skotiq's word for the kind.
    let name = normalized
        .strip_prefix('i')
        .unwrap_or(&normalized)
        .trim_end_matches(|c: char| c.is_ascii_digit())
        .trim_end_matches('v');
    match name {
        "mount" => Some(DeviceType::Mount),
        "weather" => Some(DeviceType::Weather),
        name => AscomDeviceType::from_name(name).map(|t| DeviceType::from(t.kind())),
    }
}

#[cfg(windows)]
pub(crate) fn classify_ascom_capability_device_type(prog_id: &str) -> Result<DeviceType, String> {
    let _ = skotiq_ascom::init_com();
    if let Ok(device) = skotiq_ascom::AscomDeviceConnection::new(prog_id) {
        if let Ok(device_type) =
            skotiq_ascom::com::ComDispatch::get::<String>(&device, "DeviceType")
        {
            if let Some(device_type) = normalize_ascom_capability_device_type(&device_type) {
                return Ok(device_type);
            }
        }
    }

    // Only a camera or a mount is read here (see `read_capabilities`).
    for (device_type, registry_type) in [
        (DeviceType::Camera, AscomDeviceType::Camera),
        (DeviceType::Mount, AscomDeviceType::Telescope),
    ] {
        if skotiq_ascom::discover_devices(registry_type)
            .iter()
            .any(|device| device.prog_id.eq_ignore_ascii_case(prog_id))
        {
            return Ok(device_type);
        }
    }

    Err(format!(
        "Could not determine ASCOM device type for ProgID '{}': DeviceType property was unavailable and the ProgID was not found in ASCOM driver registry",
        prog_id
    ))
}

/// Get capabilities for an ASCOM camera or mount (Windows only)
///
/// # Silent-fallback contract
///
/// ASCOM drivers raise `PropertyNotImplementedException` (HRESULT `0x80040400`)
/// when asked for an optional property they don't implement. The COM wrappers
/// in `skotiq_ascom` translate that to `Err`. Each `unwrap_or(false / 0)`
/// below therefore preserves the documented ASCOM "feature absent" semantics —
/// the per-site `// Why:` annotations cite the specific COM property each
/// fallback represents. Forwarding these errors as `?` would prevent the
/// connection dialog from ever populating for partially-conforming drivers.
#[cfg(windows)]
pub(crate) async fn get_ascom_capabilities(
    device_id: &str,
) -> Result<DeviceCapabilities, SkotiqError> {
    use crate::ascom_wrapper::camera::AscomCameraWrapper;
    use crate::ascom_wrapper::mount::AscomMountWrapper;

    let parsed = parse_device_id_cached(device_id)?;
    let prog_id = match &parsed.connection_info {
        crate::device_id::ConnectionInfo::Ascom { prog_id } => prog_id.clone(),
        _ => {
            return Err(SkotiqError::invalid_device_id(
                device_id,
                "Not an ASCOM device",
            ))
        }
    };

    let device_type = classify_ascom_capability_device_type(&prog_id)
        .map_err(|e| SkotiqError::not_supported(device_id, &e))?;

    if device_type == DeviceType::Camera {
        // Only an unconnected camera is probed with a COM object of its
        // own: a connected one answers through its handle
        // (`read_capabilities`), because many ASCOM local servers share
        // Connected state and disconnecting a second object disconnects (or
        // wedges) the live camera.
        let mut wrapper = AscomCameraWrapper::new(prog_id.clone())
            .map_err(|e| SkotiqError::connection_failed(device_id, e.to_string()))?;
        wrapper
            .connect()
            .await
            .map_err(|e| SkotiqError::connection_failed(device_id, format!("{:?}", e)))?;
        let ascom_caps = wrapper
            .get_capabilities()
            .await
            .map_err(|e| SkotiqError::hardware_error(device_id, format!("{:?}", e)))?;
        let _ = wrapper.disconnect().await;

        Ok(DeviceCapabilities::Camera(camera_capabilities_from_ascom(
            ascom_caps,
        )))
    } else if device_type == DeviceType::Mount {
        let mut wrapper = AscomMountWrapper::new(prog_id.clone())
            .map_err(|e| SkotiqError::connection_failed(device_id, e.to_string()))?;
        wrapper
            .connect()
            .await
            .map_err(|e| SkotiqError::connection_failed(device_id, format!("{:?}", e)))?;
        let ascom_caps = wrapper
            .get_capabilities()
            .await
            .map_err(|e| SkotiqError::hardware_error(device_id, format!("{:?}", e)))?;
        let _ = wrapper.disconnect().await;

        Ok(DeviceCapabilities::Mount(mount_capabilities_from_ascom(
            ascom_caps,
        )))
    } else {
        // The other types answer through their handle once connected
        // (`read_capabilities`); an id that reaches here was never registered.
        Err(SkotiqError::DeviceNotFound(device_id.to_string()))
    }
}
/// What an ASCOM camera's own capability read means for the app.
#[cfg(windows)]
pub(crate) fn camera_capabilities_from_ascom(
    ascom_caps: crate::ascom_wrapper::camera::AscomCameraCapabilities,
) -> CameraCapabilities {
    CameraCapabilities {
        max_width: ascom_caps.max_width,
        max_height: ascom_caps.max_height,
        bit_depth: ascom_caps.bit_depth,
        has_shutter: ascom_caps.has_shutter,
        can_set_ccd_temperature: ascom_caps.can_set_ccd_temperature,
        can_set_cooler: ascom_caps.has_cooler,
        can_get_cooler_power: ascom_caps.can_get_cooler_power,
        can_bin: ascom_caps.can_bin,
        max_bin_x: ascom_caps.max_bin_x,
        max_bin_y: ascom_caps.max_bin_y,
        can_abort_exposure: ascom_caps.can_abort_exposure,
        can_stop_exposure: ascom_caps.can_stop_exposure,
        pixel_size_x: ascom_caps.pixel_size_x,
        pixel_size_y: ascom_caps.pixel_size_y,
        is_color: ascom_caps.is_color,
        bayer_pattern: ascom_caps.bayer_pattern,
        sensor_type: ascom_caps.sensor_name,
        readout_modes: ascom_caps.readout_modes,
        can_set_gain: ascom_caps.controls.gain.is_present(),
        gain_min: ascom_caps.controls.gain.range().map(|(min, _)| min),
        gain_max: ascom_caps.controls.gain.range().map(|(_, max)| max),
        can_set_offset: ascom_caps.controls.offset.is_present(),
        offset_min: ascom_caps.controls.offset.range().map(|(min, _)| min),
        offset_max: ascom_caps.controls.offset.range().map(|(_, max)| max),
        can_asymmetric_bin: ascom_caps.can_asymmetric_bin,
        exposure_min: ascom_caps.exposure_min,
        exposure_max: ascom_caps.exposure_max,
        // Why: ASCOM ICameraV3 exposes SetCCDTemperature (the setpoint) but no
        // property bounding the achievable range, so the wrapper cannot report
        // one. None = "range unknown"; the UI shows the setpoint field unclamped.
        cooler_min_temp_c: None,
        cooler_max_temp_c: None,
        ..Default::default()
    }
}

/// What an ASCOM mount's own capability read means for the app.
#[cfg(windows)]
pub(crate) fn mount_capabilities_from_ascom(
    ascom_caps: crate::ascom_wrapper::mount::AscomMountCapabilities,
) -> MountCapabilities {
    MountCapabilities {
        can_slew: ascom_caps.can_slew,
        can_slew_async: ascom_caps.can_slew_async,
        can_sync: ascom_caps.can_sync,
        can_park: ascom_caps.can_park,
        can_unpark: ascom_caps.can_unpark,
        can_set_park: ascom_caps.can_set_park,
        can_pulse_guide: ascom_caps.can_pulse_guide,
        can_set_tracking: ascom_caps.can_set_tracking,
        can_find_home: ascom_caps.can_find_home,
        can_move_axis: ascom_caps.can_move_axis_primary || ascom_caps.can_move_axis_secondary,
        is_equatorial: ascom_caps.is_equatorial,
        axis_count: if ascom_caps.can_move_axis_secondary {
            2
        } else {
            1
        },
        // Why: ASCOM ITelescopeV3.PulseGuide accepts any non-negative duration
        // and the spec defines no min/max guide-pulse property, so the wrapper
        // cannot report a range. None = "range unknown" (no artificial clamp).
        min_pulse_guide_ms: None,
        max_pulse_guide_ms: None,
        ..Default::default()
    }
}

#[cfg(not(windows))]
pub(crate) async fn get_ascom_capabilities(
    device_id: &str,
) -> Result<DeviceCapabilities, SkotiqError> {
    Err(SkotiqError::not_supported(
        device_id,
        "ASCOM is only available on Windows",
    ))
}
