//! Safety monitor operations dispatcher.
//!
//! Methods in this module are an additional impl block on `DeviceManager`
//! using Rust's split-impl-block feature. Behavior is identical to the
//! previous monolithic `devices.rs`.

use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;

impl DeviceManager {
    // Safety monitor

    /// Check if conditions are safe
    pub async fn safety_is_safe(&self, device_id: &str) -> Result<bool, DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let safety_devs = self.alpaca_safety_monitors.read().await;
                if let Some(safety) = safety_devs.get(device_id) {
                    return safety.is_safe().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca safety monitor {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                // Parse INDI device ID: indi:host:port:device_name
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    use skotiq_indi::IndiSafetyMonitor;
                    let safety = IndiSafetyMonitor::new(client.clone(), &device_name);
                    return safety.is_safe().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("INDI client not connected for server {}", server_key),
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let safety_monitors = self.ascom_safety_monitors.read().await;
                    if let Some(safety) = safety_monitors.get(device_id) {
                        let safety_guard = safety.read().await;
                        return safety_guard.is_safe().await.map_err(DeviceOpError::driver);
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM safety monitor {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM is only available on Windows",
                ))
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native safety monitor not connected",
            )),
            Some(DriverType::Simulator) => {
                let safety = crate::api::devices::simulation::get_sim_safety_monitor()
                    .read()
                    .await;
                if !safety.status.connected {
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Simulator safety monitor not connected",
                    ));
                }
                Ok(safety.status.is_safe)
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }
}
