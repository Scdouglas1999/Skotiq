//! An ASCOM safety monitor (`ISafetyMonitorV3`) over COM. A failed `IsSafe`
//! read is an error, never a verdict: the run's safety fail mode decides what
//! an unreadable monitor means.

use crate::ascom_wrapper::sta_device::{driver_error, sta_accessory, StaDevice};
use crate::device_capabilities::types::SafetyMonitorCapabilities;
use crate::device_manager::accessory::SafetyMonitor;
use crate::device_manager::handle::device_error;
use crate::dispatch::error::DeviceOpError;
use crate::error::SkotiqError;
use crate::timeout_ops::Timeouts;
use async_trait::async_trait;
use skotiq_ascom::AscomSafetyMonitor;
use skotiq_device::{DriverError, SafetyMonitorDriver};

pub struct AscomSafetyMonitorWrapper {
    device: StaDevice<AscomSafetyMonitor>,
}

impl AscomSafetyMonitorWrapper {
    pub fn new(prog_id: String) -> Result<Self, String> {
        let (device, ()) = StaDevice::new(
            "SafetyMonitor",
            move || AscomSafetyMonitor::new(&prog_id),
            |_| (),
        )?;
        Ok(Self { device })
    }

    pub async fn connect(&self) -> Result<(), DeviceOpError> {
        self.device
            .run("connect", Timeouts::connection(), |d| d.connect())
            .await
    }
}

sta_accessory!(AscomSafetyMonitorWrapper);

#[async_trait]
impl SafetyMonitorDriver for AscomSafetyMonitorWrapper {
    async fn is_safe(&self) -> Result<bool, DriverError> {
        self.device
            .run("is_safe", Timeouts::property_read(), |d| d.is_safe())
            .await
            .map_err(driver_error)
    }
}

#[async_trait]
impl SafetyMonitor for AscomSafetyMonitorWrapper {
    async fn capabilities(
        &self,
        device_id: &str,
    ) -> Result<SafetyMonitorCapabilities, SkotiqError> {
        let error = |e| SkotiqError::from(device_error(device_id, e));
        Ok(SafetyMonitorCapabilities {
            is_safe: SafetyMonitorDriver::is_safe(self).await.map_err(error)?,
            safety_description: self
                .device
                .run("driver_info", Timeouts::property_read(), |d| {
                    d.driver_info()
                })
                .await
                .ok(),
        })
    }
}
