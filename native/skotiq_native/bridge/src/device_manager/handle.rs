//! One handle per connected device, behind its device type's driver trait.
//!
//! A protocol's connect path builds the driver value and stores it here; an
//! operation looks the handle up, calls the trait method and converts the
//! error. Which protocol answers is decided once, at connect.

use crate::device::{DeviceType, DriverType};
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;
use skotiq_device::{
    AccessoryDriver, CoverCalibratorDriver, DomeDriver, DriverError, RotatorDriver,
    SafetyMonitorDriver, SwitchDriver, WeatherDriver,
};
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
}

impl DeviceHandle {
    pub(crate) fn accessory(&self) -> Arc<dyn AccessoryDriver> {
        match self {
            DeviceHandle::Dome(d) => d.clone(),
            DeviceHandle::Rotator(d) => d.clone(),
            DeviceHandle::Switch(d) => d.clone(),
            DeviceHandle::Weather(d) => d.clone(),
            DeviceHandle::SafetyMonitor(d) => d.clone(),
            DeviceHandle::CoverCalibrator(d) => d.clone(),
        }
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
        self.handles.get(device_id).and_then(pick).ok_or_else(|| {
            DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!(
                    "{} {} not connected",
                    protocol_label(info.driver_type),
                    device_noun(info.device_type)
                ),
            )
        })
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
