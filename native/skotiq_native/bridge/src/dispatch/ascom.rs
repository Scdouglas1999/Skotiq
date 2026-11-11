//! ASCOM (Windows COM) driver dispatch helpers.
//!
//! Methods in this module are additional impl blocks on `DeviceManager` and
//! provide ASCOM-only logic for `connect_*` and `perform_*_health_check`. They are invoked from the dispatcher methods in
//! `crate::device_manager`. No behavior or signature has changed relative to the
//! previous monolithic `devices.rs`.

use crate::device::*;
#[cfg(windows)]
use crate::device_manager::handle::DeviceHandle;
use crate::device_manager::DeviceManager;
// DeviceDriver / MountDriver required so the trait methods `connect`,
// `disconnect`, `get_tracking` — which the ASCOM wrappers implement via the
// trait — are resolvable here.
#[cfg(windows)]
use skotiq_device::{DeviceDriver, MountDriver};
#[cfg(windows)]
use std::sync::Arc;
#[cfg(windows)]
use tokio::sync::RwLock;

/// Whether interactive driver dialogs may be shown during connect. The decision
/// (headless ⇒ never) lives next to the STA worker that also force-closes any
/// rogue modal, so the gate and its enforcement stay in one place — B1: the
/// ASCOM connect must never block the appliance on an undismissable dialog.
#[cfg(windows)]
use crate::ascom_wrapper::sta_worker::interactive_dialogs_allowed;
impl DeviceManager {
    /// Connect to an ASCOM device
    #[cfg(windows)]
    pub(crate) async fn connect_ascom(&self, info: &DeviceInfo) -> Result<(), String> {
        let prog_id = info
            .id
            .strip_prefix("ascom:")
            .ok_or_else(|| "Invalid ASCOM device ID".to_string())?;

        macro_rules! disconnect_existing_ascom {
            ($map:expr, $label:literal) => {{
                let old_wrapper = {
                    let mut map = $map.write().await;
                    map.remove(&info.id)
                };
                if let Some(old_wrapper) = old_wrapper {
                    let mut old = old_wrapper.write().await;
                    match old.disconnect().await {
                        Ok(()) => {
                            tracing::info!(
                                "Disconnected old ASCOM {} wrapper for {} before reconnect",
                                $label,
                                info.id
                            );
                        }
                        Err(error) => {
                            tracing::warn!(
                                "Failed to disconnect old ASCOM {} wrapper for {} before reconnect: {}",
                                $label,
                                info.id,
                                error
                            );
                        }
                    }
                }
            }};
        }

        match info.device_type {
            DeviceType::Camera => {
                use crate::ascom_wrapper::camera::AscomCameraWrapper;
                disconnect_existing_ascom!(self.ascom_cameras, "camera");
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

                // Store in typed map for camera-specific operations, wrapped in Arc<RwLock>
                let mut ascom_cameras = self.ascom_cameras.write().await;
                ascom_cameras.insert(info.id.clone(), Arc::new(RwLock::new(camera)));
            }
            DeviceType::Mount => {
                use crate::ascom_wrapper::mount::AscomMountWrapper;
                disconnect_existing_ascom!(self.ascom_mounts, "mount");
                let mut mount = AscomMountWrapper::new(prog_id.to_string())?;
                mount.connect().await.map_err(|e| e.to_string())?;

                let mut ascom_mounts = self.ascom_mounts.write().await;
                ascom_mounts.insert(info.id.clone(), Arc::new(RwLock::new(mount)));
            }
            DeviceType::Focuser => {
                use crate::ascom_wrapper::focuser::AscomFocuserWrapper;
                disconnect_existing_ascom!(self.ascom_focusers, "focuser");
                let mut focuser = AscomFocuserWrapper::new(prog_id.to_string())?;
                focuser.connect().await.map_err(|e| e.to_string())?;

                let mut ascom_focusers = self.ascom_focusers.write().await;
                ascom_focusers.insert(info.id.clone(), Arc::new(RwLock::new(focuser)));
            }
            DeviceType::FilterWheel => {
                use crate::ascom_wrapper::filterwheel::AscomFilterWheelWrapper;

                disconnect_existing_ascom!(self.ascom_filter_wheels, "filter wheel");

                let mut fw = AscomFilterWheelWrapper::new(prog_id.to_string())?;
                fw.connect().await.map_err(|e| e.to_string())?;

                let mut ascom_filter_wheels = self.ascom_filter_wheels.write().await;
                ascom_filter_wheels.insert(info.id.clone(), Arc::new(RwLock::new(fw)));
            }
            DeviceType::Rotator => {
                use crate::ascom_wrapper::rotator::AscomRotatorWrapper;
                self.disconnect_previous_ascom_accessory(&info.id).await;
                let rotator = AscomRotatorWrapper::new(prog_id.to_string())?;
                rotator.connect().await?;
                self.handles
                    .insert(&info.id, DeviceHandle::Rotator(Arc::new(rotator)));
            }
            DeviceType::Dome => {
                use crate::ascom_wrapper::dome::AscomDomeWrapper;
                self.disconnect_previous_ascom_accessory(&info.id).await;
                let dome = AscomDomeWrapper::new(prog_id.to_string())?;
                dome.connect().await?;
                self.handles
                    .insert(&info.id, DeviceHandle::Dome(Arc::new(dome)));
            }
            DeviceType::Switch => {
                use crate::ascom_wrapper::switch::AscomSwitchWrapper;
                self.disconnect_previous_ascom_accessory(&info.id).await;
                let sw = AscomSwitchWrapper::new(prog_id.to_string())?;
                sw.connect().await?;
                self.handles
                    .insert(&info.id, DeviceHandle::Switch(Arc::new(sw)));
            }
            DeviceType::Weather => {
                use crate::ascom_wrapper::weather::AscomObservingConditionsWrapper;
                self.disconnect_previous_ascom_accessory(&info.id).await;
                let weather = AscomObservingConditionsWrapper::new(prog_id.to_string())?;
                weather.connect().await?;
                self.handles
                    .insert(&info.id, DeviceHandle::Weather(Arc::new(weather)));
            }
            DeviceType::SafetyMonitor => {
                use crate::ascom_wrapper::safetymonitor::AscomSafetyMonitorWrapper;
                self.disconnect_previous_ascom_accessory(&info.id).await;
                let safety = AscomSafetyMonitorWrapper::new(prog_id.to_string())?;
                safety.connect().await?;
                self.handles
                    .insert(&info.id, DeviceHandle::SafetyMonitor(Arc::new(safety)));
            }
            DeviceType::CoverCalibrator => {
                use crate::ascom_wrapper::covercalibrator::AscomCoverCalibratorWrapper;
                self.disconnect_previous_ascom_accessory(&info.id).await;
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
    #[cfg(windows)]
    async fn disconnect_previous_ascom_accessory(&self, device_id: &str) {
        let Some(old) = self.handles.remove(device_id) else {
            return;
        };
        match old.accessory().disconnect().await {
            Ok(()) => tracing::info!(
                "Disconnected old ASCOM wrapper for {} before reconnect",
                device_id
            ),
            Err(error) => tracing::warn!(
                "Failed to disconnect old ASCOM wrapper for {} before reconnect: {}",
                device_id,
                error
            ),
        }
    }

    #[cfg(not(windows))]
    pub(crate) async fn connect_ascom(&self, _info: &DeviceInfo) -> Result<(), String> {
        Err("ASCOM is only available on Windows".to_string())
    }

    /// Perform health check for ASCOM devices (Windows only)
    #[cfg(windows)]
    pub(crate) async fn perform_ascom_health_check(
        &self,
        device_id: &str,
        device_type: &DeviceType,
    ) -> Result<bool, String> {
        match device_type {
            DeviceType::Camera => {
                let cameras = self.ascom_cameras.read().await;
                if let Some(camera) = cameras.get(device_id) {
                    match camera.read().await.heartbeat().await {
                        Ok(health) => {
                            let is_healthy = matches!(
                                health,
                                crate::ascom_wrapper::camera::CameraConnectionHealth::Healthy
                                    | crate::ascom_wrapper::camera::CameraConnectionHealth::Unknown
                            );
                            tracing::trace!("ASCOM camera {} heartbeat: {:?}", device_id, health);
                            Ok(is_healthy)
                        }
                        Err(e) => {
                            tracing::debug!("ASCOM camera {} heartbeat failed: {:?}", device_id, e);
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("ASCOM camera {} not found", device_id))
                }
            }
            DeviceType::Mount => {
                let mounts = self.ascom_mounts.read().await;
                if let Some(mount) = mounts.get(device_id) {
                    // Send a lightweight COM command through the worker thread to verify
                    // the mount is actually responding, not just reading an AtomicBool flag
                    let mount_guard = mount.read().await;
                    match mount_guard.get_tracking().await {
                        Ok(_) => {
                            tracing::trace!("ASCOM mount {} heartbeat: healthy", device_id,);
                            Ok(true)
                        }
                        Err(e) => {
                            tracing::debug!("ASCOM mount {} heartbeat failed: {:?}", device_id, e);
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("ASCOM mount {} not found", device_id))
                }
            }
            DeviceType::Focuser => {
                // Single probe; the retry for transient focuser/wheel failures
                // lives in the perform_health_check wrapper (driver parity).
                let focusers = self.ascom_focusers.read().await;
                if let Some(focuser) = focusers.get(device_id) {
                    match focuser.read().await.heartbeat().await {
                        Ok(()) => {
                            tracing::trace!("ASCOM focuser {} heartbeat: healthy", device_id);
                            Ok(true)
                        }
                        Err(e) => {
                            tracing::debug!(
                                "ASCOM focuser {} heartbeat failed: {:?}",
                                device_id,
                                e
                            );
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("ASCOM focuser {} not found", device_id))
                }
            }
            DeviceType::FilterWheel => {
                let filter_wheels = self.ascom_filter_wheels.read().await;
                if let Some(fw) = filter_wheels.get(device_id) {
                    match fw.read().await.heartbeat().await {
                        Ok(()) => {
                            tracing::trace!("ASCOM filter wheel {} heartbeat: healthy", device_id);
                            Ok(true)
                        }
                        Err(e) => {
                            tracing::debug!(
                                "ASCOM filter wheel {} heartbeat failed: {:?}",
                                device_id,
                                e
                            );
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("ASCOM filter wheel {} not found", device_id))
                }
            }
            _ => Err(format!(
                "No ASCOM heartbeat implementation for device {} ({:?})",
                device_id, device_type
            )),
        }
    }
}
