//! A camera's or mount's description, as the driver gives it, in the shapes
//! the application reads. The same for every protocol.

use crate::device_capabilities::types::{CameraCapabilities, MountCapabilities};
use crate::device_manager::DeviceManager;
use skotiq_device::{CameraDescription, CameraStatus, MountDescription};

/// `status` adds the cooler's readings; a camera reports cooler power when
/// its status has a reading of it.
pub(crate) fn camera_capabilities(
    description: CameraDescription,
    status: Option<&CameraStatus>,
) -> CameraCapabilities {
    let CameraDescription {
        capabilities,
        sensor,
        gain_range,
        offset_range,
        iso_speeds,
        readout_modes,
        cooler_temp_range,
        exposure_range,
        can_abort_exposure,
        can_stop_exposure,
        can_asymmetric_bin,
        sensor_type,
    } = description;
    let cooler_power = status.and_then(|s| s.cooler_power);
    // A size of 0 is a driver that does not know it.
    let pixel_size = |microns: f64| (microns > 0.0).then_some(microns);
    CameraCapabilities {
        max_width: sensor.width,
        max_height: sensor.height,
        bit_depth: sensor.bit_depth,
        has_shutter: capabilities.has_shutter,
        can_set_ccd_temperature: capabilities.can_cool,
        can_set_cooler: capabilities.can_cool,
        can_get_cooler_power: cooler_power.is_some(),
        can_bin: capabilities.can_set_binning,
        max_bin_x: capabilities.max_bin_x,
        max_bin_y: capabilities.max_bin_y,
        can_asymmetric_bin,
        can_set_gain: capabilities.can_set_gain,
        gain_min: gain_range.map(|(min, _)| min),
        gain_max: gain_range.map(|(_, max)| max),
        iso_speeds,
        can_set_offset: capabilities.can_set_offset,
        offset_min: offset_range.map(|(min, _)| min),
        offset_max: offset_range.map(|(_, max)| max),
        can_abort_exposure,
        can_stop_exposure,
        can_subframe: capabilities.can_subframe,
        pixel_size_x: pixel_size(sensor.pixel_size_x),
        pixel_size_y: pixel_size(sensor.pixel_size_y),
        is_color: sensor.color,
        bayer_pattern: sensor.bayer_pattern.map(|pattern| format!("{:?}", pattern)),
        sensor_type,
        has_fast_readout: false,
        readout_modes: readout_modes.into_iter().map(|mode| mode.name).collect(),
        exposure_min: exposure_range.map(|(min, _)| min),
        exposure_max: exposure_range.map(|(_, max)| max),
        ccd_temperature: status.and_then(|s| s.sensor_temp),
        set_ccd_temperature: status.and_then(|s| s.target_temp),
        cooler_power,
        cooler_on: status.and_then(|s| s.cooler_on),
        cooler_min_temp_c: cooler_temp_range.map(|(min, _)| min),
        cooler_max_temp_c: cooler_temp_range.map(|(_, max)| max),
    }
}

/// `tracking` is whether the mount tracks now, when it says.
pub(crate) fn mount_capabilities(
    description: MountDescription,
    tracking: Option<bool>,
) -> MountCapabilities {
    let MountDescription {
        can_slew,
        can_slew_async,
        can_sync,
        can_park,
        can_unpark,
        can_set_park,
        can_find_home,
        can_pulse_guide,
        can_set_tracking,
        tracking_rates,
        can_get_side_of_pier,
        is_equatorial,
        supports_alt_az,
        can_abort_slew,
        can_move_axis,
        axis_count,
        max_slew_rate,
        min_pulse_guide_ms,
        max_pulse_guide_ms,
    } = description;
    MountCapabilities {
        can_slew,
        can_slew_async,
        can_sync,
        can_park,
        can_unpark,
        can_set_park,
        can_pulse_guide,
        can_get_side_of_pier,
        can_set_side_of_pier: false,
        can_set_tracking,
        can_set_tracking_rate: !tracking_rates.is_empty(),
        supported_tracking_rates: tracking_rates
            .into_iter()
            .map(DeviceManager::tracking_rate_from_native)
            .collect(),
        is_equatorial,
        supports_alt_az,
        can_get_pointing_state: false,
        can_find_home,
        tracking,
        tracking_rate: None,
        can_abort_slew,
        max_slew_rate,
        can_move_axis,
        axis_count,
        min_pulse_guide_ms,
        max_pulse_guide_ms,
    }
}
