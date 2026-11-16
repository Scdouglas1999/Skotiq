//! What the simulated camera and mount say they can do.

use crate::device_capabilities::types::MountCapabilities;
use skotiq_device::{CameraCapabilities, CameraDescription, SensorInfo};

/// The simulated camera `device_id` names: the guide camera, a DSLR that
/// shoots at ISO speeds, or the imaging camera with the traits it was given.
pub(crate) fn camera_description(device_id: &str) -> CameraDescription {
    use crate::simulator::camera::{
        is_sim_guide_camera, sim_camera_iso_speeds, sim_imaging_camera_traits, SIM_GUIDE_PIXEL_UM,
        SIM_GUIDE_SENSOR_H, SIM_GUIDE_SENSOR_W,
    };
    use crate::simulator::frame::{SIM_H, SIM_MAX_ADU, SIM_W};
    let sensor = |width: u32, height: u32, pixel_um: f64, bit_depth: u32| SensorInfo {
        width,
        height,
        pixel_size_x: pixel_um,
        pixel_size_y: pixel_um,
        max_adu: u32::from(SIM_MAX_ADU),
        bit_depth,
        ..Default::default()
    };
    if is_sim_guide_camera(device_id) {
        return CameraDescription {
            capabilities: CameraCapabilities {
                can_set_gain: true,
                can_set_offset: true,
                can_set_binning: true,
                can_subframe: true,
                max_bin_x: 2,
                max_bin_y: 2,
                ..Default::default()
            },
            sensor: sensor(
                SIM_GUIDE_SENSOR_W,
                SIM_GUIDE_SENSOR_H,
                SIM_GUIDE_PIXEL_UM,
                16,
            ),
            gain_range: Some((0, 100)),
            offset_range: Some((0, 255)),
            exposure_range: Some((0.001, 60.0)),
            can_abort_exposure: true,
            can_stop_exposure: true,
            ..Default::default()
        };
    }
    let iso_speeds = sim_camera_iso_speeds(device_id).to_vec();
    if !iso_speeds.is_empty() {
        return CameraDescription {
            capabilities: CameraCapabilities {
                can_set_gain: true,
                has_shutter: true,
                ..Default::default()
            },
            sensor: sensor(SIM_W as u32, SIM_H as u32, 3.76, 14),
            gain_range: iso_speeds
                .first()
                .zip(iso_speeds.last())
                .map(|(&lo, &hi)| (lo, hi)),
            iso_speeds,
            exposure_range: Some((0.001, 3600.0)),
            can_abort_exposure: true,
            ..Default::default()
        };
    }
    let traits = sim_imaging_camera_traits();
    let cooled = !traits.no_cooler;
    let gain = !traits.no_gain;
    CameraDescription {
        capabilities: CameraCapabilities {
            can_cool: cooled,
            can_set_gain: gain,
            can_set_offset: gain,
            can_set_binning: true,
            can_subframe: true,
            has_shutter: true,
            max_bin_x: 4,
            max_bin_y: 4,
            ..Default::default()
        },
        sensor: sensor(SIM_W as u32, SIM_H as u32, 3.76, 16),
        gain_range: gain.then_some((0, 600)),
        offset_range: gain.then_some((0, 255)),
        // A representative regulated-cooling range, so the setpoint UI and
        // its clamping path are exercised end to end.
        cooler_temp_range: cooled.then_some((-40.0, 40.0)),
        exposure_range: Some((0.001, 3600.0)),
        can_abort_exposure: true,
        can_stop_exposure: true,
        ..Default::default()
    }
}

/// The simulated mount.
pub(crate) fn mount_capabilities() -> MountCapabilities {
    MountCapabilities {
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
    }
}
