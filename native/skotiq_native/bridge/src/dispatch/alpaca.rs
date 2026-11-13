//! Alpaca (HTTP) driver dispatch helpers.
//!
//! Methods in this module are additional impl blocks on `DeviceManager` and
//! provide Alpaca-only logic for `connect_*` and `perform_*_health_check`. They are invoked from the dispatcher methods in
//! `crate::device_manager`. No behavior or signature has changed relative to the
//! previous monolithic `devices.rs`.

use crate::device::*;
use crate::device_manager::handle::DeviceHandle;
use crate::device_manager::rig::ascom::{AscomFilterWheel, AscomFocuser};
use crate::device_manager::rig::camera::DriverCamera;
use crate::device_manager::rig::mount::DriverMount;
use crate::device_manager::DeviceManager;
use std::sync::Arc;

impl DeviceManager {
    pub(crate) async fn connect_alpaca(&self, info: &DeviceInfo) -> Result<(), String> {
        use crate::device_id::{parse_device_id_cached, ConnectionInfo};
        use skotiq_alpaca::*;

        let parsed = parse_device_id_cached(&info.id)
            .map_err(|e| format!("Invalid Alpaca device ID '{}': {}", info.id, e))?;

        let (base_url, device_number) = match parsed.connection_info {
            ConnectionInfo::Alpaca {
                base_url,
                device_num,
                ..
            } => (base_url, device_num),
            _ => {
                return Err(format!(
                    "Device ID '{}' is not an Alpaca device (got {:?})",
                    info.id, parsed.driver_type
                ));
            }
        };

        match info.device_type {
            DeviceType::Camera => {
                let camera = AlpacaCamera::from_server(&base_url, device_number);
                camera.connect().await.map_err(|e| e.to_string())?;
                self.handles.insert(
                    &info.id,
                    DeviceHandle::Camera(Arc::new(DriverCamera::alpaca(
                        &info.id,
                        skotiq_alpaca::AlpacaCameraDriver::new(camera),
                    ))),
                );
            }
            DeviceType::Mount => {
                let telescope = AlpacaTelescope::from_server(&base_url, device_number);
                telescope.connect().await.map_err(|e| e.to_string())?;
                self.record_declared_mount_frame(&info.id, telescope.equatorial_system().await)
                    .await;
                self.handles.insert(
                    &info.id,
                    DeviceHandle::Mount(Arc::new(DriverMount::alpaca(
                        &info.id,
                        skotiq_alpaca::AlpacaMount::new(telescope),
                    ))),
                );
            }
            DeviceType::Focuser => {
                let focuser = AlpacaFocuser::from_server(&base_url, device_number);
                focuser.connect().await.map_err(|e| e.to_string())?;
                let focuser = AscomFocuser::open(&info.id, focuser)
                    .await
                    .map_err(|e| e.to_string())?;
                self.handles
                    .insert(&info.id, DeviceHandle::Focuser(Arc::new(focuser)));
            }
            DeviceType::FilterWheel => {
                let fw = AlpacaFilterWheel::from_server(&base_url, device_number);
                fw.connect().await.map_err(|e| e.to_string())?;
                self.handles.insert(
                    &info.id,
                    DeviceHandle::FilterWheel(Arc::new(AscomFilterWheel::new(&info.id, fw))),
                );
            }
            DeviceType::Rotator => {
                let rotator = AlpacaRotator::from_server(&base_url, device_number);
                rotator.connect().await.map_err(|e| e.to_string())?;
                self.handles
                    .insert(&info.id, DeviceHandle::Rotator(Arc::new(rotator)));
            }
            DeviceType::Dome => {
                let dome = AlpacaDome::from_server(&base_url, device_number);
                dome.connect().await.map_err(|e| e.to_string())?;
                self.handles
                    .insert(&info.id, DeviceHandle::Dome(Arc::new(dome)));
            }
            DeviceType::Weather => {
                let weather = AlpacaObservingConditions::from_server(&base_url, device_number);
                weather.connect().await.map_err(|e| e.to_string())?;
                self.handles
                    .insert(&info.id, DeviceHandle::Weather(Arc::new(weather)));
            }
            DeviceType::SafetyMonitor => {
                let safety = AlpacaSafetyMonitor::from_server(&base_url, device_number);
                safety.connect().await.map_err(|e| e.to_string())?;
                self.handles
                    .insert(&info.id, DeviceHandle::SafetyMonitor(Arc::new(safety)));
            }
            DeviceType::Switch => {
                let switch = AlpacaSwitch::from_server(&base_url, device_number);
                switch.connect().await.map_err(|e| e.to_string())?;
                self.handles
                    .insert(&info.id, DeviceHandle::Switch(Arc::new(switch)));
            }
            DeviceType::CoverCalibrator => {
                let cover_cal = AlpacaCoverCalibrator::from_server(&base_url, device_number);
                cover_cal.connect().await.map_err(|e| e.to_string())?;
                self.handles
                    .insert(&info.id, DeviceHandle::CoverCalibrator(Arc::new(cover_cal)));
            }
            _ => {
                return Err(format!(
                    "Alpaca {} is not supported in this DeviceManager path",
                    info.device_type.as_str()
                ));
            }
        }

        Ok(())
    }
}
