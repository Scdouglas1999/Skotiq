//! The simulated devices behind their handles.

mod accessories;
mod camera;
mod filter_wheel;
mod focuser;
mod mount;

use crate::device::{DeviceInfo, DeviceType};
use crate::device_manager::handle::DeviceHandle;
use crate::simulator::camera::get_sim_camera_for;
use crate::simulator::cover_calibrator::get_sim_cover_calibrator;
use crate::simulator::driver::accessories::{
    SimCoverCalibrator, SimDome, SimRotator, SimSafetyMonitor, SimSwitch, SimWeather,
};
use crate::simulator::driver::camera::SimCamera;
use crate::simulator::driver::filter_wheel::SimFilterWheel;
use crate::simulator::driver::focuser::SimFocuser;
use crate::simulator::driver::mount::SimMount;
use crate::simulator::environment::{get_sim_dome, get_sim_safety_monitor, get_sim_weather};
use crate::simulator::filter_wheel::get_sim_filterwheel;
use crate::simulator::focuser::get_sim_focuser;
use crate::simulator::mount::get_sim_mount;
use crate::simulator::rotator::get_sim_rotator;
use crate::simulator::switch::get_sim_switch;
use std::sync::Arc;

/// The handle for a simulated device, `None` for the device types that have
/// no simulator. The handle of a simulator that is not connected refuses
/// every operation in the simulator's own words.
pub(crate) fn handle(info: &DeviceInfo) -> Option<DeviceHandle> {
    let device_id = info.id.clone();
    Some(match info.device_type {
        DeviceType::Camera => DeviceHandle::Camera(Arc::new(SimCamera::new(&device_id))),
        DeviceType::Mount => DeviceHandle::Mount(Arc::new(SimMount::new(&device_id))),
        DeviceType::Focuser => DeviceHandle::Focuser(Arc::new(SimFocuser {})),
        DeviceType::FilterWheel => DeviceHandle::FilterWheel(Arc::new(SimFilterWheel {})),
        DeviceType::Dome => DeviceHandle::Dome(Arc::new(SimDome { device_id })),
        DeviceType::Rotator => DeviceHandle::Rotator(Arc::new(SimRotator {})),
        DeviceType::Switch => DeviceHandle::Switch(Arc::new(SimSwitch)),
        DeviceType::Weather => DeviceHandle::Weather(Arc::new(SimWeather { device_id })),
        DeviceType::SafetyMonitor => {
            DeviceHandle::SafetyMonitor(Arc::new(SimSafetyMonitor { device_id }))
        }
        DeviceType::CoverCalibrator => DeviceHandle::CoverCalibrator(Arc::new(SimCoverCalibrator)),
        _ => return None,
    })
}

/// Opens the simulated device and returns its handle; `None` for a device
/// type with no simulator. Each handle's `disconnect` closes it again.
pub(crate) async fn connect(info: &DeviceInfo) -> Option<DeviceHandle> {
    let handle = handle(info)?;
    match info.device_type {
        DeviceType::Camera => get_sim_camera_for(&info.id).write().await.status.connected = true,
        DeviceType::Mount => get_sim_mount().write().await.status.connected = true,
        DeviceType::Focuser => get_sim_focuser().write().await.status.connected = true,
        DeviceType::FilterWheel => get_sim_filterwheel().write().await.status.connected = true,
        DeviceType::Rotator => get_sim_rotator().write().await.status.connected = true,
        DeviceType::Dome => get_sim_dome().write().await.status.connected = true,
        DeviceType::Weather => get_sim_weather().write().await.connected = true,
        DeviceType::SafetyMonitor => get_sim_safety_monitor().write().await.status.connected = true,
        DeviceType::Switch => get_sim_switch().write().await.connected = true,
        DeviceType::CoverCalibrator => get_sim_cover_calibrator().write().await.connected = true,
        DeviceType::Guider => {}
    }
    Some(handle)
}
