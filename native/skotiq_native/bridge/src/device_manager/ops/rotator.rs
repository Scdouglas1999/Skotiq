//! Rotator operations dispatcher.
//!
//! Methods in this module are an additional impl block on `DeviceManager`
//! using Rust's split-impl-block feature. Behavior is identical to the
//! previous monolithic `devices.rs`.

use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;

impl DeviceManager {
    // Rotator control

    /// Get rotator position (sky angle in degrees)
    pub async fn rotator_get_position(&self, device_id: &str) -> Result<f64, DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let rotators = self.alpaca_rotators.read().await;
                if let Some(rotator) = rotators.get(device_id) {
                    return rotator.position().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca rotator {} not found", device_id),
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let rotators = self.ascom_rotators.read().await;
                    if let Some(rotator) = rotators.get(device_id) {
                        let rotator_guard = rotator.read().await;
                        return rotator_guard
                            .position()
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM rotator {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM is only available on Windows",
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let locked = client.read().await;
                    if let Some(pos) = locked
                        .get_number(&device_name, "ABS_ROTATOR_ANGLE", "ANGLE")
                        .await
                    {
                        return Ok(pos);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI rotator not connected",
                ))
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native rotator not connected",
            )),
            Some(DriverType::Simulator) => {
                let sim = crate::device_manager::ops::sim_gate::read_rotator_status().await?;
                Ok(sim.position)
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }

    /// Move rotator to absolute sky position (degrees)
    pub async fn rotator_move_absolute(
        &self,
        device_id: &str,
        position: f64,
    ) -> Result<(), DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let rotators = self.alpaca_rotators.read().await;
                if let Some(rotator) = rotators.get(device_id) {
                    return rotator
                        .move_absolute(position)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca rotator {} not found", device_id),
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let rotators = self.ascom_rotators.read().await;
                    if let Some(rotator) = rotators.get(device_id) {
                        let rotator_guard = rotator.read().await;
                        return rotator_guard
                            .move_absolute(position)
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM rotator {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM is only available on Windows",
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let mut locked = client.write().await;
                    return locked
                        .set_number(&device_name, "ABS_ROTATOR_ANGLE", "ANGLE", position)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI rotator not connected",
                ))
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native rotator not connected",
            )),
            Some(DriverType::Simulator) => {
                let r = crate::api::devices::simulation::get_sim_rotator();
                let mut r = r.write().await;
                if !r.status.connected {
                    return Err(DeviceOpError::not_connected(
                        None,
                        crate::device_manager::ops::sim_gate::not_connected_rotator(),
                    ));
                }
                r.status.position = position;
                r.status.mechanical_position = position;
                Ok(())
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }

    /// Halt rotator motion
    pub async fn rotator_halt(&self, device_id: &str) -> Result<(), DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let rotators = self.alpaca_rotators.read().await;
                if let Some(rotator) = rotators.get(device_id) {
                    return rotator.halt().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca rotator {} not found", device_id),
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let rotators = self.ascom_rotators.read().await;
                    if let Some(rotator) = rotators.get(device_id) {
                        let rotator_guard = rotator.read().await;
                        return rotator_guard.halt().await.map_err(DeviceOpError::driver);
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM rotator {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM is only available on Windows",
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let mut locked = client.write().await;
                    return locked
                        .set_switch(&device_name, "ROTATOR_ABORT_MOTION", "ABORT", true)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI rotator not connected",
                ))
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native rotator not connected",
            )),
            Some(DriverType::Simulator) => {
                let r = crate::api::devices::simulation::get_sim_rotator();
                let mut r = r.write().await;
                if !r.status.connected {
                    return Err(DeviceOpError::not_connected(
                        None,
                        crate::device_manager::ops::sim_gate::not_connected_rotator(),
                    ));
                }
                r.status.moving = false;
                r.status.is_moving = false;
                Ok(())
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }

    /// Sync the reported rotator sky angle to `position` without moving the
    /// hardware. Used after a plate solve to align the driver's reported PA
    /// with the astrometric PA of the last frame. Why dispatch matches
    /// `rotator_move_absolute`: identical driver layout (Alpaca/ASCOM/INDI/
    /// Native) and lock acquisition rules.
    pub async fn rotator_sync(&self, device_id: &str, position: f64) -> Result<(), DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let rotators = self.alpaca_rotators.read().await;
                if let Some(rotator) = rotators.get(device_id) {
                    return rotator.sync(position).await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca rotator {} not found", device_id),
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let rotators = self.ascom_rotators.read().await;
                    if let Some(rotator) = rotators.get(device_id) {
                        let rotator_guard = rotator.read().await;
                        return rotator_guard
                            .sync(position)
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM rotator {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM is only available on Windows",
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let mut locked = client.write().await;
                    // INDI standard property for syncing the reported angle
                    // without rotating: SYNC_ROTATOR_ANGLE/ANGLE.
                    return locked
                        .set_number(&device_name, "SYNC_ROTATOR_ANGLE", "ANGLE", position)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI rotator not connected",
                ))
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native rotator not connected",
            )),
            Some(DriverType::Simulator) => {
                let r = crate::api::devices::simulation::get_sim_rotator();
                let mut r = r.write().await;
                if !r.status.connected {
                    return Err(DeviceOpError::not_connected(
                        None,
                        crate::device_manager::ops::sim_gate::not_connected_rotator(),
                    ));
                }
                // Sync snaps the reported PA without moving — matches the
                // simulator path in
                // `api::devices::simulation::api_rotator_sync_to_pa`.
                r.status.position = position;
                r.status.mechanical_position = position;
                Ok(())
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }

    /// Set the rotator's reverse-direction flag (IRotatorV3 `Reverse`,
    /// Alpaca `reverse`, INDI `ROTATOR_REVERSE`).
    pub async fn rotator_set_reverse(
        &self,
        device_id: &str,
        reverse: bool,
    ) -> Result<(), DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let rotators = self.alpaca_rotators.read().await;
                if let Some(rotator) = rotators.get(device_id) {
                    return rotator
                        .set_reverse(reverse)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca rotator {} not found", device_id),
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let rotators = self.ascom_rotators.read().await;
                    if let Some(rotator) = rotators.get(device_id) {
                        let rotator_guard = rotator.read().await;
                        return rotator_guard
                            .set_reverse(reverse)
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM rotator {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM is only available on Windows",
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let mut locked = client.write().await;
                    let element = if reverse {
                        "INDI_ENABLED"
                    } else {
                        "INDI_DISABLED"
                    };
                    return locked
                        .set_switch(&device_name, "ROTATOR_REVERSE", element, true)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI rotator not connected",
                ))
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native rotator not connected",
            )),
            Some(DriverType::Simulator) => {
                let r = crate::api::devices::simulation::get_sim_rotator();
                let r = r.read().await;
                if !r.status.connected {
                    return Err(DeviceOpError::not_connected(
                        None,
                        crate::device_manager::ops::sim_gate::not_connected_rotator(),
                    ));
                }
                if r.status.can_reverse {
                    // The simulator has no directional behavior to invert;
                    // accepting keeps sim rigs exercising the same UI path.
                    Ok(())
                } else {
                    Err(DeviceOpError::unsupported(
                        "Simulator rotator does not support reverse",
                    ))
                }
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }

    /// Check if rotator is moving
    pub async fn rotator_is_moving(&self, device_id: &str) -> Result<bool, DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let rotators = self.alpaca_rotators.read().await;
                if let Some(rotator) = rotators.get(device_id) {
                    return rotator.is_moving().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca rotator {} not found", device_id),
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let rotators = self.ascom_rotators.read().await;
                    if let Some(rotator) = rotators.get(device_id) {
                        let rotator_guard = rotator.read().await;
                        return rotator_guard
                            .is_moving()
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM rotator {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM is only available on Windows",
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let locked = client.read().await;
                    return Ok(locked
                        .is_property_busy(&device_name, "ABS_ROTATOR_ANGLE")
                        .await);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI rotator not connected",
                ))
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native rotator not connected",
            )),
            Some(DriverType::Simulator) => {
                let sim = crate::device_manager::ops::sim_gate::read_rotator_status().await?;
                Ok(sim.moving)
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }
}
