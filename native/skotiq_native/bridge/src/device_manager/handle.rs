//! One handle per connected device, behind its device type's driver trait.
//!
//! A protocol's connect path builds the driver value and stores it here; an
//! operation looks the handle up, calls the trait method and converts the
//! error. Which protocol answers is decided once, at connect.

use crate::device::{DeviceType, DriverType};
use crate::device_manager::ops::sim_gate;
use crate::device_manager::rig::filter_wheel::FilterWheel;
use crate::device_manager::rig::focuser::Focuser;
use crate::device_manager::rig::RigDriver;
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;
use skotiq_device::{
    AccessoryDriver, CoverCalibratorDriver, DomeDriver, DriverError, RotatorDriver,
    SafetyMonitorDriver, SwitchDriver, WeatherDriver,
};
use std::any::Any;
use std::collections::HashMap;
use std::sync::{Arc, RwLock};

#[derive(Clone)]
pub(crate) enum DeviceHandle {
    Dome(Arc<dyn DomeDriver>),
    Rotator(Arc<dyn RotatorDriver>),
    Switch(Arc<dyn SwitchDriver>),
    Weather(Arc<dyn WeatherDriver>),
    SafetyMonitor(Arc<dyn SafetyMonitorDriver>),
    CoverCalibrator(Arc<dyn CoverCalibratorDriver>),
    FilterWheel(Arc<dyn FilterWheel>),
    Focuser(Arc<dyn Focuser>),
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
            Link::Accessory(driver) => Ok(match driver.heartbeat().await {
                Ok(()) => {
                    tracing::trace!("{} heartbeat: healthy", device_id);
                    true
                }
                Err(e) => {
                    tracing::debug!("{} heartbeat failed: {}", device_id, e);
                    false
                }
            }),
            Link::Rig(driver) => driver.heartbeat().await,
        }
    }

    /// The driver behind the handle as its concrete type, for the capability
    /// probes that read what only one protocol's driver offers.
    fn concrete<T: Any + Send + Sync>(self) -> Option<Arc<T>> {
        let any: Arc<dyn Any + Send + Sync> = match self {
            DeviceHandle::FilterWheel(d) => d,
            DeviceHandle::Focuser(d) => d,
            _ => return None,
        };
        any.downcast().ok()
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

    /// The driver of `device_id` when it is connected through a `T`.
    pub(crate) fn concrete<T: Any + Send + Sync>(&self, device_id: &str) -> Option<Arc<T>> {
        self.get(device_id)?.concrete()
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
        self.handles.get(device_id).and_then(pick).ok_or_else(|| {
            let noun = device_noun(info.device_type);
            match (info.driver_type, info.device_type) {
                // The simulated rig devices answer with the simulator's own
                // sentence, which the FFI edge shows only for an error that
                // carries no device id.
                (DriverType::Simulator, DeviceType::FilterWheel | DeviceType::Focuser) => {
                    DeviceOpError::not_connected(None, sim_gate::not_connected(&noun))
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

    pub(crate) async fn dome(&self, device_id: &str) -> Result<Arc<dyn DomeDriver>, DeviceOpError> {
        self.connected(device_id, |h| match h {
            DeviceHandle::Dome(d) => Some(d),
            _ => None,
        })
        .await
    }

    pub(crate) async fn rotator(
        &self,
        device_id: &str,
    ) -> Result<Arc<dyn RotatorDriver>, DeviceOpError> {
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

    pub(crate) async fn weather(
        &self,
        device_id: &str,
    ) -> Result<Arc<dyn WeatherDriver>, DeviceOpError> {
        self.connected(device_id, |h| match h {
            DeviceHandle::Weather(d) => Some(d),
            _ => None,
        })
        .await
    }

    pub(crate) async fn safety_monitor(
        &self,
        device_id: &str,
    ) -> Result<Arc<dyn SafetyMonitorDriver>, DeviceOpError> {
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
