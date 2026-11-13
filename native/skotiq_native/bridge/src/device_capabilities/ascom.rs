//! What an ASCOM camera's or mount's own capability read means for the app.

use crate::device_capabilities::types::{CameraCapabilities, MountCapabilities};

/// What an ASCOM camera's own capability read means for the app.
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
