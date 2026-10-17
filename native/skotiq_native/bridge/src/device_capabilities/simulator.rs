use super::*;
use crate::device::DeviceType;
use crate::device_id::{ConnectionInfo, ParsedDeviceId};

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

/// Get capabilities for a simulator device.
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
        DeviceType::Camera => DeviceCapabilities::Camera(CameraCapabilities {
            max_width: crate::sim_frame::SIM_W as u32,
            max_height: crate::sim_frame::SIM_H as u32,
            bit_depth: 16,
            has_shutter: true,
            can_set_ccd_temperature: true,
            can_set_cooler: true,
            can_get_cooler_power: true,
            can_bin: true,
            max_bin_x: 4,
            max_bin_y: 4,
            can_asymmetric_bin: false,
            can_set_gain: true,
            gain_min: Some(0),
            gain_max: Some(600),
            can_set_offset: true,
            offset_min: Some(0),
            offset_max: Some(255),
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
            cooler_min_temp_c: Some(-40.0),
            cooler_max_temp_c: Some(40.0),
            ..Default::default()
        }),
        DeviceType::Mount => DeviceCapabilities::Mount(MountCapabilities {
            can_slew: true,
            can_slew_async: true,
            can_sync: true,
            can_park: true,
            can_unpark: true,
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
        DeviceType::Focuser => DeviceCapabilities::Focuser(FocuserCapabilities {
            max_position: 100000,
            max_increment: 50000,
            step_size: Some(1.0),
            absolute: true,
            temp_comp_available: true,
            can_halt: true,
            can_reverse: true,
            ..Default::default()
        }),
        DeviceType::FilterWheel => DeviceCapabilities::FilterWheel(FilterWheelCapabilities {
            position_count: 7,
            filter_names: vec![
                "L".into(),
                "R".into(),
                "G".into(),
                "B".into(),
                "Ha".into(),
                "OIII".into(),
                "SII".into(),
            ],
            focus_offsets: vec![0, 10, 20, 30, 100, 120, 140],
            can_set_filter_names: true,
            can_set_focus_offsets: true,
            ..Default::default()
        }),
        DeviceType::Rotator => DeviceCapabilities::Rotator(RotatorCapabilities {
            can_reverse: true,
            reverse: false,
            step_size: Some(0.1),
            is_moving: false,
            mechanical_position: Some(0.0),
            position: Some(0.0),
            can_move_absolute: true,
            can_halt: true,
            can_sync: true,
            // Simulator advertises the full mechanical sweep so the angle-range
            // UI and its clamping are exercised end-to-end.
            min_angle_deg: Some(0.0),
            max_angle_deg: Some(360.0),
        }),
        DeviceType::Dome => DeviceCapabilities::Dome(DomeCapabilities {
            can_set_azimuth: true,
            can_park: true,
            can_find_home: true,
            can_set_shutter: true,
            can_sync_azimuth: true,
            azimuth: Some(0.0),
            slewing: false,
            at_home: true,
            at_park: false,
            shutter_status: Some(ShutterStatus::Closed),
            can_slave: true,
            slaved: false,
            can_abort: true,
        }),
        DeviceType::CoverCalibrator => {
            DeviceCapabilities::CoverCalibrator(CoverCalibratorCapabilities {
                max_brightness: 255,
                cover_present: true,
                calibrator_present: true,
                cover_state: Some(CoverState::Closed),
                calibrator_state: Some(CalibratorState::Off),
                brightness: Some(0),
            })
        }
        DeviceType::Weather => DeviceCapabilities::Weather(WeatherCapabilities {
            has_cloud_cover: true,
            has_dew_point: true,
            has_humidity: true,
            has_pressure: true,
            has_rain_rate: true,
            has_sky_brightness: true,
            has_sky_quality: true,
            has_sky_temperature: true,
            has_seeing: true,
            has_temperature: true,
            has_wind_direction: true,
            has_wind_gust: true,
            has_wind_speed: true,
            average_period: Some(60.0),
        }),
        DeviceType::SafetyMonitor => {
            // Read the simulator's live state. A monitor that can only ever
            // answer SAFE means the unsafe-weather sweep — park, close, abort
            // the run — is never exercisable offline, and an unreachable
            // monitor reads unsafe so the safety layer fails closed.
            let monitor = crate::api::devices::simulation::get_sim_safety_monitor()
                .read()
                .await;
            let (is_safe, description) = if monitor.status.connected {
                (
                    monitor.status.is_safe,
                    if monitor.status.is_safe {
                        "Simulated conditions are safe"
                    } else {
                        "Simulated conditions are unsafe"
                    },
                )
            } else {
                (false, "Simulated safety monitor is not connected")
            };
            DeviceCapabilities::SafetyMonitor(SafetyMonitorCapabilities {
                is_safe,
                safety_description: Some(description.to_string()),
            })
        }
        DeviceType::Switch => DeviceCapabilities::Switch(SwitchCapabilities {
            switch_count: 4,
            switches: vec![
                SwitchInfo {
                    index: 0,
                    name: "Power Port 1".to_string(),
                    description: "12V power output".to_string(),
                    is_boolean: true,
                    min_value: 0.0,
                    max_value: 1.0,
                    step: 1.0,
                    can_write: true,
                    value: 0.0,
                },
                SwitchInfo {
                    index: 1,
                    name: "Power Port 2".to_string(),
                    description: "12V power output".to_string(),
                    is_boolean: true,
                    min_value: 0.0,
                    max_value: 1.0,
                    step: 1.0,
                    can_write: true,
                    value: 0.0,
                },
                SwitchInfo {
                    index: 2,
                    name: "Dew Heater A".to_string(),
                    description: "Variable dew heater".to_string(),
                    is_boolean: false,
                    min_value: 0.0,
                    max_value: 100.0,
                    step: 1.0,
                    can_write: true,
                    value: 0.0,
                },
                SwitchInfo {
                    index: 3,
                    name: "USB Hub".to_string(),
                    description: "USB hub power".to_string(),
                    is_boolean: true,
                    min_value: 0.0,
                    max_value: 1.0,
                    step: 1.0,
                    can_write: true,
                    value: 1.0,
                },
            ],
        }),
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
