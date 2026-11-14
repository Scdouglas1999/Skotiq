use crate::device::DeviceType;
use crate::device_capabilities::types::{
    CameraCapabilities, DeviceCapabilities, MountCapabilities,
};
use crate::device_id::{ConnectionInfo, ParsedDeviceId};
use crate::error::SkotiqError;

/// Resolve the device-type token carried by a parsed simulator id.
///
/// `ParsedDeviceId::parse` splits the legacy `sim_<type>_<instance>` form on
/// underscores, so a multi-word type arrives truncated to its first word
/// (`sim_safety_monitor_1` yields `safety`, `sim_cover_calibrator_1` yields
/// `cover`); the canonical `simulator:<type>` form carries the whole word.
/// Both spellings must resolve to the same type — matching on substrings of
/// the raw id instead let `sim_safety_monitor_1` and `sim_cover_calibrator_1`
/// miss every branch and be reported to the app as a default camera.
fn simulator_device_type(token: &str) -> Option<DeviceType> {
    match token {
        "camera" => Some(DeviceType::Camera),
        "mount" | "telescope" => Some(DeviceType::Mount),
        "focuser" => Some(DeviceType::Focuser),
        "filter" | "filterwheel" => Some(DeviceType::FilterWheel),
        "guider" => Some(DeviceType::Guider),
        "rotator" => Some(DeviceType::Rotator),
        "dome" => Some(DeviceType::Dome),
        "cover" | "covercalibrator" | "flatpanel" => Some(DeviceType::CoverCalibrator),
        "weather" | "observingconditions" => Some(DeviceType::Weather),
        "safety" | "safetymonitor" => Some(DeviceType::SafetyMonitor),
        "switch" => Some(DeviceType::Switch),
        _ => None,
    }
}

/// Get capabilities for a simulated camera or mount.
///
/// Dispatches on the device type the id parses to. A type this module does not
/// model is an error rather than a default: handing the app a camera stub for
/// a safety monitor gates the UI on the wrong capabilities and hides the
/// missing coverage.
pub(crate) async fn get_simulator_capabilities(
    parsed: &ParsedDeviceId,
) -> Result<DeviceCapabilities, SkotiqError> {
    let ConnectionInfo::Simulator {
        device_type: token, ..
    } = &parsed.connection_info
    else {
        return Err(SkotiqError::invalid_device_id(
            &parsed.raw_id,
            "simulator capabilities requested for a non-simulator device id",
        ));
    };

    let device_type = simulator_device_type(token).ok_or_else(|| {
        SkotiqError::invalid_device_id(
            &parsed.raw_id,
            format!("unrecognised simulator device type '{token}'"),
        )
    })?;

    let capabilities = match device_type {
        DeviceType::Camera if crate::simulator::camera::is_sim_guide_camera(&parsed.raw_id) => {
            use crate::simulator::camera::{
                SIM_GUIDE_PIXEL_UM, SIM_GUIDE_SENSOR_H, SIM_GUIDE_SENSOR_W,
            };
            DeviceCapabilities::Camera(CameraCapabilities {
                max_width: SIM_GUIDE_SENSOR_W,
                max_height: SIM_GUIDE_SENSOR_H,
                bit_depth: 16,
                has_shutter: false,
                can_bin: true,
                max_bin_x: 2,
                max_bin_y: 2,
                can_set_gain: true,
                gain_min: Some(0),
                gain_max: Some(100),
                can_set_offset: true,
                offset_min: Some(0),
                offset_max: Some(255),
                can_abort_exposure: true,
                can_stop_exposure: true,
                can_subframe: true,
                pixel_size_x: Some(SIM_GUIDE_PIXEL_UM),
                pixel_size_y: Some(SIM_GUIDE_PIXEL_UM),
                is_color: false,
                exposure_min: Some(0.001),
                exposure_max: Some(60.0),
                ..Default::default()
            })
        }
        DeviceType::Camera
            if !crate::simulator::camera::sim_camera_iso_speeds(&parsed.raw_id).is_empty() =>
        {
            let iso_speeds =
                crate::simulator::camera::sim_camera_iso_speeds(&parsed.raw_id).to_vec();
            DeviceCapabilities::Camera(CameraCapabilities {
                max_width: crate::simulator::frame::SIM_W as u32,
                max_height: crate::simulator::frame::SIM_H as u32,
                bit_depth: 14,
                has_shutter: true,
                can_set_gain: true,
                gain_min: iso_speeds.first().copied(),
                gain_max: iso_speeds.last().copied(),
                iso_speeds,
                can_abort_exposure: true,
                pixel_size_x: Some(3.76),
                pixel_size_y: Some(3.76),
                is_color: false,
                exposure_min: Some(0.001),
                exposure_max: Some(3600.0),
                ..Default::default()
            })
        }
        DeviceType::Camera => {
            let traits = crate::simulator::camera::sim_imaging_camera_traits();
            let cooled = !traits.no_cooler;
            let gain = !traits.no_gain;
            DeviceCapabilities::Camera(CameraCapabilities {
                max_width: crate::simulator::frame::SIM_W as u32,
                max_height: crate::simulator::frame::SIM_H as u32,
                bit_depth: 16,
                has_shutter: true,
                can_set_ccd_temperature: cooled,
                can_set_cooler: cooled,
                can_get_cooler_power: cooled,
                can_bin: true,
                max_bin_x: 4,
                max_bin_y: 4,
                can_asymmetric_bin: false,
                can_set_gain: gain,
                gain_min: gain.then_some(0),
                gain_max: gain.then_some(600),
                can_set_offset: gain,
                offset_min: gain.then_some(0),
                offset_max: gain.then_some(255),
                can_abort_exposure: true,
                can_stop_exposure: true,
                can_subframe: true,
                pixel_size_x: Some(3.76),
                pixel_size_y: Some(3.76),
                is_color: false,
                exposure_min: Some(0.001),
                exposure_max: Some(3600.0),
                // Simulator advertises a representative regulated-cooling range so
                // the setpoint UI and its clamping path are exercised end-to-end.
                cooler_min_temp_c: cooled.then_some(-40.0),
                cooler_max_temp_c: cooled.then_some(40.0),
                ..Default::default()
            })
        }
        DeviceType::Mount => DeviceCapabilities::Mount(MountCapabilities {
            can_slew: true,
            can_slew_async: true,
            can_sync: true,
            can_park: true,
            can_unpark: true,
            can_set_park: true,
            can_pulse_guide: true,
            can_set_tracking: true,
            is_equatorial: true,
            can_find_home: true,
            can_abort_slew: true,
            axis_count: 2,
            // Simulator advertises a representative pulse-guide duration range
            // (1 ms minimum tick to 8 s, the common INDI TIMED_GUIDE ceiling) so
            // the guide-pulse UI and its range validation are exercised.
            min_pulse_guide_ms: Some(1.0),
            max_pulse_guide_ms: Some(8000.0),
            ..Default::default()
        }),
        // These have a handle and answer through it once connected
        // (`read_capabilities`); an id that reaches here was never registered.
        DeviceType::Focuser
        | DeviceType::FilterWheel
        | DeviceType::Rotator
        | DeviceType::Dome
        | DeviceType::CoverCalibrator
        | DeviceType::Weather
        | DeviceType::SafetyMonitor
        | DeviceType::Switch => return Err(SkotiqError::DeviceNotFound(parsed.raw_id.clone())),
        // No `DeviceCapabilities` variant models a guider; say so rather than
        // answer with another device's capability set.
        DeviceType::Guider => {
            return Err(SkotiqError::not_supported(
                &parsed.raw_id,
                "capability reporting for simulated guiders",
            ))
        }
    };

    Ok(capabilities)
}
