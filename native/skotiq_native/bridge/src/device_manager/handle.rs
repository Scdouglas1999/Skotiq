//! One handle per connected device, behind its device type's driver trait.
//!
//! A protocol's connect path builds the driver value and stores it here; an
//! operation looks the handle up, calls the trait method and converts the
//! error. Which protocol answers is decided once, at connect.

use crate::device::{DeviceType, DriverType};
use crate::device_capabilities::types::DeviceCapabilities;
use crate::device_manager::accessory::{Dome, Rotator, SafetyMonitor, Weather};
use crate::device_manager::rig::camera::Camera;
use crate::device_manager::rig::filter_wheel::FilterWheel;
use crate::device_manager::rig::focuser::Focuser;
use crate::device_manager::rig::mount::Mount;
use crate::device_manager::rig::RigDriver;
use crate::device_manager::{accessory, DeviceManager};
use crate::dispatch::error::DeviceOpError;
use crate::error::SkotiqError;
use crate::simulator::gate;
use skotiq_device::{AccessoryDriver, CoverCalibratorDriver, DriverError, SwitchDriver};
use std::collections::HashMap;
use std::sync::{Arc, RwLock};

#[derive(Clone)]
pub(crate) enum DeviceHandle {
    Dome(Arc<dyn Dome>),
    Rotator(Arc<dyn Rotator>),
    Switch(Arc<dyn SwitchDriver>),
    Weather(Arc<dyn Weather>),
    SafetyMonitor(Arc<dyn SafetyMonitor>),
    CoverCalibrator(Arc<dyn CoverCalibratorDriver>),
    FilterWheel(Arc<dyn FilterWheel>),
    Focuser(Arc<dyn Focuser>),
    Camera(Arc<dyn Camera>),
    Mount(Arc<dyn Mount>),
}

/// What a handle is closed and probed through.
enum Link {
    Accessory(Arc<dyn AccessoryDriver>),
    Rig(Arc<dyn RigDriver>),
}

impl DeviceHandle {
    fn link(&self) -> Link {
        match self {
            DeviceHandle::Dome(d) => Link::Accessory(d.clone()),
            DeviceHandle::Rotator(d) => Link::Accessory(d.clone()),
            DeviceHandle::Switch(d) => Link::Accessory(d.clone()),
            DeviceHandle::Weather(d) => Link::Accessory(d.clone()),
            DeviceHandle::SafetyMonitor(d) => Link::Accessory(d.clone()),
            DeviceHandle::CoverCalibrator(d) => Link::Accessory(d.clone()),
            DeviceHandle::FilterWheel(d) => Link::Rig(d.clone()),
            DeviceHandle::Focuser(d) => Link::Rig(d.clone()),
            DeviceHandle::Camera(d) => Link::Rig(d.clone()),
            DeviceHandle::Mount(d) => Link::Rig(d.clone()),
        }
    }

    pub(crate) async fn disconnect(&self) -> Result<(), DriverError> {
        match self.link() {
            Link::Accessory(driver) => driver.disconnect().await,
            Link::Rig(driver) => driver.disconnect().await,
        }
    }

    /// One liveness probe; see [`RigDriver::heartbeat`] for the three answers.
    pub(crate) async fn heartbeat(&self, device_id: &str) -> Result<bool, String> {
        match self.link() {
            Link::Accessory(driver) => match driver.heartbeat().await {
                Ok(()) => {
                    tracing::trace!("{} heartbeat: healthy", device_id);
                    Ok(true)
                }
                Err(DriverError::NotConnected | DriverError::Disconnected) => {
                    tracing::debug!("{} heartbeat: not connected", device_id);
                    Ok(false)
                }
                Err(e) => Err(e.to_string()),
            },
            Link::Rig(driver) => driver.heartbeat().await,
        }
    }

    /// What the device supports, and the live readings that share the
    /// capability structs, as its driver reports them.
    pub(crate) async fn capabilities(
        &self,
        device_id: &str,
    ) -> Result<DeviceCapabilities, SkotiqError> {
        Ok(match self {
            DeviceHandle::Dome(d) => DeviceCapabilities::Dome(d.capabilities(device_id).await?),
            DeviceHandle::Rotator(d) => {
                DeviceCapabilities::Rotator(d.capabilities(device_id).await?)
            }
            DeviceHandle::Switch(d) => {
                DeviceCapabilities::Switch(accessory::switch_capabilities(d.as_ref()).await)
            }
            DeviceHandle::Weather(d) => {
                DeviceCapabilities::Weather(d.capabilities(device_id).await?)
            }
            DeviceHandle::SafetyMonitor(d) => {
                DeviceCapabilities::SafetyMonitor(d.capabilities(device_id).await?)
            }
            DeviceHandle::CoverCalibrator(d) => DeviceCapabilities::CoverCalibrator(
                accessory::cover_calibrator_capabilities(d.as_ref()).await,
            ),
            DeviceHandle::FilterWheel(d) => {
                DeviceCapabilities::FilterWheel(d.capabilities(device_id).await?)
            }
            DeviceHandle::Focuser(d) => {
                DeviceCapabilities::Focuser(d.capabilities(device_id).await?)
            }
            DeviceHandle::Camera(d) => d.capabilities(device_id).await?,
            DeviceHandle::Mount(d) => d.capabilities(device_id).await?,
        })
    }
}

/// The connected devices' handles by device id. Held only for a lookup or an
/// insert, never across an `.await`.
#[derive(Default)]
pub(crate) struct Handles(RwLock<HashMap<String, DeviceHandle>>);

impl Handles {
    pub(crate) fn get(&self, device_id: &str) -> Option<DeviceHandle> {
        self.0
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(device_id)
            .cloned()
    }

    /// Stores `handle` for `device_id`, returning the one it replaces.
    pub(crate) fn insert(&self, device_id: &str, handle: DeviceHandle) -> Option<DeviceHandle> {
        self.0
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(device_id.to_string(), handle)
    }

    pub(crate) fn remove(&self, device_id: &str) -> Option<DeviceHandle> {
        self.0
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(device_id)
    }
}

/// How a protocol names itself in messages.
pub(crate) fn protocol_label(driver_type: DriverType) -> &'static str {
    match driver_type {
        DriverType::Ascom => "ASCOM",
        DriverType::Alpaca => "Alpaca",
        DriverType::Indi => "INDI",
        DriverType::Native => "Native",
        DriverType::Simulator => "Simulator",
    }
}

/// The device type in a sentence: "dome", "safety monitor".
pub(crate) fn device_noun(device_type: DeviceType) -> String {
    device_type.as_str().to_lowercase()
}

/// A driver failure on `device_id`. A not-connected answer names the device,
/// so the FFI edge reports which device it is.
pub(crate) fn device_error(device_id: &str, error: DriverError) -> DeviceOpError {
    match error {
        DriverError::NotConnected | DriverError::Disconnected => {
            DeviceOpError::not_connected(Some(device_id.to_string()), error.to_string())
        }
        other => DeviceOpError::from(other),
    }
}

impl DeviceManager {
    /// The handle of a registered, connected device, taken out by `pick`.
    async fn connected<T>(
        &self,
        device_id: &str,
        pick: impl FnOnce(DeviceHandle) -> Option<T>,
    ) -> Result<T, DeviceOpError> {
        let info = self
            .devices
            .read()
            .await
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
        // The simulated camera and mount are the simulator's own state; a
        // handle for one holds nothing, so an id that never went through
        // connect gets one here and the simulator's gate answers for it.
        let handle = self.handles.get(device_id).or_else(|| {
            (info.driver_type == DriverType::Simulator
                && matches!(info.device_type, DeviceType::Camera | DeviceType::Mount))
            .then(|| crate::simulator::driver::handle(&info))
            .flatten()
        });
        handle.and_then(pick).ok_or_else(|| {
            let noun = device_noun(info.device_type);
            match (info.driver_type, info.device_type) {
                // The simulated rig devices answer with the simulator's own
                // sentence, which the FFI edge shows only for an error that
                // carries no device id.
                (DriverType::Simulator, DeviceType::FilterWheel | DeviceType::Focuser) => {
                    DeviceOpError::not_connected(None, gate::not_connected(&noun))
                }
                _ => DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!(
                        "{} {} not connected",
                        protocol_label(info.driver_type),
                        noun
                    ),
                ),
            }
        })
    }

    pub(crate) async fn focuser(&self, device_id: &str) -> Result<Arc<dyn Focuser>, DeviceOpError> {
        self.connected(device_id, |h| match h {
            DeviceHandle::Focuser(d) => Some(d),
            _ => None,
        })
        .await
    }

    /// An id nobody registered answers not connected, as every camera
    /// operation did.
    pub(crate) async fn camera(&self, device_id: &str) -> Result<Arc<dyn Camera>, DeviceOpError> {
        self.connected(device_id, |h| match h {
            DeviceHandle::Camera(d) => Some(d),
            _ => None,
        })
        .await
        .map_err(|error| match error {
            DeviceOpError::DeviceNotFound(_) => DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Camera {} not found", device_id),
            ),
            other => other,
        })
    }

    pub(crate) async fn mount(&self, device_id: &str) -> Result<Arc<dyn Mount>, DeviceOpError> {
        self.connected(device_id, |h| match h {
            DeviceHandle::Mount(d) => Some(d),
            _ => None,
        })
        .await
    }

    pub(crate) async fn filter_wheel(
        &self,
        device_id: &str,
    ) -> Result<Arc<dyn FilterWheel>, DeviceOpError> {
        self.connected(device_id, |h| match h {
            DeviceHandle::FilterWheel(d) => Some(d),
            _ => None,
        })
        .await
    }

    /// The handle of a registered, connected device of a type that has one.
    pub(crate) async fn handle(&self, device_id: &str) -> Result<DeviceHandle, DeviceOpError> {
        self.connected(device_id, Some).await
    }

    pub(crate) async fn dome(&self, device_id: &str) -> Result<Arc<dyn Dome>, DeviceOpError> {
        self.connected(device_id, |h| match h {
            DeviceHandle::Dome(d) => Some(d),
            _ => None,
        })
        .await
    }

    pub(crate) async fn rotator(&self, device_id: &str) -> Result<Arc<dyn Rotator>, DeviceOpError> {
        self.connected(device_id, |h| match h {
            DeviceHandle::Rotator(d) => Some(d),
            _ => None,
        })
        .await
    }

    pub(crate) async fn switch(
        &self,
        device_id: &str,
    ) -> Result<Arc<dyn SwitchDriver>, DeviceOpError> {
        self.connected(device_id, |h| match h {
            DeviceHandle::Switch(d) => Some(d),
            _ => None,
        })
        .await
    }

    pub(crate) async fn weather(&self, device_id: &str) -> Result<Arc<dyn Weather>, DeviceOpError> {
        self.connected(device_id, |h| match h {
            DeviceHandle::Weather(d) => Some(d),
            _ => None,
        })
        .await
    }

    pub(crate) async fn safety_monitor(
        &self,
        device_id: &str,
    ) -> Result<Arc<dyn SafetyMonitor>, DeviceOpError> {
        self.connected(device_id, |h| match h {
            DeviceHandle::SafetyMonitor(d) => Some(d),
            _ => None,
        })
        .await
    }

    pub(crate) async fn cover_calibrator(
        &self,
        device_id: &str,
    ) -> Result<Arc<dyn CoverCalibratorDriver>, DeviceOpError> {
        self.connected(device_id, |h| match h {
            DeviceHandle::CoverCalibrator(d) => Some(d),
            _ => None,
        })
        .await
    }
}

/// Stand-ins for a connect, for tests that bring their own driver.
#[cfg(test)]
impl DeviceManager {
    pub(crate) fn hold_vendor_camera(
        &self,
        device_id: &str,
        camera: Box<dyn skotiq_device::CameraDriver + Send + Sync>,
    ) {
        use crate::device_manager::rig::camera::vendor::VendorCamera;
        self.handles.insert(
            device_id,
            DeviceHandle::Camera(Arc::new(VendorCamera::new(device_id, camera))),
        );
    }

    pub(crate) fn hold_vendor_mount(
        &self,
        device_id: &str,
        mount: Box<dyn skotiq_device::MountDriver + Send + Sync>,
    ) {
        use crate::device_manager::rig::mount::vendor::VendorMount;
        self.handles.insert(
            device_id,
            DeviceHandle::Mount(Arc::new(VendorMount::new(device_id, mount))),
        );
    }

    pub(crate) fn hold_alpaca_mount(&self, device_id: &str, mount: skotiq_alpaca::AlpacaTelescope) {
        use crate::device_manager::rig::mount::alpaca::AlpacaMount;
        self.handles.insert(
            device_id,
            DeviceHandle::Mount(Arc::new(AlpacaMount::new(device_id, mount))),
        );
    }

    #[cfg(windows)]
    pub(crate) fn hold_ascom_mount(
        &self,
        device_id: &str,
        mount: crate::ascom_wrapper::mount::AscomMountWrapper,
    ) {
        use crate::device_manager::rig::mount::com::ComMount;
        self.handles.insert(
            device_id,
            DeviceHandle::Mount(Arc::new(ComMount::new(device_id, mount))),
        );
    }
}
