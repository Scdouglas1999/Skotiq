//! ASCOM (Windows COM) driver dispatch helpers.
//!
//! Methods in this module are additional impl blocks on `DeviceManager` and
//! provide ASCOM-only logic for `connect_*` and `perform_*_health_check`. They are invoked from the dispatcher methods in
//! `crate::device_manager`.

use crate::device::DeviceInfo;
use crate::device_manager::DeviceManager;
// `DeviceDriver`: the ASCOM camera and mount wrappers implement `connect`
// through it. Interactive driver dialogs are decided next to the STA worker
// that also closes a rogue modal (headless never shows one).
#[cfg(windows)]
use {
    crate::ascom_wrapper::sta_worker::interactive_dialogs_allowed, crate::device::DeviceType,
    crate::device_manager::handle::DeviceHandle, skotiq_device::DeviceDriver, std::sync::Arc,
};

impl DeviceManager {
    #[cfg(windows)]
    pub(crate) async fn connect_ascom(&self, info: &DeviceInfo) -> Result<(), String> {
        let prog_id = info
            .id
            .strip_prefix("ascom:")
            .ok_or_else(|| "Invalid ASCOM device ID".to_string())?;

        match info.device_type {
            DeviceType::Camera => {
                use crate::ascom_wrapper::camera::AscomCameraWrapper;
                self.disconnect_previous_ascom_handle(&info.id, "camera ")
                    .await;
                let mut camera = AscomCameraWrapper::new(prog_id.to_string())?;
                // Let the operator pick the specific camera/config via the ASCOM
                // SetupDialog before connecting — but ONLY when one is present.
                // In headless mode the modal dialog has nobody to dismiss it and
                // would hang the connect forever (B1), so we skip it and rely on
                // the driver's saved configuration.
                if interactive_dialogs_allowed() {
                    camera.setup_dialog().await.map_err(|e| e.to_string())?;
                }
                camera.connect().await.map_err(|e| e.to_string())?;

                self.handles.insert(
                    &info.id,
                    DeviceHandle::Camera(Arc::new(
                        crate::device_manager::rig::camera::ComCamera::new(&info.id, camera),
                    )),
                );
            }
            DeviceType::Mount => {
                use crate::ascom_wrapper::mount::AscomMountWrapper;
                self.disconnect_previous_ascom_handle(&info.id, "mount ")
                    .await;
                let mut mount = AscomMountWrapper::new(prog_id.to_string())?;
                mount.connect().await.map_err(|e| e.to_string())?;
                self.record_declared_mount_frame(&info.id, mount.equatorial_system().await)
                    .await;

                self.handles.insert(
                    &info.id,
                    DeviceHandle::Mount(Arc::new(
                        crate::device_manager::rig::mount::ComMount::new(&info.id, mount),
                    )),
                );
            }
            DeviceType::Focuser => {
                use crate::ascom_wrapper::focuser::AscomFocuserWrapper;
                use crate::device_manager::rig::ascom::AscomFocuser;
                use crate::device_manager::rig::Exclusive;
                self.disconnect_previous_ascom_handle(&info.id, "focuser ")
                    .await;
                let focuser = AscomFocuserWrapper::new(prog_id.to_string())?;
                focuser.connect().await.map_err(|e| e.to_string())?;
                let focuser = AscomFocuser::open(&info.id, Exclusive::new(focuser))
                    .await
                    .map_err(|e| e.to_string())?;
                self.handles
                    .insert(&info.id, DeviceHandle::Focuser(Arc::new(focuser)));
            }
            DeviceType::FilterWheel => {
                use crate::ascom_wrapper::filterwheel::AscomFilterWheelWrapper;
                use crate::device_manager::rig::ascom::AscomFilterWheel;
                use crate::device_manager::rig::Exclusive;

                self.disconnect_previous_ascom_handle(&info.id, "filter wheel ")
                    .await;

                let fw = AscomFilterWheelWrapper::new(prog_id.to_string())?;
                fw.connect().await.map_err(|e| e.to_string())?;
                let fw = AscomFilterWheel::new(&info.id, Exclusive::new(fw));
                self.handles
                    .insert(&info.id, DeviceHandle::FilterWheel(Arc::new(fw)));
            }
            DeviceType::Rotator => {
                use crate::ascom_wrapper::rotator::AscomRotatorWrapper;
                self.disconnect_previous_ascom_handle(&info.id, "").await;
                let rotator = AscomRotatorWrapper::new(prog_id.to_string())?;
                rotator.connect().await?;
                self.handles
                    .insert(&info.id, DeviceHandle::Rotator(Arc::new(rotator)));
            }
            DeviceType::Dome => {
                use crate::ascom_wrapper::dome::AscomDomeWrapper;
                self.disconnect_previous_ascom_handle(&info.id, "").await;
                let dome = AscomDomeWrapper::new(prog_id.to_string())?;
                dome.connect().await?;
                self.handles
                    .insert(&info.id, DeviceHandle::Dome(Arc::new(dome)));
            }
            DeviceType::Switch => {
                use crate::ascom_wrapper::switch::AscomSwitchWrapper;
                self.disconnect_previous_ascom_handle(&info.id, "").await;
                let sw = AscomSwitchWrapper::new(prog_id.to_string())?;
                sw.connect().await?;
                self.handles
                    .insert(&info.id, DeviceHandle::Switch(Arc::new(sw)));
            }
            DeviceType::Weather => {
                use crate::ascom_wrapper::weather::AscomObservingConditionsWrapper;
                self.disconnect_previous_ascom_handle(&info.id, "").await;
                let weather = AscomObservingConditionsWrapper::new(prog_id.to_string())?;
                weather.connect().await?;
                self.handles
                    .insert(&info.id, DeviceHandle::Weather(Arc::new(weather)));
            }
            DeviceType::SafetyMonitor => {
                use crate::ascom_wrapper::safetymonitor::AscomSafetyMonitorWrapper;
                self.disconnect_previous_ascom_handle(&info.id, "").await;
                let safety = AscomSafetyMonitorWrapper::new(prog_id.to_string())?;
                safety.connect().await?;
                self.handles
                    .insert(&info.id, DeviceHandle::SafetyMonitor(Arc::new(safety)));
            }
            DeviceType::CoverCalibrator => {
                use crate::ascom_wrapper::covercalibrator::AscomCoverCalibratorWrapper;
                self.disconnect_previous_ascom_handle(&info.id, "").await;
                let cover_cal = AscomCoverCalibratorWrapper::new(prog_id.to_string())?;
                cover_cal.connect().await?;
                self.handles
                    .insert(&info.id, DeviceHandle::CoverCalibrator(Arc::new(cover_cal)));
            }
            _ => {
                return Err(format!(
                    "ASCOM {} is not supported in this DeviceManager path",
                    info.device_type.as_str()
                ));
            }
        }

        Ok(())
    }

    /// Releases the wrapper a previous connect of `device_id` left behind, so
    /// the COM object is not held twice across a reconnect.
    ///
    /// `label` goes into the log line: empty, or a device noun followed by a
    /// space.
    #[cfg(windows)]
    async fn disconnect_previous_ascom_handle(&self, device_id: &str, label: &str) {
        let Some(old) = self.handles.remove(device_id) else {
            return;
        };
        match old.disconnect().await {
            Ok(()) => tracing::info!(
                "Disconnected old ASCOM {}wrapper for {} before reconnect",
                label,
                device_id
            ),
            Err(error) => tracing::warn!(
                "Failed to disconnect old ASCOM {}wrapper for {} before reconnect: {}",
                label,
                device_id,
                error
            ),
        }
    }

    #[cfg(not(windows))]
    pub(crate) async fn connect_ascom(&self, _info: &DeviceInfo) -> Result<(), String> {
        Err("ASCOM is only available on Windows".to_string())
    }
}
