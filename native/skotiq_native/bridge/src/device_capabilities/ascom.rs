use super::*;
#[cfg(windows)]
use crate::device::DeviceType;

#[cfg(windows)]
pub(crate) fn normalize_ascom_capability_device_type(
    value: &str,
) -> Option<DeviceType> {
    let normalized = value
        .trim()
        .to_ascii_lowercase()
        .replace([' ', '-', '_'], "");
    match normalized.as_str() {
        "camera" | "icamera" | "icamerav2" | "icamerav3" | "icamerav4" => {
            Some(DeviceType::Camera)
        }
        "telescope" | "mount" | "itelescope" | "itelescopev2" | "itelescopev3" => {
            Some(DeviceType::Mount)
        }
        "focuser" | "ifocuser" | "ifocuserv2" | "ifocuserv3" => {
            Some(DeviceType::Focuser)
        }
        "filterwheel" | "ifilterwheel" | "ifilterwheelv2" => {
            Some(DeviceType::FilterWheel)
        }
        "rotator" | "irotator" | "irotatorv2" | "irotatorv3" => {
            Some(DeviceType::Rotator)
        }
        "dome" | "idome" | "idomev2" => Some(DeviceType::Dome),
        "safetymonitor" | "isafetymonitor" | "isafetymonitorv1" => {
            Some(DeviceType::SafetyMonitor)
        }
        "observingconditions" | "weather" | "iobservingconditions" => {
            Some(DeviceType::Weather)
        }
        "switch" | "iswitch" | "iswitchv2" => Some(DeviceType::Switch),
        "covercalibrator" | "icovercalibrator" | "icovercalibratorv1" => {
            Some(DeviceType::CoverCalibrator)
        }
        _ => None,
    }
}

#[cfg(windows)]
pub(crate) fn classify_ascom_capability_device_type(
    prog_id: &str,
) -> Result<DeviceType, String> {
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
        (DeviceType::Camera, skotiq_ascom::AscomDeviceType::Camera),
        (DeviceType::Mount, skotiq_ascom::AscomDeviceType::Telescope),
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
        // A second COM object for the same ProgID is not an independent
        // capability probe. Many ASCOM local servers share Connected state, so
        // disconnecting that probe also disconnects (or wedges) the live
        // camera. Query the DeviceManager's registered wrapper whenever the
        // camera is already connected.
        let live_wrapper = {
            let manager = crate::api::get_device_manager();
            manager.ascom_cameras.read().await.get(device_id).cloned()
        };
        let ascom_caps = if let Some(wrapper) = live_wrapper {
            wrapper
                .read()
                .await
                .get_capabilities()
                .await
                .map_err(|e| SkotiqError::hardware_error(device_id, format!("{:?}", e)))?
        } else {
            let mut wrapper = AscomCameraWrapper::new(prog_id.clone())
                .map_err(|e| SkotiqError::connection_failed(device_id, e.to_string()))?;
            wrapper
                .connect()
                .await
                .map_err(|e| SkotiqError::connection_failed(device_id, format!("{:?}", e)))?;
            let capabilities = wrapper
                .get_capabilities()
                .await
                .map_err(|e| SkotiqError::hardware_error(device_id, format!("{:?}", e)))?;
            let _ = wrapper.disconnect().await;
            capabilities
        };

        Ok(DeviceCapabilities::Camera(CameraCapabilities {
            max_width: ascom_caps.max_width,
            max_height: ascom_caps.max_height,
            bit_depth: ascom_caps.bit_depth,
            has_shutter: ascom_caps.has_shutter,
            can_set_ccd_temperature: ascom_caps.can_set_ccd_temperature,
            can_set_cooler: ascom_caps.can_set_ccd_temperature, // ASCOM doesn't distinguish
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
            // Why: ASCOM ICameraV3 exposes SetCCDTemperature (the setpoint) but no
            // property bounding the achievable range, so the wrapper cannot report
            // one. None = "range unknown"; the UI shows the setpoint field unclamped.
            cooler_min_temp_c: None,
            cooler_max_temp_c: None,
            ..Default::default()
        }))
    } else if device_type == DeviceType::Mount {
        let live_wrapper = {
            let manager = crate::api::get_device_manager();
            manager.ascom_mounts.read().await.get(device_id).cloned()
        };
        let ascom_caps = if let Some(wrapper) = live_wrapper {
            wrapper
                .read()
                .await
                .get_capabilities()
                .await
                .map_err(|e| SkotiqError::hardware_error(device_id, format!("{:?}", e)))?
        } else {
            let mut wrapper = AscomMountWrapper::new(prog_id.clone())
                .map_err(|e| SkotiqError::connection_failed(device_id, e.to_string()))?;
            wrapper
                .connect()
                .await
                .map_err(|e| SkotiqError::connection_failed(device_id, format!("{:?}", e)))?;
            let capabilities = wrapper
                .get_capabilities()
                .await
                .map_err(|e| SkotiqError::hardware_error(device_id, format!("{:?}", e)))?;
            let _ = wrapper.disconnect().await;
            capabilities
        };

        Ok(DeviceCapabilities::Mount(MountCapabilities {
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
        }))
    } else {
        // The other types answer through their handle once connected
        // (`read_capabilities`); an id that reaches here was never registered.
        Err(SkotiqError::DeviceNotFound(device_id.to_string()))
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
