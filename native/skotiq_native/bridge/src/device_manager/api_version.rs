//! Device API version cache and query dispatch.
//!
//! Methods in this module are additional impl blocks on `DeviceManager` that
//! manage cached `DeviceApiVersion` data and route `query_device_api_version`
//! to the appropriate driver-specific helper in `crate::dispatch`. No behavior
//! or signature has changed relative to the previous monolithic `devices.rs`.

use crate::device::*;
use crate::device_manager::DeviceManager;

impl DeviceManager {
    /// Get the cached API version for a device
    pub async fn get_device_api_version(&self, device_id: &str) -> Option<DeviceApiVersion> {
        let devices = self.devices.read().await;
        devices.get(device_id).and_then(|d| d.api_version.clone())
    }

    /// Store API version information for a device
    pub async fn set_device_api_version(&self, device_id: &str, version: DeviceApiVersion) {
        let mut devices = self.devices.write().await;
        if let Some(dev) = devices.get_mut(device_id) {
            dev.api_version = Some(version);
        }
    }

    /// Query API version for a device (dispatches based on driver type)
    pub async fn query_device_api_version(
        &self,
        device_id: &str,
    ) -> Result<DeviceApiVersion, String> {
        // Get the device info to determine driver type
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type)
        };

        match driver_type {
            Some(DriverType::Alpaca) => self.query_alpaca_api_version(device_id).await,
            Some(DriverType::Indi) => self.query_indi_api_version(device_id).await,
            #[cfg(windows)]
            Some(DriverType::Ascom) => self.query_ascom_api_version(device_id).await,
            #[cfg(not(windows))]
            Some(DriverType::Ascom) => Err("ASCOM is only supported on Windows".to_string()),
            Some(DriverType::Native) => {
                // Native devices don't have a query-able API version
                let version = DeviceApiVersion::new(device_id.to_string(), DriverType::Native);
                self.set_device_api_version(device_id, version.clone())
                    .await;
                Ok(version)
            }
            Some(DriverType::Simulator) => {
                // Simulators don't have a query-able API version
                let version = DeviceApiVersion::new(device_id.to_string(), DriverType::Simulator);
                self.set_device_api_version(device_id, version.clone())
                    .await;
                Ok(version)
            }
            None => Err(format!("Device not found: {}", device_id)),
        }
    }

    /// Check if a device supports a specific interface version
    pub async fn device_supports_version(&self, device_id: &str, required_version: u32) -> bool {
        // Check cached version first
        if let Some(version) = self.get_device_api_version(device_id).await {
            if version.is_fresh() {
                return version.supports_version(required_version);
            }
        }

        // Try to query fresh version info
        if let Ok(version) = self.query_device_api_version(device_id).await {
            return version.supports_version(required_version);
        }

        false
    }

    /// Check if a device supports a specific action
    pub async fn device_supports_action(&self, device_id: &str, action: &str) -> bool {
        // Check cached version first
        if let Some(version) = self.get_device_api_version(device_id).await {
            if version.is_fresh() {
                return version.supports_action(action);
            }
        }

        // Try to query fresh version info
        if let Ok(version) = self.query_device_api_version(device_id).await {
            return version.supports_action(action);
        }

        false
    }
}
